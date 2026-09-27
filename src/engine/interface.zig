//! `C:\lancer\interface`: the front end's screens. OpenReliant ports what the mission uses of them so
//! far.

const std = @import("std");

pub const loadout = @import("interface/loadout/loadout.zig");

test {
    std.testing.refAllDecls(@This());
}
