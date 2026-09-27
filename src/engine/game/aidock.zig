//! `C:\lancer\game\aidock.cpp`: Dock, order 109, by which a ship docks at a port of another: a
//! freighter at a station's port, a fighter in a Nanny to take on missiles, a limpet car on a
//! ship. Its init picks one of five styles by what docks where; each style has its own init,
//! update and exit (`dock_styles`, `0x004E1618`). OpenReliant has the station's, which mission 1's
//! convoy docks at Fort Sherman by, and the Nanny's. `docs/engine/orders.md` describes it.
//!
//! Not ported: the limpet car's, the limpet car's at the Czar and the limpet pod's styles
//! ([#320](https://github.com/vdmkenny/openreliant/issues/320)), which leave the ship doing
//! nothing.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.orders);

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const Matrix = math.Matrix;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("create.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");
const sound3d = @import("sound3d.zig");

/// How a ship docks, by what it is and what it docks at (`order_dock_init`).
pub const Style = enum(u8) {
    /// Any other ship at any other port: a freighter at a station.
    station = 0,
    /// A ship at a Nanny, which takes it aboard to rearm.
    nanny = 1,
    /// A limpet car at a ship.
    limpet_car = 2,
    /// A limpet car at the Czar, docked.
    limpet_car_czar = 3,
    /// A limpet pod.
    limpet_pod = 4,
    _,
};

/// The order's data (`aigeneric.Entry.data`).
pub const Data = extern struct {
    style: Style,
    _unknown_01: u8,
    /// The ship and the port the search for a free port found (`PortSearch`), before the order
    /// takes them for its target.
    found_ship: i16 align(1),
    found_port: u8,

    comptime {
        assert(@offsetOf(Data, "found_ship") == 0x2);
        assert(@offsetOf(Data, "found_port") == 0x4);
    }
};

/// The station style's state (`GameObject.order_state`).
pub const State = extern struct {
    /// The docking path `motion_follow` follows as the ship slides in, at half its top speed.
    follower: motion.Follower,
    step: u32,
    /// The frame's tick the slide in ends at.
    until: i32,
    /// The part of the ship its docking point is on, by its place among the model's parts, and
    /// where the point stands on it; the game holds the part's node.
    own_part: u32,
    own_point: [3]f32,
    /// The part of the station its port is on, and where the port stands on it and how it is
    /// turned.
    port_part: u32,
    port_point: [3]f32,
    port_turn: [9]f32,
    /// Whether the ship came at the port from its right, which mirrors the way round.
    from_right: u32,
    /// Where the ship stood as the slide in began.
    slide_from: [3]f32,

    comptime {
        assert(@offsetOf(State, "step") == 0x08);
        assert(@offsetOf(State, "until") == 0x0C);
        assert(@offsetOf(State, "own_part") == 0x10);
        assert(@offsetOf(State, "own_point") == 0x14);
        assert(@offsetOf(State, "port_part") == 0x20);
        assert(@offsetOf(State, "port_point") == 0x24);
        assert(@offsetOf(State, "port_turn") == 0x30);
        assert(@offsetOf(State, "from_right") == 0x54);
        assert(@offsetOf(State, "slide_from") == 0x58);
    }
};

/// The station style's steps.
pub const Step = enum(u32) {
    /// Beside the port, `aside` out on the side the ship came from.
    beside = 0,
    /// Beside the port and `aside` behind it too.
    beside_behind = 1,
    /// Twice its turn's width out, and `aside` behind the port.
    turning_in = 2,
    /// On the port's line, `far_behind` behind it.
    far_behind = 3,
    /// On the port's line, `near_behind` behind it.
    near_behind = 4,
    /// It latches on, and starts to slide in.
    latching = 5,
    /// It slides in along the port's line (`way`).
    sliding = 6,
    /// It is in: set in place, and docked.
    docked = 7,
    /// OpenReliant's own: the ship or the port has no docking point, and the order ends.
    no_port = 8,
    _,
};

/// Where the station style steers, in the port's frame: out to its side and behind it
/// (`0x004DC4A0`, `0x004DC494`, and the immediates of `0x004070F0`).
const aside: f32 = 100000;
const far_behind: f32 = 50000;
const near_behind: f32 = 10000;

/// How near its point a step takes the ship before the next: the square of 2000 (`0x004DC490`).
const reach_squared: f32 = 4000000;

/// How far aside the turn in starts, in the ship's cruise speeds over its yaw rate (`0x004DC4A4`).
const turn_widths: f32 = -2;

