//! A mission's script written as rules: `on start:`, then a line for each statement, and `on
//! "Raiders".destroyed:` for a trigger, as StarLancerEditor's `.sls` scripts write them
//! (<https://src.ug.gg/mini/starlancereditor>, by mini). A source (`source.zig`) gives its rules as
//! its `script`, which `expand` turns into the parts, triggers and routines the source would
//! otherwise give, so a script written either way builds into the same mission.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const dte = @import("../dte.zig");
const build = @import("build.zig");
const source = @import("source.zig");
const commands = @import("../../engine/game/executor/commands.zig");
const Variables = @import("../../engine/vm.zig").Variables;

/// The names a rule's quoted names are looked up among: the source's ships and flight groups, by
/// their text.
pub const Names = struct {
    ships: []const ?[]const u8,
    groups: []const ?[]const u8,
};

/// The parts, triggers and routines rules give, as a source's JSON gives them.
pub const Expanded = struct {
    parts: []const json.Value,
    triggers: []const json.Value,
    routines: []const json.Value,
};

/// The name of the part `on start:` gives.
pub const start_part = "(F)Start";

/// The parts, triggers and routines the rules of `text` give, in `arena`, each quoted name of a
/// ship or flight group looked up in `names`. On `error.Invalid`, `diagnostic` says what is wrong
/// and on which line.
pub fn expand(arena: Allocator, text: []const u8, names: Names, diagnostic: *source.Diagnostic) source.ParseError!Expanded {
    var e: Expander = .{
        .arena = arena,
        .names = names,
        .diagnostic = diagnostic,
        .parts = .init(arena),
        .triggers = .init(arena),
        .routines = .init(arena),
    };
    var rule: ?Rule = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        e.line += 1;
        const line = try e.lex(std.mem.trimEnd(u8, raw, "\r"));
        if (line.tokens.len == 0) continue;
        if (line.indent == 0) {
            if (rule) |*done| try e.finish(done);
            rule = try e.header(line.tokens);
        } else {
            const open = if (rule) |*open| open else return e.fail("a statement outside a rule, or under one that runs another's body", .{});
            try open.lines.append(arena, line);
        }
    }
    if (rule) |*done| try e.finish(done);
    return .{ .parts = e.parts.items, .triggers = e.triggers.items, .routines = e.routines.items };
}

/// How a rule's first line ends: with a body of its own under the routine's id, or running the
/// body of the routine named.
const Ending = union(enum) {
    body: []const u8,
    runs: []const u8,

    fn id(ending: Ending) []const u8 {
        return switch (ending) {
            inline else => |name| name,
        };
    }

    fn rule(ending: Ending) ?Rule {
        return switch (ending) {
            .body => |name| .{ .id = name },
            .runs => null,
        };
    }
};

/// A rule being read: the lines of its body, which make its routine.
const Rule = struct {
    id: []const u8,
    lines: std.ArrayList(Line) = .empty,
    /// The `if` and `either` blocks so far, which name their labels.
    ifs: usize = 0,
    eithers: usize = 0,
};

const Token = union(enum) {
    /// A command, a keyword or a variable's name.
    word: []const u8,
    /// An integer, in decimal whatever base the line gave it in.
    number: []const u8,
    /// A quoted text, its escapes undone.
    string: []const u8,
    /// One of `( ) , . [ ] :`.
    symbol: u8,
    /// One of `= == != < <= > >= +=`.
    operator: []const u8,
};

const Line = struct {
    /// Its number in the text, from 1.
    number: usize,
    indent: usize,
    tokens: []const Token,
};

/// The script's comparisons, each by the opcode that makes it: the variable against the number.
const comparisons = [_]struct { []const u8, []const u8 }{
    .{ "==", "equal" },
    .{ "!=", "not_equal" },
    .{ ">", "greater" },
    .{ ">=", "greater_equal" },
    .{ "<", "less" },
    .{ "<=", "less_equal" },
};

/// A command's argument as a line gives it, before its parameter says what it is.
const Arg = union(enum) {
    string: []const u8,
    number: []const u8,
    boolean: bool,
    none,
    variable: Variable,
    /// `"Ship".component(index)`.
    component: struct { ship: []const u8, index: []const u8 },
};

/// A game's variable as `flag[...]` gives it: by its name in `vm.Variables`, or its number.
const Variable = union(enum) {
    name: []const u8,
    number: []const u8,

    /// The variable as the source gives one, which looks a name up itself.
    fn value(variable: Variable) json.Value {
        return switch (variable) {
            .name => |name| .{ .string = name },
            .number => |text| .{ .number_string = text },
        };
    }
};

