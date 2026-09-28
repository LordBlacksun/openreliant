//! The front end's screen, which `interface.cpp` lays out in pixels of a 640 by 480 screen, the
//! mode the game runs its front end in, and the pointer that moves over it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const spr = @import("../../../formats/spr.zig");
const device = @import("../../surrender/srd3d/device.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const input = @import("../../input.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");

/// The front end's screen in pixels, the mode returning from a mission sets the display to
/// (`0x004AD2E0`).
pub const size: [2]u32 = .{ 640, 480 };

pub const Error = spr.Error || Allocator.Error;

/// The colours the front end ramps its text through (`interface_palette_ramp`, `0x004287C0`),
/// from a `0xRRGGBB` value: the main menu's labels and the dialogs, a panel's labels under the
/// pointer, and the developers' text.
pub const blue = hud.rgb(0x40BCFF);
pub const gold = hud.rgb(0xFDB951);
pub const red = hud.rgb(0xFF0000);

/// The front end's fonts, which its start-up opens (`interface_init`, `0x004288E0`):
/// `hud.large_menu_font` and `hud.small_menu_font`, the pause menu's too.
pub const Fonts = struct {
    large: *hud.Opened,
    small: *hud.Opened,
};

/// Where the front end draws, and with what.
///
/// **Improvement.** The game switches the display to 640 by 480 for its front end, which then
/// fills the screen. OpenReliant keeps the window as it is and draws the front end as large as fits
/// in it, centred, so that it keeps its shape (`scaleFor`).
pub const Canvas = struct {
    gpa: Allocator,
    target: device.Device,
    /// The window's size in pixels.
    window: [2]u32,
    fonts: Fonts,
    strings: *const language.Language,

    /// How many of the window's pixels one of the front end's spans.
    pub fn scale(canvas: Canvas) f32 {
        return scaleFor(canvas.window);
    }

    /// Where the front end's top left corner stands in the window.
    pub fn corner(canvas: Canvas) [2]f32 {
        return cornerFor(canvas.window);
    }

    /// Where `at`, a point of the front end's screen, stands in the window.
    pub fn point(canvas: Canvas, at: [2]i32) [2]i32 {
        const s = canvas.scale();
        const from = canvas.corner();
        var out: [2]i32 = undefined;
        for (&out, from, at) |*pixel, start, offset| pixel.* = hud.round(start + @as(f32, @floatFromInt(offset)) * s);
        return out;
    }

    /// Draws `index` of `art` with its anchor at `at` (`VFX_shape_draw`).
    pub fn shape(canvas: Canvas, art: *hud.Art, index: usize, at: [2]i32) Error!void {
        try hud.drawShape(art, canvas.gpa, canvas.target, index, canvas.point(at), .{ 1, 1, 1, 1 }, canvas.scale());
    }

    /// Draws `picture` over the whole of the front end's screen, whatever its size.
    pub fn fill(canvas: Canvas, picture: *srtexture.Image) void {
        const across: f32 = @floatFromInt(picture.width());
        hud.drawImage(canvas.target, picture, canvas.corner(), .{ 1, 1, 1, 1 }, canvas.scale() * @as(f32, @floatFromInt(size[0])) / across, .{});
    }

    /// Draws a line in `colour` from the pixel at `from` to the pixel at `to`, both included
    /// (`VFX_line_draw`).
    pub fn line(canvas: Canvas, from: [2]i32, to: [2]i32, colour: [3]f32) void {
        hud.drawLine(canvas.target, canvas.pixelAt(from), canvas.pixelAt(to), hud.atBrightness(colour, 1), canvas.scale());
    }

    /// Fills the pixels from `from` to `to`, both included, with `colour` (`VFX_pane_wipe`).
    pub fn wipe(canvas: Canvas, from: [2]i32, to: [2]i32, colour: [3]f32) void {
        const s = canvas.scale();
        const start = canvas.pixelAt(from);
        const end = canvas.pixelAt(to);
        hud.drawFilled(canvas.target, .{ .left = start[0], .top = start[1], .right = end[0] + s, .bottom = end[1] + s }, hud.atBrightness(colour, 1));
    }

    /// `interface_box` (`0x00435C60`): the frame round a box `extent` across and down from `at`, at a
    /// brightness of 1. Its top and left edges are light (`box_light`), its right and bottom dark
    /// (`box_dark`), each a pixel short of the corner the other starts from, and a pixel in runs a
    /// second frame, all in between (`box_inner`).
    pub fn box(canvas: Canvas, at: [2]i32, extent: [2]i32) void {
        const x = at[0];
        const y = at[1];
        const right = x + extent[0];
        const bottom = y + extent[1];
        canvas.line(.{ x, y }, .{ right, y }, box_light);
        canvas.line(.{ x, y }, .{ x, bottom }, box_light);
        canvas.line(.{ right, y + 1 }, .{ right, bottom }, box_dark);
        canvas.line(.{ right, bottom }, .{ x + 1, bottom }, box_dark);
        canvas.line(.{ x + 1, y + 1 }, .{ right - 1, y + 1 }, box_inner);
        canvas.line(.{ x + 1, bottom - 1 }, .{ right - 1, bottom - 1 }, box_inner);
        canvas.line(.{ x + 1, y + 1 }, .{ x + 1, bottom - 1 }, box_inner);
        canvas.line(.{ right - 1, y + 1 }, .{ right - 1, bottom - 1 }, box_inner);
    }

    /// Where the pixel at `at`, a point of the front end's screen, starts in the window.
    fn pixelAt(canvas: Canvas, at: [2]i32) hud.Point {
        const s = canvas.scale();
        const from = canvas.corner();
        return .{ from[0] + @as(f32, @floatFromInt(at[0])) * s, from[1] + @as(f32, @floatFromInt(at[1])) * s };
    }

    /// Draws `picture` with its top left corner at `at`.
    pub fn image(canvas: Canvas, picture: *srtexture.Image, at: [2]i32) void {
        const s = canvas.scale();
        const from = canvas.corner();
        var left: [2]f32 = undefined;
        for (&left, from, at) |*pixel, start, offset| pixel.* = start + @as(f32, @floatFromInt(offset)) * s;
        hud.drawImage(canvas.target, picture, left, .{ 1, 1, 1, 1 }, s, .{});
    }

    /// Writes `words` in `font` at `at`, ramped through `colour` (`hud_text`).
    pub fn text(canvas: Canvas, font: *hud.Opened, at: [2]i32, words: []const u8, colour: [3]f32, alignment: hud.Align) Allocator.Error!void {
        _ = try hud.drawText(font, canvas.gpa, canvas.target, canvas.point(at), words, hud.atBrightness(colour, 1), alignment, canvas.scale());
    }

    /// `hud_text_wrapped` (`0x00480FD0`): `words` broken into lines at most `lines.width` of the
    /// front end's pixels wide, at most `lines.most` of them, each `lines.height` below the last.
    pub fn wrapped(canvas: Canvas, font: *hud.Opened, at: [2]i32, words: []const u8, colour: [3]f32, alignment: hud.Align, lines: Lines) Allocator.Error!void {
        var wrapping: hud.WrappedText = .init(&font.widths, words, lines.width, lines.most);
        var y = at[1];
        while (wrapping.next()) |shown| : (y += lines.height) try canvas.text(font, .{ at[0], y }, shown, colour, alignment);
    }

    /// How `wrapped` lays its lines out.
    pub const Lines = struct { width: i32, height: i32, most: usize };

    /// Writes the string of `id` (`language_string`); one the game doesn't have writes nothing.
    pub fn string(canvas: Canvas, font: *hud.Opened, at: [2]i32, id: u32, colour: [3]f32, alignment: hud.Align) Allocator.Error!void {
        const words = canvas.strings.string(id) orelse return;
        try canvas.text(font, at, words, colour, alignment);
    }
};

/// `interface_box`'s colours at a brightness of 1 (`0x004DC6D0`, `0x004DC6CC`; `0x004DC6C8`,
/// `0x004DC6C4`; `0x004DC6C0`, `0x004DC6BC`), in 255ths: no red, and green and blue.
const box_light = hud.rgb(0x00A7FF);
const box_dark = hud.rgb(0x005785);
const box_inner = hud.rgb(0x0086CD);

/// How many of a window's pixels one of the front end's spans in a window of `window`: as many as
/// fit the front end in it.
pub fn scaleFor(window: [2]u32) f32 {
    return hud.fit(window, size);
}

/// Where the front end's top left corner stands in a window of `window`, which centres it.
pub fn cornerFor(window: [2]u32) [2]f32 {
    return hud.centred(window, size, scaleFor(window));
}

/// A rectangle of the front end's screen, as its tables keep one: its corner and its size.
pub const Rect = extern struct {
    x: i16,
    y: i16,
    width: i16,
    height: i16,

    /// Whether `at` lies inside it, its edges left out, as `interface_hit` tests.
    pub fn holds(rect: Rect, at: [2]i32) bool {
        return rect.x < at[0] and at[0] < @as(i32, rect.x) + rect.width and rect.y < at[1] and at[1] < @as(i32, rect.y) + rect.height;
    }
};

comptime {
    std.debug.assert(@sizeOf(Rect) == 8);
}

/// `interface_hit` (`0x0043EB30`): the first of `rects` that holds `at`, or null for none.
///
/// **Unverified:** the file. It lies after `interface.cpp`'s known code and before `itac.cpp`'s,
/// and every caller is one of the front end's screens, so it goes with `interface.cpp`.
pub fn hit(rects: []const Rect, at: [2]i32) ?usize {
    for (rects, 0..) |rect, index| if (rect.holds(at)) return index;
    return null;
}

/// `hit` over a screen's items, each with its rectangle: the first item that holds `at`.
pub fn itemAt(comptime Item: type, rects: *const std.EnumArray(Item, Rect), at: [2]i32) ?Item {
    const index = hit(&rects.values, at) orelse return null;
    return std.EnumArray(Item, Rect).Indexer.keyForIndex(index);
}

/// The front end's pointer (`interface_pointer_x`, `interface_pointer_y`), its buttons and its
/// animation.
pub const Pointer = struct {
    /// Where it points on the front end's screen: (320, 200) as the main menu starts.
    at: [2]i32 = .{ 320, 200 },
    /// Whether the left button is down (`interface_pointer_down`), and the right
    /// (`interface_pointer_right_down`).
    down: bool = false,
    right_down: bool = false,
    /// The ticks into its animation (`interface_pointer_ticks`), which runs through its shapes a
    /// shape every `ticks_per_shape` ticks.
    ticks: i32 = 0,

    /// The animation's shapes, 1 to 16 of the screen's set, and how long each shows: the ticks
    /// wrap at 64 (`0x00436103`), and the drawing takes the shape `ticks / 4 + 1` (`0x0042961C`).
    pub const shapes = 16;
    pub const ticks_per_shape = 4;

    /// `interface_pointer_update` (`0x004360D0`), once a frame, `elapsed` ticks after the last:
    /// the buttons as the mouse has them, and the animation on.
    ///
    /// **Improvement.** The pointer is where the system's is, over the window, as the pause menu's
    /// is. The game adds up DirectInput's movements from where its pointer last stood.
    pub fn update(pointer: *Pointer, mouse: input.Mouse, window: [2]u32, elapsed: i32) void {
        if (mouse.at) |share| {
            const s = scaleFor(window);
            const from = cornerFor(window);
            for (&pointer.at, share, window, from, size) |*at, fraction, pixels, start, across| {
                const on_screen = fraction * @as(f32, @floatFromInt(pixels));
                at.* = std.math.clamp(hud.round((on_screen - start) / s), 0, @as(i32, @intCast(across)) - 1);
            }
        }
        pointer.down = mouse.buttons.left;
        pointer.right_down = mouse.buttons.right;
        pointer.ticks += elapsed;
        if (pointer.ticks >= shapes * ticks_per_shape) pointer.ticks = 0;
    }

    /// The shape it shows, from 1 to `shapes`.
    pub fn shape(pointer: Pointer) usize {
        return @intCast(@divTrunc(pointer.ticks, ticks_per_shape) + 1);
    }
};

test scaleFor {
    try std.testing.expectEqual(1, scaleFor(.{ 640, 480 }));
    try std.testing.expectEqual(2, scaleFor(.{ 1280, 960 }));
    // A wide window fits its height, a tall one its width.
    try std.testing.expectEqual(2.25, scaleFor(.{ 1920, 1080 }));
    try std.testing.expectEqual(1.5, scaleFor(.{ 960, 1080 }));
    try std.testing.expectEqual(0.5, scaleFor(.{ 320, 240 }));
    // Centred.
    try std.testing.expectEqual([2]f32{ 240, 0 }, cornerFor(.{ 1920, 1080 }));
    try std.testing.expectEqual([2]f32{ 0, 180 }, cornerFor(.{ 960, 1080 }));
    try std.testing.expectEqual([2]f32{ 0, 0 }, cornerFor(.{ 640, 480 }));
}

test "Canvas.fill" {
    const gpa = std.testing.allocator;
    var recorder: device.testing.Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const strings: language.Language = .{ .strings = &.{} };
    var font: hud.Opened = undefined;
    const drawn: Canvas = .{ .gpa = gpa, .target = recorder.interface(), .window = .{ 1280, 720 }, .fonts = .{ .large = &font, .small = &font }, .strings = &strings };
    // A picture 1024 by 768 covers the front end's screen, one and a half times its size in a
    // window 720 high, centred across it.
    const rgba = try gpa.alloc(u8, 1024 * 768 * 4);
    var picture = srtexture.Image.single(gpa, 1024, 768, rgba) catch |err| {
        gpa.free(rgba);
        return err;
    };
    defer picture.deinit(gpa);
    drawn.fill(&picture);
    const corners = recorder.drawn(0);
    try std.testing.expectEqual(160, corners[0].x);
    try std.testing.expectEqual(0, corners[0].y);
    try std.testing.expectEqual(1120, corners[2].x);
    try std.testing.expectEqual(720, corners[2].y);
}

test hit {
    const rects = [_]Rect{
        .{ .x = 27, .y = 123, .width = 184, .height = 290 },
        .{ .x = 332, .y = 441, .width = 20, .height = 15 },
    };
    try std.testing.expectEqual(0, hit(&rects, .{ 100, 200 }));
    try std.testing.expectEqual(1, hit(&rects, .{ 340, 450 }));
    // The edges are left out.
    try std.testing.expectEqual(null, hit(&rects, .{ 27, 200 }));
    try std.testing.expectEqual(null, hit(&rects, .{ 211, 200 }));
    try std.testing.expectEqual(null, hit(&rects, .{ 600, 20 }));
}

test itemAt {
    const Item = enum { panel, button };
    const rects = std.EnumArray(Item, Rect).init(.{
        .panel = .{ .x = 27, .y = 123, .width = 184, .height = 290 },
        .button = .{ .x = 100, .y = 200, .width = 20, .height = 15 },
    });
    // The first that holds the point, where two do.
    try std.testing.expectEqual(.panel, itemAt(Item, &rects, .{ 110, 205 }));
    try std.testing.expectEqual(null, itemAt(Item, &rects, .{ 600, 20 }));
}

test Pointer {
    var pointer: Pointer = .{};
    // With the system's pointer not yet over the window, it stays where it starts.
    pointer.update(.{}, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 320, 200 }, pointer.at);
    // The middle of a wide window is the middle of the front end's screen.
    pointer.update(.{ .at = .{ 0.5, 0.5 } }, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 320, 240 }, pointer.at);
    // Beside it, it keeps to its edge.
    pointer.update(.{ .at = .{ 0.9, 0 } }, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 639, 0 }, pointer.at);
    // Out beside the front end's screen, it keeps to its edge.
    pointer.update(.{ .at = .{ 0.01, 0.5 } }, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual(0, pointer.at[0]);
    // The animation runs through the sixteen shapes, then from the first again.
    pointer.ticks = 0;
    pointer.update(.{}, .{ 640, 480 }, 3);
    try std.testing.expectEqual(1, pointer.shape());
    pointer.update(.{}, .{ 640, 480 }, 60);
    try std.testing.expectEqual(16, pointer.shape());
    pointer.update(.{}, .{ 640, 480 }, 1);
    try std.testing.expectEqual(0, pointer.ticks);
}