/// Where a step aims, from where the ship is along the port's line, as the station style's init
/// picks its first: far behind it, and further aside than this share of the way behind
/// (`0x004DC3F8`).
const behind_share: f32 = 0.2;

/// How long the slide in lasts, in ticks, and each tick's share of it (`0x004DC49C`).
const slide_ticks = 1000;
const slide_share: f32 = 0.001;

/// The share of its top speed a ship slides in at (`0x00407303`).
const slide_limit: f32 = 0.5;

/// How the station style rolls the ship to stand as the port stands: its roll input is the roll
/// between them less twice its roll rate, the angle in degrees over forty (`0x004DC428`), within
/// 1 either way.
///
/// **Improvement:** the game holds the turn rounded to 1.4323944.
const roll_input: f32 = std.math.deg_per_rad / 40.0;
const roll_damping: f32 = 2;

/// The animation a port plays as a ship docks at it.
const port_track = "deploy";

/// How fast the port's animation plays (`0x00406E15`).
const port_speed: f32 = 4;

/// `order_dock_init` (`0x00406B80`): where the order names no port, or a flight group or a squad
/// rather than a ship, the first free port of the ships it names (`PortSearch`) becomes its
/// target. Then the style, by what the ship is and what it docks at, and the style's init.
pub fn init(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const entry = &all.slots[index].orders[0];
    if (entry.target.kind != .ship or entry.target.component == aigeneric.Target.whole) {
        entry.data.dock.found_ship = 0;
        entry.data.dock.found_port = 0;
        var search: PortSearch = .{ .all = all, .searcher = index };
        _ = ai.eachShip(ctx.world, entry.target, &search);
        entry.target.index = entry.data.dock.found_ship;
        entry.target.component = entry.data.dock.found_port;
    }
    const target = entry.target.slotIn(all) orelse return;
    const own_type = all.slots[index].object.type;
    const at_type = all.slots[target].object.type;
    entry.data.dock.style = if (own_type == .limpet_car)
        if (at_type == .czar_docked) .limpet_car_czar else .limpet_car
    else if (own_type == .limpet_pod)
        .limpet_pod
    else if (at_type == .nanny) .nanny else .station;
    switch (entry.data.dock.style) {
        .station => stationInit(ctx, index),
        .nanny => nannyInit(ctx, index),
        else => {},
    }
}

/// `0x00406A90`, the search `init` runs over each ship its target names (`ai.eachShip`): the first
/// of the ship's ports, counting its docking points part by part, at which no other object's
/// current order is Dock.
const PortSearch = struct {
    all: *create.Objects,
    searcher: u16,

    pub fn visit(search: *PortSearch, ship: aigeneric.Target) bool {
        const at = ship.slotIn(search.all) orelse return false;
        const model = if (search.all.slots[at].model) |*held| held else return false;
        var ports: DockPoints = .of(model);
        var port: u8 = 0;
        while (ports.next()) |_| : (port +%= 1) {
            if (taken(search.all, search.searcher, at, port)) continue;
            const entry = &search.all.slots[search.searcher].orders[0];
            entry.data.dock.found_ship = @intCast(at);
            entry.data.dock.found_port = port;
            return true;
        }
        return false;
    }

    /// Whether an object other than `searcher` has Dock on at port `port` of the ship in slot `at`.
    fn taken(all: *const create.Objects, searcher: u16, at: u16, port: u8) bool {
        for (all.slots[0..all.count], 0..) |*slot, index| {
            if (index == searcher or slot.object.order_count == 0) continue;
            const entry = slot.orders[0];
            if (entry.order == .dock and entry.target.index == at and entry.target.component == port) return true;
        }
        return false;
    }
};

/// A model's docking points (`shp.Attachment.Kind.dock_point`), part by part as the root's child
/// list holds them, each part's attachments in order.
pub const DockPoints = struct {
    model: *const objects.Model,
    part: usize = 0,
    attachment: usize = 0,

    pub const Point = struct { part: usize, attachment: *const shp.Attachment };

    pub fn of(model: *const objects.Model) DockPoints {
        return .{ .model = model };
    }

    pub fn next(points: *DockPoints) ?Point {
        while (points.part < points.model.parts.len) : ({
            points.part += 1;
            points.attachment = 0;
        }) {
            const part = points.model.rootChild(points.part) orelse continue;
            while (points.attachment < part.attachments.len) {
                const at = &part.attachments[points.attachment];
                points.attachment += 1;
                if (at.kind == .dock_point) return .{ .part = points.part, .attachment = at };
            }
        }
        return null;
    }

    /// The `n`th, counting from 0.
    pub fn nth(model: *const objects.Model, n: usize) ?Point {
        var points: DockPoints = .of(model);
        var left = n;
        while (points.next()) |point| {
            if (left == 0) return point;
            left -= 1;
        }
        return null;
    }
};

