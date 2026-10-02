//! A mission's source: the mission as JSON, which a person or a tool writes and `build.build` makes
//! a file of. Each record gives only what differs from what the builder would give it, so a new
//! mission stays short, and a mission read from a file (`fromFile`) writes back into the same
//! records. A routine of the script is either the instructions a file holds, or statements that
//! name the Executor's commands and the mission's ships and flight groups.
//! [`docs/formats/dte.md`](../../../docs/formats/dte.md#building) describes the source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Stringify = json.Stringify;

const dte = @import("../dte.zig");
const build = @import("build.zig");
const write = @import("write.zig");
const assemble = @import("assemble.zig");
const rules = @import("rules.zig");
const commands = @import("../../engine/game/executor/commands.zig");
const conditions = @import("../../engine/vm/conditions.zig");
const opcodes = @import("../../engine/vm/opcodes.zig");
const Type = @import("../../engine/game/gameobj.zig").Type;
const Variables = @import("../../engine/vm.zig").Variables;
const Section = dte.Section;

/// The version of the source this module writes, and the only one it reads.
pub const version = 1;

/// The sections the source gives by their records; any other a mission holds is given as it is.
const typed_sections = [_]Section{
    .strings, .globals, .ships,        .flight_groups,    .triggers,      .script,
    .objects, .parts,   .script_flags, .openreliant_name, .command_flags,
};

fn isTyped(section: Section) bool {
    return std.mem.indexOfScalar(Section, &typed_sections, section) != null;
}

// Reading a mission file.

/// A mission file as `build.build` makes it back.
pub const Read = struct {
    mission: build.Mission,
    /// The sections given as they are only because their records would not build back the same:
    /// none, for every mission the source reads in full.
    whole: []const Section,
};

pub const ReadError = Allocator.Error || dte.Error || build.Error || error{
    UnknownStride,
    /// Built back even with every section as it is, the records differ.
    NotTheSame,
};

/// `file` as `build.build` makes it back, its records the same (`write.sameRecords`), in `arena`:
/// each record as the file holds it, each name by its text where the text finds it, and each
/// count, link and table the builder works out left to it where it works out the file's own. A
/// section whose records would still build back otherwise is given as it is.
pub fn fromFile(arena: Allocator, file: dte.Mission) ReadError!Read {
    const read = try write.records(file);
    var mission: build.Mission = .{
        .name = file.openReliantName(),
        .formats = if (file.directory.len > 0) file.directory[0].formats else write.template.formats,
    };

    // The pool, as its strings where it is a run of them in UTF-8.
    const pool_bytes = read[@intFromEnum(Section.strings)].bytes;
    const pool = try Pool.split(arena, pool_bytes);
    mission.strings = pool.texts orelse &.{};

    const ships = try arena.alloc(build.Ship, (try file.ships()).len);
    for (ships, try file.ships()) |*ship, record| ship.* = .{ .name = pool.name(record.name), .record = record };
    mission.ships = ships;

    const groups = try arena.alloc(build.FlightGroup, (try file.flightGroups()).len);
    const counts = try build.groupCounts(arena, ships, groups.len);
    for (groups, try file.flightGroups(), counts) |*group, record, count| group.* = .{
        .name = pool.name(record.name),
        .record = record,
        .counted = record.ship_count == count.ship_count and record.first_ship == count.first_ship,
    };
    mission.flight_groups = groups;

    const globals = try arena.alloc(build.Global, (try file.globals()).len);
    for (globals, try file.globals()) |*global, record| global.* = .{ .name = pool.name(record.name), .record = record };
    mission.globals = globals;

    // The script cut into routines where a part or a trigger's block starts.
    const script = try file.script();
    var cuts: std.ArrayList(usize) = .empty;
    if (script.len > 0) try cuts.append(arena, 0);
    for (try file.parts()) |part| {
        if (!part.isEmpty() and part.start() < script.len) try cuts.append(arena, part.start());
    }
    for (try file.triggers()) |trigger| {
        if (trigger.block()) |start| if (start < script.len) try cuts.append(arena, start);
    }
    std.mem.sort(usize, cuts.items, {}, std.sort.asc(usize));
    var starts: std.ArrayList(usize) = .empty;
    for (cuts.items) |cut| {
        if (starts.items.len == 0 or starts.items[starts.items.len - 1] != cut) try starts.append(arena, cut);
    }
    const routines = try arena.alloc([]const u8, starts.items.len);
    for (routines, starts.items, 0..) |*routine, start, index| {
        const end = if (index + 1 < starts.items.len) starts.items[index + 1] else script.len;
        routine.* = script[start..end];
    }
    mission.routines = routines;
    const routineAt = struct {
        fn at(all: []const usize, start: usize) ?usize {
            return std.mem.indexOfScalar(usize, all, start);
        }
    }.at;

    const parts = try arena.alloc(build.Part, (try file.parts()).len);
    for (parts, try file.parts()) |*part, record| {
        const routine: ?usize = if (record.isEmpty()) null else routineAt(starts.items, record.start());
        part.* = .{
            .name = pool.name(record.name),
            .record = record,
            .routine = routine,
            .measured = if (routine) |index| record.size() == routines[index].len else true,
        };
    }
    mission.parts = parts;

    const owners = try file.triggerObjects(arena);
    const triggers = try arena.alloc(build.Trigger, (try file.triggers()).len);
    for (triggers, try file.triggers(), owners) |*trigger, record, owner| trigger.* = .{
        .record = record,
        .routine = if (record.block()) |start| routineAt(starts.items, start) else null,
        .subject = if (owner) |id| id else null,
    };
    mission.triggers = triggers;

    // The object table, where the records do not imply it.
    const objects = try file.objects();
    const squads = try file.squads();
    const implied: ?[]dte.Object = build.objectTable(arena, ships, groups, squads, triggers) catch null;
    if (implied == null or !std.mem.eql(u8, std.mem.sliceAsBytes(implied.?), std.mem.sliceAsBytes(objects))) {
        const table = try arena.alloc(dte.Object, objects.len);
        for (table, objects) |*entry, object| entry.* = object;
        mission.objects = table;
    }

    // Every other section as it is, and those the builder works out where it would not.
    for (read, 0..) |contents, index| {
        const section: Section = @enumFromInt(index);
        if (!isTyped(section) and contents.count > 0) mission.sections[index] = contents;
    }
    if (mission.name == null and read[@intFromEnum(Section.openreliant_name)].count > 0) {
        mission.sections[@intFromEnum(Section.openreliant_name)] = read[@intFromEnum(Section.openreliant_name)];
    }
    if (pool.texts == null) mission.sections[@intFromEnum(Section.strings)] = read[@intFromEnum(Section.strings)];
    // The script's flags, none set, and the template's command flags, where the file holds other.
    const flags = read[@intFromEnum(Section.script_flags)];
    if (flags.count != script.len or std.mem.indexOfNone(u8, flags.bytes, &.{0}) != null) {
        mission.sections[@intFromEnum(Section.script_flags)] = flags;
    }
    const command_flags = read[@intFromEnum(Section.command_flags)];
    if (!std.mem.eql(u8, command_flags.bytes, std.mem.sliceAsBytes(&write.template.command_flags))) {
        mission.sections[@intFromEnum(Section.command_flags)] = command_flags;
    }

    // The pool from the names alone, where that is the file's.
    if (pool.texts != null and pool.byText(mission)) {
        var concise = mission;
        concise.strings = &.{};
        if (try sameSection(arena, concise, read, .strings)) mission.strings = &.{};
    }

    // Whatever still differs, as it is.
    var whole: std.ArrayList(Section) = .empty;
    for (try differing(arena, mission, read)) |section| {
        mission.sections[@intFromEnum(section)] = read[@intFromEnum(section)];
        try whole.append(arena, section);
    }
    if ((try differing(arena, mission, read)).len > 0) return error.NotTheSame;
    return .{ .mission = mission, .whole = whole.items };
}

/// The sections, but OpenReliant's name, whose records `mission` builds otherwise than `read`.
fn differing(arena: Allocator, mission: build.Mission, read: write.Sections) ReadError![]Section {
    const bytes = try build.build(arena, mission);
    const again = try write.records(try .parse(bytes));
    var sections: std.ArrayList(Section) = .empty;
    for (read, again, 0..) |a, b, index| {
        const section: Section = @enumFromInt(index);
        if (section == .openreliant_name) continue;
        if (a.count != b.count or !std.mem.eql(u8, a.bytes, b.bytes)) try sections.append(arena, section);
    }
    return sections.items;
}

fn sameSection(arena: Allocator, mission: build.Mission, read: write.Sections, section: Section) ReadError!bool {
    return std.mem.indexOfScalar(Section, try differing(arena, mission, read), section) == null;
}