const Expander = struct {
    arena: Allocator,
    names: Names,
    diagnostic: *source.Diagnostic,
    /// The line being read, from 1.
    line: usize = 0,
    parts: json.Array,
    triggers: json.Array,
    routines: json.Array,

    fn fail(e: *Expander, comptime format: []const u8, args: anytype) error{Invalid} {
        e.diagnostic.message = std.fmt.allocPrint(e.arena, "script line {d}: " ++ format, .{e.line} ++ args) catch "out of memory";
        return error.Invalid;
    }

    /// The line's indent and its tokens, up to a `#` outside a text.
    fn lex(e: *Expander, raw: []const u8) source.ParseError!Line {
        var tokens: std.ArrayList(Token) = .empty;
        var i: usize = 0;
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
        const indent = i;
        while (i < raw.len) {
            const c = raw[i];
            switch (c) {
                ' ', '\t' => i += 1,
                '#' => break,
                '(', ')', ',', '.', '[', ']', ':' => {
                    try tokens.append(e.arena, .{ .symbol = c });
                    i += 1;
                },
                '=', '!', '<', '>', '+' => {
                    const pair = i + 1 < raw.len and raw[i + 1] == '=';
                    if (!pair and (c == '!' or c == '+')) return e.fail("\"{c}\" is not part of a rule", .{c});
                    const len: usize = if (pair) 2 else 1;
                    try tokens.append(e.arena, .{ .operator = raw[i .. i + len] });
                    i += len;
                },
                '"' => {
                    var text: std.ArrayList(u8) = .empty;
                    i += 1;
                    while (true) : (i += 1) {
                        if (i >= raw.len) return e.fail("a text with no closing quote", .{});
                        switch (raw[i]) {
                            '"' => break,
                            '\\' => {
                                i += 1;
                                if (i >= raw.len or (raw[i] != '"' and raw[i] != '\\')) return e.fail("only \\\" and \\\\ escape a text", .{});
                                try text.append(e.arena, raw[i]);
                            },
                            else => |other| try text.append(e.arena, other),
                        }
                    }
                    i += 1;
                    try tokens.append(e.arena, .{ .string = text.items });
                },
                '-', '0'...'9' => {
                    const start = i;
                    i += 1;
                    while (i < raw.len and (std.ascii.isAlphanumeric(raw[i]) or raw[i] == '_')) i += 1;
                    const value = std.fmt.parseInt(i64, raw[start..i], 0) catch return e.fail("\"{s}\" is not a number", .{raw[start..i]});
                    try tokens.append(e.arena, .{ .number = try std.fmt.allocPrint(e.arena, "{d}", .{value}) });
                },
                'a'...'z', 'A'...'Z', '_' => {
                    const start = i;
                    while (i < raw.len and (std.ascii.isAlphanumeric(raw[i]) or raw[i] == '_')) i += 1;
                    try tokens.append(e.arena, .{ .word = raw[start..i] });
                },
                else => return e.fail("\"{c}\" is not part of a rule", .{c}),
            }
        }
        return .{ .number = e.line, .indent = indent, .tokens = tokens.items };
    }

    /// A rule's first line: `on start:`, `on "Subject".event:`, `part "Name":` for a part the
    /// script calls, or `routine "Name":` for a body only other rules run. The rule it opens, or
    /// null where it runs another's body.
    fn header(e: *Expander, tokens: []const Token) source.ParseError!?Rule {
        var r: Reader = .{ .e = e, .tokens = tokens };
        if (r.isWord("routine")) {
            r.at += 1;
            const name = try r.string();
            try r.symbol(':');
            try r.end();
            return .{ .id = name };
        }
        if (r.isWord("part")) {
            r.at += 1;
            const name = try r.string();
            const routine = try e.ending(&r);
            try e.parts.append(try object(e.arena, &.{
                .{ "name", .{ .string = name } },
                .{ "routine", .{ .string = routine.id() } },
            }));
            return routine.rule();
        }
        try r.keyword("on");
        if (r.isWord("start")) {
            r.at += 1;
            const routine = try e.ending(&r);
            try e.parts.append(try object(e.arena, &.{
                .{ "name", .{ .string = start_part } },
                .{ "routine", .{ .string = routine.id() } },
                .{ "start", .{ .bool = true } },
            }));
            return routine.rule();
        } else {
            const subject = try r.string();
            try r.symbol('.');
            var event = try r.word();
            // `.component(index)` watches one of a ship's components.
            var component: ?[]const u8 = null;
            if (std.mem.eql(u8, event, "component") and r.isSymbol('(')) {
                r.at += 1;
                component = try r.number();
                try r.symbol(')');
                try r.symbol('.');
                event = try r.word();
            }
            const condition = conditionNamed(event) orelse return e.fail("no event \"{s}\"", .{event});
            const watched = if (component != null)
                try e.reference(subject, true, false) orelse return e.fail("no ship named \"{s}\"", .{subject})
            else
                try e.reference(subject, true, true) orelse return e.fail("no ship or flight group named \"{s}\"", .{subject});
            var trigger = try object(e.arena, &.{
                .{ "condition", .{ .string = @tagName(condition) } },
                .{ "subject", watched },
            });
            if (component) |index| try trigger.object.put(e.arena, "qualifier", .{ .number_string = index });
            if (r.isSymbol('(') and !r.isRepeatNext()) try e.operands(&r, &trigger.object);
            if (r.isSymbol('(')) try e.repeat(&r, &trigger.object);
            const routine = try e.ending(&r);
            try trigger.object.put(e.arena, "routine", .{ .string = routine.id() });
            try e.triggers.append(trigger);
            return routine.rule();
        }
    }

    /// The end of a rule's first line: `:` for a body of its own, `as "Name":` for a body others
    /// may run by that name, or `runs "Name"` for another rule's body.
    fn ending(e: *Expander, r: *Reader) source.ParseError!Ending {
        if (r.isWord("runs")) {
            r.at += 1;
            const name = try r.string();
            try r.end();
            return .{ .runs = name };
        }
        var id: []const u8 = try std.fmt.allocPrint(e.arena, "script line {d}", .{e.line});
        if (r.isWord("as")) {
            r.at += 1;
            id = try r.string();
        }
        try r.symbol(':');
        try r.end();
        return .{ .body = id };
    }

    /// `(operand, ...)` after a trigger's event: up to the trigger's five operands, each a ship or
    /// flight group by its name, a number, or `null`, the rest left unset.
    fn operands(e: *Expander, r: *Reader, trigger: *json.ObjectMap) source.ParseError!void {
        try r.symbol('(');
        var list: json.Array = .init(e.arena);
        if (!r.isSymbol(')')) while (true) {
            if (list.items.len == operand_count) return e.fail("an event takes {d} operands at most", .{operand_count});
            try list.append(switch (try r.arg()) {
                .string => |text| try e.reference(text, true, true) orelse return e.fail("no ship or flight group named \"{s}\"", .{text}),
                .number => |text| .{ .number_string = text },
                .none => .null,
                else => return e.fail("an operand is a ship, a flight group, a number or null", .{}),
            });
            if (!r.isSymbol(',')) break;
            r.at += 1;
        };
        try r.symbol(')');
        while (list.items.len < operand_count) try list.append(.null);
        try trigger.put(e.arena, "operands", .{ .array = list });
    }

    /// `(once)`, `(repeat)` or `(repeat count)` after a trigger's event, as its `repeat`: `once`,
    /// `always`, or `counted` with `count` firings left and `count` again each time the script arms
    /// it.
    fn repeat(e: *Expander, r: *Reader, trigger: *json.ObjectMap) source.ParseError!void {
        try r.symbol('(');
        const mode = try r.word();
        if (std.mem.eql(u8, mode, "once")) {
            try trigger.put(e.arena, "repeat", .{ .string = "once" });
        } else if (std.mem.eql(u8, mode, "repeat")) {
            if (r.isSymbol(')')) {
                try trigger.put(e.arena, "repeat", .{ .string = "always" });
            } else {
                const count = try r.number();
                try trigger.put(e.arena, "repeat", .{ .string = "counted" });
                try trigger.put(e.arena, "repeat_count", .{ .number_string = count });
                try trigger.put(e.arena, "repeat_counter", .{ .number_string = count });
            }
        } else return e.fail("expected once or repeat", .{});
        try r.symbol(')');
    }

    /// Compiles into `code` the lines of a block: those from `at.*` on that stand at `indent`, with
    /// the blocks they open.
    fn block(e: *Expander, rule: *Rule, at: *usize, indent: usize, code: *json.Array) source.ParseError!void {
        const lines = rule.lines.items;
        while (at.* < lines.len and lines[at.*].indent >= indent) {
            const line = lines[at.*];
            e.line = line.number;
            if (line.indent != indent) return e.fail("an indent that opens no block", .{});
            var r: Reader = .{ .e = e, .tokens = line.tokens };
            if (r.isWord("if")) {
                r.at += 1;
                try e.ifBlock(rule, &r, at, indent, code);
            } else if (r.isWord("either")) {
                r.at += 1;
                try e.eitherBlock(rule, &r, at, indent, code);
            } else if (r.isWord("else")) {
                return e.fail("an else with no if before it", .{});
            } else if (r.isWord("or")) {
                return e.fail("an or with no either before it", .{});
            } else {
                try e.statement(&r, code);
                at.* += 1;
            }
        }
    }

    /// `if flag[variable] comparison number:`, its block, and an `else:` block where one follows,
    /// as `push_array`, `push_byte`, the comparison and `branch_if_zero` past the block, which ends
    /// with a jump past the else whether or not there is one.
    fn ifBlock(e: *Expander, rule: *Rule, r: *Reader, at: *usize, indent: usize, code: *json.Array) source.ParseError!void {
        rule.ifs += 1;
        const skip = try std.fmt.allocPrint(e.arena, "else {d}", .{rule.ifs});
        const done = try std.fmt.allocPrint(e.arena, "end {d}", .{rule.ifs});
        try r.keyword("flag");
        const variable = try e.variableNumber(try r.flag());
        const comparison = try r.operator();
        const opcode = for (comparisons) |pair| {
            if (std.mem.eql(u8, pair[0], comparison)) break pair[1];
        } else return e.fail("\"{s}\" is not a comparison", .{comparison});
        const value = try e.byte(try r.number());
        try r.symbol(':');
        try r.end();
        try code.append(try op(e.arena, "push_array", variable));
        try code.append(try op(e.arena, "push_byte", value));
        try code.append(try op(e.arena, opcode, null));
        try code.append(try jump(e.arena, "branch_if_zero", skip));
        at.* += 1;
        try e.body(rule, at, indent, code);
        try code.append(try jump(e.arena, "jump", done));
        try code.append(try object(e.arena, &.{.{ "label", .{ .string = skip } }}));
        const lines = rule.lines.items;
        if (at.* < lines.len and lines[at.*].indent == indent) {
            var next: Reader = .{ .e = e, .tokens = lines[at.*].tokens };
            if (next.isWord("else")) {
                e.line = lines[at.*].number;
                next.at += 1;
                try next.symbol(':');
                try next.end();
                at.* += 1;
                try e.body(rule, at, indent, code);
            }
        }
        try code.append(try object(e.arena, &.{.{ "label", .{ .string = done } }}));
    }

    /// `either:` and its block, then an `or:` block for each other choice: one of them at random,
    /// each as likely, as one `random_branch` with an arm for each block but the last at even steps
    /// of its roll below 100, the last the default, each block then jumping past the rest.
    fn eitherBlock(e: *Expander, rule: *Rule, r: *Reader, at: *usize, indent: usize, code: *json.Array) source.ParseError!void {
        const line = e.line;
        rule.eithers += 1;
        try r.symbol(':');
        try r.end();
        var blocks: std.ArrayList(json.Array) = .empty;
        at.* += 1;
        try blocks.append(e.arena, .init(e.arena));
        try e.body(rule, at, indent, &blocks.items[0]);
        const lines = rule.lines.items;
        while (at.* < lines.len and lines[at.*].indent == indent) {
            var next: Reader = .{ .e = e, .tokens = lines[at.*].tokens };
            if (!next.isWord("or")) break;
            e.line = lines[at.*].number;
            next.at += 1;
            try next.symbol(':');
            try next.end();
            at.* += 1;
            try blocks.append(e.arena, .init(e.arena));
            try e.body(rule, at, indent, &blocks.items[blocks.items.len - 1]);
        }
        e.line = line;
        if (blocks.items.len < 2) return e.fail("an either with no or after it", .{});
        if (blocks.items.len > roll) return e.fail("an either of {d} choices: the roll gives {d} at most", .{ blocks.items.len, roll });
        const step = roll / blocks.items.len;
        const labels = try e.arena.alloc([]const u8, blocks.items.len);
        for (labels, 1..) |*label, index| label.* = try std.fmt.allocPrint(e.arena, "choice {d}.{d}", .{ rule.eithers, index });
        const done = try std.fmt.allocPrint(e.arena, "chosen {d}", .{rule.eithers});
        var arms: json.Array = .init(e.arena);
        for (labels[0 .. labels.len - 1], 1..) |label, index| {
            try arms.append(try object(e.arena, &.{
                .{ "to", .{ .string = label } },
                .{ "threshold", .{ .number_string = try std.fmt.allocPrint(e.arena, "{d}", .{step * index}) } },
            }));
        }
        try code.append(try object(e.arena, &.{
            .{ "op", .{ .string = "random_branch" } },
            .{ "default", .{ .string = labels[labels.len - 1] } },
            .{ "arms", .{ .array = arms } },
        }));
        for (blocks.items, labels) |block_code, label| {
            try code.append(try object(e.arena, &.{.{ "label", .{ .string = label } }}));
            try code.appendSlice(block_code.items);
            try code.append(try jump(e.arena, "jump", done));
        }
        try code.append(try object(e.arena, &.{.{ "label", .{ .string = done } }}));
    }

    /// The block a line ending in `:` opens: the lines after it, indented past `outer`.
    fn body(e: *Expander, rule: *Rule, at: *usize, outer: usize, code: *json.Array) source.ParseError!void {
        const lines = rule.lines.items;
        if (at.* >= lines.len or lines[at.*].indent <= outer) return e.fail("a block with nothing in it", .{});
        try e.block(rule, at, lines[at.*].indent, code);
    }

    /// A line of a rule's body: a command's call, `flag[variable] = value` or `+= value`,
    /// `call "Part"`, `return result`, or `yield`, which stops the routine until its trigger fires
    /// again (`InterruptTriggerCode`).
    fn statement(e: *Expander, r: *Reader, code: *json.Array) source.ParseError!void {
        const first = try r.word();
        if (std.mem.eql(u8, first, "yield")) {
            try r.end();
            return code.append(try object(e.arena, &.{ .{ "command", .{ .string = "InterruptTriggerCode" } }, .{ "args", .{ .array = .init(e.arena) } } }));
        }
        if (std.mem.eql(u8, first, "call")) {
            const part = try r.string();
            try r.end();
            return code.append(try object(e.arena, &.{.{ "call", .{ .string = part } }}));
        }
        if (std.mem.eql(u8, first, "return")) {
            const result = try r.number();
            try r.end();
            return code.append(try object(e.arena, &.{.{ "return", .{ .number_string = result } }}));
        }
        if (std.mem.eql(u8, first, "flag")) {
            const variable = try r.flag();
            const assignment = try r.operator();
            const value = try r.number();
            try r.end();
            if (std.mem.eql(u8, assignment, "=")) {
                return code.append(try object(e.arena, &.{ .{ "set", variable.value() }, .{ "to", .{ .number_string = value } } }));
            } else if (std.mem.eql(u8, assignment, "+=")) {
                try code.append(try op(e.arena, "select_array", try e.variableNumber(variable)));
                try code.append(try op(e.arena, "push_byte", try e.byte(value)));
                return code.append(try op(e.arena, "add_assign", null));
            } else return e.fail("expected = or +=", .{});
        }
        const command = commandNamed(first) orelse return e.fail("no command \"{s}\"", .{first});
        try r.symbol('(');
        var given: std.ArrayList(Arg) = .empty;
        if (!r.isSymbol(')')) while (true) {
            try given.append(e.arena, try r.arg());
            if (!r.isSymbol(',')) break;
            r.at += 1;
        };
        try r.symbol(')');
        try r.end();
        if (given.items.len != command.params.len) return e.fail("{s} takes {d} arguments, not {d}", .{ command.name, command.params.len, given.items.len });
        var args: json.Array = .init(e.arena);
        for (given.items, command.params) |arg, param| try args.append(try e.argument(arg, param.kinds));
        try code.append(try object(e.arena, &.{ .{ "command", .{ .string = command.name } }, .{ "args", .{ .array = args } } }));
    }

    /// The number of the variable `flag[...]` gave.
    fn variableNumber(e: *Expander, variable: Variable) source.ParseError!u8 {
        return switch (variable) {
            .name => |name| source.variableNumber(name) orelse e.fail("no variable \"{s}\"", .{name}),
            .number => |text| std.fmt.parseInt(u8, text, 10) catch e.fail("no variable {s}: the variables are numbered 0 to 255", .{text}),
        };
    }

    /// A number the script pushes as a byte (`push_byte`).
    fn byte(e: *Expander, text: []const u8) source.ParseError!u8 {
        return std.fmt.parseInt(u8, text, 10) catch e.fail("{s} is not a number from 0 to 255", .{text});
    }

    /// An argument as the source gives it, for a parameter of `kinds`: a quoted name is a ship or
    /// flight group where the parameter takes one of that name, else a part or a text.
    fn argument(e: *Expander, arg: Arg, kinds: commands.Kinds) source.ParseError!json.Value {
        return switch (arg) {
            .number => |text| .{ .number_string = text },
            .boolean => |flag| .{ .bool = flag },
            .none => .null,
            .variable => |variable| object(e.arena, &.{.{ "variable", variable.value() }}),
            .component => |component| {
                if (!kinds.ship) return e.fail("\"{s}\".component({s}): the parameter takes no ship", .{ component.ship, component.index });
                var found = try e.reference(component.ship, true, false) orelse return e.fail("no ship named \"{s}\"", .{component.ship});
                try found.object.put(e.arena, "component", .{ .number_string = component.index });
                return found;
            },
            .string => |text| {
                if (kinds.ship or kinds.flight_group) {
                    if (try e.reference(text, kinds.ship, kinds.flight_group)) |found| return found;
                }
                if (kinds.part) return object(e.arena, &.{.{ "part", .{ .string = text } }});
                if (kinds.text or kinds.file_name) return .{ .string = text };
                return e.fail("no ship or flight group named \"{s}\"", .{text});
            },
        };
    }

    /// `{ "ship": name }` or `{ "group": name }` for the ship or flight group named `text`, of the
    /// kinds allowed; null where none is.
    fn reference(e: *Expander, text: []const u8, ships: bool, groups: bool) source.ParseError!?json.Value {
        const ship = ships and named(e.names.ships, text);
        const group = groups and named(e.names.groups, text);
        if (ship and group) return e.fail("\"{s}\" names a ship and a flight group", .{text});
        if (ship) return try object(e.arena, &.{.{ "ship", .{ .string = text } }});
        if (group) return try object(e.arena, &.{.{ "group", .{ .string = text } }});
        return null;
    }

    /// Adds the rule's routine: its body's blocks, ending returning 1 where its last statement is
    /// not a `return` of its own.
    fn finish(e: *Expander, rule: *Rule) source.ParseError!void {
        var code: json.Array = .init(e.arena);
        const lines = rule.lines.items;
        var at: usize = 0;
        if (lines.len > 0) {
            try e.block(rule, &at, lines[0].indent, &code);
            if (at < lines.len) {
                e.line = lines[at].number;
                return e.fail("an indent that matches no block", .{});
            }
        }
        const returns = code.items.len > 0 and code.items[code.items.len - 1].object.get("return") != null;
        if (!returns) try code.append(try object(e.arena, &.{.{ "return", .{ .number_string = "1" } }}));
        try e.routines.append(try object(e.arena, &.{
            .{ "id", .{ .string = rule.id } },
            .{ "code", .{ .array = code } },
        }));
    }
};

