//! `C:\lancer\game\videoreports.cpp`: the radio's reports, the lines the pilots say with their
//! faces in the radio's window (`Radio`). **Unverified:** no string places its code; the link
//! order puts it after `loadout.cpp`, where the code that queues the reports lies, from
//! `0x00456050` to `0x00456C00`.
//!
//! The reports (`Report`) wait their time and are then said as lines: PERMISSION TO LAND's answer
//! queues one. Not ported: those the wingmen's keys and the radio's menu queue, and the kill
//! remarks ([#99](https://github.com/vdmkenny/openreliant/issues/99)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.radio);

const hog = @import("../../formats/hog.zig");
const aigeneric = @import("aigeneric.zig");
const cbox = @import("cbox.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const hog_snd = @import("hog_snd.zig");
const hudmovie = @import("hudmovie.zig");
const pilots = @import("pilots.zig");
const Windows = @import("hud/windows.zig").Windows;
const mss = @import("../mss.zig");
const vm = @import("../vm.zig");

/// How long PERMISSION TO LAND goes unheard once heard, in the timer's ticks (`0x00453FC2`).
pub const permission_every: u32 = 500;

/// `permission_to_land` (`0x00453DE0`), as the player presses PERMISSION TO LAND outside a
/// multiplayer mission (`frame_controls`, `0x0041466A`), the timer at `game_ticks`: heard at most
/// once in `permission_every` ticks (`permission_heard_from`).
///
/// In a training mission (`create.Objects.training`), where the script's `landing_cleared` is
/// set, the pilot asks (`playerSays`, `hud_012`), and the flight instructor answers in
/// `report_delay` ticks (`trnglnd_001`) and clears the player's ship to land. In any other, unless
/// the ship is landing already, the pilot asks, and the bridge of the carrier it launched from
/// answers in `report_delay` ticks (`bridgeLine`): where `landing_cleared` is set it clears the
/// ship, by a line the script's `mission_success` picks at random from its lines, and otherwise it
/// refuses, by one of the refusals. A ship cleared lands on that carrier (`ailand`). A report
/// that finds the radio's reports all taken is not said, and a ship refused that way is not
/// cleared either.
///
/// **Fix:** the game reads through a null pointer where the player's ship launched from no
/// carrier; OpenReliant asks nothing.
///
/// Not ported: the debug line it writes naming the mission's rating, which nothing shows; the
/// radio's menu, which asks too (`0x00455E48`)
/// ([#99](https://github.com/vdmkenny/openreliant/issues/99)); a multiplayer game's side of it, in
/// which a remote player's ship is cleared whatever the script says
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)); and the game's mode `0x00524FE4` 1,
/// in which the key works as in a training mission.
pub fn permissionToLand(world: gameobj.World, game_ticks: u32) void {
    const player = world.player;
    if (game_ticks < player.permission_heard_from) return;
    player.permission_heard_from = game_ticks + permission_every;
    const all = world.objects;
    const variables = world.variables orelse return;
    const radio = world.radio;
    if (all.training()) {
        if (variables.landing_cleared == 0) return;
        playerSays(world, request_line);
        if (radio) |heard| {
            const place = heard.freeReport() orelse return;
            var film: [report_text_size]u8 = undefined;
            heard.reports[place] = .{
                .object = instructor,
                .about = all.player,
                .name = instructor_name,
                .due = game_ticks + report_delay,
                .film = .of(std.fmt.bufPrint(&film, "pilots\\{s}.fm8", .{instructor_film}) catch hudmovie.static_film),
                .speech = .of(instructor_line),
            };
        }
        land(world);
        return;
    }
    if (landing(all)) return;
    const carrier = player.carrier orelse return;
    playerSays(world, request_line);
    const cleared = variables.landing_cleared != 0;
    if (radio) |heard| {
        const place = heard.freeReport() orelse return;
        const lines = if (cleared) clearances(variables.mission_success) else &refusals;
        const suffix = lines[world.random.rand() % lines.len];
        var speech: [report_text_size]u8 = undefined;
        const said = bridgeLine(&speech, all, carrier, suffix);
        heard.reports[place] = .{
            .object = if (all.slots[carrier].object.type == .yamato) yamato_bridge else reliant_bridge,
            .about = all.player,
            .name = bridge_name,
            .due = game_ticks + report_delay,
            .film = .of(said.film),
            .speech = .of(said.speech),
        };
    }
    if (cleared) land(world);
}

/// The player's ship lands on the carrier it launched from (`order_push`, Land).
fn land(world: gameobj.World) void {
    const carrier = world.player.carrier orelse return;
    const ctx: aigeneric.Context = .{ .world = world, .clock = world.clock };
    _ = aigeneric.pushShip(ctx, world.objects.player, .land, carrier, aigeneric.Target.whole) catch return;
}

/// How long a report waits before it is said, in the timer's ticks (`0x00453E40`).
pub const report_delay: u32 = 300;

/// Whose PERMISSION TO LAND's answers are: the Yamato's bridge officer and the Reliant's, pilots
/// `0x54` and `0x3C` of the pilots' table (`0x00453E22`, `0x00453E68`), and the flight instructor,
/// pilot `0x52` (`0x004542B8`); and the strings that name them.
const yamato_bridge: i32 = pilot_base + 0x54;
const reliant_bridge: i32 = pilot_base + 0x3C;
const bridge_name: u16 = 0x44;
const instructor: i32 = pilot_base + 0x52;
const instructor_name: u16 = 0x100;

