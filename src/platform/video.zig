//! The movies' packets, decoded by FFmpeg's Bink decoders (`deps/ffmpeg`) for the engine's
//! stand-in for Bink ([`engine/bink.zig`](../engine/bink.zig)'s `Codec`). Each decoder is set up as
//! FFmpeg's own reader of the container sets it up: the video's with the file's signature as its
//! tag and the header's flags as its extra data, an audio track's with its rate, its channels and
//! the file's signature.
//!
//! FFmpeg is built without threads, so it is used from the thread the game runs on alone.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("av");
const openreliant = @import("openreliant");
const bink = openreliant.engine.bink;

const log = std.log.scoped(.video);

/// The decoders, which hold nothing between the streams they open.
pub const Decoders = struct {
    /// Quiets FFmpeg's own messages: a packet it cannot decode fails the call, which says so.
    pub fn init() Decoders {
        c.av_log_set_level(c.AV_LOG_QUIET);
        return .{};
    }

    pub fn codec(decoders: *Decoders) bink.Codec {
        return .{ .context = decoders, .vtable = &.{
            .openVideo = openVideo,
            .openAudio = openAudio,
            .picture = picture,
            .samples = samples,
            .close = close,
        } };
    }
};

/// A stream's decoder, and the packet and frame it decodes through.
const Stream = struct {
    context: *c.AVCodecContext,
    packet: *c.AVPacket,
    frame: *c.AVFrame,

    fn of(stream: bink.Stream) *Stream {
        return @ptrCast(@alignCast(stream));
    }
};

fn openVideo(_: *anyopaque, video: bink.Video) bink.Error!bink.Stream {
    return open(c.AV_CODEC_ID_BINKVIDEO, struct {
        fn setUp(context: *c.AVCodecContext, setup: bink.Video) void {
            context.width = @intCast(setup.width);
            context.height = @intCast(setup.height);
            context.codec_tag = signature(setup.revision);
            std.mem.writeInt(u32, context.extradata[0..4], @bitCast(setup.flags), .little);
        }
    }.setUp, video);
}

fn openAudio(_: *anyopaque, audio: bink.Audio) bink.Error!bink.Stream {
    return open(if (audio.dct) c.AV_CODEC_ID_BINKAUDIO_DCT else c.AV_CODEC_ID_BINKAUDIO_RDFT, struct {
        fn setUp(context: *c.AVCodecContext, setup: bink.Audio) void {
            context.sample_rate = @intCast(setup.rate);
            c.av_channel_layout_default(&context.ch_layout, setup.channels);
            std.mem.writeInt(u32, context.extradata[0..4], signature(setup.revision), .little);
        }
    }.setUp, audio);
}

/// A decoder of `id`, its 4 bytes of extra data and the rest set by `setUp` from `setup`.
fn open(id: c.enum_AVCodecID, comptime setUp: anytype, setup: anytype) bink.Error!bink.Stream {
    const decoder = c.avcodec_find_decoder(id) orelse return error.Decoding;
    var context: ?*c.AVCodecContext = c.avcodec_alloc_context3(decoder) orelse return error.OutOfMemory;
    errdefer c.avcodec_free_context(&context);
    const extradata: [*]u8 = @ptrCast(c.av_mallocz(4 + c.AV_INPUT_BUFFER_PADDING_SIZE) orelse return error.OutOfMemory);
    context.?.extradata = extradata;
    context.?.extradata_size = 4;
    setUp(context.?, setup);
    if (c.avcodec_open2(context, decoder, null) < 0) return error.Decoding;
    var packet: ?*c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
    errdefer c.av_packet_free(&packet);
    const frame: ?*c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
    const stream = std.heap.c_allocator.create(Stream) catch {
        var unused = frame;
        c.av_frame_free(&unused);
        return error.OutOfMemory;
    };
    stream.* = .{ .context = context.?, .packet = packet.?, .frame = frame.? };
    return stream;
}

/// The Bink signature a movie of `revision` starts with, as a tag.
fn signature(revision: u8) c_uint {
    return std.mem.readInt(u32, &[4]u8{ 'B', 'I', 'K', revision }, .little);
}

/// Hands `packet` to the stream's decoder, in a buffer padded as FFmpeg reads past a packet's end.
fn send(stream: *Stream, packet: []const u8) bink.Error!void {
    if (c.av_new_packet(stream.packet, @intCast(packet.len)) < 0) return error.OutOfMemory;
    defer c.av_packet_unref(stream.packet);
    @memcpy(stream.packet.data[0..packet.len], packet);
    if (c.avcodec_send_packet(stream.context, stream.packet) < 0) return error.Decoding;
}