/// Reads a line's tokens in order.
const Reader = struct {
    e: *Expander,
    tokens: []const Token,
    at: usize = 0,

    fn next(r: *Reader) source.ParseError!Token {
        if (r.at >= r.tokens.len) return r.e.fail("the line ends early", .{});
        r.at += 1;
        return r.tokens[r.at - 1];
    }

    fn isWord(r: *Reader, expected: []const u8) bool {
        if (r.at >= r.tokens.len) return false;
        return switch (r.tokens[r.at]) {
            .word => |text| std.mem.eql(u8, text, expected),
            else => false,
        };
    }

    fn isSymbol(r: *Reader, expected: u8) bool {
        if (r.at >= r.tokens.len) return false;
        return switch (r.tokens[r.at]) {
            .symbol => |c| c == expected,
            else => false,
        };
    }

    /// Whether the next tokens open `(once)` or `(repeat ...)`.
    fn isRepeatNext(r: *Reader) bool {
        if (!r.isSymbol('(')) return false;
        r.at += 1;
        defer r.at -= 1;
        return r.isWord("once") or r.isWord("repeat");
    }

    fn keyword(r: *Reader, expected: []const u8) source.ParseError!void {
        if (!r.isWord(expected)) return r.e.fail("expected \"{s}\"", .{expected});
        r.at += 1;
    }

    fn word(r: *Reader) source.ParseError![]const u8 {
        return switch (try r.next()) {
            .word => |text| text,
            else => r.e.fail("expected a name", .{}),
        };
    }

    fn string(r: *Reader) source.ParseError![]const u8 {
        return switch (try r.next()) {
            .string => |text| text,
            else => r.e.fail("expected a quoted name", .{}),
        };
    }

    fn number(r: *Reader) source.ParseError![]const u8 {
        return switch (try r.next()) {
            .number => |text| text,
            else => r.e.fail("expected a number", .{}),
        };
    }

    fn operator(r: *Reader) source.ParseError![]const u8 {
        return switch (try r.next()) {
            .operator => |text| text,
            else => r.e.fail("expected = or a comparison", .{}),
        };
    }

    fn symbol(r: *Reader, expected: u8) source.ParseError!void {
        if (!r.isSymbol(expected)) return r.e.fail("expected \"{c}\"", .{expected});
        r.at += 1;
    }

    fn end(r: *Reader) source.ParseError!void {
        if (r.at < r.tokens.len) return r.e.fail("more on the line than a rule takes", .{});
    }

    /// `[variable]` after `flag`: a game's variable by its name or its number.
    fn flag(r: *Reader) source.ParseError!Variable {
        try r.symbol('[');
        const variable: Variable = switch (try r.next()) {
            .word => |text| .{ .name = text },
            .number => |text| .{ .number = text },
            else => return r.e.fail("expected a variable", .{}),
        };
        try r.symbol(']');
        return variable;
    }

    fn arg(r: *Reader) source.ParseError!Arg {
        return switch (try r.next()) {
            .string => |text| if (r.isSymbol('.')) blk: {
                r.at += 1;
                try r.keyword("component");
                try r.symbol('(');
                const index = try r.number();
                try r.symbol(')');
                break :blk .{ .component = .{ .ship = text, .index = index } };
            } else .{ .string = text },
            .number => |text| .{ .number = text },
            .word => |text| if (std.mem.eql(u8, text, "true"))
                .{ .boolean = true }
            else if (std.mem.eql(u8, text, "false"))
                .{ .boolean = false }
            else if (std.mem.eql(u8, text, "null"))
                .none
            else if (std.mem.eql(u8, text, "flag"))
                .{ .variable = try r.flag() }
            else
                r.e.fail("\"{s}\" is not an argument", .{text}),
            .symbol, .operator => r.e.fail("expected an argument", .{}),
        };
    }
};

const Field = struct { []const u8, json.Value };

/// The instruction `name`, with its one operand byte where it takes one.
fn op(arena: Allocator, name: []const u8, operand: ?u8) Allocator.Error!json.Value {
    var instruction = try object(arena, &.{.{ "op", .{ .string = name } }});
    if (operand) |byte| {
        var operands: json.Array = .init(arena);
        try operands.append(.{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{byte}) });
        try instruction.object.put(arena, "operands", .{ .array = operands });
    }
    return instruction;
}

/// The branch `name` to the label `to`.
fn jump(arena: Allocator, name: []const u8, to: []const u8) Allocator.Error!json.Value {
    return object(arena, &.{ .{ "op", .{ .string = name } }, .{ "to", .{ .string = to } } });
}

fn object(arena: Allocator, fields: []const Field) Allocator.Error!json.Value {
    var map: json.ObjectMap = .empty;
    for (fields) |field| try map.put(arena, field[0], field[1]);
    return .{ .object = map };
}

fn named(names: []const ?[]const u8, text: []const u8) bool {
    for (names) |own| {
        if (own) |name| if (std.mem.eql(u8, name, text)) return true;
    }
    return false;
}

fn commandNamed(name: []const u8) ?*const commands.Command {
    for (&commands.table) |*command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

/// What `random_branch` rolls below: an arm is taken where the roll is below its threshold.
const roll = 100;

/// The operands a trigger holds.
const operand_count = @typeInfo(@FieldType(dte.Trigger, "operands")).array.len;

/// A trigger's condition by its name in `dte.Condition`, or as StarLancerEditor writes it: the same
/// name in camel case (`shotAt`), and `readyToJump` for `player_ready_to_jump`.
fn conditionNamed(name: []const u8) ?dte.Condition {
    if (std.mem.eql(u8, name, "readyToJump")) return .player_ready_to_jump;
    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    for (name) |c| {
        const upper = std.ascii.isUpper(c);
        if (len + @as(usize, if (upper) 2 else 1) > buffer.len) return null;
        if (upper) {
            buffer[len] = '_';
            len += 1;
        }
        buffer[len] = std.ascii.toLower(c);
        len += 1;
    }
    return std.meta.stringToEnum(dte.Condition, buffer[0..len]);
}

// Writing a source's script as rules.

pub const RewriteError = source.ParseError || build.Error || std.Io.Writer.Error || error{
    /// Rules cannot say the script as the source gives it; the diagnostic says what.
    Unwritable,
};

/// The source `text` with its parts, triggers and routines given as rules, its `script`, in
/// `arena`: all of them or none. The rules must build the mission the records build, which this
/// checks. On `error.Unwritable` or `error.Invalid`, `diagnostic` says why.
pub fn rewrite(arena: Allocator, text: []const u8, diagnostic: *source.Diagnostic) RewriteError![]const u8 {
    const original = try build.build(arena, try source.parse(arena, text, diagnostic));
    var root = json.parseFromSliceLeaky(json.Value, arena, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostic.message = "the source is not JSON";
            return error.Invalid;
        },
    };
    const top = &root.object;
    var w: Writer = .{
        .arena = arena,
        .diagnostic = diagnostic,
        .ships = try namesOf(arena, top.get("ships")),
        .groups = try namesOf(arena, top.get("flight_groups")),
        .out = .init(arena),
    };
    if (top.get("script") != null) return w.refuse("the source's script is rules already", .{});
    try w.script(listOf(top.get("parts")), listOf(top.get("triggers")), listOf(top.get("routines")));
    _ = top.orderedRemove("parts");
    _ = top.orderedRemove("triggers");
    _ = top.orderedRemove("routines");
    try top.put(arena, "script", .{ .string = w.out.written() });
    const rewritten = try json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
    const again = try build.build(arena, try source.parse(arena, rewritten, diagnostic));
    if (!std.mem.eql(u8, original, again)) return w.refuse("the rules would build another mission", .{});
    return rewritten;
}