/// The string pool of a file, as a list of its strings where it is one.
const Pool = struct {
    bytes: []const u8,
    /// Each string, in order, where the pool is a run of NUL-terminated UTF-8 strings.
    texts: ?[]const []const u8,
    starts: []const usize,

    fn split(arena: Allocator, bytes: []const u8) Allocator.Error!Pool {
        var texts: std.ArrayList([]const u8) = .empty;
        var starts: std.ArrayList(usize) = .empty;
        var at: usize = 0;
        var whole = true;
        while (at < bytes.len) {
            const end = std.mem.indexOfScalarPos(u8, bytes, at, 0) orelse {
                whole = false;
                break;
            };
            if (!std.unicode.utf8ValidateSlice(bytes[at..end])) whole = false;
            try texts.append(arena, bytes[at..end]);
            try starts.append(arena, at);
            at = end + 1;
        }
        return .{ .bytes = bytes, .texts = if (whole) texts.items else null, .starts = starts.items };
    }

    /// The name at `offset`: its text, where the text's first string starts there.
    fn name(pool: Pool, offset: u16) build.Name {
        const texts = pool.texts orelse return .{ .at = offset };
        for (texts, pool.starts) |text, start| {
            if (start == offset) {
                for (texts[0..], pool.starts) |earlier, earlier_start| {
                    if (earlier_start >= start) break;
                    if (std.mem.eql(u8, earlier, text)) return .{ .at = offset };
                }
                return .{ .text = text };
            }
        }
        return .{ .at = offset };
    }

    /// Whether every name of `mission` is given by its text.
    fn byText(_: Pool, mission: build.Mission) bool {
        for (mission.parts) |part| if (part.name == .at) return false;
        for (mission.ships) |ship| if (ship.name == .at) return false;
        for (mission.flight_groups) |group| if (group.name == .at) return false;
        for (mission.globals) |global| if (global.name == .at) return false;
        return true;
    }
};

// Writing the source.

