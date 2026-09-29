//! RefPack, the Electronic Arts LZ77 variant that compresses most members of a `.hog` archive.
//!
//! Also called QFS, and named FB10 after the two bytes its header starts with. A stream is a
//! sequence of commands, each of which copies a short run of literal bytes from the input and then
//! optionally repeats a run that already appeared in the output. Four command encodings cover
//! progressively longer matches, and a fifth ends the stream.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The second header byte. The first carries flags, so the pair is the format's signature.
pub const signature: u8 = 0xFB;

/// The first two bytes of the one form of stream the game expands, read big-endian: flags with
/// only `magic` set, then the signature. `hog_read_file` (`0x004C7F60`), `hog_read_file_as_named`
/// (`0x004C8110`) and `hog_file_size` (`0x004C81F0`) compare a member's first two bytes with it,
/// and take any other member as it is stored.
pub const game_magic: u16 = 0x10FB;

/// The flags byte and the signature.
const signature_len = 2;

/// The shortest header: 3-byte sizes, and no compressed size.
pub const min_header_len = signature_len + 3;

/// The longest header: 4-byte sizes, and both of them.
pub const max_header_len = signature_len + 2 * 4;

pub const Header = struct {
    flags: Flags,
    /// Present only when `flags.compressed_size_present`.
    compressed_size: ?u32,
    decompressed_size: u32,
    /// Bytes the header occupies.
    len: usize,

    pub const Flags = packed struct(u8) {
        /// Sizes are 4 bytes rather than 3.
        compressed_size_present: bool,
        _unused: u3,
        /// Set on every stream seen in this game; part of the signature in practice.
        magic: u1,
        _unused2: u2,
        /// Sizes are 4 bytes rather than 3.
        wide_sizes: bool,

        /// The bytes each size takes.
        pub fn sizeWidth(flags: Flags) usize {
            return if (flags.wide_sizes) 4 else 3;
        }
    };

    pub fn sizeWidth(header: Header) usize {
        return header.flags.sizeWidth();
    }
};

pub const Error = error{
    /// The stream does not start with a RefPack header.
    BadSignature,
    /// A command runs past the end of the input.
    UnexpectedEnd,
    /// A back-reference points before the start of the output.
    BadReference,
    /// The commands produced a different amount of data than the header promised.
    SizeMismatch,
};

/// Reads the header at the start of `data`.
pub fn readHeader(data: []const u8) Error!Header {
    if (!looksCompressed(data)) return error.BadSignature;
    const flags: Header.Flags = @bitCast(data[0]);

    const width = flags.sizeWidth();
    var pos: usize = signature_len;

    var compressed_size: ?u32 = null;
    if (flags.compressed_size_present) {
        if (data.len < pos + width) return error.UnexpectedEnd;
        compressed_size = std.mem.readVarInt(u32, data[pos..][0..width], .big);
        pos += width;
    }
    if (data.len < pos + width) return error.UnexpectedEnd;
    const decompressed_size = std.mem.readVarInt(u32, data[pos..][0..width], .big);
    pos += width;

    return .{
        .flags = flags,
        .compressed_size = compressed_size,
        .decompressed_size = decompressed_size,
        .len = pos,
    };
}

/// True when `data` begins with a RefPack header, whatever its flags.
pub fn looksCompressed(data: []const u8) bool {
    return data.len >= signature_len and data[1] == signature;
}

/// True when `data` begins as the one form of stream the game expands (`game_magic`).
pub fn gameExpands(data: []const u8) bool {
    return data.len >= signature_len and std.mem.readInt(u16, data[0..signature_len], .big) == game_magic;
}