/// The flight instructor's film and line (`0x00505090`, `0x004F0D6C`), and the pilot's own line
/// asking to land (`0x004F0D8C`).
const instructor_film = "VirtFlt_Ins";
const instructor_line = "trnglnd_001.ut";
const request_line = "hud_012.ut";

/// The ends of the bridge's lines clearing a ship to land, for a mission the script rates a
/// success or better (`0x004EF734`), a partial failure or a partial success (`0x004EF758`), and
/// any other (`0x004EF774`); and those refusing it (`0x004EF794`).
const clearance_lines = struct {
    const success = [_][]const u8{ "_lnd_001.ut", "_lnd_002.ut", "_lnd_003.ut", "_lnd_004.ut", "_lnd_005.ut", "_lnd_006.ut", "_lnd_007.ut", "_lnd_008.ut", "_lnd_009.ut" };
    const partial = [_][]const u8{ "_lnd_010.ut", "_lnd_011.ut", "_lnd_012.ut", "_lnd_013.ut", "_lnd_014.ut", "_lnd_015.ut", "_lnd_016.ut" };
    const failure = [_][]const u8{ "_lnd_017.ut", "_lnd_018.ut", "_lnd_019.ut", "_lnd_020.ut", "_lnd_021.ut", "_lnd_022.ut", "_lnd_023.ut", "_lnd_024.ut" };
};
const refusals = [_][]const u8{ "_lnd_den_01.ut", "_lnd_den_02.ut", "_lnd_den_03.ut", "_lnd_den_04.ut" };

/// The bridge's lines clearing a ship to land for a mission rated `outcome` (`0x00453EA5`).
fn clearances(outcome: vm.Variables.Outcome) []const []const u8 {
    return switch (outcome) {
        .partial_failure, .partial_success => &clearance_lines.partial,
        .success, .success_bonus => &clearance_lines.success,
        else => &clearance_lines.failure,
    };
}

/// `0x00453620`: the bridge's line ending in `suffix`, written into `buffer`, and the film of the
/// officer who says it: the Yamato's, `yam` and `Yam_Brdge_Off`, where the carrier is a Yamato or
/// explodes; the Reliant's, `rel` and `Rel_Brdge_Off`, otherwise.
fn bridgeLine(buffer: []u8, all: *const create.Objects, carrier: u16, suffix: []const u8) struct { speech: []const u8, film: []const u8 } {
    const object = &all.slots[carrier].object;
    const yamato = object.type == .yamato or object.flags.exploding;
    const prefix = if (yamato) "yam" else "rel";
    return .{
        .speech = std.fmt.bufPrint(buffer, "{s}{s}", .{ prefix, suffix }) catch suffix,
        .film = if (yamato) "pilots\\Yam_Brdge_Off.fm8" else "pilots\\Rel_Brdge_Off.fm8",
    };
}

/// `0x004566C0` with `0x004536D0`: the pilot's own line ending in `line`, said at once without the
/// window, in a man's voice (`mp`) or a woman's (`fp`) by the pilot's sex (`input.Player.female`),
/// ending the line playing. Not ported: that a multiplayer mission says nothing
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn playerSays(world: gameobj.World, line: []const u8) void {
    const radio = world.radio orelse return;
    const hearing = world.hearing orelse return;
    var buffer: [report_text_size]u8 = undefined;
    const speech = std.fmt.bufPrint(&buffer, "{s}{s}", .{ if (world.player.female) "fp" else "mp", line }) catch return;
    radio.playSpeech(hearing.sound, speech);
}

/// Whether the player's ship is landing: its current order is Land.
fn landing(all: *create.Objects) bool {
    const entry = all.slots[all.player].current() orelse return false;
    return entry.order == .land;
}

/// Where the radio's lines come from (`speech_hog`, `0x0057BC48`): `ms_speech\msspeech.hog`,
/// whose members are the lines without their `.ut` extension (`lineName`).
pub const speech_archive = "ms_speech/msspeech.hog";

/// How many lines the radio's queue holds (`0x005295A0`, `0x74` bytes each).
pub const queue_size = 5;

/// The most of a film's path and of a speech file's name a line in the queue keeps (`0x005295A6`
/// and `0x005295D8`, the room between each and what follows).
pub const film_size = 50;
pub const name_size = 52;

/// What marks a pilot of the pilots' table (`pilots.faces`) rather than a ship's slot in whose a
/// line is (`comms_object`, `0x0057BDF4`): the pilot's number from this on (`0x00456290`).
pub const pilot_base: i32 = 0xFFFF;

/// Whose a line is where it is nobody's (`comms_object`), as `PlayCommsMovie`'s are.
pub const nobody: i32 = -1;

/// The ticks the line said waits for the radio's window to open before it starts, with its film
/// (`hud_draw`, `0x00485335`, past `0x5B`).
pub const speech_delay: i32 = 92;

/// The expiry the commands give a line: none (`0x00458AF0`).
pub const no_expiry: i32 = -1;

/// How a line is said (`radio_say`, `0x004562D0`).
/// How many reports wait their time (`0x00529D48`), and the room each gives its film's path and
/// its speech file's name (`+0x18`, `+0x4A`).
pub const report_count = 5;
const report_text_size = 50;