/// Writes `mission` as its source to `out`, indented: each record by what differs from the
/// builder's own, each routine as its instructions, and bytes where a routine's instructions
/// would not build back the same.
pub fn writeSource(arena: Allocator, mission: build.Mission, out: *std.Io.Writer) !void {
    var s: Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    const ids = try routineIds(arena, mission);
    try s.beginObject();
    try s.objectField("version");
    try s.write(version);
    if (mission.name) |name| {
        try s.objectField("name");
        try s.write(name);
    }
    if (mission.formats.byte() != write.template.formats.byte()) {
        try s.objectField("formats");
        try s.write(mission.formats.byte());
    }

    try s.objectField("flight_groups");
    try s.beginArray();
    const counts = try build.groupCounts(arena, mission.ships, mission.flight_groups.len);
    for (mission.flight_groups, counts, 0..) |group, count, index| {
        var base = build.defaults.flight_group;
        base.object_id = @truncate(mission.ships.len + index);
        base.ship_count = if (group.counted) group.record.ship_count else count.ship_count;
        base.first_ship = if (group.counted) group.record.first_ship else count.first_ship;
        try s.beginObject();
        try writeName(&s, group.name);
        try writeFields(&s, dte.FlightGroup, group.record, base, &.{"name"});
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("ships");
    try s.beginArray();
    for (mission.ships, 0..) |ship, index| {
        const record = ship.record;
        var base = build.defaults.ship;
        base.object_id = @intCast(index);
        base.runtime_position = record.position;
        base.runtime_yaw = record.yaw;
        base.runtime_pitch = record.pitch;
        base.runtime_roll = record.roll;
        try s.beginObject();
        try writeName(&s, ship.name);
        try s.objectField("kind");
        try writeKind(&s, record.kind);
        if (record.flight_group != dte.Ship.no_flight_group) {
            try s.objectField("group");
            try writeGroupRef(&s, mission, record.flight_group);
        }
        if (record.launch_from != base.launch_from) {
            try s.objectField("launch_from");
            try writeKind(&s, record.launch_from);
        }
        try writeFields(&s, dte.Ship, record, base, &.{ "name", "kind", "flight_group", "launch_from" });
        try s.endObject();
    }
    try s.endArray();

    if (mission.globals.len > 0) {
        try s.objectField("globals");
        try s.beginArray();
        for (mission.globals) |global| {
            try s.beginObject();
            try writeName(&s, global.name);
            try writeFields(&s, dte.Global, global.record, build.defaults.global, &.{"name"});
            try s.endObject();
        }
        try s.endArray();
    }

    try s.objectField("parts");
    try s.beginArray();
    for (mission.parts) |part| {
        var base = build.defaults.part;
        const start: dte.Part.Flags = .{ .start = true, ._unknown = 0 };
        try s.beginObject();
        try writeName(&s, part.name);
        if (part.routine) |routine| {
            try s.objectField("routine");
            try s.write(ids[routine]);
            base.offset = part.record.offset;
            base.length = if (part.measured) part.record.length else halfwords(mission.routines[routine].len);
        }
        if (@as(u8, @bitCast(part.record.flags)) == @as(u8, @bitCast(start))) {
            try s.objectField("start");
            try s.write(true);
            base.flags = start;
        }
        try writeFields(&s, dte.Part, part.record, base, &.{"name"});
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("triggers");
    try s.beginArray();
    for (mission.triggers) |trigger| {
        var base = build.defaults.trigger;
        base.condition = trigger.record.condition;
        try s.beginObject();
        try s.objectField("condition");
        try writeValue(&s, dte.Condition, trigger.record.condition);
        if (trigger.subject) |subject| {
            try s.objectField("subject");
            try writeSubject(&s, mission, subject);
        }
        if (trigger.routine) |routine| {
            try s.objectField("routine");
            try s.write(ids[routine]);
            base.link = trigger.record.link;
        }
        if (!std.mem.eql(u32, &trigger.record.operands, &base.operands)) {
            try s.objectField("operands");
            try s.beginArray();
            for (trigger.record.operands) |operand| {
                if (operand == build.unset_operand) try s.write(null) else try s.write(operand);
            }
            try s.endArray();
            base.operands = trigger.record.operands;
        }
        try writeFields(&s, dte.Trigger, trigger.record, base, &.{});
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("routines");
    try s.beginArray();
    for (mission.routines, ids) |routine, id| try writeRoutine(arena, &s, id, routine);
    try s.endArray();

    if (mission.objects) |table| try writeObjects(arena, &s, mission, table);

    var any_section = false;
    for (mission.sections) |given| any_section = any_section or given != null;
    if (any_section) {
        try s.objectField("sections");
        try s.beginObject();
        for (mission.sections, 0..) |given, index| {
            const contents = given orelse continue;
            try s.objectField(@tagName(@as(Section, @enumFromInt(index))));
            try s.beginObject();
            try s.objectField("count");
            try s.write(contents.count);
            try s.objectField("hex");
            try s.write(try hex(arena, contents.bytes));
            try s.endObject();
        }
        try s.endObject();
    }

    if (mission.strings.len > 0) {
        try s.objectField("strings");
        try s.beginArray();
        for (mission.strings) |text| try s.write(text);
        try s.endArray();
    }
    try s.endObject();
    try out.writeByte('\n');
}

/// Writes `value` as the source gives a field of type `T`: a number, a float's bits where it has
/// no decimal form, an enum's tag where it has one, a packed struct's word, bytes as hex.
fn writeValue(s: *Stringify, comptime T: type, value: T) Stringify.Error!void {
    switch (@typeInfo(T)) {
        .int => try s.write(value),
        .float => if (std.math.isFinite(value))
            try s.print("{d}", .{value})
        else
            try s.print("\"0x{x:0>8}\"", .{@as(u32, @bitCast(value))}),
        .@"enum" => if (std.enums.tagName(T, value)) |name| try s.write(name) else try s.write(@intFromEnum(value)),
        .@"struct" => |info| try s.write(@as(info.backing_integer.?, @bitCast(value))),
        .array => |info| if (info.child == u8) {
            try s.beginWriteRaw();
            try s.writer.writeByte('"');
            for (value) |byte| try s.writer.print("{x:0>2}", .{byte});
            try s.writer.writeByte('"');
            s.endWriteRaw();
        } else {
            try s.beginArray();
            for (value) |element| try writeValue(s, info.child, element);
            try s.endArray();
        },
        else => @compileError("no source form for " ++ @typeName(T)),
    }
}

/// Writes each field of `record` whose bytes differ from `base`'s, but those `skip` names.
fn writeFields(s: *Stringify, comptime T: type, record: T, base: T, comptime skip: []const []const u8) Stringify.Error!void {
    inline for (std.meta.fields(T)) |field| {
        if (comptime isSkipped(skip, field.name)) continue;
        const value = @field(record, field.name);
        const default = @field(base, field.name);
        if (!std.mem.eql(u8, std.mem.asBytes(&value), std.mem.asBytes(&default))) {
            try s.objectField(field.name);
            try writeValue(s, field.type, value);
        }
    }
}

fn isSkipped(comptime skip: []const []const u8, comptime name: []const u8) bool {
    for (skip) |skipped| if (std.mem.eql(u8, skipped, name)) return true;
    return false;
}

fn writeName(s: *Stringify, name: build.Name) Stringify.Error!void {
    try s.objectField("name");
    switch (name) {
        .text => |text| try s.write(text),
        .at => |at| {
            try s.beginObject();
            try s.objectField("at");
            try s.write(at);
            try s.endObject();
        },
    }
}

/// A ship's kind by the name of its type, where the type has one.
fn writeKind(s: *Stringify, kind: u16) Stringify.Error!void {
    if (std.enums.tagName(Type, @enumFromInt(kind))) |name| try s.write(name) else try s.write(kind);
}

fn writeGroupRef(s: *Stringify, mission: build.Mission, group: usize) Stringify.Error!void {
    if (group < mission.flight_groups.len) {
        if (textOf(mission.flight_groups[group].name)) |text| {
            if (firstNamed(build.FlightGroup, mission.flight_groups, text) == group) return s.write(text);
        }
    }
    try s.write(group);
}

fn writeShipRef(s: *Stringify, mission: build.Mission, ship: usize) Stringify.Error!void {
    if (textOf(mission.ships[ship].name)) |text| {
        if (firstNamed(build.Ship, mission.ships, text) == ship) return s.write(text);
    }
    try s.write(ship);
}

/// A trigger's subject: the ship or flight group of that object ID, or the object alone.
fn writeSubject(s: *Stringify, mission: build.Mission, id: u32) Stringify.Error!void {
    try s.beginObject();
    for (mission.ships, 0..) |ship, index| {
        if (ship.record.object_id == id) {
            try s.objectField("ship");
            try writeShipRef(s, mission, index);
            return s.endObject();
        }
    }
    for (mission.flight_groups, 0..) |group, index| {
        if (group.record.object_id == id) {
            try s.objectField("group");
            try writeGroupRef(s, mission, index);
            return s.endObject();
        }
    }
    try s.objectField("object");
    try s.write(id);
    try s.endObject();
}

/// The entries of `table` that differ from the table the records imply, or the whole table where
/// they imply none, or a shorter one.
fn writeObjects(arena: Allocator, s: *Stringify, mission: build.Mission, table: []const dte.Object) !void {
    const squads: []align(1) const dte.Squad = if (mission.sections[@intFromEnum(Section.squads)]) |given| std.mem.bytesAsSlice(dte.Squad, given.bytes) else &.{};
    const implied = build.objectTable(arena, mission.ships, mission.flight_groups, squads, mission.triggers) catch null;
    const none: dte.Object = .{ .kind = .ship, .count = 0, .first = build.no_triggers, ._unknown_04 = 0 };
    if (implied == null or table.len < implied.?.len) {
        try s.objectField("object_table");
        try s.beginArray();
        for (table) |entry| {
            try s.beginObject();
            try writeFields(s, dte.Object, entry, none, &.{});
            try s.endObject();
        }
        return s.endArray();
    }
    try s.objectField("objects");
    try s.beginArray();
    for (table, 0..) |entry, id| {
        // Past the implied table every entry is given, so that the table keeps its length.
        const base = if (id < implied.?.len) implied.?[id] else none;
        if (id < implied.?.len and std.mem.eql(u8, std.mem.asBytes(&entry), std.mem.asBytes(&base))) continue;
        try s.beginObject();
        try s.objectField("id");
        try s.write(id);
        try writeFields(s, dte.Object, entry, base, &.{});
        try s.endObject();
    }
    try s.endArray();
}

/// Each routine's name in the source: its part's name where that is its own, else one after the
/// part or trigger it serves, or its place.
fn routineIds(arena: Allocator, mission: build.Mission) Allocator.Error![][]const u8 {
    const ids = try arena.alloc(?[]const u8, mission.routines.len);
    @memset(ids, null);
    for (mission.parts, 0..) |part, index| {
        const routine = part.routine orelse continue;
        if (ids[routine] != null) continue;
        ids[routine] = if (textOf(part.name)) |text| if (text.len > 0) text else null else null;
        if (ids[routine] == null) ids[routine] = try std.fmt.allocPrint(arena, "part {d}", .{index});
    }
    for (mission.triggers, 0..) |trigger, index| {
        const routine = trigger.routine orelse continue;
        if (ids[routine] == null) ids[routine] = try std.fmt.allocPrint(arena, "trigger {d}", .{index});
    }
    const unique = try arena.alloc([]const u8, ids.len);
    for (unique, ids, 0..) |*id, given, index| {
        const name = given orelse try std.fmt.allocPrint(arena, "routine {d}", .{index});
        const taken = for (unique[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) break true;
        } else false;
        id.* = if (taken) try std.fmt.allocPrint(arena, "{s} #{d}", .{ name, index }) else name;
    }
    return unique;
}

/// Writes a routine as its instructions, a label before each that a branch goes to, then the
/// bytes of its padding and of its constants; or as bytes, where that would not build back the
/// same.
fn writeRoutine(arena: Allocator, s: *Stringify, id: []const u8, bytes: []const u8) (Allocator.Error || Stringify.Error)!void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    if (try Listing.of(arena, bytes)) |listing| {
        try s.objectField("code");
        try s.beginArray();
        for (listing.instructions) |instruction| {
            if (listing.targets.contains(instruction.address)) try compact(s, Statement{ .label = try label(arena, instruction.address) });
            try compact(s, try Statement.of(arena, instruction));
        }
        try s.endArray();
        if (std.mem.indexOfNone(u8, listing.padding, &.{0}) != null) {
            try s.objectField("padding");
            try s.write(try hex(arena, listing.padding));
        }
        if (listing.tail.len > 0) {
            try s.objectField("tail");
            try s.write(try hex(arena, listing.tail));
        }
    } else {
        try s.objectField("bytes");
        try s.write(try hex(arena, bytes));
    }
    try s.endObject();
}

/// Writes `value` on one line, as an element of the array being written.
fn compact(s: *Stringify, value: anytype) Stringify.Error!void {
    try s.beginWriteRaw();
    var line: Stringify = .{ .writer = s.writer, .options = .{ .emit_null_optional_fields = false } };
    try line.write(value);
    s.endWriteRaw();
}

/// A routine's block as instructions that build back into it: every byte reached, the padding
/// after, and the constants and anything else up to the next routine.
const Listing = struct {
    instructions: []const dte.Instruction,
    /// The places a branch goes to.
    targets: std.AutoHashMapUnmanaged(usize, void),
    padding: []const u8,
    tail: []const u8,

    fn of(arena: Allocator, bytes: []const u8) Allocator.Error!?Listing {
        const block = dte.BlockReader.at(bytes, 0) orelse return null;
        if (block.isShort()) return null;
        const disassembly = (try dte.disassemble(arena, bytes, 0)) orelse return null;
        if (disassembly.incomplete or disassembly.unreached > 0 or disassembly.instructions.len == 0) return null;
        const last = disassembly.instructions[disassembly.instructions.len - 1];
        const used = last.address + last.size();
        const end = dte.BlockReader.header_len + block.code.len;
        var listing: Listing = .{
            .instructions = disassembly.instructions,
            .targets = .empty,
            .padding = bytes[used..end],
            .tail = bytes[end..],
        };
        for (disassembly.instructions) |instruction| switch (instruction.flow) {
            .branch => |branch| try listing.targets.put(arena, branch.target, {}),
            .random => |arms| {
                var iterator = arms;
                while (iterator.next()) |target| try listing.targets.put(arena, target, {});
            },
            else => {},
        };
        // Only instructions that build back into the same bytes.
        const again = listing.rebuilt(arena) catch return null;
        return if (std.mem.eql(u8, again, bytes)) listing else null;
    }

    /// The bytes the listing builds into, as a source's routine of the same builds into.
    fn rebuilt(listing: Listing, arena: Allocator) (Allocator.Error || assemble.Error || error{Invalid})![]u8 {
        var routine: assemble.Routine = .init(arena);
        var at: std.AutoHashMapUnmanaged(usize, assemble.Label) = .empty;
        var targets = listing.targets.keyIterator();
        while (targets.next()) |target| try at.put(arena, target.*, try routine.label());
        for (listing.instructions) |instruction| {
            if (at.get(instruction.address)) |here| routine.place(here);
            try assemble.emit(&routine, instruction, &at);
        }
        return finishRoutine(arena, &routine, listing.padding, listing.tail);
    }
};

/// A routine's bytes: its block, the padding given in place of zeros, and the tail given in place
/// of the constants the routine's statements made.
fn finishRoutine(arena: Allocator, routine: *assemble.Routine, padding: ?[]const u8, tail: ?[]const u8) (Allocator.Error || assemble.Error || error{Invalid})![]u8 {
    if (tail != null and routine.constants.items.len > 0) return error.Invalid;
    const code_end = dte.BlockReader.header_len + routine.code.items.len;
    const bytes = try routine.finish();
    const block_end: usize = std.mem.readInt(u16, bytes[0..2], .little);
    if (padding) |given| {
        if (given.len != block_end - code_end) return error.Invalid;
        @memcpy(bytes[code_end..block_end], given);
    }
    const with_tail = tail orelse return bytes;
    return std.mem.concat(arena, u8, &.{ bytes[0..block_end], with_tail });
}

fn label(arena: Allocator, address: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "L{d}", .{address});
}

/// One instruction of a routine as the source writes it.
const Statement = struct {
    label: ?[]const u8 = null,
    op: ?[]const u8 = null,
    command: ?[]const u8 = null,
    operands: ?[]const u8 = null,
    to: ?[]const u8 = null,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    default: ?[]const u8 = null,
    arms: ?[]const Arm = null,

    const Arm = struct { to: []const u8, threshold: u8, extra: u8 };

    fn of(arena: Allocator, instruction: dte.Instruction) Allocator.Error!Statement {
        var statement: Statement = .{ .op = @tagName(instruction.opcode) };
        switch (instruction.flow) {
            .branch => |branch| statement.to = try label(arena, branch.target),
            .inline_data => |data| {
                const text_end = if (data.len > 0 and data[data.len - 1] == 0) data.len - 1 else null;
                const is_text = if (text_end) |end| std.mem.indexOfScalar(u8, data[0..end], 0) == null and std.unicode.utf8ValidateSlice(data[0..end]) else false;
                if (is_text) statement.text = data[0..text_end.?] else statement.data = try hex(arena, data);
            },
            .random => |arms_of| {
                var iterator = arms_of;
                statement.default = try label(arena, iterator.next().?);
                const header = @sizeOf(dte.ArmIterator.Header);
                var arms: std.ArrayList(Arm) = .empty;
                var index: usize = 0;
                while (iterator.next()) |target| : (index += 1) {
                    const arm = instruction.operands[header + index * 4 ..][0..4];
                    try arms.append(arena, .{ .to = try label(arena, target), .threshold = arm[2], .extra = arm[3] });
                }
                statement.arms = arms.items;
            },
            .next, .call, .@"return" => {
                const name = if (instruction.opcode == .command) commandName(instruction.operands[0]) else null;
                if (name) |known| statement.command = known else if (instruction.operands.len > 0) statement.operands = instruction.operands;
            },
        }
        return statement;
    }

    pub fn jsonStringify(statement: Statement, s: *Stringify) Stringify.Error!void {
        try s.beginObject();
        inline for (std.meta.fields(Statement)) |field| {
            if (@field(statement, field.name)) |value| {
                try s.objectField(field.name);
                if (comptime std.mem.eql(u8, field.name, "operands")) {
                    try s.beginArray();
                    for (value) |byte| try s.write(byte);
                    try s.endArray();
                } else try s.write(value);
            }
        }
        try s.endObject();
    }
};

/// The command at `index`, by name, where the name finds it again.
fn commandName(index: u8) ?[]const u8 {
    const command = commands.find(index) orelse return null;
    return if (commandIndex(command.name) == index) command.name else null;
}

fn commandIndex(name: []const u8) ?u8 {
    for (commands.table, 0..) |command, index| {
        if (std.mem.eql(u8, command.name, name)) return @intCast(index);
    }
    return null;
}

fn textOf(name: build.Name) ?[]const u8 {
    return switch (name) {
        .text => |text| text,
        .at => null,
    };
}

/// The first record named `text`.
fn firstNamed(comptime T: type, records: []const T, text: []const u8) ?usize {
    for (records, 0..) |record, index| {
        if (textOf(record.name)) |own| if (std.mem.eql(u8, own, text)) return index;
    }
    return null;
}

fn halfwords(bytes: usize) u16 {
    return @intCast(bytes / @sizeOf(u16));
}

fn hex(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const text = try arena.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        text[index * 2] = digits[byte >> 4];
        text[index * 2 + 1] = digits[byte & 0xF];
    }
    return text;
}

