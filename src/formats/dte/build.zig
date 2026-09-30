//! The mission builder: makes a mission file from its records. It adds the records' names to the
//! string pool, places the script's routines, points each part and trigger at its routine, and
//! fills in the counts and the object table from the records, the way the shipped missions have
//! them. It checks the records first, and returns an error instead of a file when they contradict
//! each other or do not fit the file's fields.
//! [`docs/formats/dte.md`](../../../docs/formats/dte.md#building) describes it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dte = @import("../dte.zig");
const write = @import("write.zig");
const Section = dte.Section;

/// The object table's `first` for an object with no triggers, as in every shipped mission.
const no_triggers: u16 = 0xFFFF;

/// The last word of a flight group (`FlightGroup._unknown_10`), as in every shipped mission.
/// **Unknown:** what it means.
const group_tail: u32 = 0xFF19FFFF;

/// A ship's `launch_from` when it does not launch from another ship.
const no_ship_kind: u16 = 0xFFFF;

/// A trigger operand that is not checked: its low halfword is `dte.Reference.unset`.
const unset_operand: u32 = 0xFFFFFFFF;

/// `call_part` takes a part's index in one byte, so a mission has at most 256 parts.
const max_parts = 256;

/// Records with the values most shipped missions use. A caller starts from one of these and
/// changes the fields it needs.
pub const defaults = struct {
    /// A ship in no flight group, with no pilot, not launching from another ship, with every
    /// component intact, in no formation, not marking a curve, and fitted with the campaign's
    /// loadout tier.
    pub const ship: dte.Ship = ship: {
        var record = std.mem.zeroes(dte.Ship);
        record.flight_group = dte.Ship.no_flight_group;
        record.pilot = dte.Ship.no_pilot;
        record.launch_from = no_ship_kind;
        record._unknown_2a = 0xFF;
        record.launch_gate = dte.Ship.no_launch;
        record.intact_components = dte.Ship.all_intact;
        record.formation_point = dte.Ship.no_formation_point;
        record._unknown_36 = 0xFFFF;
        record._unknown_3c = 0xFF;
        record.tier = dte.Ship.campaign_tier;
        record.marker_curve = -1;
        record._unknown_42 = .{ 0xFF, 0xFF };
        break :ship record;
    };

    /// A flight group that is in no wing.
    pub const flight_group: dte.FlightGroup = .{
        .object_id = 0,
        ._unknown_02 = 0,
        .name = 0,
        ._unknown_06 = 0,
        .wing = .none,
        .ship_count = 0,
        ._unknown_0a = 0,
        .first_ship = 0,
        ._unknown_10 = group_tail,
    };

    /// A trigger that is armed, watches its whole subject rather than one of its components, runs
    /// its routine at once, fires once and checks none of its operands. **Unknown:** what
    /// `_unknown_04`, `_unknown_17` and `_unknown_1b` mean. The values here are the ones most
    /// shipped triggers have, except `_unknown_04`, which varies.
    pub const trigger: dte.Trigger = .{
        .condition = .shot_at,
        .repeat = .once,
        .link = dte.Part.no_block,
        ._unknown_04 = @splat(0),
        .armed = 1,
        .qualifier = dte.Trigger.whole_object,
        .deferred = 0,
        ._unknown_17 = .{ 0xFF, 0x00 },
        .repeat_counter = 0,
        .repeat_count = 0,
        ._unknown_1b = 0x88,
        .operands = @splat(unset_operand),
    };

    /// A part that does not run at the start and takes no arguments.
    pub const part: dte.Part = std.mem.zeroes(dte.Part);

    /// A global variable with the value 0.
    pub const global: dte.Global = std.mem.zeroes(dte.Global);
};

/// A ship and its name.
pub const Ship = struct {
    name: []const u8,
    /// The ship's record. The builder sets its `name` and writes every other field as given.
    record: dte.Ship,
};

/// A flight group and its name.
pub const FlightGroup = struct {
    name: []const u8,
    /// The flight group's record. The builder sets its `name`, `ship_count` and `first_ship`.
    record: dte.FlightGroup,
};

/// A global variable of the script and its name.
pub const Global = struct {
    name: []const u8,
    /// The variable's record. The builder sets its `name`.
    record: dte.Global,
};