/// A report (`0x00529D48`, `0x7C` bytes each): a line that waits its time, then goes to the queue
/// (`Radio.stepReports`).
pub const Report = struct {
    /// Whose it is, as a line's (`Line.object`).
    object: i32,
    /// **Unknown.** Whom it concerns (`+0x08`): PERMISSION TO LAND puts the player's ship there,
    /// and nothing reads it.
    about: i32 = nobody,
    /// **Unknown.** What kind of report it is (`+0x0C`): only one of `said_report` is said.
    kind: u16 = said_report,
    /// The string that names a pilot of the pilots' table who says it (`+0x10`).
    name: u16,
    /// The timer's tick past which it is said (`+0x14`).
    due: u32,
    film: Text(report_text_size),
    speech: Text(report_text_size),
};

/// A report as the game lays it out (`0x7C` bytes), for Ghidra.
pub const ReportRecord = extern struct {
    used: u16,
    _unknown_02: u16,
    object: i32,
    about: i32,
    kind: u16,
    /// **Unknown.** `radio_reset` sets it to -1, and nothing else touches it.
    _unknown_0e: u16,
    name: u16,
    _unknown_12: u16,
    due: i32,
    film: [report_text_size]u8,
    speech: [report_text_size]u8,

    comptime {
        std.debug.assert(@offsetOf(ReportRecord, "due") == 0x14);
        std.debug.assert(@offsetOf(ReportRecord, "film") == 0x18);
        std.debug.assert(@offsetOf(ReportRecord, "speech") == 0x4A);
        std.debug.assert(@sizeOf(ReportRecord) == 0x7C);
    }
};

/// The kind of report that is said, and an object whose report is not (`0x0045607D`).
const said_report: u16 = 1;
const unsaid_object: i32 = 0x3E9;

pub const Mode = enum(u32) {
    /// At once, ending the line playing.
    now = 0,
    /// Queued, said once the lines before it are.
    queued = 1,
    /// Queued unless a line plays or waits (`radio_busy`, `0x004561A0`).
    if_idle = 2,
    _,
};

/// A line as `radio_say` takes it.
pub const Line = struct {
    /// The film of the speaker's face, a path as `pilots\<film>.fm8`.
    film: []const u8,
    /// The speech file.
    speech: []const u8,
    /// The string that names the speaker, which the window shows; none for a pilot past the
    /// pilots' table.
    name: ?u16,
    flags: hudmovie.Flags = .looping,
    /// Whose it is (`comms_object`): a ship's slot, a pilot of the pilots' table from `pilot_base`
    /// on, or `nobody`.
    object: i32,
    /// The ticks from the frame's start past which a queued line is dropped unsaid; none below 1.
    expiry: i32 = no_expiry,
};

/// What the radio reaches of the game as a line is said.
pub const Context = struct {
    /// What the lines are heard through.
    sound: *hog_snd.Sound,
    /// The display's windows, where there is a display: window 0 is the radio's.
    windows: ?*Windows,
    all: *const create.Objects,
    /// The frame's start (`frame_start`), from which a queued line's expiry counts.
    frame_start: i32,
};

/// Text of at most `size` bytes, kept in place, as the queue keeps a line's names.
fn Text(comptime size: usize) type {
    return struct {
        bytes: [size]u8 = undefined,
        len: usize = 0,

        fn of(text: []const u8) @This() {
            var kept: @This() = .{ .len = @min(text.len, size) };
            @memcpy(kept.bytes[0..kept.len], text[0..kept.len]);
            return kept;
        }

        fn slice(kept: *const @This()) []const u8 {
            return kept.bytes[0..kept.len];
        }
    };
}

/// A line waiting in the queue, with the frame's tick past which it is dropped unsaid, or none.
pub const Queued = struct {
    flags: hudmovie.Flags,
    name: ?u16,
    film: Text(film_size),
    speech: Text(name_size),
    object: i32,
    expiry: ?i32,

    /// Whether it is still to be said at `frame_start`.
    fn due(line: *const Queued, frame_start: i32) bool {
        const expiry = line.expiry orelse return true;
        return frame_start <= expiry;
    }
};

/// The name a speech file is kept under in the archive (`hog_read_file`, `0x004C7F60`): the name
/// from its last backslash on, less an extension beginning `ut`.
pub fn lineName(name: []const u8) []const u8 {
    const after = hudmovie.memberName(name);
    const dot = std.mem.lastIndexOfScalar(u8, after, '.') orelse return after;
    return if (std.ascii.startsWithIgnoreCase(after[dot + 1 ..], "ut")) after[0..dot] else after;
}

/// The room the game gives a pilot's film's path (`radio_say_pilot`, `0x00456255`).
const film_path_size = 128;

/// The path of `face`'s film for `head`, `pilots\<film>.fm8` (`0x004F0D7C`), written into
/// `buffer`; or the dead channel's film where there is no face, no film for `head`, or no room.
fn filmPath(buffer: []u8, face: ?*const pilots.Face, head: pilots.Head) []const u8 {
    const film = (face orelse return hudmovie.static_film).film(head) orelse return hudmovie.static_film;
    return std.fmt.bufPrint(buffer, "pilots\\{s}.fm8", .{film}) catch hudmovie.static_film;
}

