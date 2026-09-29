//! The discs' archives, `CD1.HOG` and `CD2.HOG`, which hold the movies of the campaign's flights,
//! its briefings and the Reliant's rooms. `cd_hog_open` (`0x0042FE00`) opens the one a part of
//! the game needs as it comes to it, in place of the one open (`cd_hog`, `0x005202D4`).
//!
//! The game reads an archive from the disc in the drive (`cd_in_drive`, `0x004AC6C0`), asking for
//! the other disc where the drive holds the wrong one; or, in a full install (`full_install`,
//! `0x005D62C4`), from the installation's folder, where both archives lie (`cd1_folder`,
//! `0x005D6A28`; `cd2_folder`, `0x005D6928`). OpenReliant reads them as a full install does:
//! `openreliant install` copies both into the game's folder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const files = @import("../../files.zig");
const bigfile = @import("../bigfile.zig");

const log = std.log.scoped(.disc);

/// The discs, by the number the game names each archive by.
pub const Number = enum(u8) {
    one = 1,
    two = 2,

    /// The archive's name, `cd%d.hog` (`0x004E866C`).
    pub fn archiveName(number: Number) []const u8 {
        return switch (number) {
            inline else => |disc| std.fmt.comptimePrint("cd{d}.hog", .{@intFromEnum(disc)}),
        };
    }
};

/// The disc's archive open (`cd_hog`).
pub const Disc = struct {
    gpa: Allocator,
    io: Io,
    /// The game's folder, which holds both archives as a full install's folder does.
    directory: Io.Dir,
    hog: ?bigfile.Hog = null,

    /// `cd_hog_open` (`0x0042FE00`) in a full install: disc `number`'s archive, found in the
    /// game's folder whatever the case of its name, opened in place of the one open
    /// (`hog_close`). Where it cannot be opened, the game stops with `Can't open HOG resource file
    /// %s`; OpenReliant goes on without it, and leaves out the movies it holds.
    pub fn open(disc: *Disc, number: Number) void {
        disc.close();
        const name = number.archiveName();
        var buffer: [files.max_path]u8 = undefined;
        const path = files.find(disc.io, disc.directory, name, &buffer) orelse {
            log.warn("the game's folder has no {s}: the movies of disc {d} are left out", .{ name, @intFromEnum(number) });
            return;
        };
        disc.hog = bigfile.Hog.open(disc.gpa, disc.io, disc.directory, path) catch |err| {
            log.warn("{s} can't be opened: {s}; the movies of disc {d} are left out", .{ path, @errorName(err), @intFromEnum(number) });
            return;
        };
    }

    pub fn close(disc: *Disc) void {
        if (disc.hog) |*hog| hog.close(disc.gpa);
        disc.hog = null;
    }

    /// The member `name` of the archive open, as it is stored (`bigfile.Hog.readStored`); null
    /// where no archive is open, or it has none.
    pub fn readStored(disc: Disc, gpa: Allocator, name: []const u8) bigfile.ReadError!?[]u8 {
        const hog = disc.hog orelse return null;
        return hog.readStored(gpa, name);
    }
};

test Number {
    try std.testing.expectEqualStrings("cd1.hog", Number.one.archiveName());
    try std.testing.expectEqualStrings("cd2.hog", Number.two.archiveName());
}

test Disc {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // The installer names the second disc's archive as the disc does.
    try bigfile.testing.write(gpa, io, tmp.dir, "CD2.HOG", &.{.{ .name = "r_h_ta.bik", .data = "BIKf" }});

    var disc: Disc = .{ .gpa = gpa, .io = io, .directory = tmp.dir };
    defer disc.close();
    try std.testing.expectEqual(null, try disc.readStored(gpa, "r_h_ta.bik"));
    disc.open(.two);
    try std.testing.expect(disc.hog != null);
    const movie = (try disc.readStored(gpa, "R_H_TA.BIK")).?;
    defer gpa.free(movie);
    try std.testing.expectEqualStrings("BIKf", movie);
    try std.testing.expectEqual(null, try disc.readStored(gpa, "y_h_ta.bik"));

    // The first disc's archive is missing: the second is closed all the same, and nothing is open.
    disc.open(.one);
    try std.testing.expectEqual(null, disc.hog);
}