/// The source `text` with the rules of its `script` given as the parts, triggers and routines they
/// expand into, after any it gives as records, in `arena`: the source a tool that edits records
/// reads. On `error.Invalid`, `diagnostic` says what is wrong and where.
pub fn expandSource(arena: Allocator, text: []const u8, diagnostic: *source.Diagnostic) (source.ParseError || std.Io.Writer.Error)![]const u8 {
    // The source as a whole first, which checks the rules as it reads them.
    _ = try source.parse(arena, text, diagnostic);
    var root = json.parseFromSliceLeaky(json.Value, arena, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostic.message = "the source is not JSON";
            return error.Invalid;
        },
    };
    const top = &root.object;
    const script = textOf(top.get("script")) orelse return text;
    const names: Names = .{ .ships = try namesOf(arena, top.get("ships")), .groups = try namesOf(arena, top.get("flight_groups")) };
    const expanded = try expand(arena, script, names, diagnostic);
    inline for (.{ "parts", "triggers", "routines" }) |key| {
        var list: json.Array = .init(arena);
        try list.appendSlice(listOf(top.get(key)));
        try list.appendSlice(@field(expanded, key));
        try top.put(arena, key, .{ .array = list });
    }
    _ = top.orderedRemove("script");
    return json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
}

fn listOf(value: ?json.Value) []const json.Value {
    const given = value orelse return &.{};
    return switch (given) {
        .array => |items| items.items,
        else => &.{},
    };
}

/// The names of the records `value` lists, as the source's parser takes them.
fn namesOf(arena: Allocator, value: ?json.Value) Allocator.Error![]const ?[]const u8 {
    return source.recordNames(arena, listOf(value));
}

/// A rule written: a part's or a trigger's, by its place.
const Owner = union(enum) {
    part: usize,
    trigger: usize,
};

/// How a written rule ends its first line: with its routine's body, unnamed or named for the other
/// rules that run it, or running a body written before.
const Opening = union(enum) {
    body,
    named: []const u8,
    runs: []const u8,
};

