//! The movies the game plays in a loop of their own: `play_bink_movie` (`0x004AB850`) and
//! `play_bink_movie_no_clear` (`0x004AB6E0`), which differ in the rate and the screen they play on
//! (`Kind`). As the renderer starts for the first time, `renderer_load` plays the intro (`intro`);
//! `WinMain` plays the splash's way into the main menu (`splash_to_menu`) before it opens the front
//! end; and the front end's screens play their transitions as they lead from one to another.
//!
//! A pass of the loop (`0x004AB7B2`) runs the message pump and reads the keyboard and the pointer;
//! Escape, the pointer's right button, the movie's end or the game quitting ends it. Otherwise the
//! next frame shows once it is due (`bink_frame`, `play`), copied into the middle of the screen.
//! A movie whose file cannot be opened stops the game with a message
//! (`play_bink_movie: error loading %s.`); OpenReliant goes on without it.
//!
//! **Improvement:** OpenReliant draws a movie as large as fits in the window, as it draws the front
//! end, so that a 16:9 movie fills a wide window (`Size`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const bink = @import("../../bink.zig");
const input = @import("../../input.zig");
const mss = @import("../../mss.zig");
const hud = @import("../hud.zig");
const canvas = @import("../interface/canvas.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const device = @import("../../surrender/srd3d/device.zig");
const container = @import("../../../formats/bink.zig");

/// The movies `renderer_load` plays as the renderer first starts (`0x004AB4D5` on), before its
/// loading screens.
pub const intro = [_][]const u8{ "new_nms.bik", "new_dalogo_fs_uncmpr.bik", "warty_.bik" };

/// The movie `0x004AB6A0` plays as `WinMain` opens the front end, from the splash into the main
/// menu (`0x0050A31C`).
pub const splash_to_menu = "splash to mm.bik";

/// The transitions between the front end's screens ported (`0x004E8240`, `0x004E8680`): SINGLE
/// PLAYER's from the main menu into the pilot roster, and the pilot roster's MAIN MENU's and
/// Escape's back.
pub const main_to_single = "interface\\main2sin.bik";
pub const single_to_main = "interface\\sin2main.bik";

/// How a movie plays.
pub const Kind = enum {
    /// `play_bink_movie`: at the movie's rate, on a screen it clears to black first. `renderer_load`
    /// plays the intro so.
    cleared,
    /// `play_bink_movie_no_clear`: at 15 frames a second (`transition_rate`), over what the screen
    /// last showed. The front end's transitions play so.
    over_screen,

    /// Whether it plays: the video settings' `Transitions` (`[Device]`, 1 unless set) leaves the
    /// transitions out, and the intro on a renderer that is not a hardware one.
    pub fn plays(kind: Kind, transitions: bool, hardware: bool) bool {
        return transitions or (kind == .cleared and hardware);
    }
};

/// How large a movie is drawn.
pub const Size = enum {
    /// **Improvement:** as large as fits in the window.
    fitted,
    /// At its size in the middle of the front end's screen, as the game draws it on a screen 640
    /// by 480.
    screen,
};

/// The rate `play_bink_movie_no_clear` plays at, whatever the movie's (`BinkSetFrameRate` with
/// `BINKFRAMERATE`, `0x004AB752`).
pub const transition_rate: bink.Rate = .{ .frames = 15, .seconds = 1 };

/// A movie playing, and the screen its frames are copied into.
pub const Player = struct {
    gpa: Allocator,
    bink: bink.Bink,
    /// The frames, the movie's size, in RGBA (`BinkCopyToBuffer`), and its pixels, which the
    /// picture holds.
    picture: srtexture.Image,
    pixels: []u8,
    /// Whether its last frame has shown (`0x005D6C90`).
    ended: bool = false,

    /// Opens the movie of `file`, which it takes, to play as `kind` has it, its sound through
    /// `sound` where there is one, and its pictures with OpenReliant's `look`.
    pub fn open(gpa: Allocator, codec: bink.Codec, file: []const u8, kind: Kind, sound: ?mss.Driver, look: bink.Look) bink.Error!Player {
        var movie: bink.Bink = try .open(gpa, codec, file, .{
            .rate = if (kind == .over_screen) transition_rate else null,
            .sound = sound,
            .look = look,
        });
        errdefer movie.close();
        const rgba = try gpa.alloc(u8, @as(usize, movie.width) * movie.height * 4);
        @memset(rgba, 0);
        var picture = srtexture.Image.single(gpa, movie.width, movie.height, rgba) catch |err| {
            gpa.free(rgba);
            return err;
        };
        picture.magnify = .edge_adaptive;
        return .{ .gpa = gpa, .bink = movie, .picture = picture, .pixels = rgba };
    }

    pub fn close(player: *Player) void {
        player.picture.deinit(player.gpa);
        player.bink.close();
    }

    /// A pass of the loop at `now`, the keyboard read and whether the pointer's right button is
    /// down: whether the movie is over.
    pub fn pass(player: *Player, keyboard: *input.Keyboard, right_down: bool, now: u64) bink.Error!bool {
        if (keyboard.pressed(input.scan.escape, .none, true) or player.ended or right_down) return true;
        if (player.bink.wait(now)) return false;
        try player.play(now);
        return false;
    }

    /// `bink_frame` (`0x004AC510`): the frame due decoded and copied into the screen, then the next
    /// one next, or the movie ended at its last.
    fn play(player: *Player, now: u64) bink.Error!void {
        try player.bink.doFrame(now);
        player.bink.copyToBuffer(player.pixels, player.bink.width * 4, .{ 0, 0 });
        player.picture.changed = true;
        if (player.bink.frame_number == player.bink.frames) player.ended = true else player.bink.nextFrame();
    }

    /// Draws the frame showing on `target`, a window `window` pixels across and down, as large as
    /// `how` has it, in the middle.
    pub fn draw(player: *Player, target: device.Device, window: [2]u32, how: Size) void {
        const size: [2]u32 = .{ player.bink.width, player.bink.height };
        const scale = switch (how) {
            .fitted => hud.fit(window, size),
            .screen => canvas.scaleFor(window),
        };
        hud.drawImage(target, &player.picture, hud.centred(window, size, scale), .{ 1, 1, 1, 1 }, scale, .{});
    }
};

test "a movie plays its frames as each falls due, and ends" {
    const gpa = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    const bytes = container.testing.movie(&buffer, 2, &.{});
    var codec: bink.testing.Decoders = .{};
    var player: Player = try .open(gpa, codec.codec(), try gpa.dupe(u8, bytes), .over_screen, null, .{});
    defer player.close();
    var keyboard: input.Keyboard = .{};
    // The first frame shows at once; the second when it is due, then the movie is over.
    try std.testing.expect(!try player.pass(&keyboard, false, 0));
    try std.testing.expectEqual(1, codec.pictures);
    try std.testing.expect(player.picture.changed);
    try std.testing.expect(!try player.pass(&keyboard, false, std.time.ns_per_s / 30));
    try std.testing.expectEqual(1, codec.pictures);
    try std.testing.expect(!try player.pass(&keyboard, false, std.time.ns_per_s / 15));
    try std.testing.expect(player.ended);
    try std.testing.expect(try player.pass(&keyboard, false, std.time.ns_per_s));
}

test "Escape and the right button end a movie" {
    const gpa = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    const bytes = container.testing.movie(&buffer, 5, &.{});
    var codec: bink.testing.Decoders = .{};
    var player: Player = try .open(gpa, codec.codec(), try gpa.dupe(u8, bytes), .cleared, null, .original);
    defer player.close();
    var keyboard: input.Keyboard = .{};
    try std.testing.expect(try player.pass(&keyboard, true, 0));
    keyboard.down[input.scan.escape] = true;
    try std.testing.expect(try player.pass(&keyboard, false, 0));
    try std.testing.expectEqual(0, codec.pictures);
}

test Kind {
    try std.testing.expect(Kind.over_screen.plays(true, false));
    try std.testing.expect(!Kind.over_screen.plays(false, true));
    try std.testing.expect(Kind.cleared.plays(false, true));
    try std.testing.expect(!Kind.cleared.plays(false, false));
}