/// A part of the script: a named routine that the script can call, or that runs at the start.
pub const Part = struct {
    name: []const u8,
    /// The part's record. The builder sets its `name`, `offset` and `length`.
    record: dte.Part,
    /// The index in `Mission.routines` of the routine the part runs, or null for a part with no
    /// routine. The game treats that part as empty: its `offset` is `dte.Part.no_block`, and its
    /// `length` 0.
    routine: ?usize,
};

/// A trigger: a routine that runs when something happens to the trigger's subject.
pub const Trigger = struct {
    /// The trigger's record. The builder sets its `link`.
    record: dte.Trigger,
    /// The index in `Mission.routines` of the routine the trigger runs, or null for a trigger that
    /// runs none: its `link` is `dte.Part.no_block`.
    routine: ?usize,
    /// The object ID of the ship, flight group or squad the trigger watches. The triggers that
    /// watch the same object must be next to each other in `Mission.triggers`, since the object
    /// table gives each object one run of triggers.
    subject: u16,
};

/// The records the builder makes a mission file from.
pub const Mission = struct {
    /// The name OpenReliant shows for the mission (`dte.OpenReliantName`), or null for none.
    name: ?[]const u8 = null,
    /// The flags in every directory entry.
    formats: dte.DirectoryEntry.Formats = write.template.formats,
    ships: []const Ship = &.{},
    flight_groups: []const FlightGroup = &.{},
    globals: []const Global = &.{},
    /// The script's routines, in the order they go in the script. Each one is the bytes of an
    /// assembled routine and its constants (`assemble.Routine.finish`).
    routines: []const []const u8 = &.{},
    parts: []const Part = &.{},
    triggers: []const Trigger = &.{},
    /// The contents of sections the builder does not make itself, such as the curves and the
    /// squads, written as given. `built_sections` lists the sections the builder makes.
    raw: [dte.section_count]?write.Contents = @splat(null),
};

/// The sections the builder makes from the records. `Mission.raw` can give any other section.
pub const built_sections = [_]Section{
    .strings, .globals, .ships,        .flight_groups, .triggers,         .script,
    .objects, .parts,   .script_flags, .command_flags, .openreliant_name,
};

pub const Error = write.Error || error{
    /// A name with a NUL byte in it. The string pool ends each name at its first NUL, so the game
    /// would read a shorter name than the one given. OpenReliant's name for the mission is
    /// checked the same way.
    NulInName,
    /// A string pool too large for the 16-bit offsets that records use to refer to it.
    PoolTooLarge,
    /// A routine with no bytes, so no instruction to run.
    EmptyRoutine,
    /// A routine with an odd number of bytes. The script counts its offsets in 16-bit words.
    OddRoutine,
    /// A routine that no part or trigger runs, so nothing can reach it.
    UnusedRoutine,
    /// A script with more bytes than a 16-bit count can hold. The script flags have one byte for
    /// each byte of the script.
    ScriptTooLarge,
    /// A part or trigger whose routine index is past the end of `Mission.routines`.
    NoSuchRoutine,
    /// A ship whose `flight_group` is neither the index of one of the mission's flight groups nor
    /// `dte.Ship.no_flight_group`.
    NoSuchFlightGroup,
    /// A trigger whose subject is not the object ID of a ship, flight group or squad.
    NoSuchObject,
    /// More records than the field that counts them can hold: parts (256), ships in one flight
    /// group (255), triggers on one object (255), object IDs (65535), or the records of a section
    /// (65535). The writer's template usually runs out of room first
    /// (`write.Error.SectionTooLarge`).
    TooMany,
    /// Two ships, flight groups or squads with the same object ID.
    SharedObjectId,
    /// Triggers that watch the same object but are not next to each other in `Mission.triggers`.
    TriggersApart,
    /// A raw section for a section that the builder makes itself (`built_sections`).
    SectionBuilt,
    /// A raw section whose count needs more bytes than it has: the count times the section's
    /// record size (`dte.Section.stride`).
    CountPastBytes,
    /// A raw section with records whose size is not known (`dte.Section.stride`).
    UnknownStride,
};