/// One decoded command: copy `literals` bytes straight through, then repeat `match_len` bytes
/// from `match_distance` back in the output.
const Command = struct {
    literals: usize,
    match_len: usize,
    match_distance: usize,
    last: bool,

    /// Decodes the command at the start of `input`, returning it and its encoded length.
    fn decode(input: []const u8) Error!struct { Command, usize } {
        if (input.len < 1) return error.UnexpectedEnd;
        const b0 = input[0];

        // Short match: 2 bytes, distances up to 1024 and matches of 3 to 10.
        if (b0 < 0x80) {
            if (input.len < 2) return error.UnexpectedEnd;
            const b1 = input[1];
            return .{ .{
                .literals = b0 & 0x03,
                .match_len = ((b0 & 0x1C) >> 2) + 3,
                .match_distance = (@as(usize, b0 & 0x60) << 3) + b1 + 1,
                .last = false,
            }, 2 };
        }

        // Medium match: 3 bytes, distances up to 16384 and matches of 4 to 67.
        if (b0 < 0xC0) {
            if (input.len < 3) return error.UnexpectedEnd;
            const b1 = input[1];
            const b2 = input[2];
            return .{ .{
                .literals = (b1 >> 6) & 0x03,
                .match_len = (b0 & 0x3F) + 4,
                .match_distance = (@as(usize, b1 & 0x3F) << 8) + b2 + 1,
                .last = false,
            }, 3 };
        }

        // Long match: 4 bytes, distances up to 131072 and matches of 5 to 1028.
        if (b0 < 0xE0) {
            if (input.len < 4) return error.UnexpectedEnd;
            const b1 = input[1];
            const b2 = input[2];
            const b3 = input[3];
            return .{ .{
                .literals = b0 & 0x03,
                .match_len = (@as(usize, b0 & 0x0C) << 6) + b3 + 5,
                .match_distance = (@as(usize, b0 & 0x10) << 12) + (@as(usize, b1) << 8) + b2 + 1,
                .last = false,
            }, 4 };
        }

        // Literal run of 4 to 112 bytes, in multiples of four. No match follows.
        if (b0 < 0xFC) {
            return .{ .{
                .literals = (@as(usize, b0 & 0x1F) << 2) + 4,
                .match_len = 0,
                .match_distance = 0,
                .last = false,
            }, 1 };
        }

        // End of stream, with up to three trailing literals.
        return .{ .{
            .literals = b0 & 0x03,
            .match_len = 0,
            .match_distance = 0,
            .last = true,
        }, 1 };
    }
};

/// Decompresses a complete RefPack stream, header included.
pub fn decompressAlloc(gpa: Allocator, stream: []const u8) (Error || Allocator.Error)![]u8 {
    const header = try readHeader(stream);
    const out = try gpa.alloc(u8, header.decompressed_size);
    errdefer gpa.free(out);
    const written = try decompressInto(out, stream[header.len..]);
    if (written != out.len) return error.SizeMismatch;
    return out;
}

/// Decompresses the command stream in `input` into `out`, returning the number of bytes written.
/// `input` starts after the header.
pub fn decompressInto(out: []u8, input: []const u8) Error!usize {
    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (true) {
        const command, const encoded_len = try Command.decode(input[in_pos..]);
        in_pos += encoded_len;

        if (input.len - in_pos < command.literals) return error.UnexpectedEnd;
        if (out.len - out_pos < command.literals) return error.SizeMismatch;
        @memcpy(out[out_pos..][0..command.literals], input[in_pos..][0..command.literals]);
        in_pos += command.literals;
        out_pos += command.literals;

        if (command.last) return out_pos;

        if (command.match_distance > out_pos) return error.BadReference;
        if (out.len - out_pos < command.match_len) return error.SizeMismatch;
        // Runs may overlap their own output, so copy one byte at a time rather than @memcpy.
        var source = out_pos - command.match_distance;
        for (0..command.match_len) |_| {
            out[out_pos] = out[source];
            out_pos += 1;
            source += 1;
        }
    }
}

/// The most a stream can expand to: the game reads the size as 3 bytes (`hog_unpack`,
/// `0x004C8480`), and has no path for the wide sizes.
pub const max_size: usize = 0xFF_FFFF;

/// The room `hog_unpack` (`0x004C8480`) leaves beyond a member's expanded size (`0x2800`). It reads
/// the compressed bytes to the end of that allocation and expands from its start, so the output
/// overtakes the input that is left unless the stream keeps within it: see `inPlaceExcess`.
pub const in_place_slack: usize = 0x2800;