fn picture(_: *anyopaque, handle: bink.Stream, packet: []const u8) bink.Error!bink.Picture {
    const stream: *Stream = .of(handle);
    try send(stream, packet);
    if (c.avcodec_receive_frame(stream.context, stream.frame) < 0) return error.Decoding;
    const frame = stream.frame;
    const width: u32 = @intCast(frame.width);
    const height: u32 = @intCast(frame.height);
    const half = (height + 1) / 2;
    var strides: [4]usize = undefined;
    for (&strides, frame.linesize[0..4]) |*stride, size| stride.* = @intCast(@max(size, 0));
    return .{
        .width = width,
        .height = height,
        .y = frame.data[0][0 .. strides[0] * height],
        .u = frame.data[1][0 .. strides[1] * half],
        .v = frame.data[2][0 .. strides[2] * half],
        .alpha = if (frame.format == c.AV_PIX_FMT_YUVA420P) frame.data[3][0 .. strides[3] * height] else null,
        .strides = strides,
    };
}

fn samples(_: *anyopaque, handle: bink.Stream, packet: []const u8, gpa: Allocator, pcm: *std.ArrayList(i16)) bink.Error!void {
    const stream: *Stream = .of(handle);
    try send(stream, packet);
    const frame = stream.frame;
    while (true) {
        const received = c.avcodec_receive_frame(stream.context, frame);
        if (received == -c.EAGAIN or received == c.AVERROR_EOF) return;
        if (received < 0) return error.Decoding;
        defer c.av_frame_unref(frame);
        const count: usize = @intCast(frame.nb_samples);
        const channels: usize = @intCast(frame.ch_layout.nb_channels);
        const out = try pcm.addManyAsSlice(gpa, count * channels);
        if (frame.format == c.AV_SAMPLE_FMT_FLTP) {
            for (0..channels) |channel| {
                const plane: [*]const f32 = @ptrCast(@alignCast(frame.extended_data[channel]));
                for (0..count) |at| out[at * channels + channel] = sample16(plane[at]);
            }
        } else {
            const interleaved: [*]const f32 = @ptrCast(@alignCast(frame.data[0]));
            for (out, interleaved[0..out.len]) |*to, from| to.* = sample16(from);
        }
    }
}

/// A float sample from -1 to 1 as a 16-bit one, rounded to the nearest and a half to the even one,
/// as FFmpeg's own conversion rounds (`lrintf`).
fn sample16(level: f32) i16 {
    const scaled = level * 32768;
    var rounded = @round(scaled);
    if (@abs(scaled - @trunc(scaled)) == 0.5 and @mod(rounded, 2) != 0) rounded -= std.math.sign(scaled);
    return @intFromFloat(std.math.clamp(rounded, -32768, 32767));
}

fn close(_: *anyopaque, handle: bink.Stream) void {
    const stream: *Stream = .of(handle);
    var context: ?*c.AVCodecContext = stream.context;
    var packet: ?*c.AVPacket = stream.packet;
    var frame: ?*c.AVFrame = stream.frame;
    c.avcodec_free_context(&context);
    c.av_packet_free(&packet);
    c.av_frame_free(&frame);
    std.heap.c_allocator.destroy(stream);
}

test sample16 {
    try std.testing.expectEqual(0, sample16(0));
    try std.testing.expectEqual(16384, sample16(0.5));
    // A half goes to the even one.
    try std.testing.expectEqual(2, sample16(2.5 / 32768.0));
    try std.testing.expectEqual(-2, sample16(-2.5 / 32768.0));
    try std.testing.expectEqual(4, sample16(3.5 / 32768.0));
    try std.testing.expectEqual(32767, sample16(1.5));
    try std.testing.expectEqual(-32768, sample16(-1));
}

test "a damaged packet fails, and the decoder closes" {
    var decoders: Decoders = .init();
    const codec = decoders.codec();
    const video = try codec.openVideo(.{ .revision = 'f', .width = 16, .height = 16, .flags = .{} });
    defer codec.close(video);
    try std.testing.expectError(error.Decoding, codec.picture(video, &.{ 0xFF, 0xFF }));
    const audio = try codec.openAudio(.{ .revision = 'f', .rate = 22050, .channels = 2, .dct = false });
    var pcm: std.ArrayList(i16) = .empty;
    defer pcm.deinit(std.testing.allocator);
    try std.testing.expectError(error.Decoding, codec.samples(audio, &.{ 1, 2 }, std.testing.allocator, &pcm));
    codec.close(audio);
}
