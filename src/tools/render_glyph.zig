const std = @import("std");

const Font = @import("../font/Font.zig");
const Glyph = @import("../font/Glyph.zig");
const helpers = @import("../helpers.zig");
const Image = @import("Image.zig");
const log = std.log.scoped(.renderGlyph);


pub fn renderGlyph(glyph: Glyph, font_info: Font.Information, font_size: u16) !Image.Gray {
    const v4f32 = @Vector(4, f32);
    const scale = @as(f32, @floatFromInt(font_size)) / @as(f32, @floatFromInt(font_info.units_per_em));
    const glyph_box: @Vector(4, i16) = .{glyph.box.x_min, glyph.box.y_min, glyph.box.x_max, glyph.box.y_max};
    const box = @as(v4f32, @floatFromInt(glyph_box)) * @as(v4f32, @splat(scale));
    const min_corner: [2]i16 = .{@intFromFloat(std.math.floor(box[0])), @intFromFloat(std.math.floor(box[1]))};
    const max_corner: [2]i16 = .{@intFromFloat(std.math.ceil(box[2])), @intFromFloat(std.math.ceil(box[3]))};
    const width: u16 = @intCast(@as(i16, max_corner[0]) - min_corner[0] + 1);
    const height: u16 = @intCast(@as(i16, max_corner[1]) - min_corner[1] + 1);
    if (!font_info.y0_baseline) log.warn("y=0 is not font baseline is not consider yet", .{});

    var im: Image.Gray = .init(width, height);
    errdefer im.deinit();
    for (0..height) |y| {
        for (0..width) |x| {
            const coord_x = @as(f32, @floatFromInt(min_corner[0] + @as(i16, @intCast(x)))) / scale;
            const coord_y = @as(f32, @floatFromInt(max_corner[1] - @as(i16, @intCast(y)))) / scale;
            im.data[y * width + x] = @intCast(std.math.clamp(glyphWindingAt(glyph, .{coord_x, coord_y}) * 20 + 100, 0, 255));
            //im.data[y * width + x] = if (glyphWindingAt(glyph, .{coord_x, coord_y}) != 0) 255 else 0;
        }
    }
    return im;
}

fn glyphWindingAt(glyph: Glyph, coord: [2]f32) i16 {
    var winding: i16 = 0;
    for (glyph.contours) |contour| {
        const curve_count = contour.points.len / 2;
        for (0..curve_count) |curve_idx| {
            const p0 = contour.points[2 * curve_idx];
            const p1 = contour.points[2 * curve_idx + 1];
            const p2 = contour.points[2 * curve_idx + 2];
            const p0x: f32 = @floatFromInt(p0.x); const p0y: f32 = @floatFromInt(p0.y);
            const p1x: f32 = @floatFromInt(p1.x); const p1y: f32 = @floatFromInt(p1.y);
            const p2x: f32 = @floatFromInt(p2.x); const p2y: f32 = @floatFromInt(p2.y);
            const cx = coord[0]; const cy = coord[1];

            const a = p0y - 2 * p1y + p2y;
            if (a == 0) {
                if (p2y == p0y) continue;
                const t = (cy - p0y) / (p2y - p0y);
                if (t < 0 or t >= 1) continue;
                const xx = ((p0x - 2 * p1x + p2x) * t + 2 * (p1x - p0x)) * t + p0x;
                if (xx < cx) continue;
                winding += if (p0y < p2y) -1 else 1;
                continue;
            }
            const delta = cy * a + p1y * p1y - p0y * p2y;
            if (delta < 0) continue;
            const t_pos = ((p0y - p1y) + std.math.sqrt(delta)) / a;
            const t_neg = ((p0y - p1y) - std.math.sqrt(delta)) / a;

            for ([2]f32 {t_pos, t_neg}) |t| {
                if (t < 0 or t >= 1) continue;
                const xx = ((p0x - 2 * p1x + p2x) * t + 2 * (p1x - p0x)) * t + p0x;
                if (xx < cx) continue;
                const dy = a * t + (p1y - p0y);
                winding += if (dy > 0) -1 else 1;
            }
        }
    }
    return winding;
}