/// The furthest back a match reaches. The long form's field holds a distance of 131072, but the
/// longest one in the game's own streams is 131071, and the encoder keeps to that.
const max_distance: usize = 0x1FFFF;

/// The longest match the long form holds.
const max_match: usize = 1028;

/// The longest literal run: the control bytes `0xE0` to `0xFB` count it in fours from 4.
const max_run: usize = 112;

/// How many earlier positions with the same three bytes the encoder tries for a match.
const chain_depth: usize = 64;

/// The positions' hash table has `1 << hash_bits` entries, and the chains through them a slot for
/// each position of the window.
const hash_bits = 16;
const window_size: usize = 1 << 17;
const window_mask: usize = window_size - 1;
const no_position = std.math.maxInt(u32);

pub const CompressError = error{
    /// The data is more than `max_size` bytes, which the header cannot hold.
    TooLarge,
    /// The stream would not survive the game's in-place expansion (`inPlaceExcess` is over
    /// `in_place_slack`), and the game does not check: it overwrites the heap. Store the data as it
    /// is.
    NotInPlace,
} || Allocator.Error;

/// Compresses `data` into a stream of the one form the game expands (`10 FB`, a 3-byte size), that
/// the game's own expansion and `decompressAlloc` both give back as `data`. The caller owns the
/// bytes.
///
/// This is not EA's compressor and does not reproduce its bytes: it is a lazy parse over hash
/// chains, which takes each match in the smallest of the three forms that holds it. Where a stream
/// would not load, `error.NotInPlace`, or `error.TooLarge`, the data has to be stored as it is; the
/// game reads a member that does not begin `10 FB` verbatim. Data that itself begins `10 FB` cannot
/// be stored as it is, since the game would take it for a stream.
pub fn compressAlloc(gpa: Allocator, data: []const u8) CompressError![]u8 {
    return compressWithin(gpa, data, in_place_slack);
}

fn compressWithin(gpa: Allocator, data: []const u8, slack: usize) CompressError![]u8 {
    if (data.len > max_size) return error.TooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, min_header_len + data.len / 2 + 16);
    try out.appendSlice(gpa, &.{
        @intCast(game_magic >> 8),
        signature,
        @intCast(data.len >> 16),
        @intCast((data.len >> 8) & 0xFF),
        @intCast(data.len & 0xFF),
    });

    var finder: Finder = try .init(gpa, data);
    defer finder.deinit(gpa);

    // The literals since the last match wait in `data[pending..pos]`.
    var pending: usize = 0;
    var pos: usize = 0;
    var found = finder.best(0);
    while (pos < data.len) {
        finder.insert(pos);
        if (found) |match| {
            // A match one byte on is taken instead when it saves more, and the byte here waits.
            const next = finder.best(pos + 1);
            if (next == null or next.?.saving() <= match.saving()) {
                try writeMatch(gpa, &out, data, pending, pos, match);
                for (pos + 1..pos + match.len) |inside| finder.insert(inside);
                pos += match.len;
                pending = pos;
                found = finder.best(pos);
                continue;
            }
            found = next;
        } else {
            found = finder.best(pos + 1);
        }
        pos += 1;
    }

    const rest = try writeRuns(gpa, &out, data, pending, data.len);
    try out.append(gpa, 0xFC | @as(u8, @intCast(data.len - rest)));
    try out.appendSlice(gpa, data[rest..]);

    // The stream is the encoder's own, so it reads back.
    const excess = inPlaceExcess(out.items) catch unreachable;
    if (excess > @as(i64, @intCast(slack))) return error.NotInPlace;
    return out.toOwnedSlice(gpa);
}

/// A match found in what the encoder has already passed.
const Match = struct {
    distance: usize,
    len: usize,

    /// The bytes of the smallest form that holds it, which the game's own compressor never goes
    /// above; null where none does. The 2-byte form takes 3 to 10 within 1024, the 3-byte one 4 to
    /// 67 within 16384, and the 4-byte one 5 to 1028.
    fn cost(match: Match) ?usize {
        if (match.distance <= 1024 and match.len >= 3 and match.len <= 10) return 2;
        if (match.distance <= 16384 and match.len >= 4 and match.len <= 67) return 3;
        if (match.len >= 5 and match.len <= max_match) return 4;
        return null;
    }

    /// How many bytes it saves over writing what it covers as literals.
    fn saving(match: Match) isize {
        return @as(isize, @intCast(match.len)) - @as(isize, @intCast(match.cost().?));
    }
};