/// `order_dock` (`0x00406C30`): the style's update.
pub fn update(ctx: Context, index: u16) void {
    switch (ctx.world.objects.slots[index].orders[0].data.dock.style) {
        .station => stationUpdate(ctx, index),
        .nanny => nannyUpdate(ctx, index),
        else => {},
    }
}

/// `order_dock_exit` (`0x00406C50`): the style's exit; the station's and the Nanny's
/// (`0x00407D10`) have the ship pass through nothing more at the first place.
pub fn exit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    switch (slot.orders[0].data.dock.style) {
        .station, .nanny => slot.object.passes_through[0] = .none,
        else => {},
    }
}

/// `dock_find_points` (`0x00406C80`): the ship's own docking point, its first, and the port of the
/// station its target names by the component, which starts the port's animation (`port_track`).
/// Whether both were found.
///
/// **Fix:** the game stops with "Docking information not defined on %s" where either has none;
/// OpenReliant logs it, and the order ends, as it does where the station has gone.
fn findPoints(ctx: Context, index: u16) bool {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.dock;
    const entry = slot.orders[0];
    const own_model = if (slot.model) |*held| held else return missing(index);
    const own = DockPoints.nth(own_model, 0) orelse return missing(index);
    state.own_part = @intCast(own.part);
    state.own_point = gameobj.vector(own.attachment.position);
    const at = entry.target.slotIn(all) orelse return missing(index);
    const model = if (all.slots[at].model) |*held| held else return missing(at);
    const port = DockPoints.nth(model, std.math.cast(usize, entry.target.component) orelse 0) orelse return missing(at);
    state.port_part = @intCast(port.part);
    state.port_point = gameobj.vector(port.attachment.position);
    state.port_turn = port.attachment.orientation;
    model.playNamed(port.part, port_track, 0, null, port_speed);
    return true;
}

fn missing(index: u16) bool {
    log.warn("the object in slot {d} has no docking point", .{index});
    return false;
}

/// Where a ship stands docked: the place of its own origin that brings its docking point onto the
/// port, turned as the port is.
pub const Berth = struct { position: Vector, orientation: Matrix };

/// `dock_berth` (`0x00406E70`): the berth at the port, as the station is drawn: the port's frame in
/// the world, less the ship's own docking point turned into it.
fn berth(world: gameobj.World, index: u16) ?Berth {
    const all = world.objects;
    const slot = &all.slots[index];
    const state = slot.state.dock;
    const at = slot.orders[0].target.slotIn(all) orelse return null;
    const station = &all.slots[at];
    const model = if (station.model) |*held| held else return null;
    const own_model = if (slot.model) |*held| held else return null;
    if (state.port_part >= model.parts.len or state.own_part >= own_model.parts.len) return null;
    const own = own_model.frameAt(state.own_part, .{ .position = @splat(0), .orientation = math.identity });
    const own_point = own.point(state.own_point);
    const port = model.frameAt(state.port_part, station.drawn);
    const local = @as(Vector, state.port_point) - math.transform(state.port_turn, own_point);
    return .{
        .position = port.point(local),
        .orientation = math.product(port.orientation, state.port_turn),
    };
}

/// The station style's init (`0x00407010`): it finds the docking points (`findPoints`), and picks
/// its first step by where the ship stands from the berth, in the port's frame: far behind the
/// port, it turns in, or comes straight along the line where it stands near it; nearer, behind it
/// or ahead of it, it goes round beside the port first. It notes which side it came from.
fn stationInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.dock;
    if (!findPoints(ctx, index)) {
        state.step = @intFromEnum(Step.no_port);
        return;
    }
    const at = berth(ctx.world, index) orelse return;
    const off = math.transformTransposed(at.orientation, gameobj.vector(slot.object.root.next_position) - at.position);
    state.from_right = @intFromBool(off[0] > 0);
    const step: Step = if (off[2] < -aside)
        if (@abs(off[0] / off[2]) > behind_share) .turning_in else .far_behind
    else if (off[2] < 0) .beside_behind else .beside;
    state.step = @intFromEnum(step);
}

