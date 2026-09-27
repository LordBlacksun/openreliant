//! `sltool fm8 ...`: read the pilots' face films (`.fm8`,
//! [`engine/game/talkie.zig`](../../engine/game/talkie.zig)) and save their frames as PNG files.

const std = @import("std");

const openreliant = @import("openreliant");
const png = openreliant.png;
const talkie = openreliant.engine.game.talkie;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { film: []const u8 },
    /// Writes every frame as an indexed PNG file over the film's palette.
    extract: struct { film: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  fm8 info <film>                 a face film's frames and chunks
        \\  fm8 extract <film> <out-dir>    save every frame as a PNG file
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        return switch (verb) {
            inline else => |tag| sltool.positional(Command, tag, operands),
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        const path = switch (command) {
            inline else => |operands| operands.film,
        };
        const bytes = try ctx.readInput(path);
        switch (command) {
            .info => try info(ctx, bytes),
            .extract => |operands| try extract(ctx, bytes, path, operands.out_dir),
        }
    }
};

fn info(ctx: Context, bytes: []u8) !void {
    var film: talkie.Film = .init(ctx.arena);
    defer film.deinit();
    var chunks: talkie.Chunks = .{ .bytes = bytes };
    var frames: usize = 0;
    var keys: usize = 0;
    var bad: usize = 0;
    try ctx.stdout.writeAll("   #  chunk  bytes\n");
    var index: usize = 0;
    while (chunks.next()) |chunk| : (index += 1) {
        try ctx.stdout.print("{d:>4}  {s:<5}  {d:>5}\n", .{ index, chunk.bytes[0..4], chunk.bytes.len });
        const decoded = film.decode(chunk) catch {
            bad += 1;
            continue;
        };
        if (decoded) frames += 1;
        if (chunk.id == .key) keys += 1;
    }
    try ctx.stdout.print("\n{d} frames of {d} x {d}, {d} of them key frames, {d:.2} s at {d} a second", .{ frames, film.width, film.height, keys, @as(f64, @floatFromInt(frames)) / talkie.frames_per_second, talkie.frames_per_second });
    if (film.transparent) |index_seen| try ctx.stdout.print(", see-through entry {d}", .{index_seen});
    if (bad > 0) try ctx.stdout.print(", {d} chunks not decoded", .{bad});
    try ctx.stdout.writeByte('\n');
}

fn extract(ctx: Context, bytes: []u8, source: []const u8, out_path: []const u8) !void {
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);
    const stem = std.fs.path.stem(std.fs.path.basename(source));
    var film: talkie.Film = .init(ctx.arena);
    defer film.deinit();
    var chunks: talkie.Chunks = .{ .bytes = bytes };
    var written: usize = 0;
    while (chunks.next()) |chunk| {
        const decoded = film.decode(chunk) catch |err| {
            try ctx.stdout.print("chunk {d} of {s} is not decoded: {s}\n", .{ written, source, @errorName(err) });
            continue;
        };
        if (!decoded) continue;
        const name = try std.fmt.allocPrint(ctx.arena, "{s}_{d:0>3}.png", .{ stem, written });
        defer ctx.arena.free(name);
        const file = try out_dir.createFile(io, name, .{});
        defer file.close(io);
        var buffer: [32 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try png.writeIndexed(ctx.arena, &writer.interface, .{
            .width = @intCast(film.width),
            .height = @intCast(film.height),
            .palette = &film.palette,
            .transparent = film.transparent,
        }, film.frame());
        try writer.interface.flush();
        written += 1;
    }
    try ctx.stdout.print("wrote {d} frames to {s}\n", .{ written, out_path });
}

test Command {
    const parsed = try Command.parse(&.{ "extract", "45Tigers_Plt.fm8", "frames" });
    try std.testing.expectEqualStrings("frames", parsed.extract.out_dir);
    try std.testing.expectEqualStrings("a.fm8", (try Command.parse(&.{ "info", "a.fm8" })).info.film);
    try std.testing.expectError(error.Usage, Command.parse(&.{"info"}));
}
