//! Building a mission from its records: the names put in the string pool, the script's routines
//! laid out in turn, each part and trigger linked to its routine, and the counts and tables the
//! records imply worked out as the shipped missions' files hold them. What a mission gives as it is,
//! a section or an object's entry, is kept as it is, so that a mission read from a file builds
//! back into the same records. [`docs/formats/dte.md`](../../../docs/formats/dte.md#building)
//! describes it; [`source.zig`](source.zig) reads it from, and writes it to, a mission's source.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dte = @import("../dte.zig");
const write = @import("write.zig");
const Section = dte.Section;

/// The object table's `first` for an object with no triggers, as every such entry of the shipped
/// missions has it.
pub const no_triggers: u16 = 0xFFFF;

/// A flight group's last word (`FlightGroup._unknown_10`), as every flight group of the shipped
/// missions has it. **Unknown:** what it means.
pub const group_tail: u32 = 0xFF19FFFF;

/// The records as most of the shipped missions' records hold them, which a mission's own values
/// then change.
pub const defaults = struct {
    /// A ship in no flight group, flown by no pilot, launching from nothing, every component
    /// intact, in no formation, fitted by the campaign's tier, and marking no curve.
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

    /// A flight group listed in no wing.
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

    /// A trigger armed, on the subject itself, whose thread runs at once, firing once, with no
    /// operand checked. **Unknown:** what `_unknown_04`, `_unknown_17` and `_unknown_1b` mean;
    /// these are the values most shipped triggers hold, save `_unknown_04`, which varies.
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

    pub const global: dte.Global = std.mem.zeroes(dte.Global);
};

/// A ship's `launch_from` where it launches from nothing.
pub const no_ship_kind: u16 = 0xFFFF;

/// A trigger's operand that is not checked: its low halfword is `dte.Reference.unset`.
pub const unset_operand: u32 = 0xFFFFFFFF;

/// A name the string pool holds.
pub const Name = union(enum) {
    /// The text: the first of the pool's strings that is the text, or a new one at the pool's end.
    text: []const u8,
    /// A byte offset into the pool, as a file holds it.
    at: u16,
};

pub const Ship = struct {
    name: Name,
    /// The record, whose `name` the pool's offset takes.
    record: dte.Ship,
};

pub const FlightGroup = struct {
    name: Name,
    record: dte.FlightGroup,
    /// Whether its `ship_count` and `first_ship` are worked out from the ships (`groupCounts`), or
    /// kept as the record has them.
    counted: bool = true,
};

pub const Global = struct {
    name: Name,
    record: dte.Global,
};

pub const Part = struct {
    name: Name,
    record: dte.Part,
    /// The routine that is the part's block, whose place gives its `offset`; null for a part whose
    /// record keeps its own, as one with no block does.
    routine: ?usize = null,
    /// Whether its `length` is its routine's, or kept as the record has it.
    measured: bool = true,
};

pub const Trigger = struct {
    record: dte.Trigger,
    /// The routine it runs, whose place gives its `link`; null for one whose record keeps its own.
    routine: ?usize = null,
    /// The object whose slice of the trigger list holds it, by object ID; null for none, which
    /// leaves the trigger unable to fire.
    subject: ?u32 = null,
};

/// What a mission holds, from which `build` makes its file.
pub const Mission = struct {
    /// OpenReliant's name for it (`dte.OpenReliantName`).
    name: ?[]const u8 = null,
    formats: dte.DirectoryEntry.Formats = write.template.formats,
    /// The strings the pool starts with, in order, each NUL-terminated, as a file holds them. The
    /// names not among them follow: the parts', the ships', the flight groups', then the globals'.
    strings: []const []const u8 = &.{},
    ships: []const Ship = &.{},
    flight_groups: []const FlightGroup = &.{},
    globals: []const Global = &.{},
    /// The script's routines in order, each a block and its constants (`assemble.Routine.finish`),
    /// or bytes as a file holds them.
    routines: []const []const u8 = &.{},
    parts: []const Part = &.{},
    triggers: []const Trigger = &.{},
    /// The object table as it is, in place of the one the records imply (`objectTable`).
    objects: ?[]const dte.Object = null,
    /// Sections as they are, in place of what the rest gives them.
    sections: [dte.section_count]?write.Contents = @splat(null),
};