/// The station style's update (`0x004070F0`), a step at a time (`Step`). Going round, the ship
/// steers at full throttle for the step's point (`ai.steer`), mirrored to the side it came from,
/// rolling to stand as the port stands, on to the next step within `reach_squared` of it. Latching
/// on, it flies `motion_follow` down the port's line (`way`), at `slide_limit` of its top speed,
/// the station stopped dead where it is. Once it is in, it is set in its berth, stopped, heard
/// docking, and has its Docked; the order ends.
///
/// **Fix:** the game goes on reading the frames of a station that has gone; OpenReliant ends the
/// order.
fn stationUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.dock;
    const at = berth(world, index) orelse {
        _ = aigeneric.pop(ctx, index);
        return;
    };
    const offset: Vector = switch (@as(Step, @enumFromInt(state.step))) {
        .beside => .{ -aside, 0, 0 },
        .beside_behind => .{ -aside, 0, -aside },
        .turning_in => turning: {
            const flight = slot.flight orelse return;
            break :turning .{ ai.cruiseSpeed(object, flight, world.view) * turn_widths / flight.yaw_rate, 0, -aside };
        },
        .far_behind => .{ 0, 0, -far_behind },
        .near_behind => .{ 0, 0, -near_behind },
        .latching => {
            object.flags.attached = true;
            slot.motion = .follow;
            state.follower = .{ .path = .dock, .limit = slide_limit };
            state.step = @intFromEnum(Step.sliding);
            state.until = ctx.clock.frame_start + slide_ticks;
            state.slide_from = gameobj.vector(object.root.next_position);
            if (slot.orders[0].target.slotIn(all)) |station| all.slots[station].object.velocity = .{ .x = 0, .y = 0, .z = 0 };
            return;
        },
        .sliding => return,
        .docked => {
            ai.stop(object);
            objects.setPosition(object, &slot.drawn, at.position);
            objects.setOrientation(object, &slot.drawn, at.orientation);
            sound3d.playIn(world, null, null, index, .dock, 1, .not_reserved);
            events.docked(world, index);
            _ = aigeneric.pop(ctx, index);
            return;
        },
        .no_port, _ => {
            _ = aigeneric.pop(ctx, index);
            return;
        },
    };
    const side: Vector = if (state.from_right != 0) .{ -1, 1, 1 } else .{ 1, 1, 1 };
    const point = math.transform(at.orientation, offset * side) + at.position;
    _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{});
    object.throttle = ai.full_throttle;
    const left = point - gameobj.vector(object.root.next_position);
    if (math.lengthSquared(left) < reach_squared) state.step += 1;
    const up = math.transformTransposed(slot.drawn.orientation, math.yAxis(at.orientation));
    object.roll_input = std.math.clamp(rollInput(object, -std.math.atan2(up[0], up[1]), roll_damping), -1, 1);
}

/// The roll input that rolls the ship `roll` radians further, less `damping` times its roll rate:
/// the angle in degrees over forty (`roll_input`).
fn rollInput(object: *const gameobj.GameObject, roll: f32, damping: f32) f32 {
    return (roll - damping * object.roll_rate) * roll_input;
}

/// `dock_way` (`0x00406F20`), which `motion_follow` calls as the ship slides in: a point on the
/// port's line behind the berth, as far back as the ship stood from it as it latched on, times the
/// square of the share of the slide left, and the port's way up. Once the slide is over, the ship's
/// motion is `motion_backward`, and it is in.
pub fn way(world: gameobj.World, index: u16) motion.Way {
    const slot = &world.objects.slots[index];
    const state = &slot.state.dock;
    const at = berth(world, index) orelse return .{ .point = gameobj.vector(slot.object.root.position) };
    const left = @max(@as(f32, @floatFromInt(state.until -% world.clock.frame_start)) * slide_share, 0);
    const back = math.distance(at.position, state.slide_from) * left * left;
    const point = at.position - math.forward(at.orientation) * @as(Vector, @splat(back));
    if (state.until < world.clock.frame_start) {
        slot.motion = .backward;
        state.step += 1;
    }
    return .{ .point = point, .up = math.yAxis(at.orientation) };
}

/// The Nanny style's state (`GameObject.order_state`).
pub const NannyState = extern struct {
    step: NannyStep,
    /// The frame's tick the step waits for.
    until: i32,
    /// Where the port stands on its part, raised by the ship's own height above its origin.
    point: [3]f32,
    /// The part of the Nanny the port is on, by its place in the root's child list; the game holds
    /// the part's node.
    part: u32,
    _unknown_18: [0x90 - 0x18]u8,

    comptime {
        assert(@offsetOf(NannyState, "point") == 0x08);
        assert(@offsetOf(NannyState, "part") == 0x14);
        assert(@sizeOf(NannyState) == 0x90);
    }
};