// Reading the source.

/// What is wrong with a source, and where, once `parse` has failed with `error.Invalid`.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const ParseError = Allocator.Error || error{Invalid};

/// The mission `text` gives, in `arena`, for `build.build`; on `error.Invalid`, `diagnostic` says
/// what is wrong and where.
pub fn parse(arena: Allocator, text: []const u8, diagnostic: *Diagnostic) ParseError!build.Mission {
    var p: Parser = .{ .arena = arena, .diagnostic = diagnostic };
    const root = json.parseFromSliceLeaky(json.Value, arena, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return p.fail("the source is not JSON ({s})", .{@errorName(err)}),
    };
    const top = try p.object(root, "the source");
    try p.onlyKeys(top, "the source", &.{ "version", "name", "formats", "strings", "flight_groups", "ships", "globals", "parts", "triggers", "routines", "script", "objects", "object_table", "sections" });
    if (top.get("version")) |given| {
        if (try p.integer(u32, given, "version") != version) return p.fail("version: only version {d} is read", .{version});
    }

    var mission: build.Mission = .{};
    if (top.get("name")) |name| mission.name = try p.string(name, "name");
    if (top.get("formats")) |formats| mission.formats = @bitCast(try p.integer(u8, formats, "formats"));
    if (top.get("strings")) |strings_of| {
        const list = try p.array(strings_of, "strings");
        const texts = try arena.alloc([]const u8, list.len);
        for (texts, list, 0..) |*string, item, index| string.* = try p.string(item, try p.at("strings", index));
        mission.strings = texts;
    }

    const group_list = if (top.get("flight_groups")) |list| try p.array(list, "flight_groups") else &.{};
    const ship_list = if (top.get("ships")) |list| try p.array(list, "ships") else &.{};
    var routine_list = if (top.get("routines")) |list| try p.array(list, "routines") else &.{};
    var part_list = if (top.get("parts")) |list| try p.array(list, "parts") else &.{};
    var trigger_list = if (top.get("triggers")) |list| try p.array(list, "triggers") else &.{};

    // Names first, which references find records by.
    p.group_names = try p.names(group_list, "flight_groups");
    p.ship_names = try p.names(ship_list, "ships");
    // The script's rules add their parts, triggers and routines after those given as records.
    if (top.get("script")) |script_of| {
        const expanded = try rules.expand(arena, try p.string(script_of, "script"), .{ .ships = p.ship_names, .groups = p.group_names }, diagnostic);
        part_list = try std.mem.concat(arena, json.Value, &.{ part_list, expanded.parts });
        trigger_list = try std.mem.concat(arena, json.Value, &.{ trigger_list, expanded.triggers });
        routine_list = try std.mem.concat(arena, json.Value, &.{ routine_list, expanded.routines });
    }
    p.part_names = try p.names(part_list, "parts");
    const ids = try arena.alloc([]const u8, routine_list.len);
    p.routine_ids = ids;
    for (ids, routine_list, 0..) |*id, item, index| {
        const where = try p.at("routines", index);
        id.* = try p.string((try p.object(item, where)).get("id") orelse return p.fail("{s}: no id", .{where}), try p.join(where, "id"));
        for (ids[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, id.*)) return p.fail("{s}: a second routine named \"{s}\"", .{ where, id.* });
        }
    }

    const groups = try arena.alloc(build.FlightGroup, group_list.len);
    for (groups, group_list, 0..) |*group, item, index| group.* = try p.flightGroup(item, index, ship_list.len);
    mission.flight_groups = groups;

    const ships = try arena.alloc(build.Ship, ship_list.len);
    for (ships, ship_list, 0..) |*ship, item, index| ship.* = try p.ship(item, index);
    mission.ships = ships;
    p.ships = ships;
    p.groups = groups;

    // The groups whose counts are given in part take the rest from the ships.
    const counts = build.groupCounts(arena, ships, groups.len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return p.fail("flight_groups: a group of more ships than its count can say", .{}),
    };
    for (groups, group_list, counts) |*group, item, count| {
        if (group.counted) continue;
        const fields = item.object;
        if (fields.get("ship_count") == null) group.record.ship_count = count.ship_count;
        if (fields.get("first_ship") == null) group.record.first_ship = count.first_ship;
    }

    if (top.get("globals")) |globals_of| {
        const list = try p.array(globals_of, "globals");
        const records = try arena.alloc(build.Global, list.len);
        for (records, list, 0..) |*global, item, index| {
            const where = try p.at("globals", index);
            const fields = try p.object(item, where);
            global.* = .{ .name = try p.name(fields, where), .record = build.defaults.global };
            try p.fields(dte.Global, &global.record, fields, where, &.{"name"});
        }
        mission.globals = records;
    }

    const routines = try arena.alloc([]const u8, routine_list.len);
    for (routines, routine_list, 0..) |*routine, item, index| routine.* = try p.routine(item, try p.at("routines", index));
    mission.routines = routines;

    const parts = try arena.alloc(build.Part, part_list.len);
    for (parts, part_list, 0..) |*part, item, index| part.* = try p.part(item, index);
    mission.parts = parts;

    const triggers = try arena.alloc(build.Trigger, trigger_list.len);
    for (triggers, trigger_list, 0..) |*trigger, item, index| trigger.* = try p.trigger(item, index);
    mission.triggers = triggers;

    if (top.get("sections")) |sections_of| {
        const fields = try p.object(sections_of, "sections");
        var iterator = fields.iterator();
        while (iterator.next()) |entry| {
            const where = try p.join("sections", entry.key_ptr.*);
            const section = std.meta.stringToEnum(Section, entry.key_ptr.*) orelse return p.fail("{s}: no section of that name", .{where});
            const contents = try p.object(entry.value_ptr.*, where);
            try p.onlyKeys(contents, where, &.{ "count", "hex" });
            mission.sections[@intFromEnum(section)] = .{
                .count = try p.integer(u16, contents.get("count") orelse return p.fail("{s}: no count", .{where}), try p.join(where, "count")),
                .bytes = if (contents.get("hex")) |bytes| try p.bytes(bytes, try p.join(where, "hex")) else &.{},
            };
        }
    }

    if (top.get("object_table")) |table_of| {
        if (top.get("objects") != null) return p.fail("objects: give objects or object_table, not both", .{});
        const list = try p.array(table_of, "object_table");
        const entries = try arena.alloc(dte.Object, list.len);
        for (entries, list, 0..) |*entry, item, index| {
            const where = try p.at("object_table", index);
            entry.* = .{ .kind = .ship, .count = 0, .first = build.no_triggers, ._unknown_04 = 0 };
            try p.fields(dte.Object, entry, try p.object(item, where), where, &.{});
        }
        mission.objects = entries;
    } else if (top.get("objects")) |overrides| {
        const squads: []align(1) const dte.Squad = if (mission.sections[@intFromEnum(Section.squads)]) |given| std.mem.bytesAsSlice(dte.Squad, given.bytes) else &.{};
        const implied = build.objectTable(arena, mission.ships, mission.flight_groups, squads, mission.triggers) catch |err|
            return p.fail("objects: the records give no object table ({s})", .{@errorName(err)});
        var table: std.ArrayList(dte.Object) = .fromOwnedSlice(implied);
        for (try p.array(overrides, "objects"), 0..) |item, index| {
            const where = try p.at("objects", index);
            const fields = try p.object(item, where);
            const id = try p.integer(u32, fields.get("id") orelse return p.fail("{s}: no id", .{where}), try p.join(where, "id"));
            while (table.items.len <= id) try table.append(arena, .{ .kind = .ship, .count = 0, .first = build.no_triggers, ._unknown_04 = 0 });
            try p.fields(dte.Object, &table.items[id], fields, where, &.{"id"});
        }
        mission.objects = table.items;
    }
    return mission;
}