/// The radio: the archive its lines come from, the line playing and the lines waiting, and the
/// film of the speaker's face.
pub const Radio = struct {
    gpa: Allocator,
    /// `speech_hog`; null where the game's folder has none, which leaves the radio silent.
    archive: ?hog.Archive,
    player: cbox.Player = .{},
    /// How the lines sound.
    style: cbox.Style = .{},
    /// The films of the speakers' faces (`hudmovie.cpp`).
    movie: hudmovie.Movie,
    /// The speech file of the line said last, read as it is said, until it starts with its film
    /// (`radio_speech`, `0x005883CC`).
    line: []u8 = &.{},
    /// The string that names whoever says the line (`0x0057BC4C`), whose it is (`comms_object`,
    /// `0x0057BDF4`), and their side (`0x0056993C`), which the window shows.
    name: ?u16 = null,
    object: i32 = nobody,
    side: gameobj.Side(u16) = .friendly,
    /// The queue (`0x005295A0`), how many lines wait (`0x00529594`), where the next is put
    /// (`0x00529870`) and where the next is taken from (`0x00529CBE`).
    queue: [queue_size]Queued = undefined,
    count: usize = 0,
    write: usize = 0,
    read: usize = 0,
    /// The reports waiting their time.
    reports: [report_count]?Report = @splat(null),

    /// The radio with its lines from `speech_archive` and its films from `hudmovie.archive_path` in
    /// `dir`, or without either where it cannot be opened.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) Radio {
        return .openAt(gpa, io, dir, speech_archive, hudmovie.archive_path);
    }

    /// The radio with its lines from the archive at `lines` and its films from the one at `films`
    /// in `dir`.
    pub fn openAt(gpa: Allocator, io: Io, dir: Io.Dir, lines: []const u8, films: []const u8) Radio {
        const archive = hog.Archive.open(gpa, io, dir, lines) catch |err| none: {
            log.warn("the radio's lines are left out: {s} cannot be opened: {s}", .{ lines, @errorName(err) });
            break :none null;
        };
        return .{ .gpa = gpa, .archive = archive, .movie = .openAt(gpa, io, dir, films) };
    }

    pub fn deinit(radio: *Radio, sound: ?*hog_snd.Sound) void {
        radio.reset(sound);
        radio.movie.deinit();
        if (radio.archive) |*archive| archive.close(radio.gpa);
        radio.archive = null;
    }

    /// `radio_reset` (`0x004560F0`), as a mission starts and as it ends: the line playing ended
    /// (`speech_stop_all`, `0x004620D0`), the queue emptied, and the window naming no one.
    ///
    /// **Fix:** the game leaves a film playing into the next mission, whose first line then starts
    /// before its window has opened; OpenReliant stops it.
    pub fn reset(radio: *Radio, sound: ?*hog_snd.Sound) void {
        if (sound) |heard| radio.player.stop(radio.gpa, heard) else radio.player.deinit(radio.gpa);
        radio.dropLine();
        radio.movie.stop();
        radio.movie.waiting = false;
        radio.name = null;
        radio.object = nobody;
        radio.count = 0;
        radio.write = 0;
        radio.read = 0;
        radio.reports = @splat(null);
    }

    /// `speech_playing` (`0x004620A0`): whether a line plays.
    pub fn speaking(radio: *const Radio, sound: ?*hog_snd.Sound) bool {
        const heard = sound orelse return false;
        return radio.player.playing(heard);
    }

    /// `radio_busy` (`0x004561A0`): whether a line plays or waits.
    pub fn busy(radio: *const Radio, sound: *hog_snd.Sound) bool {
        return radio.speaking(sound) or radio.count > 0;
    }

    /// `radio_say` (`0x004562D0`), outside a multiplayer mission: `line` said as `mode` has it.
    /// Said at once (`sayNow`), it ends the line playing. Queued, it waits its turn (`frame`),
    /// dropped past its expiry from the frame's start where it has one, or where the queue is
    /// full.
    pub fn say(radio: *Radio, ctx: Context, line: Line, mode: Mode) void {
        switch (mode) {
            .now => radio.sayNow(ctx, line),
            .queued => radio.enqueue(line, ctx.frame_start),
            .if_idle => if (!radio.busy(ctx.sound)) radio.enqueue(line, ctx.frame_start),
            _ => {},
        }
    }

    /// `radio_say`'s mode 0: the window opens held unless it is open (`Windows.hold`), the line
    /// playing stops, the window names the speaker, their side found (`sideOf`), and the line's
    /// speech is read and its film played, the line starting with it (`start`).
    fn sayNow(radio: *Radio, ctx: Context, line: Line) void {
        if (ctx.windows) |windows| if (windows.status.get(.radio).phase != .open) windows.hold(.radio);
        radio.player.stop(radio.gpa, ctx.sound);
        radio.name = line.name;
        radio.object = line.object;
        radio.side = sideOf(ctx.all, line.object);
        radio.load(line.speech);
        radio.start(ctx, line.film, line.flags);
    }

    /// `radio_say_pilot` (`0x00456250`): `speech` said by pilot `pilot` of the pilots' table, its
    /// face moving as `head` says, outside a multiplayer mission.
    pub fn sayPilot(radio: *Radio, ctx: Context, pilot: u16, head: pilots.Head, speech: []const u8, mode: Mode, flags: hudmovie.Flags, expiry: i32) void {
        const face = pilots.faceOf(pilot);
        var buffer: [film_path_size]u8 = undefined;
        radio.say(ctx, .{
            .film = filmPath(&buffer, face, head),
            .speech = speech,
            .name = if (face) |found| found.name else null,
            .flags = flags,
            .object = pilot_base + @as(i32, pilot),
            .expiry = expiry,
        }, mode);
    }

    /// `radio_say_ship` (`0x004561C0`): `speech` said by the ship in slot `ship`, its pilot's face
    /// moving as `head` says, outside a multiplayer mission: not by a stand-in, nor a ship
    /// exploding.
    ///
    /// **Fix:** the game reads beside the pilots' table for a pilot past it; OpenReliant says the
    /// line with the dead channel's film and no name. Where the game's ship has no pilot record it
    /// says nothing; every ship OpenReliant makes has a pilot.
    pub fn sayShip(radio: *Radio, ctx: Context, ship: u16, head: pilots.Head, speech: []const u8, mode: Mode, flags: hudmovie.Flags, expiry: i32) void {
        const all = ctx.all;
        if (ship >= all.slots.len) return;
        const object = &all.slots[ship].object;
        if (object.flags.stand_in or object.flags.exploding) return;
        const face = pilots.faceOf(object.pilot);
        var buffer: [film_path_size]u8 = undefined;
        radio.say(ctx, .{
            .film = filmPath(&buffer, face, head),
            .speech = speech,
            .name = if (face) |found| found.name else null,
            .flags = flags,
            .object = ship,
            .expiry = expiry,
        }, mode);
    }

    /// `radio_frame` (`0x00456510`), each frame: while lines wait, the window is shut or closing and
    /// no line plays, the next is taken, and said unless its time has passed: the window opens
    /// held, names the speaker, and, where the line is someone's, its speech is read and its film
    /// played, the line starting with it. One that is nobody's leaves the window open with nothing
    /// in it, which then closes.
    pub fn frame(radio: *Radio, ctx: Context) void {
        if (radio.count == 0) return;
        if (ctx.windows) |windows| switch (windows.status.get(.radio).phase) {
            .shut, .closing => {},
            .opening, .open => return,
        };
        if (radio.speaking(ctx.sound)) return;
        const line = &radio.queue[radio.read];
        if (line.due(ctx.frame_start)) {
            if (ctx.windows) |windows| windows.hold(.radio);
            radio.dropLine();
            radio.object = line.object;
            radio.name = line.name;
            if (line.object != nobody) {
                radio.side = sideOf(ctx.all, line.object);
                radio.load(line.speech.slice());
                radio.start(ctx, line.film.slice(), line.flags);
            }
        }
        radio.count -= 1;
        radio.read = (radio.read + 1) % queue_size;
    }

    /// `0x004560D0`: the first report free, or null where all are taken.
    pub fn freeReport(radio: *const Radio) ?usize {
        for (radio.reports, 0..) |report, place| {
            if (report == null) return place;
        }
        return null;
    }

    /// `0x00456050`, each frame after `frame`: each report whose time has passed at `game_ticks`
    /// goes, and one of `said_report` is said, queued, looping and never too late (`say`), unless
    /// it is nobody's or `unsaid_object`'s, or a ship's that is exploding. A ship's report is
    /// named by its pilot's face, a pilot's by the report's name.
    pub fn stepReports(radio: *Radio, ctx: Context, game_ticks: u32) void {
        for (&radio.reports) |*held| {
            const report = held.* orelse continue;
            if (game_ticks <= report.due) continue;
            held.* = null;
            if (report.kind != said_report or report.object == nobody or report.object == unsaid_object) continue;
            var name: ?u16 = report.name;
            if (report.object < pilot_base) {
                if (report.object < 0 or report.object >= ctx.all.slots.len) continue;
                const object = &ctx.all.slots[@intCast(report.object)].object;
                if (object.flags.exploding) continue;
                name = if (pilots.faceOf(object.pilot)) |face| face.name else null;
            }
            radio.say(ctx, .{
                .film = report.film.slice(),
                .speech = report.speech.slice(),
                .name = name,
                .object = report.object,
            }, .queued);
        }
    }

    /// The film's timer for a frame of `ticks` (`hudmovie.Movie.run`): a film that held for its
    /// line, which is over, has stopped, and the window closes.
    pub fn runFilm(radio: *Radio, ctx: Context, ticks: u32) void {
        if (!radio.movie.run(ticks, radio.speaking(ctx.sound), ctx.all.mission_number)) return;
        if (ctx.windows) |windows| windows.close(.radio);
    }

    /// `hud_draw` (`0x0048531D`), each frame: while the line said waits for the window to open
    /// (`hudmovie.Movie.waiting`), the frame's ticks are counted, and at `speech_delay` the line
    /// starts, and its film with it.
    pub fn waitForWindow(radio: *Radio, sound: ?*hog_snd.Sound, ticks: i32) void {
        const movie = &radio.movie;
        if (!movie.waiting) return;
        movie.waited += ticks;
        if (movie.waited < speech_delay) return;
        if (sound) |heard| radio.startLine(heard);
        movie.waiting = false;
    }

    /// `cmd_PlaySpeech`'s line (`0x00458090`): the speech file `speech` played at once, without a
    /// window or a film, ending the line playing. The game reads it into a buffer of its own
    /// (`0x005883D0`), so a line waiting for the window keeps its own.
    pub fn playSpeech(radio: *Radio, sound: *hog_snd.Sound, speech: []const u8) void {
        radio.player.stop(radio.gpa, sound);
        const bytes = radio.readLine(speech) orelse return;
        defer radio.gpa.free(bytes);
        radio.play(sound, bytes);
    }

    /// The ship whose line the window names while it is open or opening, unless it is cloaked
    /// (`hud_comms_marker`, `0x0048B0F0`; `hud_radar`, `0x00488BDE`); none for a pilot's line or
    /// nobody's.
    ///
    /// **Fix:** the radar takes a pilot's number for a slot, and marks whatever ship lies there;
    /// OpenReliant marks only a ship whose line it is.
    pub fn speakingShip(radio: *const Radio, windows: *const Windows, all: *const create.Objects) ?u16 {
        if (!windows.up(.radio)) return null;
        if (radio.object < 0 or radio.object >= all.count) return null;
        const ship: u16 = @intCast(radio.object);
        if (all.slots[ship].object.flags.cloaked) return null;
        return ship;
    }

    fn enqueue(radio: *Radio, line: Line, frame_start: i32) void {
        if (radio.count >= queue_size) return;
        radio.queue[radio.write] = .{
            .flags = line.flags,
            .name = line.name,
            .film = .of(line.film),
            .speech = .of(line.speech),
            .object = line.object,
            .expiry = if (line.expiry < 1) null else frame_start + line.expiry,
        };
        radio.count += 1;
        radio.write = (radio.write + 1) % queue_size;
    }

    /// The film at `film` played as `flags` say (`hudmovie.Movie.play`), and the line said with it
    /// started where a film was playing already; otherwise it waits for the window
    /// (`waitForWindow`).
    fn start(radio: *Radio, ctx: Context, film: []const u8, flags: hudmovie.Flags) void {
        if (radio.movie.play(film, flags, ctx.all.mission_number)) radio.startLine(ctx.sound);
    }

    /// The line said last (`line`) read from the archive, in place of the one before.
    fn load(radio: *Radio, speech: []const u8) void {
        radio.dropLine();
        radio.line = radio.readLine(speech) orelse &.{};
    }

    fn dropLine(radio: *Radio) void {
        radio.gpa.free(radio.line);
        radio.line = &.{};
    }

    /// `speech_start` for the line said last, which then goes.
    fn startLine(radio: *Radio, sound: *hog_snd.Sound) void {
        if (radio.line.len == 0) return;
        defer radio.dropLine();
        radio.play(sound, radio.line);
    }

    /// The speech file `speech` names as the archive holds it, in `gpa`; or null, with a warning,
    /// for one the archive lacks.
    fn readLine(radio: *Radio, speech: []const u8) ?[]u8 {
        const archive = radio.archive orelse return null;
        const name = lineName(speech);
        const entry = archive.find(name) orelse {
            log.warn("the radio's line {s} is not in {s}", .{ name, speech_archive });
            return null;
        };
        const contents = archive.read(radio.gpa, entry) catch |err| {
            log.warn("the radio's line {s} cannot be read: {s}", .{ name, @errorName(err) });
            return null;
        };
        return contents.bytes;
    }

    /// `bytes`, a speech file, played (`cbox.Player.start`) at the volume every line the game plays
    /// takes, the line playing ended; one that is not a speech file is left out with a warning.
    fn play(radio: *Radio, sound: *hog_snd.Sound, bytes: []u8) void {
        const parsed = cbox.Speech.parse(bytes) orelse {
            log.warn("a line of the radio's is not a speech file", .{});
            return;
        };
        _ = radio.player.start(radio.gpa, sound, parsed, hog_snd.loudest, radio.style);
    }
};

