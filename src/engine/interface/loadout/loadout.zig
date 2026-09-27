//! `C:\lancer\interface\loadout\loadout.cpp`: the loadout screen. OpenReliant ports only what the
//! mission's objects use of it so far: the band a planet's atmosphere is made of (`bandMesh`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const Vector = math.Vector;

/// `mesh_build_band` (`0x0044F200`): a band of `segments` quads round the Z axis, between a circle
/// of `segments` vertices of `radius` at Z 0 and another like it at `depth`, the first circle's
/// vertices first, from the one at the top going toward X. Each quad is two triangles, from a
/// vertex of the first circle to the next and to the one beside it on the second, then from the
/// next to its own on the second and back; the texture spans each quad once, across it from the
/// first vertex to the next, `v` 1 on the first circle and 0 on the second. Its faces' planes, its
/// vertex normals and its bounds are worked out; its one surface is left for the caller.
///
/// **Improvement:** the sine and cosine come from `std.math` rather than the engine's tables
/// (`sr_sin`, `sr_cos`).
pub fn bandMesh(gpa: Allocator, segments: u16, radius: f32, depth: f32) Allocator.Error!srapiext.Mesh {
    const n: usize = segments;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 2 * n, .vertices = 2 * n, .indices = 6 * n });
    errdefer mesh.deinit(gpa);
    const step = 1.0 / @as(f32, @floatFromInt(n)) * 2 * std.math.pi;
    for (0..n) |i| {
        const angle = @as(f32, @floatFromInt(i)) * step;
        const across: Vector = .{ @sin(angle) * radius, @cos(angle) * radius, 0 };
        mesh.positions[i] = across;
        mesh.positions[n + i] = across + Vector{ 0, 0, depth };
    }
    mesh.numberPolygons(3);
    const uv = try mesh.addCoordinates(gpa);
    for (0..n) |i| {
        const next: u16 = @intCast((i + 1) % n);
        const at: u16 = @intCast(i);
        const far: u16 = @intCast(n);
        mesh.indices[6 * i ..][0..6].* = .{ at, next, at + far, next, next + far, at + far };
        uv[6 * i ..][0..6].* = .{ .{ 0, 1 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    }
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

test bandMesh {
    const gpa = std.testing.allocator;
    var mesh = try bandMesh(gpa, 4, 10, 5);
    defer mesh.deinit(gpa);
    // Two circles of four, the first from the top toward X, the second the same at its depth.
    try std.testing.expectEqual(8, mesh.positions.len);
    try std.testing.expectApproxEqAbs(10, mesh.positions[0][1], 1e-5);
    try std.testing.expectApproxEqAbs(10, mesh.positions[1][0], 1e-5);
    try std.testing.expectEqual(mesh.positions[1] + Vector{ 0, 0, 5 }, mesh.positions[5]);
    // Two triangles a quad, the last wrapping round to the first vertex.
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 4, 1, 5, 4 }, mesh.indices[0..6]);
    try std.testing.expectEqualSlices(u16, &.{ 3, 0, 7, 0, 4, 7 }, mesh.indices[18..24]);
    // The texture across each quad once, `v` 1 on the first circle.
    try std.testing.expectEqual([2]f32{ 0, 1 }, mesh.uv[0].?[0]);
    try std.testing.expectEqual([2]f32{ 1, 0 }, mesh.uv[0].?[4]);
    // Round a band with depth, the normals stand out from its axis, one long.
    for (mesh.normals) |normal| {
        try std.testing.expectApproxEqAbs(0, normal[2], 1e-5);
        try std.testing.expectApproxEqAbs(1, math.length(normal), 1e-5);
    }
}