const Parser = struct {
    arena: Allocator,
    diagnostic: *Diagnostic,
    group_names: []const ?[]const u8 = &.{},
    ship_names: []const ?[]const u8 = &.{},
    part_names: []const ?[]const u8 = &.{},
    routine_ids: []const []const u8 = &.{},
    ships: []const build.Ship = &.{},
    groups: []const build.FlightGroup = &.{},

    fn fail(p: *Parser, comptime format: []const u8, args: anytype) error{Invalid} {
        p.diagnostic.message = std.fmt.allocPrint(p.arena, format, args) catch "out of memory";
        return error.Invalid;
    }

    fn at(p: *Parser, list: []const u8, index: usize) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(p.arena, "{s}[{d}]", .{ list, index });
    }

    fn join(p: *Parser, where: []const u8, key: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(p.arena, "{s}.{s}", .{ where, key });
    }

    fn object(p: *Parser, value: json.Value, where: []const u8) ParseError!json.ObjectMap {
        return switch (value) {
            .object => |map| map,
            else => p.fail("{s}: not an object", .{where}),
        };
    }

    fn array(p: *Parser, value: json.Value, where: []const u8) ParseError![]const json.Value {
        return switch (value) {
            .array => |items| items.items,
            else => p.fail("{s}: not a list", .{where}),
        };
    }

    fn string(p: *Parser, value: json.Value, where: []const u8) ParseError![]const u8 {
        return switch (value) {
            .string => |text| text,
            else => p.fail("{s}: not a string", .{where}),
        };
    }

    fn onlyKeys(p: *Parser, given: json.ObjectMap, where: []const u8, allowed: []const []const u8) ParseError!void {
        for (given.keys()) |key| {
            for (allowed) |allowed_key| {
                if (std.mem.eql(u8, allowed_key, key)) break;
            } else return p.fail("{s}: no field \"{s}\"", .{ where, key });
        }
    }

    fn integer(p: *Parser, comptime T: type, value: json.Value, where: []const u8) ParseError!T {
        const text = switch (value) {
            .number_string, .string => |text| text,
            .bool => |flag| return @intFromBool(flag),
            else => return p.fail("{s}: not a number", .{where}),
        };
        return std.fmt.parseInt(T, text, 0) catch p.fail("{s}: {s} is not a {s}", .{ where, text, @typeName(T) });
    }

    fn bytes(p: *Parser, value: json.Value, where: []const u8) ParseError![]u8 {
        const text = try p.string(value, where);
        if (text.len % 2 != 0) return p.fail("{s}: hex of an odd length", .{where});
        const out = try p.arena.alloc(u8, text.len / 2);
        _ = std.fmt.hexToBytes(out, text) catch return p.fail("{s}: not hex", .{where});
        return out;
    }

    fn typed(p: *Parser, comptime T: type, given: json.Value, where: []const u8) ParseError!T {
        switch (@typeInfo(T)) {
            .int => return p.integer(T, given, where),
            .float => return switch (given) {
                .number_string => |text| std.fmt.parseFloat(T, text) catch p.fail("{s}: {s} is not a number", .{ where, text }),
                .string => @bitCast(try p.integer(std.meta.Int(.unsigned, @bitSizeOf(T)), given, where)),
                else => p.fail("{s}: not a number", .{where}),
            },
            .@"enum" => |info| return switch (given) {
                .string => |text| std.meta.stringToEnum(T, text) orelse p.fail("{s}: no {s} named \"{s}\"", .{ where, @typeName(T), text }),
                else => @enumFromInt(try p.integer(info.tag_type, given, where)),
            },
            .@"struct" => |info| return @bitCast(try p.integer(info.backing_integer.?, given, where)),
            .array => |info| {
                var result: T = undefined;
                if (info.child == u8 and given == .string) {
                    const decoded = try p.bytes(given, where);
                    if (decoded.len != info.len) return p.fail("{s}: {d} bytes, not {d}", .{ where, decoded.len, info.len });
                    @memcpy(&result, decoded);
                    return result;
                }
                const items = try p.array(given, where);
                if (items.len != info.len) return p.fail("{s}: {d} values, not {d}", .{ where, items.len, info.len });
                for (&result, items, 0..) |*element, item, index| element.* = try p.typed(info.child, item, try p.at(where, index));
                return result;
            },
            else => @compileError("no source form for " ++ @typeName(T)),
        }
    }

    /// Sets each field of `record` that `fields` gives, but those `skip` names, which the caller
    /// reads; a key that names no field fails.
    fn fields(p: *Parser, comptime T: type, record: *T, given: json.ObjectMap, where: []const u8, comptime skip: []const []const u8) ParseError!void {
        var iterator = given.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            const skipped = for (skip) |skipped_key| {
                if (std.mem.eql(u8, skipped_key, key)) break true;
            } else false;
            if (skipped) continue;
            if (!try p.field(T, record, key, entry.value_ptr.*, where)) return p.fail("{s}: no field \"{s}\"", .{ where, key });
        }
    }

    /// Sets the field of `record` named `key`, where `T` has one.
    fn field(p: *Parser, comptime T: type, record: *T, key: []const u8, given: json.Value, where: []const u8) ParseError!bool {
        inline for (std.meta.fields(T)) |info| {
            if (std.mem.eql(u8, info.name, key)) {
                @field(record, info.name) = try p.typed(info.type, given, try p.join(where, key));
                return true;
            }
        }
        return false;
    }

    fn name(p: *Parser, given: json.ObjectMap, where: []const u8) ParseError!build.Name {
        const value_of = given.get("name") orelse return .{ .text = "" };
        return switch (value_of) {
            .string => |text| .{ .text = text },
            .object => |map| .{ .at = try p.integer(u16, map.get("at") orelse return p.fail("{s}.name: no at", .{where}), try p.join(where, "name.at")) },
            else => p.fail("{s}.name: not a string", .{where}),
        };
    }

    /// Each record's name, where it is given by its text.
    fn names(p: *Parser, list: []const json.Value, where: []const u8) ParseError![]const ?[]const u8 {
        const all = try p.arena.alloc(?[]const u8, list.len);
        for (all, list, 0..) |*text, item, index| {
            const map = try p.object(item, try p.at(where, index));
            text.* = if (map.get("name")) |given| switch (given) {
                .string => |own| own,
                else => null,
            } else "";
        }
        return all;
    }

    /// The record `given` names in `list`: by its name, the first so named, or its index.
    fn lookup(p: *Parser, list: []const ?[]const u8, given: json.Value, what: []const u8, where: []const u8) ParseError!usize {
        switch (given) {
            .string => |text| {
                for (list, 0..) |own, index| {
                    if (own) |named| if (std.mem.eql(u8, named, text)) return index;
                }
                return p.fail("{s}: no {s} named \"{s}\"", .{ where, what, text });
            },
            else => {
                const index = try p.integer(usize, given, where);
                if (index >= list.len) return p.fail("{s}: no {s} {d}", .{ where, what, index });
                return index;
            },
        }
    }

    fn kind(p: *Parser, given: json.Value, where: []const u8) ParseError!u16 {
        return switch (given) {
            .string => |text| if (std.meta.stringToEnum(Type, text)) |named| std.math.cast(u16, named.number()) orelse p.fail("{s}: too large", .{where}) else p.fail("{s}: no ship type named \"{s}\"", .{ where, text }),
            else => p.integer(u16, given, where),
        };
    }

    fn flightGroup(p: *Parser, item: json.Value, index: usize, ship_count: usize) ParseError!build.FlightGroup {
        const where = try p.at("flight_groups", index);
        const given = try p.object(item, where);
        var group: build.FlightGroup = .{ .name = try p.name(given, where), .record = build.defaults.flight_group };
        group.record.object_id = std.math.cast(u16, ship_count + index) orelse return p.fail("{s}: too many objects", .{where});
        try p.fields(dte.FlightGroup, &group.record, given, where, &.{"name"});
        group.counted = given.get("ship_count") == null and given.get("first_ship") == null;
        return group;
    }

    fn ship(p: *Parser, item: json.Value, index: usize) ParseError!build.Ship {
        const where = try p.at("ships", index);
        const given = try p.object(item, where);
        var record = build.defaults.ship;
        record.object_id = @intCast(index);
        if (given.get("kind")) |kind_of| record.kind = try p.kind(kind_of, try p.join(where, "kind"));
        if (given.get("launch_from")) |kind_of| record.launch_from = try p.kind(kind_of, try p.join(where, "launch_from"));
        if (given.get("group")) |group| record.flight_group = switch (group) {
            .null => dte.Ship.no_flight_group,
            else => std.math.cast(u8, try p.lookup(p.group_names, group, "flight group", try p.join(where, "group"))) orelse return p.fail("{s}.group: too large", .{where}),
        };
        try p.fields(dte.Ship, &record, given, where, &.{ "name", "kind", "launch_from", "group", "flight_group" });
        if (given.get("runtime_position") == null) record.runtime_position = record.position;
        if (given.get("runtime_yaw") == null) record.runtime_yaw = record.yaw;
        if (given.get("runtime_pitch") == null) record.runtime_pitch = record.pitch;
        if (given.get("runtime_roll") == null) record.runtime_roll = record.roll;
        return .{ .name = try p.name(given, where), .record = record };
    }

    fn routineIndex(p: *Parser, given: json.Value, where: []const u8) ParseError!?usize {
        if (given == .null) return null;
        const id = try p.string(given, where);
        for (p.routine_ids, 0..) |own, index| if (std.mem.eql(u8, own, id)) return index;
        return p.fail("{s}: no routine \"{s}\"", .{ where, id });
    }

    fn part(p: *Parser, item: json.Value, index: usize) ParseError!build.Part {
        const where = try p.at("parts", index);
        const given = try p.object(item, where);
        var result: build.Part = .{ .name = try p.name(given, where), .record = build.defaults.part };
        if (given.get("routine")) |routine_of| result.routine = try p.routineIndex(routine_of, try p.join(where, "routine"));
        if (result.routine != null and given.get("offset") != null) return p.fail("{s}.offset: a part's routine gives its offset", .{where});
        if (given.get("start")) |start| result.record.flags.start = switch (start) {
            .bool => |flag| flag,
            else => return p.fail("{s}.start: not true or false", .{where}),
        };
        try p.fields(dte.Part, &result.record, given, where, &.{ "name", "routine", "start" });
        result.measured = given.get("length") == null;
        return result;
    }

    fn trigger(p: *Parser, item: json.Value, index: usize) ParseError!build.Trigger {
        const where = try p.at("triggers", index);
        const given = try p.object(item, where);
        var result: build.Trigger = .{ .record = build.defaults.trigger };
        if (given.get("routine")) |routine_of| result.routine = try p.routineIndex(routine_of, try p.join(where, "routine"));
        if (given.get("subject")) |subject_of| result.subject = try p.subject(subject_of, try p.join(where, "subject"));
        if (given.get("operands")) |operands| {
            const list = try p.array(operands, try p.join(where, "operands"));
            if (list.len != result.record.operands.len) return p.fail("{s}.operands: {d} values, not {d}", .{ where, list.len, result.record.operands.len });
            for (&result.record.operands, list, 0..) |*slot, operand_of, n| slot.* = try p.operand(operand_of, try p.at(try p.join(where, "operands"), n));
        }
        try p.fields(dte.Trigger, &result.record, given, where, &.{ "routine", "subject", "operands" });
        if (result.routine != null and given.get("link") != null) return p.fail("{s}.link: a trigger's routine gives its link", .{where});
        return result;
    }

    /// A trigger's subject: a ship or a flight group, by name or index, or an object ID.
    fn subject(p: *Parser, given: json.Value, where: []const u8) ParseError!?u32 {
        if (given == .null) return null;
        const fields_of = try p.object(given, where);
        try p.onlyKeys(fields_of, where, &.{ "ship", "group", "object" });
        if (fields_of.get("ship")) |ref| return p.ships[try p.lookup(p.ship_names, ref, "ship", try p.join(where, "ship"))].record.object_id;
        if (fields_of.get("group")) |ref| return p.groups[try p.lookup(p.group_names, ref, "flight group", try p.join(where, "group"))].record.object_id;
        if (fields_of.get("object")) |id| return try p.integer(u32, id, try p.join(where, "object"));
        return p.fail("{s}: give a ship, a group or an object", .{where});
    }

    /// A trigger's operand: unset, a number, or a ship or flight group referenced as the matcher
    /// reads one (`dte.Reference`).
    fn operand(p: *Parser, given: json.Value, where: []const u8) ParseError!u32 {
        return switch (given) {
            .null => build.unset_operand,
            .object => |fields_of| blk: {
                try p.onlyKeys(fields_of, where, &.{ "ship", "group" });
                const reference: dte.Reference = if (fields_of.get("ship")) |ref|
                    .{ .index = @intCast(try p.lookup(p.ship_names, ref, "ship", where)), .tag = .ship, ._unknown_24 = 0 }
                else if (fields_of.get("group")) |ref|
                    .{ .index = @intCast(try p.lookup(p.group_names, ref, "flight group", where)), .tag = .flight_group, ._unknown_24 = 0 }
                else
                    return p.fail("{s}: give a ship or a group", .{where});
                break :blk @bitCast(reference);
            },
            else => p.integer(u32, given, where),
        };
    }

    fn routine(p: *Parser, item: json.Value, where: []const u8) ParseError![]const u8 {
        const given = try p.object(item, where);
        try p.onlyKeys(given, where, &.{ "id", "code", "padding", "tail", "bytes" });
        if (given.get("bytes")) |bytes_of| {
            if (given.get("code") != null) return p.fail("{s}: give code or bytes, not both", .{where});
            const raw = try p.bytes(bytes_of, try p.join(where, "bytes"));
            if (raw.len % 2 != 0) return p.fail("{s}.bytes: an odd number of bytes", .{where});
            return raw;
        }
        var labels: std.StringHashMapUnmanaged(assemble.Label) = .empty;
        var placed: std.StringHashMapUnmanaged(void) = .empty;
        var block: assemble.Routine = .init(p.arena);
        const statements = if (given.get("code")) |code| try p.array(code, try p.join(where, "code")) else &.{};
        for (statements, 0..) |item_of, index| {
            const here = try p.at(try p.join(where, "code"), index);
            p.statement(&block, &labels, &placed, try p.object(item_of, here), here) catch |err| switch (err) {
                error.Invalid, error.OutOfMemory => |e| return e,
                else => return p.fail("{s}: {s}", .{ here, @errorName(err) }),
            };
        }
        var unplaced = labels.keyIterator();
        while (unplaced.next()) |key| {
            if (!placed.contains(key.*)) return p.fail("{s}: no label \"{s}\" is placed", .{ where, key.* });
        }
        const padding = if (given.get("padding")) |padding_of| try p.bytes(padding_of, try p.join(where, "padding")) else null;
        const tail = if (given.get("tail")) |tail_of| try p.bytes(tail_of, try p.join(where, "tail")) else null;
        return finishRoutine(p.arena, &block, padding, tail) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Invalid => p.fail("{s}: a tail stands in for the constants, so the statements may not push any, and padding must fill the block's", .{where}),
            else => p.fail("{s}: {s}", .{ where, @errorName(err) }),
        };
    }

    fn labelNamed(p: *Parser, block: *assemble.Routine, labels: *std.StringHashMapUnmanaged(assemble.Label), text: []const u8) (Allocator.Error)!assemble.Label {
        const slot = try labels.getOrPut(p.arena, text);
        if (!slot.found_existing) slot.value_ptr.* = try block.label();
        return slot.value_ptr.*;
    }

    fn statement(
        p: *Parser,
        block: *assemble.Routine,
        labels: *std.StringHashMapUnmanaged(assemble.Label),
        placed: *std.StringHashMapUnmanaged(void),
        given: json.ObjectMap,
        where: []const u8,
    ) (ParseError || assemble.Error)!void {
        if (given.get("label")) |text_of| {
            try p.onlyKeys(given, where, &.{"label"});
            const text = try p.string(text_of, try p.join(where, "label"));
            if ((try placed.getOrPut(p.arena, text)).found_existing) return p.fail("{s}: label \"{s}\" placed twice", .{ where, text });
            block.place(try p.labelNamed(block, labels, text));
        } else if (given.get("op")) |op_of| {
            try p.onlyKeys(given, where, &.{ "op", "command", "operands", "to", "text", "data", "default", "arms" });
            const name_of = try p.string(op_of, try p.join(where, "op"));
            const opcode = std.meta.stringToEnum(dte.Opcode, name_of) orelse return p.fail("{s}: no opcode \"{s}\"", .{ where, name_of });
            const info = opcodes.find(@intFromEnum(opcode)).?;
            switch (info.form) {
                .branch => try block.branch(opcode, try p.labelNamed(block, labels, try p.string(given.get("to") orelse return p.fail("{s}: no to", .{where}), where))),
                .inline_data => {
                    const data = if (given.get("text")) |text_of|
                        try std.mem.concat(p.arena, u8, &.{ try p.string(text_of, where), "\x00" })
                    else if (given.get("data")) |data_of|
                        try p.bytes(data_of, where)
                    else
                        return p.fail("{s}: no text or data", .{where});
                    try block.inlineData(opcode, data);
                },
                .sequential, .transfer => if (opcode == .random_branch) {
                    const default = try p.labelNamed(block, labels, try p.string(given.get("default") orelse return p.fail("{s}: no default", .{where}), where));
                    const arms_of = if (given.get("arms")) |list| try p.array(list, where) else &.{};
                    const arms = try p.arena.alloc(assemble.Arm, arms_of.len);
                    for (arms, arms_of, 0..) |*arm, arm_of, index| {
                        const arm_where = try p.at(try p.join(where, "arms"), index);
                        const fields_of = try p.object(arm_of, arm_where);
                        arm.* = .{
                            .target = try p.labelNamed(block, labels, try p.string(fields_of.get("to") orelse return p.fail("{s}: no to", .{arm_where}), arm_where)),
                            .threshold = try p.integer(u8, fields_of.get("threshold") orelse return p.fail("{s}: no threshold", .{arm_where}), arm_where),
                            .extra = if (fields_of.get("extra")) |extra| try p.integer(u8, extra, arm_where) else 0,
                        };
                    }
                    try block.randomBranch(default, arms);
                } else if (opcode == .command and given.get("command") != null) {
                    const command_name = try p.string(given.get("command").?, where);
                    try block.op(.command, &.{commandIndex(command_name) orelse return p.fail("{s}: no command \"{s}\"", .{ where, command_name })});
                } else {
                    const operands_of = if (given.get("operands")) |list| try p.array(list, where) else &.{};
                    const operands = try p.arena.alloc(u8, operands_of.len);
                    for (operands, operands_of, 0..) |*operand_byte, byte_of, index| operand_byte.* = try p.integer(u8, byte_of, try p.at(where, index));
                    block.op(opcode, operands) catch return p.fail("{s}: {s} takes {d} operand bytes", .{ where, name_of, info.operands });
                },
            }
        } else if (given.get("command")) |name_of| {
            try p.onlyKeys(given, where, &.{ "command", "args" });
            try p.command(block, try p.string(name_of, where), if (given.get("args")) |args| try p.array(args, where) else &.{}, where);
        } else if (given.get("set")) |variable_of| {
            try p.onlyKeys(given, where, &.{ "set", "to" });
            try block.op(.select_array, &.{try p.variable(variable_of, try p.join(where, "set"))});
            try block.pushConstant(@bitCast(try p.integer(i32, given.get("to") orelse return p.fail("{s}: no to", .{where}), try p.join(where, "to"))));
            try block.op(.assign, &.{});
        } else if (given.get("call")) |part_of| {
            try p.onlyKeys(given, where, &.{"call"});
            try block.op(.call_part, &.{std.math.cast(u8, try p.lookup(p.part_names, part_of, "part", where)) orelse return p.fail("{s}: past the 256 parts a call reaches", .{where})});
        } else if (given.get("return")) |result| {
            try p.onlyKeys(given, where, &.{"return"});
            try block.op(.push_byte, &.{try p.integer(u8, result, try p.join(where, "return"))});
            try block.op(.@"return", &.{});
        } else return p.fail("{s}: give a label, an op, a command, a set, a call or a return", .{where});
    }

    /// A game's variable by its name in `vm.Variables`, or its number.
    fn variable(p: *Parser, given: json.Value, where: []const u8) ParseError!u8 {
        const text = switch (given) {
            .string => |text| text,
            else => return p.integer(u8, given, where),
        };
        return variableNumber(text) orelse p.fail("{s}: no variable \"{s}\"", .{ where, text });
    }

    /// A call of command `name`: each argument pushed in the order of the command's parameters,
    /// as its kind takes it, then the command.
    fn command(p: *Parser, block: *assemble.Routine, name_of: []const u8, args: []const json.Value, where: []const u8) (ParseError || assemble.Error)!void {
        const index = commandIndex(name_of) orelse return p.fail("{s}: no command \"{s}\"", .{ where, name_of });
        const params = commands.table[index].params;
        if (args.len != params.len) return p.fail("{s}: {s} takes {d} arguments, not {d}", .{ where, name_of, params.len, args.len });
        for (args, params, 0..) |arg, param, n| {
            const arg_where = try std.fmt.allocPrint(p.arena, "{s}: argument {d} of {s} ({s})", .{ where, n + 1, name_of, param.label });
            try p.argument(block, arg, param.kinds, arg_where);
        }
        try block.op(.command, &.{index});
    }

    fn argument(p: *Parser, block: *assemble.Routine, arg: json.Value, kinds: commands.Kinds, where: []const u8) (ParseError || assemble.Error)!void {
        switch (arg) {
            .null => try block.op(.push_null, &.{}),
            .bool => |flag| try block.pushConstant(@intFromBool(flag)),
            .number_string => try block.pushConstant(@bitCast(try p.integer(i32, arg, where))),
            .string => |text| {
                if (!kinds.file_name and !kinds.text) return p.fail("{s}: takes no text", .{where});
                try block.pushString(text);
            },
            .object => |fields_of| {
                if (fields_of.get("ship")) |ref| {
                    try p.onlyKeys(fields_of, where, &.{ "ship", "component" });
                    if (!kinds.ship) return p.fail("{s}: takes no ship", .{where});
                    const index = try p.lookup(p.ship_names, ref, "ship", where);
                    if (fields_of.get("component")) |component| {
                        try block.op(.push_component, &.{ std.math.cast(u8, index) orelse return p.fail("{s}: a component of a ship past the 256th", .{where}), try p.integer(u8, component, where) });
                    } else if (std.math.cast(u8, index)) |small| {
                        try block.op(.push_ship, &.{small});
                    } else {
                        var wide: [2]u8 = undefined;
                        std.mem.writeInt(u16, &wide, @intCast(index), .big);
                        try block.op(.push_ship_wide, &wide);
                    }
                } else if (fields_of.get("group")) |ref| {
                    try p.onlyKeys(fields_of, where, &.{"group"});
                    if (!kinds.flight_group) return p.fail("{s}: takes no flight group", .{where});
                    try block.op(.push_flight_group, &.{std.math.cast(u8, try p.lookup(p.group_names, ref, "flight group", where)) orelse return p.fail("{s}: past the 256th flight group", .{where})});
                } else if (fields_of.get("curve")) |ref| {
                    try p.onlyKeys(fields_of, where, &.{"curve"});
                    try block.op(.push_curve, &.{try p.integer(u8, ref, where)});
                } else if (fields_of.get("squad")) |ref| {
                    try p.onlyKeys(fields_of, where, &.{"squad"});
                    try block.op(.push_squad, &.{try p.integer(u8, ref, where)});
                } else if (fields_of.get("variable")) |ref| {
                    try p.onlyKeys(fields_of, where, &.{"variable"});
                    try block.op(.push_array, &.{try p.variable(ref, where)});
                } else if (fields_of.get("part")) |ref| {
                    // A part by its index, as the shipped scripts give `CreateTimer` one.
                    try p.onlyKeys(fields_of, where, &.{"part"});
                    if (!kinds.part) return p.fail("{s}: takes no part", .{where});
                    try block.op(.push_byte, &.{std.math.cast(u8, try p.lookup(p.part_names, ref, "part", where)) orelse return p.fail("{s}: past the 256 parts", .{where})});
                } else return p.fail("{s}: give a ship, a group, a part, a curve, a squad or a variable", .{where});
            },
            else => return p.fail("{s}: not an argument", .{where}),
        }
    }
};