/// Finds matches by chaining the earlier positions that begin with the same three bytes.
const Finder = struct {
    data: []const u8,
    /// The newest position of each hash.
    head: []u32,
    /// The position before each one, in the same chain, by its place in the window.
    prev: []u32,

    fn init(gpa: Allocator, data: []const u8) Allocator.Error!Finder {
        const head = try gpa.alloc(u32, 1 << hash_bits);
        errdefer gpa.free(head);
        @memset(head, no_position);
        const prev = try gpa.alloc(u32, window_size);
        return .{ .data = data, .head = head, .prev = prev };
    }

    fn deinit(finder: Finder, gpa: Allocator) void {
        gpa.free(finder.head);
        gpa.free(finder.prev);
    }

    fn hash(finder: Finder, pos: usize) usize {
        const bytes = finder.data[pos..][0..3];
        const value = @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16;
        return (value *% 0x9E3779B1) >> (32 - hash_bits);
    }

    /// Makes the position available to matches from later ones.
    fn insert(finder: *Finder, pos: usize) void {
        if (pos + 3 > finder.data.len) return;
        const slot = finder.hash(pos);
        finder.prev[pos & window_mask] = finder.head[slot];
        finder.head[slot] = @intCast(pos);
    }

    /// The match at `pos` that saves the most, the newest among equals.
    fn best(finder: Finder, pos: usize) ?Match {
        if (pos + 3 > finder.data.len) return null;
        const data = finder.data;
        const limit = @min(data.len - pos, max_match);

        var found: ?Match = null;
        var candidate = finder.head[finder.hash(pos)];
        var tries: usize = 0;
        while (candidate != no_position and tries < chain_depth) : (tries += 1) {
            const distance = pos - candidate;
            if (distance > max_distance) break;

            var len: usize = 0;
            while (len < limit and data[candidate + len] == data[pos + len]) len += 1;
            const match: Match = .{ .distance = distance, .len = len };
            if (match.cost() != null and (found == null or match.saving() > found.?.saving()))
                found = match;
            if (len == limit) break;

            // A slot the window has come round to holds a newer position, which ends the chain.
            const before = finder.prev[candidate & window_mask];
            if (before >= candidate) break;
            candidate = before;
        }
        return found;
    }
};

/// Writes `data[from..to]` as literal runs of 4 to 112 bytes, leaving up to three bytes for the
/// command that follows to carry, and returns where those begin.
fn writeRuns(gpa: Allocator, out: *std.ArrayList(u8), data: []const u8, from: usize, to: usize) Allocator.Error!usize {
    var at = from;
    while (to - at > 3) {
        const run = @min(max_run, (to - at) & ~@as(usize, 3));
        try out.append(gpa, 0xE0 | @as(u8, @intCast(run / 4 - 1)));
        try out.appendSlice(gpa, data[at..][0..run]);
        at += run;
    }
    return at;
}

/// Writes the literals waiting in `data[from..pos]`, then `match` at `pos`, with the last 0 to 3 of
/// the literals carried by its command.
fn writeMatch(gpa: Allocator, out: *std.ArrayList(u8), data: []const u8, from: usize, pos: usize, match: Match) Allocator.Error!void {
    const carried_at = try writeRuns(gpa, out, data, from, pos);
    const carried: u8 = @intCast(pos - carried_at);
    const back: u32 = @intCast(match.distance - 1);
    const len: u32 = @intCast(match.len);

    switch (match.cost().?) {
        2 => try out.appendSlice(gpa, &.{
            @intCast((back >> 8) << 5 | (len - 3) << 2 | carried),
            @intCast(back & 0xFF),
        }),
        3 => try out.appendSlice(gpa, &.{
            @intCast(0x80 | (len - 4)),
            @intCast(@as(u32, carried) << 6 | back >> 8),
            @intCast(back & 0xFF),
        }),
        else => try out.appendSlice(gpa, &.{
            @intCast(0xC0 | (back >> 16) << 4 | ((len - 5) >> 8) << 2 | carried),
            @intCast((back >> 8) & 0xFF),
            @intCast(back & 0xFF),
            @intCast((len - 5) & 0xFF),
        }),
    }
    try out.appendSlice(gpa, data[carried_at..pos]);
}