/// Makes the mission file for `mission`, in `gpa`. Returns an error instead, and makes nothing, if
/// the records contradict each other or do not fit the file's fields.
pub fn build(gpa: Allocator, mission: Mission) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try checkRaw(mission.raw);
    if (mission.name) |name| try checkName(name);
    for (mission.ships) |ship| {
        const group = ship.record.flight_group;
        if (group != dte.Ship.no_flight_group and group >= mission.flight_groups.len) return error.NoSuchFlightGroup;
    }
    if (mission.parts.len > max_parts) return error.TooMany;

    // Which routines the parts and the triggers run.
    const run_by_part = try arena.alloc(bool, mission.routines.len);
    @memset(run_by_part, false);
    const run_by_trigger = try arena.alloc(bool, mission.routines.len);
    @memset(run_by_trigger, false);
    for (mission.parts) |part| {
        const routine = part.routine orelse continue;
        if (routine >= mission.routines.len) return error.NoSuchRoutine;
        run_by_part[routine] = true;
    }
    for (mission.triggers) |trigger| {
        const routine = trigger.routine orelse continue;
        if (routine >= mission.routines.len) return error.NoSuchRoutine;
        run_by_trigger[routine] = true;
    }

    // The script: first the routines that only triggers run, then the others, each in the order
    // given, as most shipped missions place them. `dte.Mission.routines` finds a trigger's routine
    // only before the first part's. Each part and trigger points at the start of its routine,
    // counted in 16-bit words.
    var script: std.ArrayList(u8) = .empty;
    const starts = try arena.alloc(u16, mission.routines.len);
    for ([_]bool{ true, false }) |triggers_only| {
        for (mission.routines, starts, run_by_part, run_by_trigger) |routine, *start, by_part, by_trigger| {
            if ((by_trigger and !by_part) != triggers_only) continue;
            if (!by_part and !by_trigger) return error.UnusedRoutine;
            if (routine.len == 0) return error.EmptyRoutine;
            if (routine.len % @sizeOf(u16) != 0) return error.OddRoutine;
            start.* = halfwords(script.items.len) orelse return error.ScriptTooLarge;
            try script.appendSlice(arena, routine);
        }
    }
    // The script flags have one byte for each byte of the script, counted in 16 bits.
    if (script.items.len > std.math.maxInt(u16)) return error.ScriptTooLarge;
    const script_length = halfwords(script.items.len) orelse return error.ScriptTooLarge;

    // The records, with their names added to the pool in this order: the parts', the ships', the
    // flight groups', then the globals'.
    var pool: Pool = .{};
    const parts = try arena.alloc(dte.Part, mission.parts.len);
    for (parts, mission.parts) |*record, part| {
        record.* = part.record;
        record.name = try pool.offset(arena, part.name);
        if (part.routine) |routine| {
            record.offset = starts[routine];
            record.length = halfwords(mission.routines[routine].len) orelse return error.ScriptTooLarge;
        } else {
            record.offset = dte.Part.no_block;
            record.length = 0;
        }
    }
    const ships = try arena.alloc(dte.Ship, mission.ships.len);
    for (ships, mission.ships) |*record, ship| {
        record.* = ship.record;
        record.name = try pool.offset(arena, ship.name);
    }
    // Each flight group counts its ships. Its `first_ship` is where its first ship is in a list of
    // every group's ships, group by group, and `no_ship` for a group with none, as binding the
    // mission works them out again (`mission_list_group_ships`, `0x00452EC0`).
    const groups = try arena.alloc(dte.FlightGroup, mission.flight_groups.len);
    var listed: u32 = 0;
    for (groups, mission.flight_groups, 0..) |*record, group, index| {
        var in_group: usize = 0;
        for (mission.ships) |ship| {
            const own = ship.record.flightGroup() orelse continue;
            if (own == index) in_group += 1;
        }
        record.* = group.record;
        record.name = try pool.offset(arena, group.name);
        record.ship_count = std.math.cast(u8, in_group) orelse return error.TooMany;
        record.first_ship = if (in_group == 0) dte.FlightGroup.no_ship else listed;
        listed += @intCast(in_group);
    }
    const globals = try arena.alloc(dte.Global, mission.globals.len);
    for (globals, mission.globals) |*record, global| {
        record.* = global.record;
        record.name = try pool.offset(arena, global.name);
    }
    if (pool.bytes.items.len > std.math.maxInt(u16)) return error.PoolTooLarge;

    const triggers = try arena.alloc(dte.Trigger, mission.triggers.len);
    for (triggers, mission.triggers) |*record, trigger| {
        record.* = trigger.record;
        record.link = if (trigger.routine) |routine| starts[routine] else dte.Part.no_block;
    }
    const objects = try objectTable(arena, mission.ships, mission.flight_groups, rawSquads(mission.raw), mission.triggers);

    var sections: write.Sections = @splat(.{});
    for (&sections, mission.raw) |*section, given| {
        if (given) |contents| section.* = contents;
    }
    try set(&sections, .strings, pool.bytes.items.len, pool.bytes.items);
    try set(&sections, .globals, globals.len, std.mem.sliceAsBytes(globals));
    try set(&sections, .ships, ships.len, std.mem.sliceAsBytes(ships));
    try set(&sections, .flight_groups, groups.len, std.mem.sliceAsBytes(groups));
    try set(&sections, .triggers, triggers.len, std.mem.sliceAsBytes(triggers));
    try set(&sections, .script, script_length, script.items);
    try set(&sections, .objects, objects.len, std.mem.sliceAsBytes(objects));
    try set(&sections, .parts, parts.len, std.mem.sliceAsBytes(parts));
    // One flag for each byte of the script, all clear, as the script debugger reads them.
    if (script.items.len > 0) {
        const flags = try arena.alloc(u8, script.items.len);
        @memset(flags, 0);
        try set(&sections, .script_flags, flags.len, flags);
    }
    // The command flags of the missions the writer's template comes from.
    const command_flags = &write.template.command_flags;
    try set(&sections, .command_flags, command_flags.len, std.mem.sliceAsBytes(command_flags));
    return write.write(gpa, &sections, .{ .formats = mission.formats, .name = mission.name });
}

