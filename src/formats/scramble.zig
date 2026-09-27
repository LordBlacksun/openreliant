//! The scrambling of the game's speech files ([`engine/game/cbox.zig`](../engine/game/cbox.zig))
//! and its face films ([`engine/game/talkie.zig`](../engine/game/talkie.zig)): a key of four
//! bytes XORed over a stretch of the file, repeating from a place a multiple of four in, so that
//! each byte takes the key byte its place in the file picks.

const std = @import("std");

/// `bytes`, a stretch of a file starting a multiple of four bytes in, XORed with `key` repeating,
/// which scrambles and unscrambles alike.
pub fn xor(bytes: []u8, key: [4]u8) void {
    for (bytes, 0..) |*byte, i| byte.* ^= key[i % key.len];
}

test xor {
    const key = [4]u8{ 0xA3, 0x27, 0xB7, 0xDD };
    var bytes = [_]u8{ 0, 0, 0, 0, 0, 0xFF };
    xor(&bytes, key);
    try std.testing.expectEqualSlices(u8, &.{ 0xA3, 0x27, 0xB7, 0xDD, 0xA3, 0xD8 }, &bytes);
    // Its own inverse.
    xor(&bytes, key);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0xFF }, &bytes);
}
