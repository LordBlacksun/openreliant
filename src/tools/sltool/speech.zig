//! `sltool speech ...`: decode the radio's speech files, `.ut`, of the game's own codec
//! ([`engine/game/voice.zig`](../../engine/game/voice.zig)), to WAV, the samples as the game
//! makes them.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const cbox = openreliant.engine.game.cbox;
const hog = openreliant.hog;
const wave = openreliant.wave;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    decode: struct { file: []const u8, out: []const u8 },
    /// Decodes every member that is a speech file.
    extract: struct { archive: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  speech decode <file> <out.wav>  decode a speech file to a WAV file
        \\  speech extract <archive> <out-dir>
        \\                                  decode every line of a speech archive to WAV files
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        return switch (verb) {
            inline else => |tag| sltool.positional(Command, tag, operands),
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        switch (command) {
            .decode => |operands| try decode(ctx, operands.file, operands.out),
            .extract => |operands| try extract(ctx, operands.archive, operands.out_dir),
        }
    }
};

fn decode(ctx: Context, path: []const u8, out: []const u8) !void {
    const bytes = try ctx.readInput(path);
    const speech = cbox.Speech.parse(bytes) orelse return error.NotASpeechFile;
    const samples = try cbox.decode(ctx.arena, speech, .cut);
    const file = try wave.pcm16(ctx.arena, cbox.rate, 1, samples);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = out, .data = file });
    try ctx.stdout.print("wrote {d} samples, {d:.2} s, to {s}\n", .{ samples.len, @as(f64, @floatFromInt(samples.len)) / cbox.rate, out });
}

fn extract(ctx: Context, path: []const u8, out_path: []const u8) !void {
    const io = ctx.io;
    var archive = try hog.Archive.open(ctx.arena, io, .cwd(), path);
    defer archive.close(ctx.arena);
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);
    // Each line's bytes, samples and file live only as long as it takes to write it.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var written: usize = 0;
    var skipped: usize = 0;
    for (archive.entries) |entry| {
        _ = scratch.reset(.retain_capacity);
        const gpa = scratch.allocator();
        const contents = try archive.read(gpa, entry);
        const speech = cbox.Speech.parse(contents.bytes) orelse {
            skipped += 1;
            continue;
        };
        const samples = try cbox.decode(gpa, speech, .cut);
        const file = try wave.pcm16(gpa, cbox.rate, 1, samples);
        const name = try std.fmt.allocPrint(gpa, "{s}.wav", .{entry.name});
        try out_dir.writeFile(io, .{ .sub_path = name, .data = file });
        written += 1;
    }
    try ctx.stdout.print("wrote {d} lines to {s}", .{ written, out_path });
    if (skipped > 0) try ctx.stdout.print(", {d} members not speech files left out", .{skipped});
    try ctx.stdout.writeByte('\n');
}

test Command {
    const parsed = try Command.parse(&.{ "decode", "ms1_ban_001", "out.wav" });
    try std.testing.expectEqualStrings("out.wav", parsed.decode.out);
    try std.testing.expectEqualStrings("lines", (try Command.parse(&.{ "extract", "msspeech.hog", "lines" })).extract.out_dir);
    try std.testing.expectError(error.Usage, Command.parse(&.{"decode"}));
}