const Writer = struct {
    arena: Allocator,
    diagnostic: *source.Diagnostic,
    ships: []const ?[]const u8,
    groups: []const ?[]const u8,
    out: std.Io.Writer.Allocating,
    /// The routine being written, for what a refusal says.
    routine: []const u8 = "",
    /// How many branches go to each of the routine's labels.
    uses: std.StringHashMapUnmanaged(usize) = .empty,
    /// Where each of the routine's labels stands among its statements.
    places: std.StringHashMapUnmanaged(usize) = .empty,

    fn refuse(w: *Writer, comptime format: []const u8, args: anytype) error{Unwritable} {
        w.diagnostic.message = std.fmt.allocPrint(w.arena, format, args) catch "out of memory";
        return error.Unwritable;
    }

    fn refuseStatement(w: *Writer, statement: json.Value) RewriteError {
        const text = try json.Stringify.valueAlloc(w.arena, statement, .{});
        return w.refuse("routine \"{s}\": rules cannot say {s}", .{ w.routine, text });
    }

    /// The rules of the parts, triggers and routines: the parts and the triggers each in their
    /// order, a part first where either could come, each routine's body with the first rule to run
    /// it, in the routines' order. A routine more than one rule runs is named after its id: `as`
    /// where its body is, `runs` at the others.
    fn script(w: *Writer, parts: []const json.Value, triggers: []const json.Value, routines: []const json.Value) RewriteError!void {
        const ids = try w.arena.alloc([]const u8, routines.len);
        for (ids, routines, 0..) |*id, routine, index| {
            id.* = textOf(fieldOf(routine, "id")) orelse return w.refuse("routines[{d}]: no id", .{index});
        }
        // How many rules run each routine.
        const runs = try w.arena.alloc(usize, routines.len);
        @memset(runs, 0);
        const part_routines = try w.arena.alloc(usize, parts.len);
        for (part_routines, parts) |*routine, part| {
            routine.* = try w.routineOf(ids, part);
            runs[routine.*] += 1;
        }
        const trigger_routines = try w.arena.alloc(usize, triggers.len);
        for (trigger_routines, triggers) |*routine, trigger| {
            routine.* = try w.routineOf(ids, trigger);
            runs[routine.*] += 1;
        }
        for (runs, ids) |count, id| {
            if (count == 0) return w.refuse("routine \"{s}\" serves no part or trigger", .{id});
        }
        const written = try w.arena.alloc(bool, routines.len);
        @memset(written, false);
        var next_routine: usize = 0;
        var next_part: usize = 0;
        var next_trigger: usize = 0;
        var first = true;
        while (next_part < parts.len or next_trigger < triggers.len) {
            const ready_part = next_part < parts.len and (written[part_routines[next_part]] or part_routines[next_part] == next_routine);
            const ready_trigger = next_trigger < triggers.len and (written[trigger_routines[next_trigger]] or trigger_routines[next_trigger] == next_routine);
            if (!first) try w.out.writer.writeByte('\n');
            first = false;
            if (!ready_part and !ready_trigger) {
                // The next routine's rules come later: it stands on its own, for them to run.
                if (next_routine == routines.len) return w.refuse("the parts, triggers and routines stand in an order rules cannot keep", .{});
                w.routine = ids[next_routine];
                try w.out.writer.writeAll("routine ");
                try w.quoted(ids[next_routine]);
                try w.out.writer.writeAll(":\n");
                try w.body(routines[next_routine]);
                written[next_routine] = true;
                next_routine += 1;
                continue;
            }
            const owner: Owner = if (ready_part) .{ .part = next_part } else .{ .trigger = next_trigger };
            const routine = switch (owner) {
                .part => |index| part_routines[index],
                .trigger => |index| trigger_routines[index],
            };
            const opening: Opening = if (written[routine])
                .{ .runs = ids[routine] }
            else if (runs[routine] > 1)
                .{ .named = ids[routine] }
            else
                .body;
            w.routine = ids[routine];
            switch (owner) {
                .part => |index| {
                    try w.partHeader(parts[index], opening);
                    next_part += 1;
                },
                .trigger => |index| {
                    try w.triggerHeader(triggers[index], opening);
                    next_trigger += 1;
                },
            }
            if (opening != .runs) {
                try w.body(routines[routine]);
                written[routine] = true;
                next_routine += 1;
            }
        }
    }

    /// The place of the routine `record` names.
    fn routineOf(w: *Writer, ids: []const []const u8, record: json.Value) RewriteError!usize {
        const id = textOf(fieldOf(record, "routine")) orelse return w.refuse("a part or trigger with no routine", .{});
        for (ids, 0..) |own_id, index| {
            if (std.mem.eql(u8, own_id, id)) return index;
        }
        return w.refuse("no routine \"{s}\"", .{id});
    }

    /// How a rule's first line ends: `:` and a body, `as "id":` and a body others run, or
    /// `runs "id"`.
    fn opens(w: *Writer, opening: Opening) RewriteError!void {
        switch (opening) {
            .body => return w.out.writer.writeAll(":\n"),
            .named => |id| {
                try w.out.writer.writeAll(" as ");
                try w.quoted(id);
                return w.out.writer.writeAll(":\n");
            },
            .runs => |id| {
                try w.out.writer.writeAll(" runs ");
                try w.quoted(id);
                return w.out.writer.writeByte('\n');
            },
        }
    }

    fn partHeader(w: *Writer, part: json.Value, opening: Opening) RewriteError!void {
        try w.onlyKeys(part, &.{ "name", "routine", "start" });
        const name = textOf(fieldOf(part, "name")) orelse return w.refuse("routine \"{s}\": a part named by other than its text", .{w.routine});
        const start = if (fieldOf(part, "start")) |flag| switch (flag) {
            .bool => |set| set,
            else => return w.refuse("routine \"{s}\": a part's start that is not true or false", .{w.routine}),
        } else false;
        if (start) {
            if (!std.mem.eql(u8, name, start_part)) return w.refuse("routine \"{s}\": rules name the start part {s}, not {s}", .{ w.routine, start_part, name });
            try w.out.writer.writeAll("on start");
            return w.opens(opening);
        }
        try w.out.writer.writeAll("part ");
        try w.quoted(name);
        try w.opens(opening);
    }

    fn triggerHeader(w: *Writer, trigger: json.Value, opening: Opening) RewriteError!void {
        try w.onlyKeys(trigger, &.{ "condition", "subject", "routine", "operands", "qualifier", "repeat", "repeat_count", "repeat_counter" });
        const condition_name = textOf(fieldOf(trigger, "condition")) orelse return w.refuse("routine \"{s}\": a condition not given by its name", .{w.routine});
        const condition = std.meta.stringToEnum(dte.Condition, condition_name) orelse return w.refuse("routine \"{s}\": no condition \"{s}\"", .{ w.routine, condition_name });
        var component: ?u8 = null;
        if (fieldOf(trigger, "qualifier")) |given| {
            const qualifier = byteOf(given) orelse return w.refuse("routine \"{s}\": a qualifier not a number", .{w.routine});
            if (qualifier != dte.Trigger.whole_object) component = qualifier;
        }
        const subject = fieldOf(trigger, "subject") orelse return w.refuse("routine \"{s}\": a trigger with no subject", .{w.routine});
        const watched = try w.reference(subject, true, component == null);
        try w.out.writer.writeAll("on ");
        try w.quoted(watched);
        if (component) |index| try w.out.writer.print(".component({d})", .{index});
        try w.out.writer.print(".{s}", .{@tagName(condition)});
        if (fieldOf(trigger, "operands")) |given| try w.operands(given);
        try w.repeat(trigger);
        try w.opens(opening);
    }

    /// The operands up to the last that is set.
    fn operands(w: *Writer, given: json.Value) RewriteError!void {
        const list = switch (given) {
            .array => |items| items.items,
            else => return w.refuse("routine \"{s}\": operands not a list", .{w.routine}),
        };
        var count = list.len;
        while (count > 0 and list[count - 1] == .null) count -= 1;
        if (count == 0) return;
        try w.out.writer.writeByte('(');
        for (list[0..count], 0..) |operand, index| {
            if (index > 0) try w.out.writer.writeAll(", ");
            switch (operand) {
                .null => try w.out.writer.writeAll("null"),
                .number_string => |number| try w.out.writer.writeAll(number),
                else => try w.quoted(try w.reference(operand, true, true)),
            }
        }
        try w.out.writer.writeByte(')');
    }

    fn repeat(w: *Writer, trigger: json.Value) RewriteError!void {
        const count = fieldOf(trigger, "repeat_count");
        const counter = fieldOf(trigger, "repeat_counter");
        const mode = if (fieldOf(trigger, "repeat")) |given| textOf(given) orelse return w.refuse("routine \"{s}\": a repeat not given by its name", .{w.routine}) else {
            if (count != null or counter != null) return w.refuse("routine \"{s}\": a repeat count on a trigger that is not counted", .{w.routine});
            return;
        };
        if (std.mem.eql(u8, mode, "counted")) {
            const firings = byteOf(count orelse .null) orelse return w.refuse("routine \"{s}\": a counted trigger with no repeat_count", .{w.routine});
            if (byteOf(counter orelse .null) != firings) return w.refuse("routine \"{s}\": a counted trigger whose counter is not its count", .{w.routine});
            return w.out.writer.print(" (repeat {d})", .{firings});
        }
        if (count != null or counter != null) return w.refuse("routine \"{s}\": a repeat count on a trigger that is not counted", .{w.routine});
        if (std.mem.eql(u8, mode, "once")) return w.out.writer.writeAll(" (once)");
        if (std.mem.eql(u8, mode, "always")) return w.out.writer.writeAll(" (repeat)");
        return w.refuse("routine \"{s}\": no repeat \"{s}\"", .{ w.routine, mode });
    }

    /// The name of a ship or flight group `{ "ship": name }` or `{ "group": name }` gives, where
    /// rules would find the same record by it.
    fn reference(w: *Writer, given: json.Value, ships: bool, groups: bool) RewriteError![]const u8 {
        const fields = switch (given) {
            .object => |map| map,
            else => return w.refuse("routine \"{s}\": a ship or flight group not given by its name", .{w.routine}),
        };
        if (fields.count() != 1) return w.refuse("routine \"{s}\": a reference rules cannot say", .{w.routine});
        if (fields.get("ship")) |name_of| {
            const name = textOf(name_of) orelse return w.refuse("routine \"{s}\": a ship not given by its name", .{w.routine});
            if (!ships or !named(w.ships, name) or (groups and named(w.groups, name))) return w.refuse("routine \"{s}\": the ship \"{s}\" by its name alone", .{ w.routine, name });
            return name;
        }
        if (fields.get("group")) |name_of| {
            const name = textOf(name_of) orelse return w.refuse("routine \"{s}\": a flight group not given by its name", .{w.routine});
            if (!groups or !named(w.groups, name) or (ships and named(w.ships, name))) return w.refuse("routine \"{s}\": the flight group \"{s}\" by its name alone", .{ w.routine, name });
            return name;
        }
        return w.refuse("routine \"{s}\": a reference rules cannot say", .{w.routine});
    }

    /// The routine's statements as the rule's body, which ends with a `return`: its last, left
    /// unwritten where it returns 1.
    fn body(w: *Writer, routine: json.Value) RewriteError!void {
        try w.onlyKeys(routine, &.{ "id", "code" });
        const code = listOf(fieldOf(routine, "code"));
        if (code.len == 0) return w.refuse("routine \"{s}\" does not end with a return", .{w.routine});
        const result = fieldOf(code[code.len - 1], "return") orelse return w.refuse("routine \"{s}\" does not end with a return", .{w.routine});
        w.uses = .empty;
        w.places = .empty;
        for (code, 0..) |statement, index| {
            if (textOf(fieldOf(statement, "label"))) |label| try w.places.put(w.arena, label, index);
            for ([_][]const u8{ "to", "default" }) |key| {
                if (textOf(fieldOf(statement, key))) |label| try w.use(label);
            }
            for (listOf(fieldOf(statement, "arms"))) |arm| {
                if (textOf(fieldOf(arm, "to"))) |label| try w.use(label);
            }
        }
        try w.block(code, 0, code.len - 1, 1);
        const number = switch (result) {
            .number_string => |text| text,
            else => return w.refuseStatement(code[code.len - 1]),
        };
        if (!std.mem.eql(u8, number, "1")) {
            try w.indent(1);
            try w.out.writer.print("return {s}\n", .{number});
        }
    }

    fn use(w: *Writer, label: []const u8) Allocator.Error!void {
        const slot = try w.uses.getOrPut(w.arena, label);
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
    }

    /// Writes the statements from `from` to `to` at `depth`.
    fn block(w: *Writer, code: []const json.Value, from: usize, to: usize, depth: usize) RewriteError!void {
        var at = from;
        while (at < to) {
            if (try w.ifBlock(code, at, to, depth)) |next| {
                at = next;
            } else if (try w.eitherBlock(code, at, to, depth)) |next| {
                at = next;
            } else if (try w.addition(code, at, to, depth)) |next| {
                at = next;
            } else {
                try w.simpleStatement(code[at], depth);
                at += 1;
            }
        }
    }

    /// An `if` block at `at`, as `ifBlock` builds one: the place after it, or null where none is.
    fn ifBlock(w: *Writer, code: []const json.Value, at: usize, to: usize, depth: usize) RewriteError!?usize {
        if (at + 4 > to) return null;
        const variable = operandOf(code[at], "push_array") orelse return null;
        const value = operandOf(code[at + 1], "push_byte") orelse return null;
        const comparison = for (comparisons) |pair| {
            if (isOp(code[at + 2], pair[1]) and fieldOf(code[at + 2], "operands") == null) break pair[0];
        } else return null;
        const skip = branchOf(code[at + 3], "branch_if_zero") orelse return null;
        const skip_at = w.labelled(skip, at + 5, to) orelse return null;
        const done = branchOf(code[skip_at - 1], "jump") orelse return null;
        const done_at = w.labelled(done, skip_at + 1, to) orelse return null;
        if (std.mem.eql(u8, skip, done) or w.uses.get(skip) != 1 or w.uses.get(done) != 1) return null;
        try w.indent(depth);
        try w.out.writer.writeAll("if ");
        try w.writeFlag(variable);
        try w.out.writer.print(" {s} {d}:\n", .{ comparison, value });
        try w.block(code, at + 4, skip_at - 1, depth + 1);
        if (done_at > skip_at + 1) {
            try w.indent(depth);
            try w.out.writer.writeAll("else:\n");
            try w.block(code, skip_at + 1, done_at, depth + 1);
        }
        return done_at + 1;
    }

    /// An `either` block at `at`, as `eitherBlock` builds one: the place after it, or null where
    /// none is.
    fn eitherBlock(w: *Writer, code: []const json.Value, at: usize, to: usize, depth: usize) RewriteError!?usize {
        if (!isOp(code[at], "random_branch")) return null;
        const last = textOf(fieldOf(code[at], "default")) orelse return null;
        const arms = listOf(fieldOf(code[at], "arms"));
        const count = arms.len + 1;
        if (count < 2 or count > roll) return null;
        const step = roll / count;
        const labels = try w.arena.alloc([]const u8, count);
        for (arms, 0..) |arm, index| {
            if (fieldOf(arm, "extra")) |extra| if (byteOf(extra) != 0) return null;
            const threshold = byteOf(fieldOf(arm, "threshold") orelse return null) orelse return null;
            if (threshold != step * (index + 1)) return null;
            labels[index] = textOf(fieldOf(arm, "to")) orelse return null;
        }
        labels[count - 1] = last;
        // Each block: its label, its statements, a jump to the label after them all.
        const starts = try w.arena.alloc(usize, count + 1);
        var done: ?[]const u8 = null;
        var place = at + 1;
        for (labels, 0..) |label, index| {
            if (place >= to or !std.mem.eql(u8, textOf(fieldOf(code[place], "label")) orelse return null, label)) return null;
            if (w.uses.get(label) != 1) return null;
            starts[index] = place + 1;
            // The block ends at the jump before the next block's label, or before the label after
            // them all.
            const next = if (index + 1 < count) labels[index + 1] else done orelse return null;
            const next_at = w.labelled(next, place + 2, to) orelse return null;
            const exit = branchOf(code[next_at - 1], "jump") orelse return null;
            if (done) |known| {
                if (!std.mem.eql(u8, known, exit)) return null;
            } else done = exit;
            place = next_at;
            if (index + 1 == count) starts[count] = next_at;
        }
        const after = done.?;
        if (w.uses.get(after) != count) return null;
        try w.indent(depth);
        try w.out.writer.writeAll("either:\n");
        for (0..count) |index| {
            if (index > 0) {
                try w.indent(depth);
                try w.out.writer.writeAll("or:\n");
            }
            const end = if (index + 1 < count) w.places.get(labels[index + 1]).? else starts[count];
            try w.block(code, starts[index], end - 1, depth + 1);
        }
        return starts[count] + 1;
    }

    /// `+=` at `at`: `select_array`, `push_byte` and `add_assign`. The place after it, or null.
    fn addition(w: *Writer, code: []const json.Value, at: usize, to: usize, depth: usize) RewriteError!?usize {
        if (at + 3 > to) return null;
        const variable = operandOf(code[at], "select_array") orelse return null;
        const value = operandOf(code[at + 1], "push_byte") orelse return null;
        if (!isOp(code[at + 2], "add_assign") or fieldOf(code[at + 2], "operands") != null) return null;
        try w.indent(depth);
        try w.writeFlag(variable);
        try w.out.writer.print(" += {d}\n", .{value});
        return at + 3;
    }

    fn simpleStatement(w: *Writer, given: json.Value, depth: usize) RewriteError!void {
        const fields = switch (given) {
            .object => |map| map,
            else => return w.refuseStatement(given),
        };
        if (fields.get("set")) |variable| {
            if (fields.count() != 2) return w.refuseStatement(given);
            const value = switch (fields.get("to") orelse return w.refuseStatement(given)) {
                .number_string => |text| text,
                else => return w.refuseStatement(given),
            };
            try w.indent(depth);
            try w.out.writer.writeAll("flag[");
            switch (variable) {
                .string, .number_string => |text| try w.out.writer.writeAll(text),
                else => return w.refuseStatement(given),
            }
            return w.out.writer.print("] = {s}\n", .{value});
        }
        if (fields.get("call")) |part| {
            const name = textOf(part) orelse return w.refuseStatement(given);
            if (fields.count() != 1) return w.refuseStatement(given);
            try w.indent(depth);
            try w.out.writer.writeAll("call ");
            try w.quoted(name);
            return w.out.writer.writeByte('\n');
        }
        if (fields.get("return")) |result| {
            const number = switch (result) {
                .number_string => |text| text,
                else => return w.refuseStatement(given),
            };
            if (fields.count() != 1) return w.refuseStatement(given);
            try w.indent(depth);
            return w.out.writer.print("return {s}\n", .{number});
        }
        if (fields.get("command")) |name_of| {
            const name = textOf(name_of) orelse return w.refuseStatement(given);
            const command = commandNamed(name) orelse return w.refuseStatement(given);
            if (fields.count() != 2 or fields.get("args") == null) return w.refuseStatement(given);
            const args = listOf(fields.get("args"));
            if (args.len != command.params.len) return w.refuseStatement(given);
            try w.indent(depth);
            if (std.mem.eql(u8, name, "InterruptTriggerCode")) return w.out.writer.writeAll("yield\n");
            try w.out.writer.print("{s}(", .{name});
            for (args, command.params, 0..) |arg, param, index| {
                if (index > 0) try w.out.writer.writeAll(", ");
                w.argument(arg, param.kinds) catch |err| switch (err) {
                    error.Unwritable => return w.refuseStatement(given),
                    else => |other| return other,
                };
            }
            return w.out.writer.writeAll(")\n");
        }
        return w.refuseStatement(given);
    }

    /// An argument as rules give it, where rules read it back the same for a parameter of `kinds`.
    fn argument(w: *Writer, given: json.Value, kinds: commands.Kinds) RewriteError!void {
        switch (given) {
            .null => return w.out.writer.writeAll("null"),
            .bool => |flag| return w.out.writer.writeAll(if (flag) "true" else "false"),
            .number_string => |number| return w.out.writer.writeAll(number),
            .string => |text| {
                if (!(kinds.text or kinds.file_name) or kinds.part or w.shadowed(text, kinds)) return error.Unwritable;
                return w.quoted(text);
            },
            .object => |fields| {
                if (fields.count() == 2) {
                    // A ship's component, which rules look up among the ships alone.
                    const name = textOf(fields.get("ship")) orelse return error.Unwritable;
                    const index = switch (fields.get("component") orelse return error.Unwritable) {
                        .number_string => |number| number,
                        else => return error.Unwritable,
                    };
                    if (!kinds.ship or !named(w.ships, name)) return error.Unwritable;
                    try w.quoted(name);
                    return w.out.writer.print(".component({s})", .{index});
                }
                if (fields.count() != 1) return error.Unwritable;
                if (fields.get("ship") != null or fields.get("group") != null) {
                    return w.quoted(try w.reference(given, kinds.ship, kinds.flight_group));
                }
                if (fields.get("part")) |part| {
                    const name = textOf(part) orelse return error.Unwritable;
                    if (!kinds.part or w.shadowed(name, kinds)) return error.Unwritable;
                    return w.quoted(name);
                }
                if (fields.get("variable")) |variable| {
                    try w.out.writer.writeAll("flag[");
                    switch (variable) {
                        .string, .number_string => |text| try w.out.writer.writeAll(text),
                        else => return error.Unwritable,
                    }
                    return w.out.writer.writeByte(']');
                }
                return error.Unwritable;
            },
            else => return error.Unwritable,
        }
    }

    /// Whether rules would read `text` as a ship or flight group, for a parameter of `kinds`.
    fn shadowed(w: *Writer, text: []const u8, kinds: commands.Kinds) bool {
        return (kinds.ship and named(w.ships, text)) or (kinds.flight_group and named(w.groups, text));
    }

    /// `flag[...]` for the variable numbered `number`, by its name where it has one.
    fn writeFlag(w: *Writer, number: u8) RewriteError!void {
        if (source.variableName(number)) |name| return w.out.writer.print("flag[{s}]", .{name});
        return w.out.writer.print("flag[{d}]", .{number});
    }

    fn quoted(w: *Writer, text: []const u8) RewriteError!void {
        try w.out.writer.writeByte('"');
        for (text) |c| switch (c) {
            '"', '\\' => {
                try w.out.writer.writeByte('\\');
                try w.out.writer.writeByte(c);
            },
            '\n', '\r' => return w.refuse("routine \"{s}\": a text with a line break", .{w.routine}),
            else => try w.out.writer.writeByte(c),
        };
        try w.out.writer.writeByte('"');
    }

    fn indent(w: *Writer, depth: usize) RewriteError!void {
        try w.out.writer.splatByteAll(' ', depth * 4);
    }

    fn onlyKeys(w: *Writer, record: json.Value, comptime allowed: []const []const u8) RewriteError!void {
        const fields = switch (record) {
            .object => |map| map,
            else => return w.refuse("routine \"{s}\": a record that is not an object", .{w.routine}),
        };
        var keys = fields.iterator();
        while (keys.next()) |entry| {
            const known = for (allowed) |key| {
                if (std.mem.eql(u8, key, entry.key_ptr.*)) break true;
            } else false;
            if (!known) return w.refuse("routine \"{s}\": rules cannot say a record's \"{s}\"", .{ w.routine, entry.key_ptr.* });
        }
    }

    /// Where `label` stands, where that is from `from` and before `to`.
    fn labelled(w: *Writer, label: []const u8, from: usize, to: usize) ?usize {
        const place = w.places.get(label) orelse return null;
        return if (place >= from and place < to) place else null;
    }
};