/// The Nanny style's steps.
pub const NannyStep = enum(u32) {
    /// The door of its port opens.
    opening = 0,
    /// It flies to a point ahead of the port and above it.
    approaching = 1,
    /// It flies in, and stops aboard as the door closes behind it.
    entering = 2,
    /// Aboard for `aboard_ticks`; then it is re-armed, and the way out opens.
    rearming = 3,
    /// As the way out opens; then it has its Docked, and flies out.
    leaving = 4,
    /// It flies out at full burn; then the way out closes, and the order ends.
    going = 5,
    /// OpenReliant's own: the Nanny has no such port, or has gone, and the order ends.
    no_port = 6,
    _,
};

/// The Nanny's doors, by the port a ship docks at: the way in, its root's children 0 and 1, and
/// the way out, 4 and 3 (`0x0040755B`, `0x00407B51`). A port but the first takes the second of
/// each.
const entry_doors = [2]usize{ 0, 1 };
const exit_doors = [2]usize{ 4, 3 };

/// The doors' animation, and how fast it plays (`0x004E1728`, `0x0040757A`).
const door_track = "opendoor";
const door_speed: f32 = 1;

/// Where the approach aims, from the port: above it and ahead (`0x004DC4B8`, `0x004DC444`); the
/// distance within which it slows to `approach_speed` a tick, over its cruise speed, from full
/// (`0x004DC43C`, `0x004DC440`); and how near the point it comes before it flies in
/// (`0x004DC438`).
const approach_above: f32 = 1500;
const approach_ahead: f32 = 20000;
const approach_slowing: f32 = 10000;
const approach_speed: f32 = 100;
const approach_reach: f32 = 2000;

/// How the ship flies in: beyond `lead_beyond` of the port it aims `lead_share` of its distance
/// further on along the Nanny's own axes, a little above (`0x004DC44C`, `0x00407722`,
/// `0x004DC4B4`); within the cosine `aligned` of the port it rolls to stand as the Nanny does,
/// less `entry_roll_damping` times its roll rate (`0x004DC434`, `0x004DC42C`); its throttle is
/// `entry_throttle` a unit less `entry_throttle_less`, at most `approach_speed` a tick
/// (`0x004DC4B0`, `0x004DC4AC`); within `aboard_reach` it is aboard (`0x004DC4A8`).
const lead_beyond: f32 = 1000;
const lead: Vector = .{ 0, -0.075, 1 };
const lead_share: f32 = 0.6;
const aligned: f32 = 0.98;
const entry_roll_damping: f32 = 12;
const entry_throttle: f32 = 0.0001;
const entry_throttle_less: f32 = 0.02;
const aboard_reach: f32 = 500;

/// How long the ship stays aboard, how long the way out takes to open, and how long it flies out
/// before the way out closes, in ticks (`0x004079A7`, `0x00407BC7`, `0x00407C09`).
const aboard_ticks = 500;
const exit_opening_ticks = 400;
const going_ticks = 150;

/// The Nanny style's init (`0x004073E0`): the ship passes through the Nanny, flies by its nose
/// (`motion.Motion.plain`), and takes the port its order names, among the Nanny's docking points
/// (`DockPoints`), raised by the ship's height above its origin.
///
/// **Fix:** the game stops with "trying to dock to invalid location on %s" where the Nanny has no
/// such port; OpenReliant logs it, and the order ends.
fn nannyInit(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.nanny_dock;
    const entry = slot.orders[0];
    slot.object.passes_through[0] = .from(entry.target.slotIn(all));
    state.step = .opening;
    slot.motion = .plain;
    const at = entry.target.slotIn(all) orelse return nannyMissing(state, index);
    const model = if (all.slots[at].model) |*held| held else return nannyMissing(state, at);
    const port = DockPoints.nth(model, std.math.cast(usize, entry.target.component) orelse 0) orelse return nannyMissing(state, at);
    state.point = gameobj.vector(port.attachment.position) - Vector{ 0, slot.object.bounds_max.y, 0 };
    state.part = @intCast(port.part);
}

fn nannyMissing(state: *NannyState, index: u16) void {
    state.step = .no_port;
    _ = missing(index);
}