pub const Error = write.Error || error{
    /// A `Name.at` past the pool's end, or a name or string a pool given as it is does not hold.
    NameOutsidePool,
    /// A string pool longer than its count can say.
    PoolTooLarge,
    /// A routine of an odd number of bytes: the script counts its places in halfwords.
    OddRoutine,
    /// A script longer than a part's offset or the directory's count can say.
    ScriptTooLarge,
    /// A part or trigger naming a routine the mission does not have.
    NoSuchRoutine,
    /// More ships in a flight group, triggers in an object's slice, or objects than their count can
    /// say.
    TooMany,
    /// A section given as it is whose bytes are not a whole number of its records.
    PartialRecord,
    /// Two records with the same object ID.
    SharedObjectId,
    /// An object's triggers apart in the list: a slice is a run of the list.
    TriggersApart,
};

/// How many of the mission's ships a flight group has, and where the first stands in the list of
/// the groups' ships, as the shipped missions' files hold them: the groups' ships in the groups'
/// order, each group's in the mission's order, and for a group with none the place its first
/// would take. Binding works them out again (`mission_list_group_ships`, `0x00452EC0`), and gives
/// a group with none `FlightGroup.no_ship`.
pub const GroupCount = struct { ship_count: u8, first_ship: u32 };

/// Each flight group's `GroupCount`, in `gpa`.
pub fn groupCounts(gpa: Allocator, ships: []const Ship, group_count: usize) Error![]GroupCount {
    const counts = try gpa.alloc(GroupCount, group_count);
    var listed: u32 = 0;
    for (counts, 0..) |*count, group| {
        var in_group: usize = 0;
        for (ships) |ship| {
            if (ship.record.flight_group == group) in_group += 1;
        }
        count.* = .{ .ship_count = std.math.cast(u8, in_group) orelse return error.TooMany, .first_ship = listed };
        listed += @intCast(in_group);
    }
    return counts;
}

/// The object table the records imply, in `gpa`: an entry for each object ID up to the highest
/// the ships, flight groups and squads take, of the kind of the record that takes it, and for
/// each object the run of the triggers whose subject it is. An ID no record takes gets an entry of
/// a ship with no triggers.
pub fn objectTable(
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
    for (triggers) |trigger| {
        if (trigger.subject) |id| size = @max(size, @as(usize, id) + 1);
    }
    // The directory counts the table's entries in a `u16`.
    if (size > std.math.maxInt(u16)) return error.TooMany;

    const table = try gpa.alloc(dte.Object, size);
    errdefer gpa.free(table);
    @memset(table, .{ .kind = .ship, .count = 0, .first = no_triggers, ._unknown_04 = 0 });
    const claimed = try gpa.alloc(bool, size);
    defer gpa.free(claimed);
    @memset(claimed, false);
    const claim = struct {
        fn claim(all: []dte.Object, taken: []bool, id: usize, kind: dte.Object.Kind) Error!void {
            if (taken[id]) return error.SharedObjectId;
            taken[id] = true;
            all[id].kind = kind;
        }
    }.claim;
    for (ships) |ship| try claim(table, claimed, ship.record.object_id, .ship);
    for (groups) |group| try claim(table, claimed, group.record.object_id, .flight_group);
    for (squads) |squad| try claim(table, claimed, squad.object_id, .squad);

    for (triggers, 0..) |trigger, index| {
        const id = trigger.subject orelse continue;
        const entry = &table[id];
        if (entry.count == 0) {
            entry.first = std.math.cast(u16, index) orelse return error.TooMany;
        } else if (@as(usize, entry.first) + entry.count != index) return error.TriggersApart;
        entry.count = std.math.add(u8, entry.count, 1) catch return error.TooMany;
    }
    return table;
}

/// The squads of the section `mission` gives as it is, which the object table counts: none where
/// it gives none.
pub fn givenSquads(mission: Mission) Error![]align(1) const dte.Squad {
    const given = mission.sections[@intFromEnum(Section.squads)] orelse return &.{};
    if (given.bytes.len % @sizeOf(dte.Squad) != 0) return error.PartialRecord;
    return std.mem.bytesAsSlice(dte.Squad, given.bytes);
}

