//! What `openreliant` draws with, and the frames it draws outside the game's loop: the loading
//! screens' and the movies'.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const srapi = engine.surrender.surrenderlib.srapi;
const srcore = engine.surrender.surrenderlib.srcore;
const srd3d = engine.surrender.srd3d;

/// What the driver draws with: the GPU, or the software device, OpenReliant's reference, whose
/// frames the window shows.
pub const Screen = union(enum) {
    gpu: platform.gpu.Gpu,
    software: srd3d.software.Software,

    pub fn interface(screen: *Screen) srd3d.device.Device {
        return switch (screen.*) {
            inline else => |*device| device.interface(),
        };
    }
};

/// Frames drawn outside the game's loop, as the loading screens' and the movies' are: an overlay
/// drawn over an empty scene and put on the window at once.
pub const Presenter = struct {
    window: *platform.window.Window,
    screen: *Screen,
    driver: *srd3d.srd3d.Driver,
    context: *srapi.Context,
    /// The size `--size` asks the frames to be drawn at, where it does.
    wanted: ?[2]u32,
    /// What the software device is made in.
    arena: Allocator,
    /// The scene, empty, and what a frame is drawn in.
    scene: srcore.Scene = .{},
    frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    pub fn close(presenter: *Presenter, gpa: Allocator) void {
        presenter.scene.deinit(gpa);
        presenter.frame_arena.deinit();
    }

    /// The size the frames are drawn at.
    pub fn size(presenter: *Presenter) ![2]u32 {
        return frameSize(presenter.screen, presenter.window, presenter.wanted, presenter.arena);
    }

    /// Draws a frame `pixels` in size of `overlay` alone and puts it on the window.
    pub fn present(presenter: *Presenter, pixels: [2]u32, overlay: srcore.Overlay) !void {
        _ = presenter.frame_arena.reset(.retain_capacity);
        const arena = presenter.frame_arena.allocator();
        try srcore.render(arena, presenter.context, &presenter.scene, presenter.driver.interface(), overlay);
        if (presenter.screen.* == .software) try presenter.window.present(try presenter.screen.software.rgba(arena), pixels[0], pixels[1]);
    }
};

/// The size a frame is drawn at: on the GPU the display's own resolution; for the software device
/// `wanted`, or else the window's size in points, the device made again when it changes.
pub fn frameSize(screen: *Screen, window: *const platform.window.Window, wanted: ?[2]u32, arena: Allocator) ![2]u32 {
    return switch (screen.*) {
        .gpu => |*device| device.frameSize(),
        .software => |*device| resized: {
            const size = wanted orelse window.size();
            if (device.width != size[0] or device.height != size[1]) {
                device.deinit(arena);
                device.* = try .init(arena, size[0], size[1]);
            }
            break :resized size;
        },
    };
}