/// How far the game's in-place expansion of `stream` (`hog_unpack`, `0x004C8480`) comes to the
/// slack it has: the most, over the start of the stream and after each of its commands, by which
/// the input still to read exceeds the output still to write. The stream loads while this is at
/// most `in_place_slack`.
///
/// `hog_unpack` allocates the expanded size and `in_place_slack` more, reads the stream to the end of
/// that, and expands from the start of the same block. The output must not reach input not yet
/// read, and the expansion checks nothing (`0x004CC350`), so a stream over the bound expands into
/// its own commands and smashes the heap. That happens at the start, where the stream is longer than
/// the data by more than the slack, or later, after a run of matches has put the output well ahead
/// and literals then take the input past it. The retail streams are all far inside: the largest
/// value is 486 (`smp3d.fat`).
///
/// `stream` must be of the form the game expands (`gameExpands`).
pub fn inPlaceExcess(stream: []const u8) Error!i64 {
    if (!gameExpands(stream)) return error.BadSignature;
    const header = try readHeader(stream);
    const total: i64 = @intCast(stream.len);
    const size: i64 = header.decompressed_size;

    var read: usize = header.len;
    var written: i64 = 0;
    var worst = total - size;
    while (true) {
        const command, const encoded_len = try Command.decode(stream[read..]);
        read += encoded_len;
        if (stream.len - read < command.literals) return error.UnexpectedEnd;
        read += command.literals;
        written += @intCast(command.literals);
        if (!command.last) written += @intCast(command.match_len);
        worst = @max(worst, (total - @as(i64, @intCast(read))) - (size - written));
        if (command.last) return worst;
    }
}

test readHeader {
    const header = try readHeader(&.{ 0x10, 0xFB, 0x08, 0xB5, 0xA8 });
    try std.testing.expectEqual(@as(u32, 0x08B5A8), header.decompressed_size);
    try std.testing.expectEqual(@as(?u32, null), header.compressed_size);
    try std.testing.expectEqual(@as(usize, 5), header.len);
    try std.testing.expect(!header.flags.wide_sizes);

    // With a compressed size, and with wide sizes.
    const with_both = try readHeader(&.{ 0x81, 0xFB, 0, 0, 0x10, 0x00, 0, 0, 0x20, 0x00 });
    try std.testing.expectEqual(@as(?u32, 0x1000), with_both.compressed_size);
    try std.testing.expectEqual(@as(u32, 0x2000), with_both.decompressed_size);
    try std.testing.expectEqual(@as(usize, 10), with_both.len);
    try std.testing.expectEqual(max_header_len, with_both.len);
    try std.testing.expectEqual(min_header_len, header.len);

    try std.testing.expectError(error.BadSignature, readHeader(&.{ 0x10, 0x00, 0, 0, 0 }));
    try std.testing.expectError(error.BadSignature, readHeader(&.{0x10}));
    try std.testing.expectError(error.UnexpectedEnd, readHeader(&.{ 0x81, 0xFB, 0, 0, 0x10, 0x00, 0, 0, 0x20 }));
}

test gameExpands {
    try std.testing.expect(gameExpands(&.{ 0x10, 0xFB, 0x00, 0x00, 0x0C }));
    // Other flags make RefPack all the same, but the game takes such a member as it is stored.
    try std.testing.expect(looksCompressed(&.{ 0x11, 0xFB }) and !gameExpands(&.{ 0x11, 0xFB }));
    try std.testing.expect(!gameExpands(&.{0x10}));
    try std.testing.expect(!gameExpands("RIFF"));
}

