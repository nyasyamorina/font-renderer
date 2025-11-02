const std = @import("std");

const Glyph = @This();
const helpers = @import("../helpers.zig");
const log = std.log.scoped(.Glyph);
const ttf = @import("ttf.zig");
const i18d14 = helpers.FixedPointNumber(i32, 14);

const ensureAlloc = helpers.ensureAlloc;


box: Box,
contours: []Contour,


pub const Box = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

pub const Contour = struct {
    /// the even-index points are on-curve, the odd-index points are not. and the last point is the same point as the first one.
    points: []Point,

    pub const Point = struct {
        x: i16,
        y: i16,

        pub fn initMiddle(prev: Point, next: Point) Point {
            const p: @Vector(2, i32) = .{prev.x, prev.y};
            const n: @Vector(2, i32) = .{next.x, next.y};
            const m = (p + n) / @as(@TypeOf(p), @splat(2));
            return .{ .x = @truncate(m[0]), .y = @truncate(m[1]) };
        }
    };

    pub fn countTTFPoints(data: ttf.SimpleGlyph) u16 {
        var count: u16 = @intCast(data.end_pts_of_contours.len);

        var coord_start: u16 = 0;
        for (data.end_pts_of_contours) |coord_end| {
            var prev_on_curve = data.on_curve.isSet(coord_end);
            for (coord_start .. coord_end + 1) |coord| {
                const curr_on_curve = data.on_curve.isSet(coord);
                count += if (prev_on_curve == curr_on_curve) 2 else 1;
                prev_on_curve = curr_on_curve;
            }
            coord_start = coord_end + 1;
        }

        return count;
    }

    pub fn initTTF(data: ttf.SimpleGlyph, contour_index: u16, empty_point_buf: []Point) !Contour {
        const coord_start = if (contour_index == 0) 0 else data.end_pts_of_contours[contour_index - 1] + 1;
        const coord_end = data.end_pts_of_contours[contour_index];

        var prev_on_curve = data.on_curve.isSet(coord_end);
        var prev_coord = data.coordinates[coord_end];
        var next_point: u16 = if (prev_on_curve) 1 else 0;
        for (coord_start .. coord_end + 1) |coord| {
            const curr_on_curve = data.on_curve.isSet(coord);
            const curr_coord = data.coordinates[coord];

            if (prev_on_curve == curr_on_curve) {
                empty_point_buf[next_point] = .initMiddle(prev_coord, curr_coord);
                next_point += 1;
            }
            empty_point_buf[next_point] = curr_coord;
            next_point += 1;

            prev_on_curve = curr_on_curve;
            prev_coord = curr_coord;
        }

        if (prev_on_curve) {
            empty_point_buf[0] = empty_point_buf[next_point - 1];
        } else {
            empty_point_buf[next_point] = empty_point_buf[0];
            next_point += 1;
        }
        return .{ .points = empty_point_buf[0 .. next_point] };
    }
};

pub fn initEmpty(description: ttf.GlyphDescription) Glyph {
    return .{
        .box = .{
            .x_min = description.x_min, .y_min = description.y_min,
            .x_max = description.x_max, .y_max = description.y_max,
        },
        .contours = &.{},
    };
}

pub fn initTTFSimple(description: ttf.GlyphDescription, data: ttf.SimpleGlyph) !Glyph {
    if (data.instructions.len > 0) @panic("not impl"); // TODO:

    const contours = ensureAlloc(helpers.allocator.alloc(Contour, data.end_pts_of_contours.len));
    errdefer helpers.allocator.free(contours);
    const points = ensureAlloc(helpers.allocator.alloc(Contour.Point, Contour.countTTFPoints(data)));
    errdefer helpers.allocator.free(points);

    var empty_point_buf = points;
    for (contours, 0..) |*contour, idx| {
        contour.* = try .initTTF(data, @intCast(idx), empty_point_buf);
        empty_point_buf = empty_point_buf[contour.points.len..];
    }
    std.debug.assert(empty_point_buf.len == 0);

    return .{
        .box = .{
            .x_min = description.x_min, .y_min = description.y_min,
            .x_max = description.x_max, .y_max = description.y_max,
        },
        .contours = contours,
    };
}

pub fn initTTFComponent(description: ttf.GlyphDescription, data: ttf.ComponentGlyph, glyphs: []const ?Glyph) !Glyph {
    if (data.instructions.len > 0) @panic("not impl"); // TODO:
    if (data.matrics_index != null) @panic("not impl"); // TODO:

    const contour_count, const point_count = blk: {
        var p: usize = 0;
        var c: usize = 0;
        for (data.parts) |part| {
            const part_glyph = glyphs[part.glyph_index].?;
            c += part_glyph.contours.len;
            for (part_glyph.contours) |contour| {
                p += contour.points.len;
            }
        }
        break :blk .{c, p};
    };

    const contours = ensureAlloc(helpers.allocator.alloc(Contour, contour_count));
    errdefer helpers.allocator.free(contours);
    const points = ensureAlloc(helpers.allocator.alloc(Contour.Point, point_count));
    errdefer helpers.allocator.free(points);

    var next_contour: usize = 0;
    var empty_list = points;
    for (data.parts) |part| {
        const part_glyph = glyphs[part.glyph_index].?;
        if (!part.flag.args_are_xy_values) @panic("not impl"); // TODO:

        for (part_glyph.contours) |contour| {
            for (contour.points, 0..) |point, idx| {
                const x = transform1(point.x, point.y, part.transformation[0], part.transformation[2], @bitCast(part.argument1));
                const y = transform1(point.x, point.y, part.transformation[1], part.transformation[3], @bitCast(part.argument2));

                empty_list[idx] = if (part.flag.round_xy_to_grid)
                    .{ .x = x.roundToInt(i16), .y = y.roundToInt(i16) }
                else blk: {
                    const x_grid = x.toInt(i16);
                    const y_grid = y.toInt(i16);
                    if (x.cmp(.init(x_grid)) != .eq) @panic("not impl"); // TODO:
                    if (y.cmp(.init(y_grid)) != .eq) @panic("not impl");
                    break :blk .{ .x = x_grid, .y = y_grid };
                };
            }

            contours[next_contour] = .{ .points = empty_list[0..contour.points.len] };
            empty_list = empty_list[contour.points.len ..];
            next_contour += 1;
        }
    }

    return .{
        .box = .{
            .x_min = description.x_min, .y_min = description.y_min,
            .x_max = description.x_max, .y_max = description.y_max,
        },
        .contours = contours,
    };
}

pub fn deinit(self: *Glyph) void {
    if (self.contours.len > 0) {
        var count: usize = 0;
        for (self.contours) |contour| count += contour.points.len;
        helpers.allocator.free(self.contours[0].points.ptr[0 .. count]);
    }
    helpers.allocator.free(self.contours);
    self.contours = undefined;
}


fn transform1(x: i16, y: i16, a_or_b: ttf.i2d14, c_or_d: ttf.i2d14, e_or_f: i16) i18d14 {
    const tmp: i32 = @max(@abs(a_or_b.data), @abs(c_or_d.data));
    const shift = e_or_f << @intFromBool(@abs(@as(i16, @bitCast(@abs(a_or_b.data) -% @abs(c_or_d.data)))) <= 8);
    return .{ .data = @as(i32, a_or_b.data) * @as(i32, x) + @as(i32, c_or_d.data) * @as(i32, y) + tmp * shift };
}