/// The Nanny style's update (`0x00407510`), a step at a time (`NannyStep`). The player's ship is
/// watched from beside the Nanny as it docks (`camera.View.nanny_dock`), and from its cockpit
/// again once it has left. Aboard, the ship is re-armed (`create.rearm`).
///
/// **Fix:** the game closes the second port's doors from the time the first port's stand at, which
/// shuts them at once; OpenReliant closes each from where it stands. And where the Nanny has gone,
/// the game goes on reading it; OpenReliant ends the order.
fn nannyUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.nanny_dock;
    const entry = slot.orders[0];
    const now = ctx.clock.frame_start;
    const at = entry.target.slotIn(all) orelse return nannyEnd(ctx, index);
    const nanny = &all.slots[at];
    const model = if (nanny.model) |*held| held else return nannyEnd(ctx, index);
    const port: usize = if (entry.target.component == 0) 0 else 1;
    const flight = slot.flight orelse return;
    const slowest = approach_speed / ai.cruiseSpeed(object, flight, world.view);
    const ship = gameobj.vector(object.root.next_position);
    switch (state.step) {
        .opening => {
            if (index == all.player) if (world.camera) |watching| {
                _ = watching.setView(.nanny_dock, at, true, true, ctx.clock.viewTime());
            };
            swingDoor(world, at, entry_doors[port], 0, door_speed);
            state.step = .approaching;
        },
        .approaching => {
            const place = model.frameAt(state.part, nanny.drawn);
            const point = place.point(@as(Vector, state.point) + Vector{ 0, -approach_above, approach_ahead });
            _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{});
            const left = math.distance(point, ship);
            object.throttle = if (left > approach_slowing) ai.full_throttle else slowest;
            if (left < approach_reach) state.step = .entering;
        },
        .entering => {
            const turn = nanny.object.root.next_orientation;
            var point = model.frameAt(state.part, nanny.drawn).point(state.point);
            const to_port = point - ship;
            const left = math.length(to_port);
            if (left > lead_beyond) point += math.transform(turn, lead * @as(Vector, @splat(left * lead_share)));
            _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{});
            if (left * aligned < math.dot(math.forward(object.root.next_orientation), to_port)) {
                const up = math.transformTransposed(turn, math.yAxis(slot.drawn.orientation));
                object.roll_input = rollInput(object, -std.math.atan2(up[0], up[1]), entry_roll_damping);
            }
            object.throttle = @min(left * entry_throttle - entry_throttle_less, slowest);
            if (left >= aboard_reach) return;
            sound3d.playIn(world, null, null, index, .nanny03, 1, .guaranteed);
            object.yaw_input = 0;
            object.pitch_input = 0;
            object.roll_input = 0;
            object.throttle = 0;
            swingDoor(world, at, entry_doors[port], objects.Model.keep_time, -door_speed);
            state.step = .rearming;
            state.until = now + aboard_ticks;
        },
        .rearming => {
            if (state.until >= now) return;
            create.rearm(world, index) catch |err| log.warn("the object in slot {d} is not re-armed: {s}", .{ index, @errorName(err) });
            swingDoor(world, at, exit_doors[port], 0, door_speed);
            state.step = .leaving;
            state.until = now + exit_opening_ticks;
        },
        .leaving => {
            if (state.until >= now) return;
            events.docked(world, index);
            state.step = .going;
            state.until = now + going_ticks;
            slot.motion = .forward;
        },
        .going => {
            object.afterburner = true;
            if (state.until >= now) return;
            swingDoor(world, at, exit_doors[port], objects.Model.keep_time, -door_speed);
            nannyEnd(ctx, index);
        },
        .no_port, _ => nannyEnd(ctx, index),
    }
}

/// The Nanny style's end: the order ends, and the player's ship is watched from its cockpit.
fn nannyEnd(ctx: Context, index: u16) void {
    _ = aigeneric.pop(ctx, index);
    const world = ctx.world;
    if (index != world.objects.player) return;
    if (world.camera) |watching| _ = watching.setView(.cockpit, index, false, true, ctx.clock.viewTime());
}

/// Door `door` of the Nanny in slot `at`, a child of its root, played from `time` at `speed`: open
/// from the start, or closed from where it stands; with its sound where it stands (`nanny02`).
fn swingDoor(world: gameobj.World, at: u16, door: usize, time: f32, speed: f32) void {
    const nanny = &world.objects.slots[at];
    const model = if (nanny.model) |*held| held else return;
    if (model.rootChild(door) == null) return;
    model.playNamed(door, door_track, time, null, speed);
    const place = model.frameAt(door, nanny.drawn);
    sound3d.playIn(world, place.position, math.forward(place.orientation), at, .nanny02, 1, .guaranteed);
}