test "literal run then end" {
    // 0xE0: four literals. 0xFC: end with no trailing literals.
    var out: [4]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0xE0, 'a', 'b', 'c', 'd', 0xFC });
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqualStrings("abcd", &out);
}

test "short match repeats earlier output" {
    // 0xE0 -> 4 literals "abcd"; then a short match: b0=0x04 gives 0 literals and length
    // ((0x04 & 0x1C) >> 2) + 3 = 4, b1=3 gives distance 4; then 0xFC ends.
    var out: [8]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0xE0, 'a', 'b', 'c', 'd', 0x04, 0x03, 0xFC });
    try std.testing.expectEqual(@as(usize, 8), written);
    try std.testing.expectEqualStrings("abcdabcd", &out);
}

test "overlapping match extends a run" {
    // A distance of one repeats the previous byte, so the copy reads bytes it is still writing.
    // b0 = 0x01: one literal, match length ((0x01 & 0x1C) >> 2) + 3 = 3, b1 = 0 -> distance 1.
    // 0xFE ends the stream with two trailing literals.
    var out: [6]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0x01, 0x00, 'x', 0xFE, 'y', 'z' });
    try std.testing.expectEqual(@as(usize, 6), written);
    try std.testing.expectEqualStrings("xxxxyz", &out);
}

test "truncated input is rejected" {
    var out: [16]u8 = undefined;
    try std.testing.expectError(error.UnexpectedEnd, decompressInto(&out, &.{0xE0}));
    try std.testing.expectError(error.UnexpectedEnd, decompressInto(&out, &.{0x04}));
    // A match reaching before the start of the output.
    try std.testing.expectError(error.BadReference, decompressInto(&out, &.{ 0x00, 0x00, 0xFC }));
}

test "round-trips a real stream shape" {
    const gpa = std.testing.allocator;
    // "abcdabcdabcd" as header + two commands.
    const stream = [_]u8{ 0x10, 0xFB, 0x00, 0x00, 0x0C, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC };
    const out = try decompressAlloc(gpa, &stream);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("abcdabcdabcd", out);
}

/// Compresses `data` and checks what comes back: what the port's decoder gives, and what the game's
/// expansion demands of the stream.
fn expectRoundTrip(data: []const u8) !void {
    const gpa = std.testing.allocator;
    const stream = try compressAlloc(gpa, data);
    defer gpa.free(stream);

    try std.testing.expect(gameExpands(stream));
    const header = try readHeader(stream);
    try std.testing.expectEqual(@as(u32, @intCast(data.len)), header.decompressed_size);
    try std.testing.expectEqual(min_header_len, header.len);
    try std.testing.expect(try inPlaceExcess(stream) <= @as(i64, in_place_slack));

    const expanded = try decompressAlloc(gpa, stream);
    defer gpa.free(expanded);
    try std.testing.expectEqualSlices(u8, data, expanded);
}

test compressAlloc {
    const gpa = std.testing.allocator;

    // No data is a header and the terminator.
    const empty = try compressAlloc(gpa, "");
    defer gpa.free(empty);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0xFB, 0x00, 0x00, 0x00, 0xFC }, empty);

    // Data the terminator carries alone, then data a run and the terminator carry.
    try expectRoundTrip("a");
    try expectRoundTrip("abc");
    try expectRoundTrip("abcd");
    try expectRoundTrip("abcdefghi");

    try expectRoundTrip("abcdabcdabcd");
    try expectRoundTrip("The quick brown fox jumps over the lazy dog. " ** 200);

    // One byte over and over: the matches overlap what they are writing, and the longest ones are
    // cut at 1028.
    try expectRoundTrip(&@as([100_000]u8, @splat(0)));
    try expectRoundTrip(&@as([1029]u8, @splat(7)));

    var counting: [5000]u8 = undefined;
    for (&counting, 0..) |*byte, i| byte.* = @intCast(i % 251);
    try expectRoundTrip(&counting);
}