/// Checks the raw sections. None of them can be a section the builder makes, and each one needs
/// the bytes its count says it has: the count times the section's record size. Bytes after the
/// records are allowed and written as given.
fn checkRaw(raw: [dte.section_count]?write.Contents) Error!void {
    for (raw, 0..) |given, index| {
        const contents = given orelse continue;
        const section: Section = @enumFromInt(index);
        if (std.mem.indexOfScalar(Section, &built_sections, section) != null) return error.SectionBuilt;
        if (contents.count == 0) continue;
        const stride = section.stride() orelse return error.UnknownStride;
        if (@as(usize, contents.count) * stride > contents.bytes.len) return error.CountPastBytes;
    }
}

/// Checks that `name` has no NUL byte in it.
fn checkName(name: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.NulInName;
}

/// The squads of the raw squads section, if there is one. `checkRaw` has made sure it has the
/// bytes its count needs.
fn rawSquads(raw: [dte.section_count]?write.Contents) []align(1) const dte.Squad {
    const given = raw[@intFromEnum(Section.squads)] orelse return &.{};
    return std.mem.bytesAsSlice(dte.Squad, given.bytes[0 .. @as(usize, given.count) * @sizeOf(dte.Squad)]);
}

/// Sets section `which` of `sections` to `count` records in `bytes`, or returns `TooMany` if the
/// count does not fit the directory's 16-bit count.
fn set(sections: *write.Sections, which: Section, count: usize, bytes: []const u8) Error!void {
    if (count > std.math.maxInt(u16)) return error.TooMany;
    write.set(sections, which, count, bytes);
}

/// The object table, in `gpa`: one entry for each object ID from 0 to the highest one that a
/// ship, flight group or squad has. Each entry has the kind of the record with that ID and the
/// run of triggers that watch it. An ID that no record has gets the entry of a ship with no
/// triggers, like the unused IDs in the shipped missions.
fn objectTable(
    gpa: Allocator,
    ships: []const Ship,
    groups: []const FlightGroup,
    squads: []align(1) const dte.Squad,
    triggers: []const Trigger,
) Error![]dte.Object {
    var size: usize = 0;
    for (ships) |ship| size = @max(size, @as(usize, ship.record.object_id) + 1);
    for (groups) |group| size = @max(size, @as(usize, group.record.object_id) + 1);
    for (squads) |squad| size = @max(size, @as(usize, squad.object_id) + 1);
    // The directory counts the table's entries in 16 bits.
    if (size > std.math.maxInt(u16)) return error.TooMany;

    const table = try gpa.alloc(dte.Object, size);
    errdefer gpa.free(table);
    @memset(table, .{ .kind = .ship, .count = 0, .first = no_triggers, ._unknown_04 = 0 });
    const taken = try gpa.alloc(bool, size);
    defer gpa.free(taken);
    @memset(taken, false);
    for (ships) |ship| try claim(table, taken, ship.record.object_id, .ship);
    for (groups) |group| try claim(table, taken, group.record.object_id, .flight_group);
    for (squads) |squad| try claim(table, taken, squad.object_id, .squad);

    for (triggers, 0..) |trigger, index| {
        if (trigger.subject >= size or !taken[trigger.subject]) return error.NoSuchObject;
        const entry = &table[trigger.subject];
        if (entry.count == 0) {
            entry.first = std.math.cast(u16, index) orelse return error.TooMany;
        } else if (@as(usize, entry.first) + entry.count != index) return error.TriggersApart;
        entry.count = std.math.add(u8, entry.count, 1) catch return error.TooMany;
    }
    return table;
}

