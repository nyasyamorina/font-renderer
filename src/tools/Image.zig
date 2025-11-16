const std = @import("std");

const helpers = @import("../helpers.zig");
const Glyph = @import("../font/Glyph.zig");
const render_glyph = @import("render_glyph.zig");
const Point = @import("geometry.zig").Point;
const Image = @This();

const ensureAlloc = helpers.ensureAlloc;


vtable: *const VTable,


pub const VTable = struct {
    getWidth: *const fn (image: *Image) u32,
    getHeight: *const fn (image: *Image) u32,
    getRGBLinear: *const fn (image: *Image, index: usize) [3]u8,
    getRGB: *const fn (image: *Image, x: u32, y: u32) [3]u8 = &defaultGetRGB,
};

fn defaultGetRGB(image: *Image, x: u32, y: u32) [3]u8 {
    const width = image.getWidth();
    const index = @as(usize, y) * width + x;
    return image.getRGBLinear(index);
}


pub fn getWidth(self: *Image) u32 {
    return self.vtable.getWidth(self);
}

pub fn getHeight(self: *Image) u32 {
    return self.vtable.getHeight(self);
}

pub fn getRGB(self: *Image, x: u32, y: u32) [3]u8 {
    return self.vtable.getRGB(self, x, y);
}

pub fn getRGBLinear(self: *Image, index: usize) [3]u8 {
    return self.vtable.getRGBLinear(self, index);
}


pub const Gray = struct {
    width: u32,
    height: u32,
    data: []u8,
    interface: Image,

    pub fn initInterface() Image {
        return .{ .vtable = &.{
            .getWidth = &implGetWidth,
            .getHeight = &implGetHeight,
            .getRGBLinear = &implGetRGBLinear,
        } };
    }

    pub fn init(width: u32, height: u32) Image.Gray {
        const data = helpers.alloc(u8, @as(usize, width) * height);
        return .{ .width = width, .height = height, .data = data, .interface = initInterface() };
    }

    pub fn deinit(self: *Image.Gray) void {
        helpers.allocator.free(self.data);
        self.data = undefined;
    }

    fn implGetWidth(image: *Image) u32 {
        const self: *const Image.Gray = @fieldParentPtr("interface", image);
        return self.width;
    }

    fn implGetHeight(image: *Image) u32 {
        const self: *const Image.Gray = @fieldParentPtr("interface", image);
        return self.height;
    }

    fn implGetRGBLinear(image: *Image, index: usize) [3]u8 {
        const self: *const Image.Gray = @fieldParentPtr("interface", image);
        const val = self.data[index];
        return .{val, val, val};
    }
};

pub const Winding = struct {
    width: u32,
    height: u32,
    data: []i16,
    scaler: u8,
    overflow_color: u8,
    interface: Image,

    pub fn initInterface() Image {
        return .{ .vtable = &.{
            .getWidth = &implGetWidth,
            .getHeight = &implGetHeight,
            .getRGBLinear = &implGetRGBLinear,
        } };
    }

    pub fn init(width: u32, height: u32, scaler: u8, overflow_color: u8) Image.Winding {
        const data = helpers.alloc(i16, @as(usize, width) * height);
        return .{ .width = width, .height = height, .data = data, .scaler = scaler, .overflow_color = overflow_color, .interface = initInterface() };
    }

    pub fn deinit(self: *Image.Winding) void {
        helpers.allocator.free(self.data);
        self.data = undefined;
    }

    fn implGetWidth(image: *Image) u32 {
        const self: *const Image.Winding = @fieldParentPtr("interface", image);
        return self.width;
    }

    fn implGetHeight(image: *Image) u32 {
        const self: *const Image.Winding = @fieldParentPtr("interface", image);
        return self.height;
    }

    fn implGetRGBLinear(image: *Image, index: usize) [3]u8 {
        const self: *const Image.Winding = @fieldParentPtr("interface", image);
        const val = self.data[index];
        if (val == 0) return .{0, 0, 0};
        const c = self.scaler *| @abs(val);
        const color: u8 = @truncate(std.math.clamp(c, 0, 255));
        const subcolor = if (c == color) 0 else self.overflow_color;
        return if (val > 0) .{subcolor, subcolor, color} else .{color, subcolor, subcolor};
    }
};