test "compresses data of every shape" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5741_524C);
    const random = prng.random();

    var noise: [20_000]u8 = undefined;
    random.bytes(&noise);
    try expectRoundTrip(&noise);

    // Runs of noise and copies of what came before, from a byte to a few hundred back, over
    // distances that reach every form and go past the furthest one.
    const size = 400_000;
    const data = try gpa.alloc(u8, size);
    defer gpa.free(data);
    var at: usize = 0;
    while (at < size) {
        if (at > 16 and random.boolean()) {
            const distance = 1 + random.uintLessThan(usize, @min(at, 200_000));
            const len = @min(3 + random.uintLessThan(usize, 300), size - at);
            for (0..len) |i| data[at + i] = data[at + i - distance];
            at += len;
        } else {
            const len = @min(1 + random.uintLessThan(usize, 6), size - at);
            random.bytes(data[at..][0..len]);
            at += len;
        }
    }
    try expectRoundTrip(data);
}

test "each form holds the match it was written for" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { distance: usize, len: usize, bytes: usize }{
        .{ .distance = 1, .len = 3, .bytes = 2 },
        .{ .distance = 1024, .len = 10, .bytes = 2 },
        .{ .distance = 1024, .len = 3, .bytes = 2 },
        .{ .distance = 1025, .len = 4, .bytes = 3 },
        .{ .distance = 1, .len = 11, .bytes = 3 },
        .{ .distance = 16384, .len = 67, .bytes = 3 },
        .{ .distance = 16384, .len = 4, .bytes = 3 },
        .{ .distance = 1, .len = 68, .bytes = 4 },
        .{ .distance = 16385, .len = 5, .bytes = 4 },
        .{ .distance = 131071, .len = 5, .bytes = 4 },
        .{ .distance = 131071, .len = 1028, .bytes = 4 },
        .{ .distance = 500, .len = 1028, .bytes = 4 },
    };
    const literals = [_]u8{ 0xA1, 0xB2, 0xC3 };
    for (cases) |case| {
        for (0..literals.len + 1) |carried| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            const match: Match = .{ .distance = case.distance, .len = case.len };
            try std.testing.expectEqual(@as(?usize, case.bytes), match.cost());
            try writeMatch(gpa, &out, &literals, 0, carried, match);

            const command, const encoded_len = try Command.decode(out.items);
            try std.testing.expectEqual(case.bytes, encoded_len);
            try std.testing.expectEqual(carried, command.literals);
            try std.testing.expectEqual(case.len, command.match_len);
            try std.testing.expectEqual(case.distance, command.match_distance);
            try std.testing.expect(!command.last);
            // The carried literals follow the command's own bytes.
            try std.testing.expectEqualSlices(u8, literals[0..carried], out.items[encoded_len..]);
        }
    }

    // What no form holds: a short match too far, a match under 3, one over 1028.
    try std.testing.expectEqual(@as(?usize, null), (Match{ .distance = 1025, .len = 3 }).cost());
    try std.testing.expectEqual(@as(?usize, null), (Match{ .distance = 16385, .len = 4 }).cost());
    try std.testing.expectEqual(@as(?usize, null), (Match{ .distance = 1, .len = 2 }).cost());
    try std.testing.expectEqual(@as(?usize, null), (Match{ .distance = 1, .len = 1029 }).cost());
}