/// The string pool: NUL-terminated strings, which records name by byte offset.
const Pool = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Where each string starts, in order.
    starts: std.ArrayList(u16) = .empty,
    /// Set for a pool given as it is (`Mission.sections`), which takes no new strings.
    given: bool = false,

    /// The pool `bytes` hold, as a section given as it is holds it.
    fn of(gpa: Allocator, bytes: []const u8) Error!Pool {
        var pool: Pool = .{ .given = true };
        try pool.bytes.appendSlice(gpa, bytes);
        var at: usize = 0;
        while (at < bytes.len) {
            try pool.starts.append(gpa, std.math.cast(u16, at) orelse return error.PoolTooLarge);
            at = (std.mem.indexOfScalarPos(u8, bytes, at, 0) orelse break) + 1;
        }
        return pool;
    }

    /// Adds `text` at the end, NUL-terminated, whether or not the pool holds it already.
    fn add(pool: *Pool, gpa: Allocator, text: []const u8) Error!void {
        const at = std.math.cast(u16, pool.bytes.items.len) orelse return error.PoolTooLarge;
        try pool.bytes.appendSlice(gpa, text);
        try pool.bytes.append(gpa, 0);
        try pool.starts.append(gpa, at);
    }

    /// The offset of the first string that is `text`, where the pool holds one.
    fn find(pool: Pool, text: []const u8) ?u16 {
        for (pool.starts.items) |at| {
            const rest = pool.bytes.items[at..];
            if (rest.len > text.len and rest[text.len] == 0 and std.mem.eql(u8, rest[0..text.len], text)) return at;
        }
        return null;
    }

    /// The offset `name` gives, adding its text where the pool does not hold it.
    fn offset(pool: *Pool, gpa: Allocator, name: Name) Error!u16 {
        switch (name) {
            .at => |at| return if (at < pool.bytes.items.len) at else error.NameOutsidePool,
            .text => |text| {
                if (pool.find(text)) |at| return at;
                if (pool.given) return error.NameOutsidePool;
                const at = std.math.cast(u16, pool.bytes.items.len) orelse return error.PoolTooLarge;
                try pool.add(gpa, text);
                return at;
            },
        }
    }
};

