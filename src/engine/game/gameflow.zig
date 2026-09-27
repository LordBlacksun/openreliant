//! `C:\lancer\game\gameflow.cpp`: the campaign's flow from one mission to the next.
//! **Unverified:** that `campaign_new`, `mission_reset_variables` and `mission_end_record` are this
//! file's: they lie beside the file's known code, between `explode.cpp`'s and `gameobj.cpp`'s.
//!
//! Ported so far: the game's variables as a campaign begins and as each attempt at a mission
//! starts (`restartPoint`), and what a mission's end keeps of the pilot's kills (`endMission`).

const std = @import("std");

const input = @import("../input.zig");
const vm = @import("../vm.zig");
const Ending = @import("main.zig").Ending;

/// How many of the game's variables `campaign_new` clears, from the first on (`0x004751B4`).
const cleared_variables = 32;

/// The game's variables a new campaign sets to 1 (`campaign_new`), by number: the campaign's flags,
/// such as `ghost_alive`, and `mission_success`, which each attempt clears again. The rest of the
/// campaign's start at 0.
const campaign_flags = [_]u8{ 14, 16, 17, 18, 19, 20, 21, 5, 22, 23, 29, 30, 31, 32, 35, 13, 8, 7, 6, 36 };

/// `campaign_new` (`0x004751B0`) as a new campaign begins, which `WinMain` runs as the game starts:
/// clears the first 32 of the game's variables, then sets the campaign's flags (`campaign_flags`). **Not ported:** the rest of what it sets up
/// for the campaign: mission 1 as the next, the pilot's tallies and each mission's records, and
/// the pilot's profile ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
pub fn newCampaign(variables: *vm.Variables) void {
    for (0..cleared_variables) |index| variables.slot(@intCast(index)).* = 0;
    for (campaign_flags) |index| variables.slot(index).* = 1;
}

/// `mission_reset_variables` (`0x00475620`) before each attempt at a mission: clears the variables
/// that belong to the attempt.
pub fn resetVariables(variables: *vm.Variables) void {
    variables.ready = .{};
    variables.backup_available = 0;
    variables.mission_over = 0;
    variables.landing_cleared = 0;
    variables.ion_cannons_hold_lock = 0;
    variables.mission_success = .failure;
    variables.objectives_met = 0;
    variables._unknown_34 = 0;
}

/// The game's variables as an attempt at a mission starts. `WinMain` saves the variables before a
/// mission's first attempt and loads them again for each replay and each restart (`restart_save`,
/// `0x00475D20`; `restart_load`, `0x00475D30`), so that every attempt starts from the variables
/// the first had, less the attempt's own (`resetVariables`). OpenReliant, which has no campaign
/// yet, starts every attempt from a new campaign's (`newCampaign`), as the game's first mission
/// does. **Not ported:** a mission's end moving the campaign on to the next mission with the
/// variables it leaves ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
pub fn restartPoint() vm.Variables {
    var variables: vm.Variables = .{};
    newCampaign(&variables);
    resetVariables(&variables);
    return variables;
}

test restartPoint {
    var variables: vm.Variables = .{};
    variables.landing_cleared = 1;
    variables.last_success = .success;
    variables.countdown = 30;
    variables.beyond[0] = 5;
    newCampaign(&variables);
    // The first 32 cleared, the campaign's flags set, the rest left.
    try std.testing.expectEqual(0, variables.landing_cleared);
    try std.testing.expectEqual(.failure, variables.last_success);
    try std.testing.expectEqual(1, variables.ghost_alive);
    try std.testing.expectEqual(.partial_failure, variables.mission_success);
    try std.testing.expectEqual(1, variables._unknown_35[1]);
    try std.testing.expectEqual(30, variables.countdown);
    try std.testing.expectEqual(5, variables.beyond[0]);

    // Each attempt clears its own, and keeps the campaign's.
    variables.ready.jump = .newly;
    variables.objectives_met = 1;
    variables.ion_cannons_hold_lock = 1;
    resetVariables(&variables);
    try std.testing.expectEqual(@as(vm.Variables, .{}).ready, variables.ready);
    try std.testing.expectEqual(0, variables.objectives_met);
    try std.testing.expectEqual(0, variables.ion_cannons_hold_lock);
    try std.testing.expectEqual(.failure, variables.mission_success);
    try std.testing.expectEqual(1, variables.ghost_alive);

    const start = restartPoint();
    try std.testing.expectEqual(1, start.ghost_alive);
    try std.testing.expectEqual(.failure, start.mission_success);
    try std.testing.expectEqual(0, start.countdown);
}

/// Whether a mission that ends so keeps the pilot's kills: every ending but the player's ship
/// destroyed or its ejected pilot killed or captured.
pub fn keepsKills(ending: Ending) bool {
    return switch (ending) {
        .destroyed, .captured => false,
        else => true,
    };
}

/// `mission_end_record` (`0x00475A90`) as a mission ends: keeps the pilot's kills, where the
/// ending keeps them (`keepsKills`), for the next mission's start (`winmain.startMission`).
/// **Not ported:** the rest of what it keeps and does, which the campaign needs: the mission's
/// rating in `vm.Variables.last_success`, promoting the pilot by the kills each rank needs
/// (`rank_kills`, 0, 35, 72, 115, 150, 200, 255, 275 and 300), the medals, the mission's rank and
/// moving `mission_number` on ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
pub fn endMission(player: *input.Player) void {
    if (keepsKills(player.ending)) player.kills.kept = player.kills.count;
}

test endMission {
    var player: input.Player = .{ .kills = .{ .count = 7, .kept = 2 } };
    // Destroyed, or captured after ejecting, the attempt's kills are not kept.
    player.ending = .destroyed;
    endMission(&player);
    try std.testing.expectEqual(2, player.kills.kept);
    player.ending = .captured;
    endMission(&player);
    try std.testing.expectEqual(2, player.kills.kept);
    // Picked up, they are.
    player.ending = .rescued;
    endMission(&player);
    try std.testing.expectEqual(7, player.kills.kept);
}
