//! `C:\lancer\game\videoreports.cpp`: the radio's video reports, the pilots' faces and the films
//! that play in the radio's windows. **Unverified:** no string places its code; the link order puts
//! it after `loadout.cpp`, where the code that queues the radio's reports lies. OpenReliant ports
//! only what PERMISSION TO LAND does of it so far (`permissionToLand`).
//!
//! Not ported: the reports themselves ([#99](https://github.com/vdmkenny/openreliant/issues/99)).

const std = @import("std");

const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");

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