fn byteOf(value: json.Value) ?u8 {
    return switch (value) {
        .number_string => |number| std.fmt.parseInt(u8, number, 10) catch null,
        else => null,
    };
}

fn isOp(statement: json.Value, name: []const u8) bool {
    const op_name = textOf(fieldOf(statement, "op")) orelse return false;
    return std.mem.eql(u8, op_name, name);
}

/// The one operand byte of the instruction `name`, where `statement` is it.
fn operandOf(statement: json.Value, name: []const u8) ?u8 {
    if (!isOp(statement, name)) return null;
    const fields = statement.object;
    if (fields.count() != 2) return null;
    const list = listOf(fields.get("operands"));
    if (list.len != 1) return null;
    return byteOf(list[0]);
}

/// The label the branch `name` goes to, where `statement` is it.
fn branchOf(statement: json.Value, name: []const u8) ?[]const u8 {
    if (!isOp(statement, name) or statement.object.count() != 2) return null;
    return textOf(statement.object.get("to"));
}

fn textOf(value: ?json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |given| given,
        else => null,
    };
}

fn fieldOf(value: json.Value, key: []const u8) ?json.Value {
    return switch (value) {
        .object => |fields| fields.get(key),
        else => null,
    };
}

// Tests.

/// The source `data` (a JSON object) with `script` added as its rules.
fn withScript(arena: Allocator, data: []const u8, script: []const u8) ![]const u8 {
    var root = try json.parseFromSliceLeaky(json.Value, arena, data, .{ .parse_numbers = false });
    try root.object.put(arena, "script", .{ .string = script });
    return json.Stringify.valueAlloc(arena, root, .{});
}

/// The mission of the source `text`, built.
fn built(arena: Allocator, text: []const u8) ![]u8 {
    var diagnostic: source.Diagnostic = .{};
    const mission = source.parse(arena, text, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message});
        return err;
    };
    return build.build(arena, mission);
}

test "rules build the mission their JSON builds" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders", "position": [0, 0, 150000] }
        \\  ]
        \\}
    ;
    const as_json =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders", "position": [0, 0, 150000] }
        \\  ],
        \\  "parts": [{ "name": "(F)Start", "routine": "start", "start": true }],
        \\  "triggers": [{ "condition": "destroyed", "subject": { "group": "(FG)Raiders" }, "routine": "won" }],
        \\  "routines": [
        \\    { "id": "start", "code": [
        \\      { "command": "CreateFlightGroup", "args": [{ "group": "(FG)Alpha" }] },
        \\      { "command": "SetHostile", "args": [{ "group": "(FG)Raiders" }, true] },
        \\      { "command": "PlayMusic", "args": ["New_Mission01.wav", 0] },
        \\      { "return": 1 }
        \\    ] },
        \\    { "id": "won", "code": [
        \\      { "set": "objectives_met", "to": 1 },
        \\      { "return": 1 }
        \\    ] }
        \\  ]
        \\}
    ;
    const script =
        \\# The raiders come; the mission is won when they are gone.
        \\on start:
        \\    CreateFlightGroup("(FG)Alpha")
        \\    SetHostile("(FG)Raiders", true)
        \\    PlayMusic("New_Mission01.wav", 0)
        \\
        \\on "(FG)Raiders".destroyed:
        \\    flag[objectives_met] = 1
        \\
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );
}