/// The number of the game's variable `name` in `vm.Variables`, where a script names it so.
pub fn variableNumber(name: []const u8) ?u8 {
    inline for (std.meta.fields(Variables)) |info| {
        if (comptime isVariable(info)) {
            if (std.mem.eql(u8, info.name, name)) return Variables.number(info.name);
        }
    }
    return null;
}

/// The name of the game's variable numbered `number`, where a script names it.
pub fn variableName(number: u8) ?[]const u8 {
    inline for (std.meta.fields(Variables)) |info| {
        if (comptime isVariable(info)) {
            if (Variables.number(info.name) == number) return info.name;
        }
    }
    return null;
}

/// Whether a field of `vm.Variables` is a variable a script names.
fn isVariable(comptime field: std.builtin.Type.StructField) bool {
    if (field.name[0] == '_' or std.mem.eql(u8, field.name, "spare")) return false;
    return switch (@typeInfo(field.type)) {
        .int, .@"enum" => @sizeOf(field.type) == @sizeOf(u32),
        else => false,
    };
}

// The catalogue.

/// Writes what a builder offers to `out`: the ship types, the Executor's commands with their
/// parameters, the conditions with the values their events carry, and the game's variables.
pub fn writeCatalogue(out: *std.Io.Writer) Stringify.Error!void {
    var s: Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_1 } };
    try s.beginObject();
    try s.objectField("version");
    try s.write(version);
    try s.objectField("types");
    try s.beginArray();
    inline for (std.meta.fields(Type)) |field| try compact(&s, .{ .number = @as(u32, field.value), .name = field.name });
    try s.endArray();
    try s.objectField("commands");
    try s.beginArray();
    for (commands.table, 0..) |command_of, index| {
        try s.beginObject();
        try s.objectField("index");
        try s.write(index);
        try s.objectField("name");
        try s.write(command_of.name);
        try s.objectField("description");
        try s.write(command_of.description);
        try s.objectField("params");
        try s.beginArray();
        for (command_of.params) |param| try compact(&s, .{ .label = param.label, .kinds = kindNames(param.kinds) });
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("conditions");
    try s.beginArray();
    for (conditions.table, 0..) |condition, index| {
        const tag = std.enums.tagName(dte.Condition, @enumFromInt(index)) orelse continue;
        try s.beginObject();
        try s.objectField("name");
        try s.write(tag);
        try s.objectField("label");
        try s.write(condition.name);
        try s.objectField("scriptable");
        try s.write(index <= @intFromEnum(dte.Condition.last_scriptable));
        try s.objectField("subjects");
        try compact(&s, .{ .ship = condition.subjects.ship, .flight_group = condition.subjects.flight_group, .squad = condition.subjects.squad });
        try s.objectField("values");
        try s.beginArray();
        for (condition.values) |value_of| try compact(&s, .{ .label = value_of.label, .kinds = kindNames(value_of.kinds), .checked = value_of.checked });
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("variables");
    try s.beginArray();
    inline for (std.meta.fields(Variables)) |field| {
        if (comptime isVariable(field)) try compact(&s, .{ .number = @as(u32, Variables.number(field.name)), .name = field.name });
    }
    try s.endArray();
    try s.endObject();
    try out.writeByte('\n');
}

/// The names of the kinds of value a parameter takes.
fn kindNames(kinds: commands.Kinds) KindNames {
    var names: KindNames = .{};
    inline for (.{ "number", "file_name", "text", "ship", "flight_group", "part", "constant", "condition", "curve" }) |kind_name| {
        if (@field(kinds, kind_name)) {
            names.list[names.len] = kind_name;
            names.len += 1;
        }
    }
    return names;
}

const KindNames = struct {
    list: [9][]const u8 = undefined,
    len: usize = 0,

    pub fn jsonStringify(names: KindNames, s: *Stringify) Stringify.Error!void {
        try s.beginArray();
        for (names.list[0..names.len]) |kind_name| try s.write(kind_name);
        try s.endArray();
    }
};

// Tests.

/// The mission of `text`, built.
fn buildText(gpa: Allocator, text: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const mission = parse(arena_state.allocator(), text, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message});
        return err;
    };
    return build.build(gpa, mission);
}