pub const RGB = struct {
    width: u32,
    height: u32,
    data: [][3]u8,
    interface: Image,

    pub fn initInterface() Image {
        return .{ .vtable = &.{
            .getWidth = &implGetWidth,
            .getHeight = &implGetHeight,
            .getRGBLinear = &implGetRGBLinear,
        } };
    }

    pub fn init(width: u32, height: u32) Image.RGB {
        const data = helpers.alloc([3]u8, @as(usize, width) * height);
        return .{ .width = width, .height = height, .data = data, .interface = initInterface() };
    }

    pub fn deinit(self: *Image.RGB) void {
        helpers.allocator.free(self.data);
        self.data = undefined;
    }

    fn implGetWidth(image: *Image) u32 {
        const self: *const Image.RGB = @fieldParentPtr("interface", image);
        return self.width;
    }

    fn implGetHeight(image: *Image) u32 {
        const self: *const Image.RGB = @fieldParentPtr("interface", image);
        return self.height;
    }

    fn implGetRGBLinear(image: *Image, index: usize) [3]u8 {
        const self: *const Image.RGB = @fieldParentPtr("interface", image);
        return self.data[index];
    }
};


pub const GlyphDebug = struct {
    rgb: Image.RGB,
    glyph_box: Glyph.Box,
    winding_scale: u8,
    overflow_color: u8,
    on_curve_color: [3]u8,
    off_curve_color: [3]u8,

    pub fn init(glyph_box: Glyph.Box, winding_scale: u8, overflow_color: u8, on_curve_color: [3]u8, off_curve_color: [3]u8) Image.GlyphDebug {
        return .{
            .rgb = .init(@intCast(glyph_box.x_max - glyph_box.x_min + 3), @intCast(glyph_box.y_max - glyph_box.y_min + 3)),
            .glyph_box = glyph_box,
            .winding_scale = winding_scale,
            .overflow_color = overflow_color,
            .on_curve_color = on_curve_color,
            .off_curve_color = off_curve_color,
        };
    }

    pub fn setWindingLinear(self: *Image.GlyphDebug, index: usize, winding: i16) void {
        if (winding == 0) {
            self.rgb.data[index] = .{0, 0, 0};
        }
        const c = @abs(winding) *| self.winding_scale;
        const main_color: u8 = @truncate(std.math.clamp(c, 0, 255));
        const sub_color = if (c == main_color) 0 else self.overflow_color;
        self.rgb.data[index] = if (winding > 0) .{sub_color, sub_color, main_color} else .{main_color, sub_color, sub_color};
    }

    pub fn setGlyphPoints(self: *Image.GlyphDebug, glyph: Glyph) void {
        std.debug.assert(std.meta.eql(self.glyph_box, glyph.box));
        for (glyph.contours) |contour| {
            const curve_count = contour.points.len / 2;
            for (0..curve_count) |curve_idx| {
                const on_curve_pt = contour.points[2 * curve_idx];
                const w0: u32 = @intCast(on_curve_pt.x - self.glyph_box.x_min + 1);
                const h0: u32 = @intCast(self.glyph_box.y_max - on_curve_pt.y + 1);
                self.rgb.data[h0 * self.rgb.width + w0] = self.on_curve_color;
                const off_curve_pt = contour.points[2 * curve_idx + 1];
                const w1: u32 = @intCast(off_curve_pt.x - self.glyph_box.x_min + 1);
                const h1: u32 = @intCast(self.glyph_box.y_max - off_curve_pt.y + 1);
                self.rgb.data[h1 * self.rgb.width + w1] = self.off_curve_color;

            }
        }
    }

    pub fn render(glyph: Glyph, winding_scale: u8) Image.GlyphDebug {
        var glyph_info = render_glyph.GlyphInfo.init(glyph);
        defer glyph_info.deinit();

        var im: Image.GlyphDebug = .init(glyph.box, winding_scale, 150, .{255, 255, 0}, .{0, 255, 255});
        errdefer im.rgb.deinit();

        var h: u16 = 0;
        while (h < im.rgb.height) : (h += 1) {
            var w: u16 = 0;
            while (w < im.rgb.width) : (w += 1) {
                const idx = h * im.rgb.width + w;
                const y = glyph.box.y_max - @as(i16, @intCast(h)) + 1;
                const x = glyph.box.x_min + @as(i16, @intCast(w)) - 1;
                const winding = render_glyph.windingInGlyph(glyph, glyph_info, .{ .x = x, .y = y });
                im.setWindingLinear(idx, winding);
            }
        }
        im.setGlyphPoints(glyph);
        return im;
    }
};