/// The side of whoever says a line whose `object` is (`radio_say`, `0x00456475`): a ship's, a
/// pilot's face's, or the friendly side for nobody's. One past the objects or the pilots' table,
/// which the game reads beside them, is friendly too.
pub fn sideOf(all: *const create.Objects, object: i32) gameobj.Side(u16) {
    if (object >= pilot_base) {
        const face = pilots.faceOf(object - pilot_base) orelse return .friendly;
        return face.side;
    }
    if (object < 0 or object >= all.count) return .friendly;
    const side = @intFromEnum(all.slots[@intCast(object)].object.side);
    return @enumFromInt(@as(u16, @truncate(@as(u32, @bitCast(side)))));
}

test Radio {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // An archive of two lines, each of silence, as the game's holds them: without extensions; and
    // one of films.
    const line = try cbox.testFile(gpa, 4410, 200);
    defer gpa.free(line);
    try hog.testing.write(gpa, io, tmp.dir, "speech.hog", &.{ .{ .name = "MS1_BAN_001", .data = line }, .{ .name = "PLCK_001", .data = line } });
    try hudmovie.testing.write(gpa, io, tmp.dir, "pilots.hog", &.{
        .{ .name = "45volntrs_plt.fm8", .frames = 2, .colour = 0x40 },
        .{ .name = "static.fm8", .frames = 2, .colour = 0x80 },
    });
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    mission.objects.mission_number = 1;
    const wingman = try mission.add(.predator, @splat(0));
    const enemy = try mission.add(.predator, .{ 0, 0, 1000 });
    mission.slot(enemy).object.side = .hostile;

    var radio: Radio = .openAt(gpa, io, tmp.dir, "speech.hog", "pilots.hog");
    var mixer: mss.Mixer = .init(22050);
    var sound: hog_snd.Sound = undefined;
    sound.init(mixer.driver(), 2, null);
    defer sound.shutdown();
    defer radio.deinit(&sound);
    try std.testing.expect(radio.archive != null and radio.movie.archive != null);
    var windows: Windows = .{};
    const ctx: Context = .{ .sound = &sound, .windows = &windows, .all = mission.objects, .frame_start = 100 };

    // A line said at once opens the window held and names its speaker; the line waits for the
    // window, with its film, the 45th Tigers' pilot's as the Volunteers' in mission 1.
    radio.sayShip(ctx, wingman, .squadron, "ms1_ban_001.ut", .now, .looping, no_expiry);
    try std.testing.expectEqual(.opening, windows.status.get(.radio).phase);
    try std.testing.expect(windows.status.get(.radio).held);
    try std.testing.expectEqual(pilots.faces[0].name, radio.name.?);
    try std.testing.expectEqual(@as(i32, wingman), radio.object);
    try std.testing.expect(radio.movie.playing and radio.movie.waiting);
    try std.testing.expectEqual([4]u8{ 0x40, 0x40, 0x40, 0xFF }, radio.movie.rgba[0..4].*);
    try std.testing.expect(!radio.speaking(&sound));
    radio.waitForWindow(&sound, speech_delay - 1);
    try std.testing.expect(!radio.speaking(&sound));
    radio.waitForWindow(&sound, 1);
    try std.testing.expect(radio.speaking(&sound));
    try std.testing.expect(!radio.movie.waiting);

    // A line queued waits while the window is up, and until the line playing is over.
    radio.sayShip(ctx, enemy, .talking, "plck_001.ut", .queued, .looping, no_expiry);
    try std.testing.expectEqual(1, radio.count);
    radio.frame(ctx);
    try std.testing.expectEqual(1, radio.count);
    windows.close(.radio);
    radio.player.stop(gpa, &sound);
    radio.frame(ctx);
    try std.testing.expectEqual(0, radio.count);
    // Taken, it opens the window again, with a film playing already, so its line starts at once,
    // on the hostile side.
    try std.testing.expectEqual(.opening, windows.status.get(.radio).phase);
    try std.testing.expect(radio.speaking(&sound));
    try std.testing.expectEqual(.hostile, radio.side);
    // The ship whose line it is shows while the window is up, unless cloaked.
    try std.testing.expectEqual(enemy, radio.speakingShip(&windows, mission.objects).?);
    mission.slot(enemy).object.flags.cloaked = true;
    try std.testing.expectEqual(null, radio.speakingShip(&windows, mission.objects));

    // A line queued unless the radio is busy waits for it to go quiet; one whose time has passed
    // is dropped unsaid.
    const pilot_line: Line = .{ .film = hudmovie.static_film, .speech = "plck_001.ut", .name = null, .object = pilot_base + 3, .expiry = 50 };
    radio.say(ctx, pilot_line, .if_idle);
    try std.testing.expectEqual(0, radio.count);
    radio.player.stop(gpa, &sound);
    radio.say(ctx, pilot_line, .if_idle);
    try std.testing.expectEqual(1, radio.count);
    try std.testing.expectEqual(150, radio.queue[radio.read].expiry.?);
    windows.close(.radio);
    radio.frame(.{ .sound = &sound, .windows = &windows, .all = mission.objects, .frame_start = 200 });
    try std.testing.expectEqual(0, radio.count);
    try std.testing.expect(!radio.speaking(&sound));
    // The queue holds five; a sixth is dropped.
    for (0..queue_size + 1) |_| radio.say(ctx, pilot_line, .queued);
    try std.testing.expectEqual(queue_size, radio.count);
    radio.reset(&sound);
    try std.testing.expectEqual(0, radio.count);
    try std.testing.expect(!radio.movie.playing);

    // A line played by the script has no window nor film; one the archive lacks is left out.
    radio.playSpeech(&sound, "ms1_ban_001.ut");
    try std.testing.expect(radio.speaking(&sound));
    try std.testing.expect(!radio.movie.playing);
    radio.playSpeech(&sound, "nothing.ut");
    try std.testing.expect(!radio.speaking(&sound));
}