/// A model of one part hanging from the root, holding a docking point, unturned, at each of up to
/// two places. Set it up where it stays, as its records point into it.
const TestModel = struct {
    attachments: [2]shp.Attachment,
    data: [1]shp.PartData,
    loaded_parts: [1]@import("srofiles.zig").LoadedPart,
    source: shp.Model,
    loaded: @import("srofiles.zig").Loaded,

    fn init(model: *TestModel, points: []const Vector) void {
        for (&model.attachments, 0..) |*attachment, n| {
            attachment.* = std.mem.zeroes(shp.Attachment);
            attachment.kind = if (n < points.len) .dock_point else .missile;
            attachment.position = gameobj.vec3(if (n < points.len) points[n] else @splat(0));
            attachment.orientation = math.identity;
        }
        model.data = .{objects.testing.part()};
        model.data[0].part.parent = -1;
        model.data[0].attachments = &model.attachments;
        model.loaded_parts = .{.{ .flags = .{}, .levels = &.{}, .meshes = &.{} }};
        model.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &model.data, .trailing_bytes = 0 };
        model.loaded = .{ .parts = &model.loaded_parts };
    }

    fn fit(model: *const TestModel, slot: *create.Slot) !void {
        slot.model = try .create(std.testing.allocator, &model.source, &model.loaded, .{});
        gameobj.linkPart(&slot.model.?, 0);
    }
};

/// A station at 10000 along Z, its two ports 1000 behind it and 1000 to its right, and two
/// freighters, each with its docking point at its nose, 500 ahead.
const TestDock = struct {
    game: gameobj.testing.Mission,
    station_model: TestModel,
    freighter_model: TestModel,
    station: u16,
    freighters: [2]u16,

    fn init(dock: *TestDock) !void {
        try dock.game.init(std.testing.allocator);
        errdefer dock.game.deinit();
        dock.station_model.init(&.{ .{ 0, 0, -1000 }, .{ 1000, 0, 0 } });
        dock.freighter_model.init(&.{.{ 0, 0, 500 }});
        _ = try dock.game.add(.predator, .{ 0, 50000, 0 });
        dock.station = try dock.game.add(.predator, .{ 0, 0, 10000 });
        try dock.station_model.fit(dock.game.slot(dock.station));
        dock.game.slot(dock.station).drawn = .{ .position = .{ 0, 0, 10000 } };
        for (&dock.freighters) |*freighter| {
            freighter.* = try dock.game.add(.predator, .{ 0, 0, -200000 });
            try dock.freighter_model.fit(dock.game.slot(freighter.*));
            dock.place(freighter.*, .{ 0, 0, -200000 });
        }
    }

    fn deinit(dock: *TestDock) void {
        for ([_]u16{ dock.station, dock.freighters[0], dock.freighters[1] }) |index| {
            if (dock.game.slot(index).model) |*model| model.deinit(std.testing.allocator);
            dock.game.slot(index).model = null;
        }
        dock.game.deinit();
    }

    fn place(dock: *TestDock, index: u16, at: Vector) void {
        const slot = dock.game.slot(index);
        slot.object.root.next_position = gameobj.vec3(at);
        slot.object.root.position = gameobj.vec3(at);
        slot.drawn = .{ .position = at };
    }

    fn orders(dock: *TestDock) Context {
        return dock.game.orders();
    }
};

test "a freighter docks at a station's port, from far behind it" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const index = dock.freighters[0];
    const slot = dock.game.slot(index);
    slot.motion = .forward;
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(dock.station, 0)));

    // Far behind the port, on its line, it comes straight along it, full ahead.
    aigeneric.objectOrders(dock.orders(), index);
    const state = &slot.state.dock;
    try std.testing.expectEqual(Style.station, slot.orders[0].data.dock.style);
    try std.testing.expectEqual(@intFromEnum(Step.far_behind), state.step);
    try std.testing.expectEqual(1, slot.object.throttle);
    // Its berth brings its nose onto the port.
    const at = berth(dock.orders().world, index).?;
    try std.testing.expectEqual(Vector{ 0, 0, 8500 }, at.position);
    // Near each point, on to the next, and then it latches on.
    dock.place(index, .{ 0, 0, 8500 - far_behind });
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(@intFromEnum(Step.near_behind), state.step);
    dock.place(index, .{ 0, 0, 8500 - near_behind });
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(@intFromEnum(Step.latching), state.step);
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(@intFromEnum(Step.sliding), state.step);
    try std.testing.expectEqual(motion.Motion.follow, slot.motion.?);
    try std.testing.expect(slot.object.flags.attached);
    // Half way through the slide, a quarter of the way back along the port's line.
    dock.game.clock.frame_start += slide_ticks / 2;
    const half = way(dock.orders().world, index);
    try std.testing.expectApproxEqAbs(8500 - near_behind / 4, half.point[2], 1e-2);
    // Past its end, it is in: set in its berth, and its order over.
    dock.game.clock.frame_start += slide_ticks;
    _ = way(dock.orders().world, index);
    try std.testing.expectEqual(@intFromEnum(Step.docked), state.step);
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(8500, slot.object.root.position.z);
    try std.testing.expectEqual(gameobj.Slot.none, slot.object.passes_through[0]);
}