test "a mission from its source" {
    const gpa = std.testing.allocator;
    const bytes = try buildText(gpa,
        \\{
        \\  "version": 1,
        \\  "name": "Patrol",
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders", "position": [0, 0, 150000], "yaw": 180, "pilot": 42 }
        \\  ],
        \\  "parts": [{ "name": "(F)Start", "routine": "start", "start": true }],
        \\  "triggers": [{ "condition": "destroyed", "subject": { "group": "(FG)Raiders" }, "routine": "won" }],
        \\  "routines": [
        \\    { "id": "won", "code": [
        \\      { "set": "objectives_met", "to": 1 },
        \\      { "command": "CreateTimer", "args": [1, { "part": "(F)Start" }, 5, 1] },
        \\      { "return": 1 }
        \\    ] },
        \\    { "id": "start", "code": [
        \\      { "command": "CreateFlightGroup", "args": [{ "group": "(FG)Alpha" }] },
        \\      { "command": "CreateFlightGroup", "args": [{ "group": "(FG)Raiders" }] },
        \\      { "command": "SetHostile", "args": [{ "group": "(FG)Raiders" }, true] },
        \\      { "command": "SetHostile", "args": [{ "group": "(FG)Alpha" }, false] },
        \\      { "command": "PlayMusic", "args": ["New_Mission01.wav", 0] },
        \\      { "return": 1 }
        \\    ] }
        \\  ]
        \\}
    );
    defer gpa.free(bytes);
    const file: dte.Mission = try .parse(bytes);
    try std.testing.expectEqualStrings("Patrol", file.openReliantName().?);
    const ships = try file.ships();
    try std.testing.expectEqual(Type.sabre.number(), ships[0].kind);
    try std.testing.expectEqual(1, ships[1].flight_group);
    try std.testing.expectEqual(150000, ships[1].runtime_position[2]);
    try std.testing.expectEqual(180, ships[1].runtime_yaw);
    // The trigger in the Raiders' slice, running the first routine.
    const objects = try file.objects();
    try std.testing.expectEqual(1, objects[3].count);
    try std.testing.expectEqual(0, (try file.triggers())[0].block().?);
    // The start part: the commands by their catalogue, the constants after the block.
    const part = (try file.parts())[0];
    try std.testing.expect(part.flags.start);
    const disassembly = (try dte.disassemble(gpa, try file.script(), part.start())).?;
    defer gpa.free(disassembly.instructions);
    try std.testing.expect(!disassembly.incomplete);
    var names: [6][]const u8 = undefined;
    var found: usize = 0;
    for (disassembly.instructions) |instruction| {
        if (instruction.opcode == .command) {
            names[found] = commands.find(instruction.operands[0]).?.name;
            found += 1;
        }
    }
    try std.testing.expectEqual(5, found);
    try std.testing.expectEqualStrings("SetHostile", names[2]);
    // The trigger's routine names the start part by its index, a byte, for CreateTimer.
    const won = (try dte.disassemble(gpa, try file.script(), 0)).?;
    defer gpa.free(won.instructions);
    try std.testing.expect(for (won.instructions) |instruction| {
        if (instruction.opcode == .push_byte and instruction.operands[0] == 0) break true;
    } else false);
}