/// Marks object ID `id` as a record of `kind`, or returns `SharedObjectId` if another record has
/// it already.
fn claim(table: []dte.Object, taken: []bool, id: usize, kind: dte.Object.Kind) Error!void {
    if (taken[id]) return error.SharedObjectId;
    taken[id] = true;
    table[id].kind = kind;
}

/// The string pool: names that each end in a NUL, which records refer to by byte offset.
const Pool = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// The offset of each name in the pool, in order.
    starts: std.ArrayList(u16) = .empty,

    /// The offset of `name` in the pool. The name is added at the end if the pool does not have
    /// it yet, so each name is in the pool once.
    fn offset(pool: *Pool, gpa: Allocator, name: []const u8) Error!u16 {
        try checkName(name);
        if (pool.find(name)) |at| return at;
        const at = std.math.cast(u16, pool.bytes.items.len) orelse return error.PoolTooLarge;
        try pool.bytes.appendSlice(gpa, name);
        try pool.bytes.append(gpa, 0);
        try pool.starts.append(gpa, at);
        return at;
    }

    /// The offset of the name in the pool that equals `name`, if there is one.
    fn find(pool: Pool, name: []const u8) ?u16 {
        for (pool.starts.items) |at| {
            const rest = pool.bytes.items[at..];
            if (rest.len > name.len and rest[name.len] == 0 and std.mem.eql(u8, rest[0..name.len], name)) return at;
        }
        return null;
    }
};

/// The number of 16-bit words in `bytes` bytes, or null if a 16-bit count cannot hold it.
fn halfwords(bytes: usize) ?u16 {
    return std.math.cast(u16, bytes / @sizeOf(u16));
}

const testing = struct {
    /// Two routines that each return 1 at once, in `gpa`.
    fn routines(gpa: Allocator) ![2][]u8 {
        var all: [2][]u8 = undefined;
        for (&all) |*routine| {
            var block: @import("assemble.zig").Routine = .init(gpa);
            defer block.deinit();
            try block.op(.push_byte, &.{1});
            try block.op(.@"return", &.{});
            routine.* = try block.finish();
        }
        return all;
    }

    /// Three ships in two flight groups, a part that runs at the start, and a trigger on the
    /// second flight group. The trigger runs routine 0 of `blocks` and the part runs routine 1.
    fn mission(blocks: *const [2][]u8) Mission {
        return .{
            .name = "Test",
            .ships = comptime &.{
                .{ .name = "Player", .record = dte.testing.ship(0, 0, 0) },
                .{ .name = "Wingman", .record = dte.testing.ship(1, 0, 0) },
                .{ .name = "Enemy", .record = dte.testing.ship(2, 1, 0) },
            },
            .flight_groups = comptime &.{
                .{ .name = "(FG)Alpha", .record = dte.testing.flightGroup(3, .player) },
                .{ .name = "(FG)Enemy", .record = dte.testing.flightGroup(4, .none) },
            },
            .routines = blocks,
            .parts = comptime &.{.{ .name = "(F)Start", .record = startPart(), .routine = 1 }},
            .triggers = comptime &.{.{ .record = destroyed(), .routine = 0, .subject = 4 }},
        };
    }

    fn startPart() dte.Part {
        var record = defaults.part;
        record.flags.start = true;
        return record;
    }

    fn destroyed() dte.Trigger {
        var record = defaults.trigger;
        record.condition = .destroyed;
        return record;
    }
};