test "a ship without a port given takes the first free one" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    for (dock.freighters) |index| {
        try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .{ .kind = .ship, .index = @intCast(dock.station), .component = aigeneric.Target.whole }));
        aigeneric.objectOrders(dock.orders(), index);
    }
    try std.testing.expectEqual(0, dock.game.slot(dock.freighters[0]).orders[0].target.component);
    try std.testing.expectEqual(1, dock.game.slot(dock.freighters[1]).orders[0].target.component);
}

test "a ship docks nowhere at a ship with no docking point" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const index = dock.freighters[0];
    // The player's ship, in the first slot, has no model, and so no port.
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(0, 0)));
    aigeneric.objectOrders(dock.orders(), index);
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(0, dock.game.slot(index).object.order_count);
}

test "a fighter docks in a Nanny, is re-armed, and flies out" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const all = dock.game.objects;
    const index = dock.freighters[0];
    const slot = dock.game.slot(index);
    // A Nanny where the station stands, its port 1000 behind its origin.
    const nanny = dock.station;
    all.slots[nanny].object.type = .nanny;
    slot.object.bounds_max.y = 100;
    slot.object.countermeasures = 0;
    slot.object.afterburner_fuel = 0;
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(nanny, 0)));

    // It passes through the Nanny, flies by its nose, and heads for a point ahead of the port and
    // above it, full ahead while far off.
    aigeneric.objectOrders(dock.orders(), index);
    const state = &slot.state.nanny_dock;
    try std.testing.expectEqual(Style.nanny, slot.orders[0].data.dock.style);
    try std.testing.expectEqual(gameobj.Slot.of(nanny), slot.object.passes_through[0]);
    try std.testing.expectEqual(motion.Motion.plain, slot.motion.?);
    try std.testing.expectEqual(NannyStep.approaching, state.step);
    try std.testing.expectEqual(Vector{ 0, -100, -1000 }, @as(Vector, state.point));
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(ai.full_throttle, slot.object.throttle);
    // Near that point it flies in; within reach of the port it is aboard, stopped.
    dock.place(index, .{ 0, -1600, 29000 - 1000 });
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(NannyStep.entering, state.step);
    dock.place(index, .{ 0, -100, 9000 - 400 });
    dock.game.clock.frame_start = 100;
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(NannyStep.rearming, state.step);
    try std.testing.expectEqual(0, slot.object.throttle);
    // Its time aboard over, it is re-armed, and the way out opens.
    dock.game.clock.frame_start = 100 + aboard_ticks + 1;
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(NannyStep.leaving, state.step);
    try std.testing.expectEqual(gameobj.countermeasures_when_created, slot.object.countermeasures);
    try std.testing.expect(slot.object.afterburner_fuel > 0);
    // Then it flies out at full burn, and the order ends.
    dock.game.clock.frame_start += exit_opening_ticks + 1;
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(NannyStep.going, state.step);
    try std.testing.expectEqual(motion.Motion.forward, slot.motion.?);
    dock.game.clock.frame_start += going_ticks + 1;
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expect(slot.object.afterburner);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(gameobj.Slot.none, slot.object.passes_through[0]);
}

test "a ship at a Nanny's missing port docks nowhere" {
    var dock: TestDock = undefined;
    try dock.init();
    defer dock.deinit();
    const index = dock.freighters[0];
    dock.game.objects.slots[dock.station].object.type = .nanny;
    try std.testing.expect(try aigeneric.push(dock.orders(), index, .dock, .at(dock.station, 5)));
    aigeneric.objectOrders(dock.orders(), index);
    try std.testing.expectEqual(0, dock.game.slot(index).object.order_count);
}
