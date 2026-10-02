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
            const open = if (rule) |*open| open else return e.fail("a statement outside a rule", .{});
            try open.lines.append(arena, line);
        }
    }
    if (rule) |*done| try e.finish(done);
    return .{ .parts = e.parts.items, .triggers = e.triggers.items, .routines = e.routines.items };
}

/// A rule being read: the lines of its body, which make its routine.
const Rule = struct {
    id: []const u8,
    lines: std.ArrayList(Line) = .empty,
    /// The `if` blocks so far, which name their labels.
    ifs: usize = 0,
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

    /// A rule's first line: `on start:`, `on "Subject".event:`, or `part "Name":` for a part the
    /// script calls.
    fn header(e: *Expander, tokens: []const Token) source.ParseError!Rule {
        var r: Reader = .{ .e = e, .tokens = tokens };
        const id = try std.fmt.allocPrint(e.arena, "script line {d}", .{e.line});
        if (r.isWord("part")) {
            r.at += 1;
            const name = try r.string();
            try r.symbol(':');
            try r.end();
            try e.parts.append(try object(e.arena, &.{
                .{ "name", .{ .string = name } },
                .{ "routine", .{ .string = id } },
            }));
            return .{ .id = id };
        }
        try r.keyword("on");
        if (r.isWord("start")) {
            r.at += 1;
            try r.symbol(':');
            try r.end();
            try e.parts.append(try object(e.arena, &.{
                .{ "name", .{ .string = start_part } },
                .{ "routine", .{ .string = id } },
                .{ "start", .{ .bool = true } },
            }));
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
                .{ "routine", .{ .string = id } },
            });
            if (component) |index| try trigger.object.put(e.arena, "qualifier", .{ .number_string = index });
            if (r.isSymbol('(') and !r.isRepeatNext()) try e.operands(&r, &trigger.object);
            if (r.isSymbol('(')) try e.repeat(&r, &trigger.object);
            try r.symbol(':');
            try r.end();
            try e.triggers.append(trigger);
        }
        return .{ .id = id };
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
            } else if (r.isWord("else")) {
                return e.fail("an else with no if before it", .{});
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
            .string => |text| .{ .string = text },
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