test build {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    const bytes = try build(gpa, testing.mission(&routines));
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);

    // The part's name is first in the pool.
    try std.testing.expectEqualStrings("(F)Start", file.name(0));
    try std.testing.expectEqualStrings("Wingman", file.name((try file.ships())[1].name));
    try std.testing.expectEqualStrings("(FG)Enemy", file.name((try file.flightGroups())[1].name));
    try std.testing.expectEqualStrings("Test", file.openReliantName().?);
    // Each flight group counts its ships, and the second group's ships come after the first's.
    const groups = try file.flightGroups();
    try std.testing.expectEqual(2, groups[0].ship_count);
    try std.testing.expectEqual(0, groups[0].first_ship);
    try std.testing.expectEqual(1, groups[1].ship_count);
    try std.testing.expectEqual(2, groups[1].first_ship);
    // The routines are in order: the trigger's first, then the part's.
    const part = (try file.parts())[0];
    try std.testing.expectEqual(routines[0].len, part.start());
    try std.testing.expectEqual(routines[1].len, part.size());
    try std.testing.expectEqual(0, (try file.triggers())[0].block().?);
    // The object table has the ships, then the flight groups. The second group's entry holds the
    // trigger.
    const objects = try file.objects();
    try std.testing.expectEqual(5, objects.len);
    try std.testing.expectEqual(dte.Object.Kind.flight_group, objects[4].kind);
    try std.testing.expectEqual(1, objects[4].count);
    try std.testing.expectEqual(0, objects[4].first);
    try std.testing.expectEqual(no_triggers, objects[0].first);
    // One script flag for each byte of the script, and the template's command flags.
    try std.testing.expectEqual((try file.script()).len, file.entry(.script_flags).count);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&write.template.command_flags), std.mem.sliceAsBytes(try file.records(u16, .command_flags)));
}

test "a name that several records have is in the pool once" {
    const ships = [_]Ship{
        .{ .name = "Raider", .record = dte.testing.ship(0, dte.Ship.no_flight_group, 0) },
        .{ .name = "Raider", .record = dte.testing.ship(1, dte.Ship.no_flight_group, 0) },
    };
    const bytes = try build(std.testing.allocator, .{ .ships = &ships });
    defer std.testing.allocator.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    const records = try file.ships();
    try std.testing.expectEqual(records[0].name, records[1].name);
    try std.testing.expectEqual("Raider".len + 1, file.entry(.strings).count);
}

test "inserting a ship updates the counts, the names and the object table" {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    var mission = testing.mission(&routines);
    // A second enemy goes first in the list, with the next free object ID. The builder does not
    // renumber references to ships by their index in the list, in trigger operands, curves and
    // the script: a caller that inserts a ship updates those. This mission has none.
    const ships = [_]Ship{.{ .name = "Second enemy", .record = dte.testing.ship(5, 1, 0) }} ++ mission.ships[0..3].*;
    mission.ships = &ships;
    const bytes = try build(gpa, mission);
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);

    // The first group keeps its two ships at the start of the list, and the second group now has
    // two ships after them.
    const groups = try file.flightGroups();
    try std.testing.expectEqual(2, groups[0].ship_count);
    try std.testing.expectEqual(0, groups[0].first_ship);
    try std.testing.expectEqual(2, groups[1].ship_count);
    try std.testing.expectEqual(2, groups[1].first_ship);
    // Every ship still has its own name.
    const records = try file.ships();
    for (records, ships) |record, ship| try std.testing.expectEqualStrings(ship.name, file.name(record.name));
    // The new object ID is in the table, and the trigger still watches the second flight group.
    const objects = try file.objects();
    try std.testing.expectEqual(6, objects.len);
    try std.testing.expectEqual(dte.Object.Kind.ship, objects[5].kind);
    try std.testing.expectEqual(1, objects[4].count);
    try std.testing.expectEqual(0, objects[4].first);
}

test "a raw section for a section the builder makes is refused" {
    // The builder makes the ships section from `Mission.ships`, so a raw one would contradict it.
    var mission: Mission = .{};
    mission.raw[@intFromEnum(Section.ships)] = .{ .count = 65535, .bytes = "" };
    try std.testing.expectError(error.SectionBuilt, build(std.testing.allocator, mission));
}

test "a raw section needs the bytes its count says it has" {
    const gpa = std.testing.allocator;
    const curve = [_]u8{0} ** @sizeOf(dte.Curve);
    var mission: Mission = .{};
    mission.raw[@intFromEnum(Section.curves)] = .{ .count = 2, .bytes = &curve };
    try std.testing.expectError(error.CountPastBytes, build(gpa, mission));
    // Bytes after the records are allowed, and the file has one curve.
    const padded = curve ++ [_]u8{0} ** 4;
    mission.raw[@intFromEnum(Section.curves)] = .{ .count = 1, .bytes = &padded };
    const bytes = try build(gpa, mission);
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    try std.testing.expectEqual(1, (try file.records(dte.Curve, .curves)).len);
}