test "literals go in runs of at most 112 and the last few ride the next command" {
    const gpa = std.testing.allocator;
    var data: [303]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast(i % 256);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const rest = try writeRuns(gpa, &out, &data, 0, data.len);
    // 112, 112 and 76 leave 3.
    try std.testing.expectEqual(@as(usize, 300), rest);
    try std.testing.expectEqual(@as(usize, 303), out.items.len);
    try std.testing.expectEqual(@as(u8, 0xFB), out.items[0]);
    try std.testing.expectEqualSlices(u8, data[0..112], out.items[1..113]);
    try std.testing.expectEqual(@as(u8, 0xFB), out.items[113]);
    try std.testing.expectEqual(@as(u8, 0xF2), out.items[226]);

    // Three or fewer are not a run.
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), try writeRuns(gpa, &out, &data, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test inPlaceExcess {
    // `abcd`, then a match of 8 from 4 back: the stream is one byte longer than its data, all in
    // the terminator still to read, and no later point is worse.
    const short = [_]u8{ 0x10, 0xFB, 0x00, 0x00, 0x0C, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC };
    try std.testing.expectEqual(@as(i64, 1), try inPlaceExcess(&short));

    // A stream shorter than its data, and worst in the middle: three matches that each put the
    // output 6 bytes ahead of the input, then two runs of literals that take the input back. It
    // starts at -9 and stands at 3 after the third match.
    const middle = [_]u8{
        0x10, 0xFB, 0x00, 0x00, 36, // 36 bytes out
        0xE0, 'a', 'b', 'c', 'd', // 4
        0x14, 0x03, 0x14, 0x03, 0x14, 0x03, // 24 more
        0xE0, 'e', 'f', 'g', 'h', 0xE0, 'i', 'j', 'k', 'l', // 8 more
        0xFC,
    };
    try std.testing.expectEqual(@as(i64, 3), try inPlaceExcess(&middle));
    const expanded = try decompressAlloc(std.testing.allocator, &middle);
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqual(@as(usize, 36), expanded.len);

    // Only the form the game expands has a bound.
    try std.testing.expectError(error.BadSignature, inPlaceExcess(&.{ 0x11, 0xFB, 0, 0, 0, 0, 0, 0, 0xFC }));
    try std.testing.expectError(error.UnexpectedEnd, inPlaceExcess(&.{ 0x10, 0xFB, 0, 0, 4, 0xE0, 'a' }));
}

/// A stream of `size` bytes written as literals alone.
fn literalStream(gpa: Allocator, size: usize) ![]u8 {
    const data = try gpa.alloc(u8, size);
    defer gpa.free(data);
    @memset(data, 0);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x10, 0xFB, @intCast(size >> 16), @intCast((size >> 8) & 0xFF), @intCast(size & 0xFF) });
    const rest = try writeRuns(gpa, &out, data, 0, size);
    try out.append(gpa, 0xFC | @as(u8, @intCast(size - rest)));
    try out.appendSlice(gpa, data[rest..]);
    return out.toOwnedSlice(gpa);
}

test "the largest literals-only payload the game loads in place" {
    const gpa = std.testing.allocator;
    // Each run of 112 adds a control byte, and the header and the terminator add 6, and a last
    // run when 4 or more are left over: a payload of N bytes takes
    // `5 + N / 112 + (N % 112 >= 4) + 1` more than its own size. That is the slack at 1,146,211
    // bytes, and one over it at 1,146,212 ([#113](https://github.com/vdmkenny/openreliant/issues/113)).
    for ([_]usize{ 1000, 1_146_211, 1_146_212 }) |size| {
        const stream = try literalStream(gpa, size);
        defer gpa.free(stream);
        const expected: i64 = @intCast(5 + size / 112 + @intFromBool(size % 112 >= 4) + 1);
        try std.testing.expectEqual(expected, try inPlaceExcess(stream));
    }
    const at_edge = try literalStream(gpa, 1_146_211);
    defer gpa.free(at_edge);
    try std.testing.expectEqual(@as(i64, in_place_slack), try inPlaceExcess(at_edge));
    const over = try literalStream(gpa, 1_146_212);
    defer gpa.free(over);
    try std.testing.expectEqual(@as(i64, in_place_slack) + 1, try inPlaceExcess(over));
}

test "a stream the game could not load in place is refused" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(3);
    var noise: [3000]u8 = undefined;
    prng.random().bytes(&noise);

    // Noise cannot shrink, so its stream is longer than it: work out by how much, and refuse at
    // one under.
    const stream = try compressWithin(gpa, &noise, in_place_slack);
    defer gpa.free(stream);
    const excess: usize = @intCast(try inPlaceExcess(stream));
    try std.testing.expect(excess > 0);
    const at_bound = try compressWithin(gpa, &noise, excess);
    gpa.free(at_bound);
    try std.testing.expectError(error.NotInPlace, compressWithin(gpa, &noise, excess - 1));

    // More than the header holds.
    const huge = try gpa.alloc(u8, max_size + 1);
    defer gpa.free(huge);
    try std.testing.expectError(error.TooLarge, compressAlloc(gpa, huge));
}