test "a source that is wrong says where" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.Invalid, parse(arena, "{ \"ships\": [{ \"name\": \"A\", \"group\": \"(FG)None\" }] }", &diagnostic));
    try std.testing.expectEqualStrings("ships[0].group: no flight group named \"(FG)None\"", diagnostic.message);
    try std.testing.expectError(error.Invalid, parse(arena,
        \\{ "routines": [{ "id": "a", "code": [{ "command": "SetHostile", "args": [1] }] }] }
    , &diagnostic));
    try std.testing.expectEqualStrings("routines[0].code[0]: SetHostile takes 2 arguments, not 1", diagnostic.message);
    try std.testing.expectError(error.Invalid, parse(arena, "{ \"ships\": [{ \"speed\": 3 }] }", &diagnostic));
    try std.testing.expectEqualStrings("ships[0]: no field \"speed\"", diagnostic.message);
}

test "a mission file written as its source builds back the same" {
    const gpa = std.testing.allocator;
    const original = try buildText(gpa,
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Player", "kind": "sabre", "group": "(FG)Alpha", "position": [1.5, -2.25, 3e7] }],
        \\  "parts": [{ "name": "(F)Start", "routine": "start", "start": true }],
        \\  "routines": [{ "id": "start", "code": [
        \\    { "label": "top" },
        \\    { "op": "random_branch", "default": "a", "arms": [{ "to": "b", "threshold": 50 }] },
        \\    { "label": "a" },
        \\    { "command": "PlayMusic", "args": ["x.wav", 70000] },
        \\    { "op": "jump", "to": "b" },
        \\    { "label": "b" },
        \\    { "return": 1 }
        \\  ] }]
        \\}
    );
    defer gpa.free(original);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const read = try fromFile(arena, try .parse(original));
    try std.testing.expectEqual(0, read.whole.len);
    var text: std.Io.Writer.Allocating = .init(arena);
    try writeSource(arena, read.mission, &text.writer);
    var diagnostic: Diagnostic = .{};
    const again = try build.build(arena, try parse(arena, text.written(), &diagnostic));
    try std.testing.expectEqualSlices(u8, original, again);
    // The routine as instructions, with its constants after them.
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "\"tail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "\"command\":\"PlayMusic\"") != null);
}

test "a pool that is not text, and an object table longer than its records, build back the same" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Names by offset into a pool with a byte past ASCII, and a table one entry past the ship's.
    var ship = build.defaults.ship;
    ship.name = 5;
    var mission: build.Mission = .{
        .ships = &.{.{ .name = .{ .at = 5 }, .record = ship }},
        .objects = &.{
            .{ .kind = .ship, .count = 0, .first = build.no_triggers, ._unknown_04 = 8 },
            .{ .kind = .ship, .count = 0, .first = build.no_triggers, ._unknown_04 = 0 },
        },
    };
    mission.sections[@intFromEnum(Section.strings)] = .{ .count = 11, .bytes = "Caf\xe9\x00Ship\x00\x00" };
    const original = try build.build(arena, mission);

    const read = try fromFile(arena, try .parse(original));
    try std.testing.expectEqual(0, read.whole.len);
    var text: std.Io.Writer.Allocating = .init(arena);
    try writeSource(arena, read.mission, &text.writer);
    var diagnostic: Diagnostic = .{};
    const again = try build.build(arena, try parse(arena, text.written(), &diagnostic));
    try std.testing.expectEqualSlices(u8, original, again);

    // A pool given as it is takes no new names.
    mission.ships = &.{.{ .name = .{ .text = "Other" }, .record = ship }};
    try std.testing.expectError(error.NameOutsidePool, build.build(arena, mission));
}

test writeCatalogue {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writeCatalogue(&text.writer);
    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, text.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(commands.table.len, parsed.value.object.get("commands").?.array.items.len);
}