/// The file `mission` makes, laid out as `write` lays a mission out, in `gpa`.
pub fn build(gpa: Allocator, mission: Mission) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The pool: the section as it is given, or the strings as given, then each name not among
    // them, in the order the file's records come.
    var pool: Pool = if (mission.sections[@intFromEnum(Section.strings)]) |given| try .of(arena, given.bytes) else .{};
    for (mission.strings) |text| {
        if (pool.given) return error.NameOutsidePool;
        try pool.add(arena, text);
    }
    const parts = try arena.alloc(dte.Part, mission.parts.len);
    for (parts, mission.parts) |*record, part| {
        record.* = part.record;
        record.name = try pool.offset(arena, part.name);
    }
    const ships = try arena.alloc(dte.Ship, mission.ships.len);
    for (ships, mission.ships) |*record, ship| {
        record.* = ship.record;
        record.name = try pool.offset(arena, ship.name);
    }
    const groups = try arena.alloc(dte.FlightGroup, mission.flight_groups.len);
    const counts = try groupCounts(arena, mission.ships, groups.len);
    for (groups, mission.flight_groups, counts) |*record, group, count| {
        record.* = group.record;
        record.name = try pool.offset(arena, group.name);
        if (group.counted) {
            record.ship_count = count.ship_count;
            record.first_ship = count.first_ship;
        }
    }
    const globals = try arena.alloc(dte.Global, mission.globals.len);
    for (globals, mission.globals) |*record, global| {
        record.* = global.record;
        record.name = try pool.offset(arena, global.name);
    }

    // The script: the routines in turn, each part and trigger at its routine's place.
    var script: std.ArrayList(u8) = .empty;
    const starts = try arena.alloc(u16, mission.routines.len);
    for (starts, mission.routines) |*start, routine| {
        if (routine.len % @sizeOf(u16) != 0) return error.OddRoutine;
        start.* = halfwords(script.items.len) orelse return error.ScriptTooLarge;
        try script.appendSlice(arena, routine);
    }
    const script_length = halfwords(script.items.len) orelse return error.ScriptTooLarge;
    for (parts, mission.parts) |*record, part| {
        const routine = part.routine orelse continue;
        if (routine >= starts.len) return error.NoSuchRoutine;
        record.offset = starts[routine];
        if (part.measured) record.length = halfwords(mission.routines[routine].len) orelse return error.ScriptTooLarge;
    }
    const triggers = try arena.alloc(dte.Trigger, mission.triggers.len);
    for (triggers, mission.triggers) |*record, trigger| {
        record.* = trigger.record;
        const routine = trigger.routine orelse continue;
        if (routine >= starts.len) return error.NoSuchRoutine;
        record.link = starts[routine];
    }

    var sections: write.Sections = @splat(.{});
    const set = struct {
        /// `write.set`, for a count a description gives: `TooMany` where it does not fit the
        /// directory's `u16`.
        fn set(all: *write.Sections, which: Section, count: usize, bytes: []const u8) Error!void {
            if (count > std.math.maxInt(u16)) return error.TooMany;
            write.set(all, which, count, bytes);
        }
    }.set;
    const objects = mission.objects orelse try objectTable(arena, mission.ships, mission.flight_groups, try givenSquads(mission), mission.triggers);

    if (pool.bytes.items.len > std.math.maxInt(u16)) return error.PoolTooLarge;
    try set(&sections, .strings, pool.bytes.items.len, pool.bytes.items);
    try set(&sections, .globals, globals.len, std.mem.sliceAsBytes(globals));
    try set(&sections, .ships, ships.len, std.mem.sliceAsBytes(ships));
    try set(&sections, .flight_groups, groups.len, std.mem.sliceAsBytes(groups));
    try set(&sections, .triggers, triggers.len, std.mem.sliceAsBytes(triggers));
    try set(&sections, .script, script_length, script.items);
    try set(&sections, .objects, objects.len, std.mem.sliceAsBytes(objects));
    try set(&sections, .parts, parts.len, std.mem.sliceAsBytes(parts));
    // A flag for each script byte, none set, and the command flags of the template's missions.
    if (script.items.len > 0) {
        const flags = try arena.alloc(u8, script.items.len);
        @memset(flags, 0);
        try set(&sections, .script_flags, flags.len, flags);
    }
    const command_flags = &write.template.command_flags;
    try set(&sections, .command_flags, command_flags.len, std.mem.sliceAsBytes(command_flags));
    for (&sections, mission.sections) |*section, given| {
        if (given) |contents| section.* = contents;
    }
    return write.write(gpa, &sections, .{ .formats = mission.formats, .name = mission.name });
}

/// `bytes` counted in halfwords, as the script's places are, where a halfword count can say it.
pub fn halfwords(bytes: usize) ?u16 {
    return std.math.cast(u16, bytes / @sizeOf(u16));
}