test "a raw section of unknown record size must be empty" {
    const gpa = std.testing.allocator;
    var mission: Mission = .{};
    mission.raw[@intFromEnum(Section.unused_20)] = .{ .count = 1, .bytes = "abcd" };
    try std.testing.expectError(error.UnknownStride, build(gpa, mission));
    mission.raw[@intFromEnum(Section.unused_20)] = .{ .count = 0, .bytes = "" };
    gpa.free(try build(gpa, mission));
}

test "the squads of a raw squads section are in the object table" {
    const gpa = std.testing.allocator;
    var squad = std.mem.zeroes(dte.Squad);
    squad.object_id = 1;
    squad.first_member = dte.Squad.no_member;
    const ships = [_]Ship{.{ .name = "Player", .record = dte.testing.ship(0, dte.Ship.no_flight_group, 0) }};
    var mission: Mission = .{ .ships = &ships };
    mission.raw[@intFromEnum(Section.squads)] = .{ .count = 1, .bytes = std.mem.asBytes(&squad) };
    const bytes = try build(gpa, mission);
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    try std.testing.expectEqual(dte.Object.Kind.squad, (try file.objects())[1].kind);
    // A squad with the ship's object ID is refused.
    squad.object_id = 0;
    try std.testing.expectError(error.SharedObjectId, build(gpa, mission));
}

test "a name with a NUL in it is refused" {
    const gpa = std.testing.allocator;
    const ships = [_]Ship{.{ .name = "Player\x00Extra", .record = dte.testing.ship(0, dte.Ship.no_flight_group, 0) }};
    try std.testing.expectError(error.NulInName, build(gpa, .{ .ships = &ships }));
    try std.testing.expectError(error.NulInName, build(gpa, .{ .name = "Test\x00Extra" }));
}

test "a ship in a flight group the mission does not have is refused" {
    const ships = [_]Ship{.{ .name = "Player", .record = dte.testing.ship(0, 3, 0) }};
    try std.testing.expectError(error.NoSuchFlightGroup, build(std.testing.allocator, .{ .ships = &ships }));
}

test "a part or trigger that runs a routine the mission does not have is refused" {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    var mission = testing.mission(&routines);
    mission.parts = comptime &.{.{ .name = "(F)Start", .record = testing.startPart(), .routine = 2 }};
    try std.testing.expectError(error.NoSuchRoutine, build(gpa, mission));
    mission = testing.mission(&routines);
    mission.triggers = comptime &.{.{ .record = testing.destroyed(), .routine = 2, .subject = 4 }};
    try std.testing.expectError(error.NoSuchRoutine, build(gpa, mission));
}

test "a trigger on an object ID that no record has is refused" {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    var mission = testing.mission(&routines);
    mission.triggers = comptime &.{.{ .record = testing.destroyed(), .routine = 0, .subject = 9 }};
    try std.testing.expectError(error.NoSuchObject, build(gpa, mission));
}

test "an empty, odd-sized or unused routine is refused" {
    const gpa = std.testing.allocator;
    const parts = [_]Part{.{ .name = "(F)Start", .record = testing.startPart(), .routine = 0 }};
    try std.testing.expectError(error.EmptyRoutine, build(gpa, .{ .routines = &.{""}, .parts = &parts }));
    try std.testing.expectError(error.OddRoutine, build(gpa, .{ .routines = &.{"\x01"}, .parts = &parts }));
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    try std.testing.expectError(error.UnusedRoutine, build(gpa, .{ .routines = &routines, .parts = &parts }));
}

test "more parts than call_part can reach are refused" {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    const parts: [max_parts + 1]Part = @splat(.{ .name = "(F)Part", .record = defaults.part, .routine = 0 });
    try std.testing.expectError(error.TooMany, build(gpa, .{ .routines = &routines, .parts = &parts }));
}

test "an object ID too large for the object table is refused before the table is made" {
    var ship = defaults.ship;
    ship.object_id = std.math.maxInt(u32);
    const ships = [_]Ship{.{ .name = "Player", .record = ship }};
    // An allocator that fails at once: the ID is refused before a table of that size is allocated.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.TooMany, objectTable(failing.allocator(), &ships, &.{}, &.{}, &.{}));
    try std.testing.expectError(error.TooMany, build(std.testing.allocator, .{ .ships = &ships }));
}

