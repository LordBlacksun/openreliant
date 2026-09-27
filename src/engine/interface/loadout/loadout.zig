//! `C:\lancer\interface\loadout\loadout.cpp`: the loadout screen. OpenReliant ports only what the
//! mission's objects use of it so far: the band a planet's atmosphere is made of (`bandMesh`), and
//! the square the chase view's sights and a jump's flare are drawn on (`squareMesh`).

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

/// `mesh_build_square` (`0x0044F000`): a rectangle facing along Z, `width` by `height` about its
/// centre, its corners from the lower left round to the upper left, as two triangles, and where
/// `two_sided` two more facing the other way. The texture spans it from its left edge to
/// `square_span` of the way across, `v` 1 at the top; the callers set `u` to the whole of it. Its
/// faces' planes, its vertex normals and its bounds are worked out; its one surface is left for the
/// caller.
pub fn squareMesh(gpa: Allocator, two_sided: bool, width: f32, height: f32) Allocator.Error!srapiext.Mesh {
    const faces: usize = if (two_sided) 4 else 2;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = faces, .vertices = 4, .indices = 3 * faces });
    errdefer mesh.deinit(gpa);
    const w = width / 2;
    const h = height / 2;
    mesh.positions[0..4].* = .{ .{ -w, -h, 0 }, .{ w, -h, 0 }, .{ w, h, 0 }, .{ -w, h, 0 } };
    mesh.numberPolygons(3);
    const uv = try mesh.addCoordinates(gpa);
    mesh.indices[0..6].* = .{ 3, 2, 0, 2, 1, 0 };
    uv[0..6].* = .{ .{ 0, 1 }, .{ square_span, 1 }, .{ 0, 0 }, .{ square_span, 1 }, .{ square_span, 0 }, .{ 0, 0 } };
    if (two_sided) {
        mesh.indices[6..12].* = .{ 0, 2, 3, 0, 1, 2 };
        uv[6..12].* = .{ .{ square_span, 0 }, .{ 0, 1 }, .{ square_span, 1 }, .{ square_span, 0 }, .{ 0, 0 }, .{ 0, 1 } };
    }
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// How far across its texture `squareMesh` spans (`0x3F3F0000`).
pub const square_span: f32 = 0.74609375;

test squareMesh {
    const gpa = std.testing.allocator;
    var mesh = try squareMesh(gpa, false, 4, 2);
    defer mesh.deinit(gpa);
    try std.testing.expectEqualSlices(Vector, &.{ .{ -2, -1, 0 }, .{ 2, -1, 0 }, .{ 2, 1, 0 }, .{ -2, 1, 0 } }, mesh.positions);
    try std.testing.expectEqualSlices(u16, &.{ 3, 2, 0, 2, 1, 0 }, mesh.indices);
    try std.testing.expectEqual([2]f32{ square_span, 0 }, mesh.uv[0].?[4]);
    // It faces along Z.
    for (mesh.planes) |plane| try std.testing.expectApproxEqAbs(1, @abs(plane.normal[2]), 1e-6);
    // Two-sided, the same corners again the other way round.
    var both = try squareMesh(gpa, true, 4, 2);
    defer both.deinit(gpa);
    try std.testing.expectEqual(4, both.polygons.len);
    try std.testing.expectEqualSlices(u16, &.{ 0, 2, 3, 0, 1, 2 }, both.indices[6..12]);
    try std.testing.expectEqual(-both.planes[0].normal[2], both.planes[2].normal[2]);
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