test "a rule repeats as its trigger does, and yields until it fires again" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders" }
        \\  ]
        \\}
    ;
    const as_json =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders" }
        \\  ],
        \\  "triggers": [
        \\    { "condition": "jumped_in", "subject": { "ship": "Player" }, "routine": "legs", "repeat": "always" },
        \\    { "condition": "destroyed", "subject": { "group": "(FG)Raiders" }, "routine": "twice",
        \\      "repeat": "counted", "repeat_count": 2, "repeat_counter": 2 },
        \\    { "condition": "destroyed", "subject": { "ship": "Raider" }, "routine": "first", "repeat": "once" }
        \\  ],
        \\  "routines": [
        \\    { "id": "legs", "code": [
        \\      { "command": "PlayMusic", "args": ["out.wav", 0] },
        \\      { "command": "InterruptTriggerCode", "args": [] },
        \\      { "command": "PlayMusic", "args": ["back.wav", 0] },
        \\      { "return": 1 }
        \\    ] },
        \\    { "id": "twice", "code": [{ "set": "objectives_met", "to": 1 }, { "return": 1 }] },
        \\    { "id": "first", "code": [{ "set": "objectives_met", "to": 2 }, { "return": 1 }] }
        \\  ]
        \\}
    ;
    const script =
        \\on "Player".jumped_in (repeat):
        \\    PlayMusic("out.wav", 0)
        \\    yield
        \\    PlayMusic("back.wav", 0)
        \\on "(FG)Raiders".destroyed (repeat 2):
        \\    flag[objectives_met] = 1
        \\on "Raider".destroyed (once):
        \\    flag[objectives_met] = 2
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );
}

test "a rule's event takes the trigger's operands and a component, in either spelling" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders" }
        \\  ]
        \\}
    ;
    const as_json =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders" }
        \\  ],
        \\  "triggers": [
        \\    { "condition": "shot_at", "subject": { "ship": "Raider" }, "routine": "a",
        \\      "operands": [{ "ship": "Player" }, null, null, null, null] },
        \\    { "condition": "proximity_general", "subject": { "ship": "Raider" }, "routine": "b",
        \\      "operands": [{ "ship": "Player" }, 30, null, null, null] },
        \\    { "condition": "destroyed", "subject": { "ship": "Raider" }, "routine": "c", "qualifier": 2 },
        \\    { "condition": "ship_reached", "subject": { "ship": "Player" }, "routine": "d", "repeat": "always",
        \\      "operands": [{ "group": "(FG)Raiders" }, null, null, null, null] },
        \\    { "condition": "player_ready_to_jump", "subject": { "ship": "Player" }, "routine": "e" }
        \\  ],
        \\  "routines": [
        \\    { "id": "a", "code": [{ "set": "objectives_met", "to": 1 }, { "return": 1 }] },
        \\    { "id": "b", "code": [{ "set": "objectives_met", "to": 2 }, { "return": 1 }] },
        \\    { "id": "c", "code": [{ "set": "objectives_met", "to": 3 }, { "return": 1 }] },
        \\    { "id": "d", "code": [{ "set": "objectives_met", "to": 4 }, { "return": 1 }] },
        \\    { "id": "e", "code": [{ "set": "objectives_met", "to": 5 }, { "return": 1 }] }
        \\  ]
        \\}
    ;
    const script =
        \\on "Raider".shotAt("Player"):
        \\    flag[objectives_met] = 1
        \\on "Raider".proximity_general("Player", 30):
        \\    flag[objectives_met] = 2
        \\on "Raider".component(2).destroyed:
        \\    flag[objectives_met] = 3
        \\on "Player".shipReached("(FG)Raiders") (repeat):
        \\    flag[objectives_met] = 4
        \\on "Player".readyToJump:
        \\    flag[objectives_met] = 5
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );
}

test "a part is a rule the script calls by its name, and a rule may return its own result" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Player", "kind": "sabre", "group": "(FG)Alpha" }]
        \\}
    ;
    const as_json =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Player", "kind": "sabre", "group": "(FG)Alpha" }],
        \\  "parts": [
        \\    { "name": "(F)Start", "routine": "start", "start": true },
        \\    { "name": "(F)Honour", "routine": "honour" }
        \\  ],
        \\  "routines": [
        \\    { "id": "start", "code": [
        \\      { "call": "(F)Honour" },
        \\      { "command": "CreateTimer", "args": [1, { "part": "(F)Honour" }, 5, 1] },
        \\      { "return": 1 }
        \\    ] },
        \\    { "id": "honour", "code": [{ "set": "objectives_met", "to": 1 }, { "return": 0 }] }
        \\  ]
        \\}
    ;
    const script =
        \\on start:
        \\    call "(F)Honour"
        \\    CreateTimer(1, "(F)Honour", 5, 1)
        \\
        \\part "(F)Honour":
        \\    flag[objectives_met] = 1
        \\    return 0
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );
}

test "if and else test a variable against a number, and += adds to one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Player", "kind": "sabre", "group": "(FG)Alpha" }]
        \\}
    ;
    // A test of the variable, the branch past the block, a jump past the else whether or not there
    // is one, then `select_array`, the number and `add_assign`.
    const as_json = std.fmt.comptimePrint(
        \\{{
        \\  "flight_groups": [{{ "name": "(FG)Alpha", "wing": 0 }}],
        \\  "ships": [{{ "name": "Player", "kind": "sabre", "group": "(FG)Alpha" }}],
        \\  "parts": [{{ "name": "(F)Start", "routine": "start", "start": true }}],
        \\  "routines": [{{ "id": "start", "code": [
        \\    {{ "op": "push_array", "operands": [50] }}, {{ "op": "push_byte", "operands": [0] }},
        \\    {{ "op": "equal" }}, {{ "op": "branch_if_zero", "to": "else 1" }},
        \\    {{ "set": 50, "to": 1 }},
        \\    {{ "op": "push_array", "operands": [{d}] }}, {{ "op": "push_byte", "operands": [2] }},
        \\    {{ "op": "not_equal" }}, {{ "op": "branch_if_zero", "to": "else 2" }},
        \\    {{ "command": "PlayMusic", "args": ["a.wav", 0] }},
        \\    {{ "op": "jump", "to": "end 2" }}, {{ "label": "else 2" }}, {{ "label": "end 2" }},
        \\    {{ "op": "jump", "to": "end 1" }}, {{ "label": "else 1" }},
        \\    {{ "command": "PlayMusic", "args": ["b.wav", 0] }},
        \\    {{ "label": "end 1" }},
        \\    {{ "op": "push_array", "operands": [51] }}, {{ "op": "push_byte", "operands": [3] }},
        \\    {{ "op": "less" }}, {{ "op": "branch_if_zero", "to": "else 3" }},
        \\    {{ "op": "select_array", "operands": [51] }}, {{ "op": "push_byte", "operands": [1] }},
        \\    {{ "op": "add_assign" }},
        \\    {{ "op": "jump", "to": "end 3" }}, {{ "label": "else 3" }}, {{ "label": "end 3" }},
        \\    {{ "return": 1 }}
        \\  ] }}]
        \\}}
    , .{comptime Variables.number("objectives_met")});
    const script =
        \\on start:
        \\    if flag[50] == 0:
        \\        flag[50] = 1
        \\        if flag[objectives_met] != 2:
        \\            PlayMusic("a.wav", 0)
        \\    else:
        \\        PlayMusic("b.wav", 0)
        \\    if flag[51] < 3:
        \\        flag[51] += 1
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );
}

test "either and or run one of their blocks at random, each as likely" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Player", "kind": "sabre", "group": "(FG)Alpha" }]
        \\}
    ;
    // One `random_branch`: an arm for each block but the last, at even steps of the roll below
    // 100, the last the default; each block then jumps past the rest.
    const as_json =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Player", "kind": "sabre", "group": "(FG)Alpha" }],
        \\  "parts": [{ "name": "(F)Start", "routine": "start", "start": true }],
        \\  "routines": [{ "id": "start", "code": [
        \\    { "op": "random_branch", "default": "c", "arms": [{ "to": "a", "threshold": 33 }, { "to": "b", "threshold": 66 }] },
        \\    { "label": "a" }, { "command": "PlayMusic", "args": ["a.wav", 0] }, { "op": "jump", "to": "done" },
        \\    { "label": "b" }, { "command": "PlayMusic", "args": ["b.wav", 0] }, { "op": "jump", "to": "done" },
        \\    { "label": "c" }, { "command": "PlayMusic", "args": ["c.wav", 0] }, { "op": "jump", "to": "done" },
        \\    { "label": "done" },
        \\    { "return": 1 }
        \\  ] }]
        \\}
    ;
    const script =
        \\on start:
        \\    either:
        \\        PlayMusic("a.wav", 0)
        \\    or:
        \\        PlayMusic("b.wav", 0)
        \\    or:
        \\        PlayMusic("c.wav", 0)
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );
}

test "an argument names a ship's component as a trigger's subject does" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Alpha" }
        \\  ]
        \\}
    ;
    const as_json =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Alpha" }
        \\  ],
        \\  "parts": [{ "name": "(F)Start", "routine": "start", "start": true }],
        \\  "routines": [{ "id": "start", "code": [
        \\    { "command": "SetPlayerTarget", "args": [{ "ship": "Player" }, { "ship": "Raider", "component": 2 }] },
        \\    { "return": 1 }
        \\  ] }]
        \\}
    ;
    const script =
        \\on start:
        \\    SetPlayerTarget("Player", "Raider".component(2))
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );
}

test "a routine stands on its own where its rules come later" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Raider", "kind": "predator", "group": "(FG)Alpha" }]
        \\}
    ;
    // The second trigger's routine first.
    const as_json =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Raider", "kind": "predator", "group": "(FG)Alpha" }],
        \\  "triggers": [
        \\    { "condition": "shot_at", "subject": { "ship": "Raider" }, "routine": "hit" },
        \\    { "condition": "destroyed", "subject": { "ship": "Raider" }, "routine": "down" }
        \\  ],
        \\  "routines": [
        \\    { "id": "down", "code": [{ "set": 50, "to": 1 }, { "return": 1 }] },
        \\    { "id": "hit", "code": [{ "set": 51, "to": 1 }, { "return": 1 }] }
        \\  ]
        \\}
    ;
    const script =
        \\routine "down":
        \\    flag[50] = 1
        \\
        \\on "Raider".shot_at:
        \\    flag[51] = 1
        \\
        \\on "Raider".destroyed runs "down"
        \\
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );

    // Written back, the routine no rule can take yet stands on its own.
    var diagnostic: source.Diagnostic = .{};
    const written = rewrite(arena, as_json, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message});
        return err;
    };
    const root = try json.parseFromSliceLeaky(json.Value, arena, written, .{});
    try std.testing.expectEqualStrings(script, root.object.get("script").?.string);
}