test sideOf {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const enemy = try mission.add(.predator, @splat(0));
    mission.slot(enemy).object.side = .hostile;
    try std.testing.expectEqual(.hostile, sideOf(mission.objects, enemy));
    try std.testing.expectEqual(.friendly, sideOf(mission.objects, nobody));
    // A pilot's side is its face's, and the pilots past the table friendly.
    try std.testing.expectEqual(pilots.faces[21].side, sideOf(mission.objects, pilot_base + 21));
    try std.testing.expectEqual(.friendly, sideOf(mission.objects, pilot_base + pilots.faces.len));
}

test filmPath {
    var buffer: [film_path_size]u8 = undefined;
    const bandit = pilots.faceOf(0);
    try std.testing.expectEqualStrings("pilots\\45TigersWL_Bandit_d.fm8", filmPath(&buffer, bandit, .dying));
    try std.testing.expectEqualStrings(hudmovie.static_film, filmPath(&buffer, bandit, @enumFromInt(4)));
    try std.testing.expectEqualStrings(hudmovie.static_film, filmPath(&buffer, null, .talking));
}

test lineName {
    try std.testing.expectEqualStrings("ms1_ban_001", lineName("ms1_ban_001.ut"));
    try std.testing.expectEqualStrings("trnglnd_001", lineName("speech\\trnglnd_001.UT"));
    try std.testing.expectEqualStrings("plck_001.wav", lineName("plck_001.wav"));
    try std.testing.expectEqualStrings("abrt_001", lineName("abrt_001"));
}