const testing = struct {
    /// Two blocks that return at once, in `gpa`.
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

    /// A mission of three ships in two flight groups, a part that runs at the start and a trigger
    /// on the second group, whose routines are `blocks`: the trigger's first.
    fn mission(blocks: *const [2][]u8) Mission {
        return .{
            .name = "Test",
            .ships = comptime &.{
                .{ .name = .{ .text = "Player" }, .record = dte.testing.ship(0, 0, 0) },
                .{ .name = .{ .text = "Wingman" }, .record = dte.testing.ship(1, 0, 0) },
                .{ .name = .{ .text = "Enemy" }, .record = dte.testing.ship(2, 1, 0) },
            },
            .flight_groups = comptime &.{
                .{ .name = .{ .text = "(FG)Alpha" }, .record = dte.testing.flightGroup(3, .player) },
                .{ .name = .{ .text = "(FG)Enemy" }, .record = dte.testing.flightGroup(4, .none) },
            },
            .routines = blocks,
            .parts = comptime &.{.{ .name = .{ .text = "(F)Start" }, .record = startPart(), .routine = 1 }},
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

    // The names in the pool, the part's first, each once.
    try std.testing.expectEqualStrings("(F)Start", file.name(0));
    try std.testing.expectEqualStrings("Wingman", file.name((try file.ships())[1].name));
    try std.testing.expectEqualStrings("(FG)Enemy", file.name((try file.flightGroups())[1].name));
    try std.testing.expectEqualStrings("Test", file.openReliantName().?);
    // Each group counts its ships, listed in the groups' order.
    const groups = try file.flightGroups();
    try std.testing.expectEqual(2, groups[0].ship_count);
    try std.testing.expectEqual(0, groups[0].first_ship);
    try std.testing.expectEqual(1, groups[1].ship_count);
    try std.testing.expectEqual(2, groups[1].first_ship);
    // The routines in turn: the trigger's block first, then the part's.
    const part = (try file.parts())[0];
    try std.testing.expectEqual(routines[0].len, part.start());
    try std.testing.expectEqual(routines[1].len, part.size());
    try std.testing.expectEqual(0, (try file.triggers())[0].block().?);
    // The object table: the ships, then the groups, the second group's slice holding the trigger.
    const objects = try file.objects();
    try std.testing.expectEqual(5, objects.len);
    try std.testing.expectEqual(dte.Object.Kind.flight_group, objects[4].kind);
    try std.testing.expectEqual(1, objects[4].count);
    try std.testing.expectEqual(0, objects[4].first);
    try std.testing.expectEqual(no_triggers, objects[0].first);
    // A flag for each script byte, and the template's command flags.
    try std.testing.expectEqual((try file.script()).len, file.entry(.script_flags).count);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&write.template.command_flags), std.mem.sliceAsBytes(try file.records(u16, .command_flags)));
}

test "a section given as it is stands in for the one the records make" {
    const gpa = std.testing.allocator;
    const routines = try testing.routines(gpa);
    defer for (routines) |routine| gpa.free(routine);
    var mission = testing.mission(&routines);
    mission.sections[@intFromEnum(Section.command_flags)] = .{};
    mission.strings = &.{ "Unused", "Player" };
    const bytes = try build(gpa, mission);
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    try std.testing.expectEqual(0, file.entry(.command_flags).count);
    // The given strings first, which the names then find.
    try std.testing.expectEqualStrings("Unused", file.name(0));
    try std.testing.expectEqual(7, (try file.ships())[0].name);
}

test "a section of squads given as it is holds whole records" {
    var mission: Mission = .{};
    mission.sections[@intFromEnum(Section.squads)] = .{ .count = 1, .bytes = "\x00" };
    try std.testing.expectError(error.PartialRecord, build(std.testing.allocator, mission));
}

test "an object ID past what the object table can count fails" {
    const gpa = std.testing.allocator;
    var ship = defaults.ship;
    ship.object_id = 70000;
    try std.testing.expectError(error.TooMany, objectTable(gpa, &.{.{ .name = .{ .at = 0 }, .record = ship }}, &.{}, &.{}, &.{}));
    const subject = [_]Trigger{.{ .record = defaults.trigger, .subject = 70000 }};
    try std.testing.expectError(error.TooMany, objectTable(gpa, &.{}, &.{}, &.{}, &subject));
}

test "an object's triggers are a run of the list" {
    const gpa = std.testing.allocator;
    const ships = [_]Ship{ .{ .name = .{ .at = 0 }, .record = dte.testing.ship(0, 0, 0) }, .{ .name = .{ .at = 0 }, .record = dte.testing.ship(1, 0, 0) } };
    const apart = [_]Trigger{ .{ .record = defaults.trigger, .subject = 0 }, .{ .record = defaults.trigger, .subject = 1 }, .{ .record = defaults.trigger, .subject = 0 } };
    try std.testing.expectError(error.TriggersApart, objectTable(gpa, &ships, &.{}, &.{}, &apart));
    const shared = [_]Ship{ .{ .name = .{ .at = 0 }, .record = dte.testing.ship(0, 0, 0) }, .{ .name = .{ .at = 0 }, .record = dte.testing.ship(0, 0, 0) } };
    try std.testing.expectError(error.SharedObjectId, objectTable(gpa, &shared, &.{}, &.{}, &.{}));
}