test "a rule's body named with as is run by other rules wherever they stand" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Guard" }],
        \\  "ships": [
        \\    { "name": "Guard 1", "kind": "predator", "group": "(FG)Guard" },
        \\    { "name": "Guard 2", "kind": "predator", "group": "(FG)Guard" }
        \\  ]
        \\}
    ;
    // Each guard's triggers together, as an object's must be, so the shared routine's triggers
    // stand apart; the part runs a trigger's routine too.
    const as_json =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Guard" }],
        \\  "ships": [
        \\    { "name": "Guard 1", "kind": "predator", "group": "(FG)Guard" },
        \\    { "name": "Guard 2", "kind": "predator", "group": "(FG)Guard" }
        \\  ],
        \\  "parts": [{ "name": "(F)Again", "routine": "pod" }],
        \\  "triggers": [
        \\    { "condition": "shot_at", "subject": { "ship": "Guard 1" }, "routine": "pod" },
        \\    { "condition": "destroyed", "subject": { "ship": "Guard 1" }, "routine": "down 1" },
        \\    { "condition": "shot_at", "subject": { "ship": "Guard 2" }, "routine": "pod" },
        \\    { "condition": "destroyed", "subject": { "ship": "Guard 2" }, "routine": "down 2" }
        \\  ],
        \\  "routines": [
        \\    { "id": "pod", "code": [{ "set": 50, "to": 1 }, { "return": 1 }] },
        \\    { "id": "down 1", "code": [{ "set": 51, "to": 1 }, { "return": 1 }] },
        \\    { "id": "down 2", "code": [{ "set": 52, "to": 1 }, { "return": 1 }] }
        \\  ]
        \\}
    ;
    const script =
        \\on "Guard 1".shot_at as "fired on a pod":
        \\    flag[50] = 1
        \\on "Guard 1".destroyed:
        \\    flag[51] = 1
        \\on "Guard 2".shot_at runs "fired on a pod"
        \\on "Guard 2".destroyed:
        \\    flag[52] = 1
        \\part "(F)Again" runs "fired on a pod"
    ;
    try std.testing.expectEqualSlices(
        u8,
        try built(arena, as_json),
        try built(arena, try withScript(arena, data, script)),
    );

    // Written back: the routine named after its id where more than one rule runs it, its body with
    // the first rule to come, a part before a trigger.
    var diagnostic: source.Diagnostic = .{};
    const written = rewrite(arena, as_json, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message});
        return err;
    };
    const root = try json.parseFromSliceLeaky(json.Value, arena, written, .{});
    try std.testing.expectEqualStrings(
        \\part "(F)Again" as "pod":
        \\    flag[50] = 1
        \\
        \\on "Guard 1".shot_at runs "pod"
        \\
        \\on "Guard 1".destroyed:
        \\    flag[51] = 1
        \\
        \\on "Guard 2".shot_at runs "pod"
        \\
        \\on "Guard 2".destroyed:
        \\    flag[52] = 1
        \\
    , root.object.get("script").?.string);
}

test "rules that are wrong say on which line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "Twin" }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Twin", "kind": "sabre", "group": "Twin" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders" }
        \\  ]
        \\}
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "on start:\n    SetHostile(\"(FG)Raiders\")", "script line 2: SetHostile takes 2 arguments, not 1" },
        .{ "on \"Twin\".destroyed:", "script line 1: \"Twin\" names a ship and a flight group" },
        .{ "on start:\n    PlayMusic(\"a.wav\", 0)\n    else:", "script line 3: an else with no if before it" },
        .{ "on start:\n    if flag[50] == 0:\n    PlayMusic(\"a.wav\", 0)", "script line 2: a block with nothing in it" },
        .{ "on \"Raider\".exploded:", "script line 1: no event \"exploded\"" },
    };
    for (cases) |case| {
        var diagnostic: source.Diagnostic = .{};
        try std.testing.expectError(error.Invalid, source.parse(arena, try withScript(arena, data, case[0]), &diagnostic));
        try std.testing.expectEqualStrings(case[1], diagnostic.message);
    }
}

test "a source's script is written back as rules that build the same mission" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const records =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }, { "name": "(FG)Raiders" }],
        \\  "ships": [
        \\    { "name": "Player", "kind": "sabre", "group": "(FG)Alpha" },
        \\    { "name": "Raider", "kind": "predator", "group": "(FG)Raiders" }
        \\  ],
        \\  "parts": [
        \\    { "name": "(F)Start", "routine": "start", "start": true },
        \\    { "name": "(F)Honour", "routine": "honour" }
        \\  ],
        \\  "triggers": [
        \\    { "condition": "destroyed", "subject": { "group": "(FG)Raiders" }, "routine": "won",
        \\      "repeat": "counted", "repeat_count": 2, "repeat_counter": 2 },
        \\    { "condition": "shot_at", "subject": { "ship": "Raider" }, "routine": "hit", "repeat": "always",
        \\      "operands": [{ "ship": "Player" }, null, null, null, null] },
        \\    { "condition": "destroyed", "subject": { "ship": "Raider" }, "routine": "turret", "qualifier": 2 }
        \\  ],
        \\  "routines": [
        \\    { "id": "start", "code": [
        \\      { "command": "CreateFlightGroup", "args": [{ "group": "(FG)Alpha" }] },
        \\      { "command": "SetHostile", "args": [{ "group": "(FG)Raiders" }, true] },
        \\      { "command": "PlayMusic", "args": ["New_Mission01.wav", 0] },
        \\      { "command": "CreateTimer", "args": [1, { "part": "(F)Honour" }, 5, 1] },
        \\      { "op": "random_branch", "default": "b", "arms": [{ "to": "a", "threshold": 50 }] },
        \\      { "label": "a" }, { "command": "PlayMusic", "args": ["a.wav", 0] }, { "op": "jump", "to": "done" },
        \\      { "label": "b" }, { "command": "PlayMusic", "args": ["b.wav", 0] }, { "op": "jump", "to": "done" },
        \\      { "label": "done" },
        \\      { "return": 1 }
        \\    ] },
        \\    { "id": "won", "code": [
        \\      { "set": "objectives_met", "to": 1 },
        \\      { "op": "push_array", "operands": [50] }, { "op": "push_byte", "operands": [0] },
        \\      { "op": "equal" }, { "op": "branch_if_zero", "to": "else" },
        \\      { "set": 50, "to": 1 }, { "call": "(F)Honour" },
        \\      { "op": "jump", "to": "fi" }, { "label": "else" },
        \\      { "op": "select_array", "operands": [51] }, { "op": "push_byte", "operands": [1] }, { "op": "add_assign" },
        \\      { "label": "fi" },
        \\      { "return": 1 }
        \\    ] },
        \\    { "id": "honour", "code": [{ "set": 52, "to": 1 }, { "return": 0 }] },
        \\    { "id": "hit", "code": [
        \\      { "command": "PlayMusic", "args": ["hit.wav", 0] },
        \\      { "command": "InterruptTriggerCode", "args": [] },
        \\      { "command": "PlayMusic", "args": ["again.wav", 0] },
        \\      { "return": 1 }
        \\    ] },
        \\    { "id": "turret", "code": [
        \\      { "command": "SetHostile", "args": [{ "ship": "Raider" }, false] },
        \\      { "command": "SetPlayerTarget", "args": [{ "ship": "Player" }, { "ship": "Raider", "component": 2 }] },
        \\      { "return": 1 }
        \\    ] }
        \\  ]
        \\}
    ;
    var diagnostic: source.Diagnostic = .{};
    const written = rewrite(arena, records, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message});
        return err;
    };
    const root = try json.parseFromSliceLeaky(json.Value, arena, written, .{});
    try std.testing.expect(root.object.get("parts") == null);
    try std.testing.expect(root.object.get("triggers") == null);
    try std.testing.expect(root.object.get("routines") == null);
    try std.testing.expectEqualStrings(
        \\on start:
        \\    CreateFlightGroup("(FG)Alpha")
        \\    SetHostile("(FG)Raiders", true)
        \\    PlayMusic("New_Mission01.wav", 0)
        \\    CreateTimer(1, "(F)Honour", 5, 1)
        \\    either:
        \\        PlayMusic("a.wav", 0)
        \\    or:
        \\        PlayMusic("b.wav", 0)
        \\
        \\on "(FG)Raiders".destroyed (repeat 2):
        \\    flag[objectives_met] = 1
        \\    if flag[50] == 0:
        \\        flag[50] = 1
        \\        call "(F)Honour"
        \\    else:
        \\        flag[51] += 1
        \\
        \\part "(F)Honour":
        \\    flag[52] = 1
        \\    return 0
        \\
        \\on "Raider".shot_at("Player") (repeat):
        \\    PlayMusic("hit.wav", 0)
        \\    yield
        \\    PlayMusic("again.wav", 0)
        \\
        \\on "Raider".component(2).destroyed:
        \\    SetHostile("Raider", false)
        \\    SetPlayerTarget("Player", "Raider".component(2))
        \\
    , root.object.get("script").?.string);
    try std.testing.expectEqualSlices(u8, try built(arena, records), try built(arena, written));
}

test expandSource {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{
        \\  "flight_groups": [{ "name": "(FG)Alpha", "wing": 0 }],
        \\  "ships": [{ "name": "Player", "kind": "sabre", "group": "(FG)Alpha" }]
        \\}
    ;
    const with_script = try withScript(arena, data,
        \\on start:
        \\    CreateFlightGroup("(FG)Alpha")
        \\on "Player".destroyed:
        \\    flag[objectives_met] = 1
    );
    var diagnostic: source.Diagnostic = .{};
    const expanded = expandSource(arena, with_script, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message});
        return err;
    };
    // Records in place of the rules, which build the same mission.
    const root = try json.parseFromSliceLeaky(json.Value, arena, expanded, .{});
    try std.testing.expect(root.object.get("script") == null);
    try std.testing.expectEqual(1, root.object.get("parts").?.array.items.len);
    try std.testing.expectEqual(1, root.object.get("triggers").?.array.items.len);
    try std.testing.expectEqual(2, root.object.get("routines").?.array.items.len);
    try std.testing.expectEqualSlices(u8, try built(arena, with_script), try built(arena, expanded));
    // Rules that are wrong say where.
    try std.testing.expectError(error.Invalid, expandSource(arena, try withScript(arena, data, "on start:\n    Nothing()"), &diagnostic));
    try std.testing.expectEqualStrings("script line 2: no command \"Nothing\"", diagnostic.message);
}