test "PERMISSION TO LAND's answers wait their time, then the radio says them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const silence = try cbox.testFile(gpa, 4410, 200);
    defer gpa.free(silence);
    try hog.testing.write(gpa, io, tmp.dir, "speech.hog", &.{ .{ .name = "MPHUD_012", .data = silence }, .{ .name = "FPHUD_012", .data = silence } });
    try hudmovie.testing.write(gpa, io, tmp.dir, "pilots.hog", &.{.{ .name = "static.fm8", .frames = 1, .colour = 0x80 }});
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 1000 });
    var radio: Radio = .openAt(gpa, io, tmp.dir, "speech.hog", "pilots.hog");
    var mixer: mss.Mixer = .init(22050);
    var sound: hog_snd.Sound = undefined;
    sound.init(mixer.driver(), 2, null);
    defer sound.shutdown();
    defer radio.deinit(&sound);
    var variables: vm.Variables = .{ .landing_cleared = 1, .mission_success = .success };
    var place: @import("camera.zig").Place = .{};
    var world = mission.world();
    world.variables = &variables;
    world.radio = &radio;
    world.hearing = .{ .sound = &sound, .camera = &place, .clock = &mission.clock };
    mission.player.carrier = reliant;

    // The pilot asks at once, and the Reliant's bridge answers in its time, clearing the ship by one
    // of the lines for a success.
    permissionToLand(world, 100);
    try std.testing.expect(radio.speaking(&sound));
    const report = radio.reports[0].?;
    try std.testing.expectEqual(reliant_bridge, report.object);
    try std.testing.expectEqual(bridge_name, report.name);
    try std.testing.expectEqual(100 + report_delay, report.due);
    try std.testing.expectEqualStrings("pilots\\Rel_Brdge_Off.fm8", report.film.slice());
    try std.testing.expect(std.mem.startsWith(u8, report.speech.slice(), "rel_lnd_00"));
    try std.testing.expectEqual(.land, mission.slot(player).current().?.order);
    var windows: Windows = .{};
    const ctx: Context = .{ .sound = &sound, .windows = &windows, .all = mission.objects, .frame_start = 0 };
    radio.stepReports(ctx, 100 + report_delay);
    try std.testing.expectEqual(0, radio.count);
    radio.stepReports(ctx, 101 + report_delay);
    try std.testing.expectEqual(null, radio.reports[0]);
    try std.testing.expectEqual(1, radio.count);
    try std.testing.expectEqual(reliant_bridge, radio.queue[radio.read].object);
    try std.testing.expectEqual(bridge_name, radio.queue[radio.read].name.?);

    // Not cleared, it refuses; and with the reports all taken, nothing answers and nothing lands.
    radio.reset(&sound);
    mission.slot(player).object.order_count = 0;
    variables.landing_cleared = 0;
    permissionToLand(world, 1000);
    try std.testing.expect(std.mem.startsWith(u8, radio.reports[0].?.speech.slice(), "rel_lnd_den_0"));
    try std.testing.expectEqual(0, mission.slot(player).object.order_count);
    variables.landing_cleared = 1;
    for (&radio.reports) |*held| held.* = radio.reports[0];
    permissionToLand(world, 2000);
    try std.testing.expectEqual(0, mission.slot(player).object.order_count);
    try std.testing.expectEqual(null, radio.freeReport());

    // In training, the flight instructor answers.
    radio.reset(&sound);
    mission.objects.mission_number = create.training_missions[0];
    mission.player.female = true;
    permissionToLand(world, 3000);
    try std.testing.expect(radio.speaking(&sound));
    try std.testing.expectEqual(instructor, radio.reports[0].?.object);
    try std.testing.expectEqualStrings("pilots\\VirtFlt_Ins.fm8", radio.reports[0].?.film.slice());
    try std.testing.expectEqualStrings(instructor_line, radio.reports[0].?.speech.slice());
}

test permissionToLand {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var variables: @import("../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 1000 });
    const slot = mission.slot(player);

    // Not yet cleared, the ship lands on nothing, and the key goes unheard for a while.
    mission.player.carrier = reliant;
    permissionToLand(world, 100);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(100 + permission_every, mission.player.permission_heard_from);
    // Cleared, it is heard again only once the while is up, and the ship lands on its carrier.
    variables.landing_cleared = 1;
    permissionToLand(world, 100 + permission_every - 1);
    try std.testing.expectEqual(0, slot.object.order_count);
    permissionToLand(world, 100 + permission_every);
    try std.testing.expectEqual(.land, slot.current().?.order);
    try std.testing.expectEqual(reliant, slot.current().?.target.slotIn(mission.objects).?);

    // A ship that launched from no carrier lands on nothing.
    slot.object.order_count = 0;
    mission.player.carrier = null;
    permissionToLand(world, 10000);
    try std.testing.expectEqual(0, slot.object.order_count);
}
