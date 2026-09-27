//! `C:\lancer\game\videoreports.cpp`: the radio's reports, the lines the pilots say with their
//! faces in the radio's window (`Radio`). **Unverified:** no string places its code; the link
//! order puts it after `loadout.cpp`, where the code that queues the reports lies, from
//! `0x00456050` to `0x00456C00`.
//!
//! Not ported: the window and the faces' films, the delayed reports the wingmen's keys and
//! PERMISSION TO LAND queue, and the kill remarks
//! ([#99](https://github.com/vdmkenny/openreliant/issues/99)).

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
const mss = @import("../mss.zig");

/// How long PERMISSION TO LAND goes unheard once heard, in the timer's ticks (`0x00453FC2`).
pub const permission_every: u32 = 500;

/// `permission_to_land` (`0x00453DE0`), as the player presses PERMISSION TO LAND outside a
/// multiplayer mission (`frame_controls`, `0x0041466A`), the timer at `game_ticks`: heard at most
/// once in `permission_every` ticks (`permission_heard_from`). In a training mission (`create.Objects.training`), the flight
/// instructor clears the player's ship to land where the script's `landing_cleared` is set. In any
/// other, unless the ship is landing already, the carrier it launched from refuses it, or clears it
/// where `landing_cleared` is set. A ship cleared lands on that carrier (`ailand`).
///
/// **Fix:** the game reads through a null pointer where the player's ship launched from no
/// carrier; OpenReliant does nothing.
///
/// Not ported: the reports on the radio, the flight instructor's and the carrier's, whose
/// clearance the script's `mission_success` picks, and the debug line naming that rating; the
/// radio's menu, which asks too (`0x00455E48`)
/// ([#99](https://github.com/vdmkenny/openreliant/issues/99)); a multiplayer game's side of it; and
/// the game's mode `0x00524FE4` 1, in which the key works as in a training mission.
pub fn permissionToLand(world: gameobj.World, game_ticks: u32) void {
    const player = world.player;
    if (game_ticks < player.permission_heard_from) return;
    player.permission_heard_from = game_ticks + permission_every;
    const all = world.objects;
    if (!all.training() and landing(all)) return;
    const variables = world.variables orelse return;
    if (variables.landing_cleared == 0) return;
    const carrier = player.carrier orelse return;
    const ctx: aigeneric.Context = .{ .world = world, .clock = world.clock };
    _ = aigeneric.pushShip(ctx, all.player, .land, carrier, aigeneric.Target.whole) catch return;
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

/// The most of a speech file's name a command keeps (`0x00458AC2`).
pub const name_size = 52;

/// What marks a pilot of the pilots' table (`pilot_faces`, `0x005048D8`) rather than a ship's slot
/// in whose a line is (`comms_object`, `0x0057BDF4`): the pilot's number from this on
/// (`0x00456290`).
pub const pilot_base: i32 = 0xFFFF;

/// How a line is said (`radio_say`, `0x004562D0`).
pub const Mode = enum(u32) {
    /// At once, ending the line playing.
    now = 0,
    /// Queued, said once the lines before it are.
    queued = 1,
    /// Queued unless a line plays or waits (`radio_busy`, `0x004561A0`).
    if_idle = 2,
    _,
};

/// A line waiting in the queue: its speech file, whose it is (`comms_object`), and the frame's
/// tick past which it is dropped unsaid, or none. The game keeps the film's name, the speaker's
/// name and the film's flags with it too, for the window.
pub const Queued = struct {
    speech: [name_size]u8,
    speech_len: usize,
    object: i32,
    expiry: ?i32,

    fn speechName(line: *const Queued) []const u8 {
        return line.speech[0..line.speech_len];
    }
};

/// The name a speech file is kept under in the archive (`hog_read_file`, `0x004C7F60`): the name
/// from its last backslash on, less an extension beginning `ut`.
pub fn lineName(name: []const u8) []const u8 {
    const after = if (std.mem.lastIndexOfScalar(u8, name, '\\')) |at| name[at + 1 ..] else name;
    const dot = std.mem.lastIndexOfScalar(u8, after, '.') orelse return after;
    return if (std.ascii.startsWithIgnoreCase(after[dot + 1 ..], "ut")) after[0..dot] else after;
}

/// The radio: the archive its lines come from, the line playing and the lines waiting.
pub const Radio = struct {
    gpa: Allocator,
    /// `speech_hog`; null where the game's folder has none, which leaves the radio silent.
    archive: ?hog.Archive,
    player: cbox.Player = .{},
    /// How the lines sound.
    style: cbox.Style = .{},
    /// The queue (`0x005295A0`), how many lines wait (`0x00529594`), where the next is put
    /// (`0x00529870`) and where the next is taken from (`0x00529CBE`).
    queue: [queue_size]Queued = undefined,
    count: usize = 0,
    write: usize = 0,
    read: usize = 0,

    /// The radio with its lines from `speech_archive` in `dir`, or none where it cannot be opened.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) Radio {
        return .openAt(gpa, io, dir, speech_archive);
    }

    /// The radio with its lines from the archive at `path` in `dir`.
    pub fn openAt(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Radio {
        const archive = hog.Archive.open(gpa, io, dir, path) catch |err| none: {
            log.warn("the radio's lines are left out: {s} cannot be opened: {s}", .{ path, @errorName(err) });
            break :none null;
        };
        return .{ .gpa = gpa, .archive = archive };
    }

    pub fn deinit(radio: *Radio, sound: ?*hog_snd.Sound) void {
        radio.reset(sound);
        if (radio.archive) |*archive| archive.close(radio.gpa);
        radio.archive = null;
    }

    /// As a mission starts and as it ends: the line playing ended (`speech_stop_all`,
    /// `0x004620D0`) and the queue emptied.
    pub fn reset(radio: *Radio, sound: ?*hog_snd.Sound) void {
        if (sound) |heard| radio.player.stop(radio.gpa, heard) else radio.player.deinit(radio.gpa);
        radio.count = 0;
        radio.write = 0;
        radio.read = 0;
    }

    /// `radio_busy` (`0x004561A0`): whether a line plays or waits.
    pub fn busy(radio: *const Radio, sound: *hog_snd.Sound) bool {
        return radio.player.playing(sound) or radio.count > 0;
    }

    /// `radio_say` (`0x004562D0`), outside a multiplayer mission: the speech file `speech` said
    /// as `mode` has it, by `object`. Said at once, it ends the line playing (`play`). Queued, it
    /// waits its turn (`frame`), dropped past `expiry` ticks from `frame_start` where that is
    /// given, or where the queue is full.
    ///
    /// Not ported: the window it opens and the film it plays with the line, and the speaker's
    /// name and side it keeps for them.
    pub fn say(radio: *Radio, sound: *hog_snd.Sound, speech: []const u8, mode: Mode, object: i32, expiry: i32, frame_start: i32) void {
        switch (mode) {
            .now => radio.play(sound, speech),
            .queued => radio.enqueue(speech, object, expiry, frame_start),
            .if_idle => if (!radio.busy(sound)) radio.enqueue(speech, object, expiry, frame_start),
            _ => {},
        }
    }

    /// `radio_say_pilot` (`0x00456250`): `speech` said by pilot `pilot` of the pilots' table,
    /// whose face moves as `head` says, outside a multiplayer mission.
    pub fn sayPilot(radio: *Radio, sound: *hog_snd.Sound, pilot: u16, head: u32, speech: []const u8, mode: Mode, expiry: i32, frame_start: i32) void {
        _ = head;
        radio.say(sound, speech, mode, pilot_base + @as(i32, pilot), expiry, frame_start);
    }

    /// `radio_say_ship` (`0x004561C0`): `speech` said by the ship in slot `ship`, whose pilot's
    /// face moves as `head` says, outside a multiplayer mission: not by a stand-in, nor a ship
    /// exploding.
    ///
    /// Not ported: a ship with no pilot record says nothing, which every ship OpenReliant makes
    /// has.
    pub fn sayShip(radio: *Radio, sound: *hog_snd.Sound, all: *const create.Objects, ship: u16, head: u32, speech: []const u8, mode: Mode, expiry: i32, frame_start: i32) void {
        _ = head;
        if (ship >= all.slots.len) return;
        const object = &all.slots[ship].object;
        if (object.flags.stand_in or object.flags.exploding) return;
        radio.say(sound, speech, mode, ship, expiry, frame_start);
    }

    /// `radio_frame` (`0x00456510`), each frame: while lines wait and none plays, the next is
    /// taken, and said unless its time has passed.
    ///
    /// Not ported: the game waits while the window is opening or closing.
    pub fn frame(radio: *Radio, sound: *hog_snd.Sound, frame_start: i32) void {
        if (radio.count == 0 or radio.player.playing(sound)) return;
        const line = &radio.queue[radio.read];
        const due = if (line.expiry) |expiry| frame_start <= expiry else true;
        if (due) radio.play(sound, line.speechName());
        radio.count -= 1;
        radio.read = (radio.read + 1) % queue_size;
    }

    fn enqueue(radio: *Radio, speech: []const u8, object: i32, expiry: i32, frame_start: i32) void {
        if (radio.count >= queue_size) return;
        const line = &radio.queue[radio.write];
        const len = @min(speech.len, name_size);
        @memcpy(line.speech[0..len], speech[0..len]);
        line.speech_len = len;
        line.object = object;
        line.expiry = if (expiry < 1) null else frame_start + expiry;
        radio.count += 1;
        radio.write = (radio.write + 1) % queue_size;
    }

    /// The line `speech` names read from the archive and played (`cbox.Player.start`), at the
    /// volume every line the game plays takes. A line the archive lacks, or not a speech file, is
    /// left out with a warning.
    fn play(radio: *Radio, sound: *hog_snd.Sound, speech: []const u8) void {
        const archive = radio.archive orelse return;
        const name = lineName(speech);
        const entry = archive.find(name) orelse {
            log.warn("the radio's line {s} is not in {s}", .{ name, speech_archive });
            return;
        };
        const contents = archive.read(radio.gpa, entry) catch |err| {
            log.warn("the radio's line {s} cannot be read: {s}", .{ name, @errorName(err) });
            return;
        };
        defer contents.deinit(radio.gpa);
        const parsed = cbox.Speech.parse(contents.bytes) orelse {
            log.warn("the radio's line {s} is not a speech file", .{name});
            return;
        };
        _ = radio.player.start(radio.gpa, sound, parsed, hog_snd.loudest, radio.style);
    }
};

test Radio {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // An archive of two lines, each of silence, as the game's holds them: without extensions.
    const line = try cbox.testFile(gpa, 4410, 200);
    defer gpa.free(line);
    try hog.testing.write(gpa, io, tmp.dir, "speech.hog", &.{ .{ .name = "MS1_BAN_001", .data = line }, .{ .name = "PLCK_001", .data = line } });
    var radio: Radio = .openAt(gpa, io, tmp.dir, "speech.hog");
    var mixer: mss.Mixer = .init(22050);
    var sound: hog_snd.Sound = undefined;
    sound.init(mixer.driver(), 2, null);
    defer sound.shutdown();
    defer radio.deinit(&sound);
    try std.testing.expect(radio.archive != null);

    // A line said at once plays; one queued waits until it is over, and then plays.
    radio.say(&sound, "ms1_ban_001.ut", .now, 0, -1, 100);
    try std.testing.expect(radio.player.playing(&sound));
    radio.say(&sound, "plck_001.ut", .queued, 1, -1, 100);
    try std.testing.expectEqual(1, radio.count);
    radio.frame(&sound, 101);
    try std.testing.expectEqual(1, radio.count);
    radio.player.stop(gpa, &sound);
    radio.frame(&sound, 102);
    try std.testing.expectEqual(0, radio.count);
    try std.testing.expect(radio.player.playing(&sound));
    // A line queued unless the radio is busy waits for it to go quiet; one whose time has passed
    // is dropped unsaid.
    radio.say(&sound, "plck_001.ut", .if_idle, 1, -1, 103);
    try std.testing.expectEqual(0, radio.count);
    radio.player.stop(gpa, &sound);
    radio.say(&sound, "plck_001.ut", .if_idle, 1, 50, 103);
    try std.testing.expectEqual(1, radio.count);
    try std.testing.expectEqual(153, radio.queue[radio.read].expiry.?);
    radio.frame(&sound, 200);
    try std.testing.expectEqual(0, radio.count);
    try std.testing.expect(!radio.player.playing(&sound));
    // A line the archive lacks is left out.
    radio.say(&sound, "nothing.ut", .now, 0, -1, 300);
    try std.testing.expect(!radio.player.playing(&sound));
    // The queue holds five; a sixth is dropped.
    for (0..queue_size + 1) |_| radio.say(&sound, "plck_001.ut", .queued, 1, -1, 300);
    try std.testing.expectEqual(queue_size, radio.count);
    radio.reset(&sound);
    try std.testing.expectEqual(0, radio.count);
}

test lineName {
    try std.testing.expectEqualStrings("ms1_ban_001", lineName("ms1_ban_001.ut"));
    try std.testing.expectEqualStrings("trnglnd_001", lineName("speech\\trnglnd_001.UT"));
    try std.testing.expectEqualStrings("plck_001.wav", lineName("plck_001.wav"));
    try std.testing.expectEqualStrings("abrt_001", lineName("abrt_001"));
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