test "an object's triggers are next to each other, and an object ID belongs to one record" {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    const ships = [_]Ship{
        .{ .name = "One", .record = dte.testing.ship(0, dte.Ship.no_flight_group, 0) },
        .{ .name = "Two", .record = dte.testing.ship(1, dte.Ship.no_flight_group, 0) },
    };
    const apart = [_]Trigger{
        .{ .record = defaults.trigger, .routine = 0, .subject = 0 },
        .{ .record = defaults.trigger, .routine = 0, .subject = 1 },
        .{ .record = defaults.trigger, .routine = 0, .subject = 0 },
    };
    try std.testing.expectError(error.TriggersApart, build(gpa, .{ .ships = &ships, .routines = routines[0..1], .triggers = &apart }));
    const shared = [_]Ship{
        .{ .name = "One", .record = dte.testing.ship(0, dte.Ship.no_flight_group, 0) },
        .{ .name = "Two", .record = dte.testing.ship(0, dte.Ship.no_flight_group, 0) },
    };
    try std.testing.expectError(error.SharedObjectId, build(gpa, .{ .ships = &shared }));
}

test "the routines that only triggers run go first, where the reader looks for them" {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    // The part's routine is given first and the trigger's second.
    var mission = testing.mission(&routines);
    mission.parts = comptime &.{.{ .name = "(F)Start", .record = testing.startPart(), .routine = 0 }};
    mission.triggers = comptime &.{.{ .record = testing.destroyed(), .routine = 1, .subject = 4 }};
    const bytes = try build(gpa, mission);
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    // The trigger's routine starts the script, and the reader lists both routines.
    try std.testing.expectEqual(0, (try file.triggers())[0].block().?);
    try std.testing.expectEqual(routines[1].len, (try file.parts())[0].start());
    const listed = try file.routines(gpa);
    defer {
        for (listed) |routine| switch (routine.owner) {
            .triggers => |indices| gpa.free(indices),
            .part => {},
        };
        gpa.free(listed);
    }
    try std.testing.expectEqual(2, listed.len);
}

test "a part or trigger with no routine is written as empty" {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    // Shipped missions have such records: 7 of 1630 parts and 69 of 2446 triggers.
    var mission = testing.mission(&routines);
    mission.routines = routines[1..2];
    mission.parts = comptime &.{
        .{ .name = "(F)Start", .record = testing.startPart(), .routine = 0 },
        .{ .name = "(F)Empty", .record = defaults.part, .routine = null },
    };
    mission.triggers = comptime &.{.{ .record = testing.destroyed(), .routine = null, .subject = 4 }};
    const bytes = try build(gpa, mission);
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    const parts = try file.parts();
    try std.testing.expect(parts[1].isEmpty());
    try std.testing.expectEqual(0, parts[1].length);
    try std.testing.expectEqual(null, (try file.triggers())[0].block());
    // The trigger still watches its flight group.
    try std.testing.expectEqual(1, (try file.objects())[4].count);
}

test "a ship in no flight group is in no group's count, even the 256th group's" {
    const gpa = std.testing.allocator;
    var groups: [256]FlightGroup = undefined;
    for (&groups, 0..) |*group, index| {
        var record = defaults.flight_group;
        record.object_id = @intCast(index + 1);
        group.* = .{ .name = "(FG)Group", .record = record };
    }
    const ships = [_]Ship{.{ .name = "Loner", .record = dte.testing.ship(0, dte.Ship.no_flight_group, 0) }};
    const bytes = try build(gpa, .{ .ships = &ships, .flight_groups = &groups });
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    try std.testing.expectEqual(0, (try file.flightGroups())[255].ship_count);
}

test "a flight group with no ships has no first ship, as binding gives it" {
    const gpa = std.testing.allocator;
    var empty = defaults.flight_group;
    empty.object_id = 1;
    var full = defaults.flight_group;
    full.object_id = 2;
    const ships = [_]Ship{.{ .name = "Raider", .record = dte.testing.ship(0, 1, 0) }};
    const groups = [_]FlightGroup{ .{ .name = "(FG)Empty", .record = empty }, .{ .name = "(FG)Raiders", .record = full } };
    const bytes = try build(gpa, .{ .ships = &ships, .flight_groups = &groups });
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    const records = try file.flightGroups();
    try std.testing.expectEqual(dte.FlightGroup.no_ship, records[0].first_ship);
    try std.testing.expectEqual(0, records[1].first_ship);
}

test "a script larger than a 16-bit count of bytes is refused" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 65536);
    defer gpa.free(big);
    @memset(big, 0);
    const parts = [_]Part{.{ .name = "(F)Start", .record = testing.startPart(), .routine = 0 }};
    try std.testing.expectError(error.ScriptTooLarge, build(gpa, .{ .routines = &.{big}, .parts = &parts }));
}
