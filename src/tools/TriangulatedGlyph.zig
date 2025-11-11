const std = @import("std");

const vk = @import("../c/vk.zig");
const Glyph = @import("../font/Glyph.zig");
const helpers = @import("../helpers.zig");
const Point = @import("geometry.zig").Point;
const TriangulatedGlyph = @This();


vertices: []Vertex,
concave_indices: [][3]u16,
convex_indices: [][3]u16,
extra_indices_count: u16,


pub const Vertex = extern struct {
    position: Point(f32) align(4),
    tex_coord: packed struct(u8) { x: u1, y: u1, _pad: u6 = 0 } align(1),

    const _ = std.debug.assert(@alignOf(Vertex) == 1);

    pub const binding_description: vk.VertexInputBindingDescription = .{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .inputRate = vk.vertex_input_rate_vertex,
    };
    pub const attribute_descriptions: [2]vk.VertexInputAttributeDescription = .{
        .{
            .binding = 0,
            .location = 0,
            .format = vk.format_r32g32_sfloat,
            .offset = @offsetOf(Vertex, "position"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = vk.format_r8_uint,
            .offset = @offsetOf(Vertex, "tex_coord"),
        },
    };
};

pub fn init(glyph: Glyph) TriangulatedGlyph {
    //var glyph_info: GlyphInfo = .init(glyph);
    //defer glyph_info.deinit();

    var vertex_count: usize = 0;
    var curve_count: usize = 0;
    for (glyph.contours) |contour| {
        vertex_count += contour.points.len;
        curve_count += contour.points.len / 2;
    }
    const vertices = helpers.ensureAlloc(helpers.allocator.alloc(Vertex, vertex_count));
    errdefer helpers.allocator.free(vertices);
    const indices = helpers.ensureAlloc(helpers.allocator.alloc([3]u16, curve_count));
    errdefer helpers.allocator.free(indices);

    var vertex_idx: u16 = 0;
    var concave_indices_end: u16 = 0;
    var indices_end: u16 = 0;
    for (glyph.contours) |contour| {
        vertices[vertex_idx] = .{
            .position = contour.points[0].to(f32),
            .tex_coord = .{ .x = 1, .y = 0 },
        };
        vertex_idx += 1;

        const count = contour.points.len / 2;
        for (0..count) |curve_idx| {
            const odd_curve = curve_idx & 1 != 0;
            const p0_idx: u16 = @intCast(2 * curve_idx);
            vertices[vertex_idx] = .{
                .position = contour.points[p0_idx + 1].to(f32),
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            vertices[vertex_idx + 1] = .{
                .position = contour.points[p0_idx + 2].to(f32),
                .tex_coord = .{ .x = @intFromBool(odd_curve), .y = @intFromBool(!odd_curve) },
            };

            const p0 = contour.points[p0_idx].to(i32);
            const p1 = contour.points[p0_idx + 1].to(i32);
            const p2 = contour.points[p0_idx + 2].to(i32);
            switch (std.math.order((p1.x - p0.x) * (p2.y - p0.y), (p1.y - p0.y) * (p2.x - p0.x))) {
                .lt => { // clockwise, normally means this curve is convex
                    indices[indices_end] = .{vertex_idx - 1, vertex_idx + 1, vertex_idx};
                    indices_end += 1;
                },
                .eq => {}, // stright line
                .gt => { // conter-clockwise, normally means this curve is concave
                    if (concave_indices_end != indices_end) indices[indices_end] = indices[concave_indices_end];
                    indices_end += 1;
                    indices[concave_indices_end] = .{vertex_idx - 1, vertex_idx, vertex_idx + 1};
                    concave_indices_end += 1;
                },
            }
            vertex_idx += 2;
            //const is_clockwise = (p1.x - p0.x) * (p2.y - p0.y) > (p1.y - p0.y) * (p2.x - p0.x);
            //const triangle: [3]u16 = if (is_clockwise) .{vertex_idx - 1, vertex_idx, vertex_idx + 1} else .{vertex_idx - 1, vertex_idx + 1, vertex_idx};

            //const is_concave = windingInGlyph(glyph, glyph_info, contour.points[p0_idx + 1]) != 0;
            //if (is_concave) {
            //    if (concave_indices_end != indices_end) indices[indices_end] = indices[concave_indices_end];
            //    indices[concave_indices_end] = triangle;
            //    concave_indices_end += 1;
            //} else {
            //    indices[indices_end] = triangle;
            //}

            //vertex_idx += 2;
            //indices_end += 1;
        }
    }

    return .{
        .vertices = vertices,
        .concave_indices = indices[0 .. concave_indices_end],
        .convex_indices = indices[concave_indices_end .. indices_end],
        .extra_indices_count = @intCast(indices.len - indices_end),
    };
}

pub fn deinit(self: *TriangulatedGlyph) void {
    helpers.allocator.free(self.vertices);
    self.vertices = undefined;
    helpers.allocator.free(self.concave_indices.ptr[0 .. (self.concave_indices.len + self.convex_indices.len + self.extra_indices_count)]);
    self.concave_indices = undefined;
    self.convex_indices = undefined;
}


pub const GlyphInfo = struct {
    contours: [][]CurveInfo,

    pub const CurveInfo = struct {
        curve_type: CurveType,
        include_p0: bool,
    };

    pub const CurveType = enum {
        x_axis,
        balance,
        up_stright,
        up_normal,
        up_u,
        up_inv_u,
        down_stright,
        down_normal,
        down_inv_u,
        down_u,

        pub fn init(p0: Point(i16), p1: Point(i16), p2: Point(i16)) CurveType {
            if (p0.y == p2.y) return if (p1.y == p0.y) .x_axis else .balance;
            if (p0.y < p2.y) {
                if (@abs(p0.x + p2.x - 2 * p1.x) <= 1 and @abs(p0.y + p2.y - 2 * p1.y) <= 1) return .up_stright;
                if (p0.y <= p1.y and p1.y <= p2.y) return .up_normal;
                return if (p1.y < p0.y) .up_u else .up_inv_u;
            } else { // p0.y > p2.y
                if (@abs(p0.x + p2.x - 2 * p1.x) <= 1 and @abs(p0.y + p2.y - 2 * p1.y) <= 1) return .down_stright;
                if (p2.y <= p1.y and p1.y <= p0.y) return .down_normal;
                return if (p1.y > p0.y) .down_inv_u else .down_u;
            }
        }
    };

    pub fn init(glyph: Glyph) GlyphInfo {
        if (glyph.contours.len == 0) return .{ .contours = &.{} };

        const contours = helpers.ensureAlloc(helpers.allocator.alloc([]CurveInfo, glyph.contours.len));
        errdefer helpers.allocator.free(contours);
        const curves = helpers.ensureAlloc(helpers.allocator.alloc(CurveInfo, blk: {
            var count: usize = 0;
            for (glyph.contours) |contour| count += contour.points.len / 2;
            break :blk count;
        }));
        errdefer helpers.allocator.free(curves);

        var empty_list = curves;
        for (glyph.contours, contours) |contour, *contour_info| {
            const curve_count = contour.points.len / 2;
            for (0..curve_count) |curve_idx| {
                const p_2 = contour.points[if (curve_idx != 0) 2 * curve_idx - 2 else contour.points.len - 3];
                const p_1 = contour.points[if (curve_idx != 0) 2 * curve_idx - 1 else contour.points.len - 2];
                const p0 = contour.points[2 * curve_idx];
                const p1 = contour.points[2 * curve_idx + 1];
                const p2 = contour.points[2 * curve_idx + 2];

                const prev_end_winding = 2 * std.math.sign(p0.y - p_1.y) + std.math.sign(p0.y - p_2.y);
                const curr_start_winding = 2 * std.math.sign(p1.y - p0.y) + std.math.sign(p2.y - p0.y);

                empty_list[curve_idx] = .{
                    .include_p0 = curr_start_winding != 0 and (prev_end_winding == 0 or ((prev_end_winding > 0) ^ (curr_start_winding < 0))),
                    .curve_type = .init(p0, p1, p2),
                };
            }

            contour_info.* = empty_list[0..curve_count];
            empty_list = empty_list[curve_count..];
        }

        return .{ .contours = contours };
    }

    pub fn deinit(self: *GlyphInfo) void {
        var count: usize = 0;
        for (self.contours) |contour| count += contour.len;
        helpers.allocator.free(self.contours[0].ptr[0 .. count]);
        helpers.allocator.free(self.contours);
        self.contours = undefined;
    }
};

/// ! still has some problem !
///
/// TODO: fix it!
pub fn windingInGlyph(glyph: Glyph, glyph_info: GlyphInfo, point: Point(i16)) i16 {
    const p = point.to(i32);
    // counting the winding number using a ray that starts at `point` and points to positive x-axis
    var winding: i16 = 0;
    for (glyph.contours, glyph_info.contours) |contour, contour_info| {
        for (contour_info, 0..) |info, curve_idx| {
            const p0 = contour.points[2 * curve_idx + 0].to(i32);
            const p1 = contour.points[2 * curve_idx + 1].to(i32);
            const p2 = contour.points[2 * curve_idx + 2].to(i32);

            switch (info.curve_type) {
                .x_axis => {},
                .balance => {
                    if (info.include_p0 and p.y == p0.y) {
                        if (p.x < p0.x) winding += if (p1.y < p0.y) 1 else -1;
                    } else if (!(p1.y < p0.y) ^ (p.y < p0.y)) {
                        winding += solve2RootsWinding(p, p0, p1, p2);
                    }
                },
                .up_stright => {
                    if ((p0.y < p.y or (info.include_p0 and p0.y == p.y)) and p.y < p2.y) {
                        const v1 = (p.y - p0.y) * (p2.x - p0.x);
                        const v2 = (p.x - p0.x) * (p2.y - p0.y);
                        if (v1 >= v2) winding += -1;
                    }
                },
                .up_normal => {
                    if ((p0.y < p.y or (info.include_p0 and p0.y == p.y)) and p.y < p2.y) {
                        if (solve1RootCrossing(p, p0, p1, p2, .up)) winding += -1;
                    }
                },
                .up_u => {
                    if (p0.y <= p.y and p.y < p2.y) {
                        const cross = solve1RootCrossing(p, p0, p1, p2, .up);
                        if (p0.y < p.y) {
                            if (cross) winding += -1;
                        } else if (info.include_p0 and (cross ^ (p.x <= p0.x))) {
                            winding += if (cross) -1 else 1;
                        }
                    } else if (p.y < p0.y) {
                        winding += solve2RootsWinding(p, p0, p1, p2);
                    }
                },
                .up_inv_u => {
                    if ((p0.y < p.y or (info.include_p0 and p0.y == p.y)) and p.y <= p2.y) {
                        if (solve1RootCrossing(p, p0, p1, p2, .up)) winding += -1;
                    } else if (p2.y < p.y) {
                        winding += solve2RootsWinding(p, p0, p1, p2);
                    }
                },
                .down_stright => {
                    if (p2.y < p.y and (p.y < p0.y or (info.include_p0 and p.y == p0.y))) {
                        const v1 = (p.y - p0.y) * (p2.x - p0.x);
                        const v2 = (p.x - p0.x) * (p2.y - p0.y);
                        if (v1 <= v2) winding += 1;
                    }
                },
                .down_normal => {
                    if (p2.y < p.y and (p.y < p0.y or (info.include_p0 and p.y == p0.y))) {
                        if (solve1RootCrossing(p, p0, p1, p2, .down)) winding += 1;
                    }
                },
                .down_inv_u => {
                    if (p2.y < p.y and p.y <= p0.y) {
                        const cross = solve1RootCrossing(p, p0, p1, p2, .down);
                        if (p0.y > p.y) {
                            if (cross) winding += -1;
                        } else if (info.include_p0 and (cross ^ (p.x > p0.x))) {
                            winding += if (cross) 1 else -1;
                        }
                    } else if (p.y > p0.y) {
                        winding += solve2RootsWinding(p, p0, p1, p2);
                    }
                },
                .down_u => {
                    if (p2.y <= p.y and (p.y < p0.y or (info.include_p0 and p.y == p0.y))) {
                        if (solve1RootCrossing(p, p0, p1, p2, .down)) {
                            winding += 1;
                        }
                    } else if (p.y < p2.y) {
                        winding += solve2RootsWinding(p, p0, p1, p2);
                    }
                },
            }
        }
    }
    return winding;
}

fn solve2RootsWinding(p: Point(i32), p0: Point(i32), p1: Point(i32), p2: Point(i32)) i2 {
    const ay: i64 = p0.y + p2.y - 2 * p1.y;
    const by: i64 = (p1.y - p0.y) * 2;
    const cy: i64 = p0.y - p.y;
    const dy: i64 = by * by - 4 * ay * cy;
    if (dy <= 0) return 0;
    const ax: i64 = p0.x + p2.x - 2 * p1.x;
    const bx: i64 = (p1.x - p0.x) * 2;
    const cx: i64 = p0.x - p.x;

    // t = (-by ± √dy) / (2*ay)
    // ax*t*t + bx*t + cx >= 0 <=> ∓√dy * (ax*by-ay*bx) >= 2*ay * (ax*cy-ay*cx) - by * (ax*by-ay*bx)
    // winding = if (2*ay*t + by < 0) 1 else -1 // the changing of y at the point on curve
    //
    // return 0 if both t_± satified or not at the same time,
    // return 1 if t_- satified and t_+ not,
    // return -1 if t_+ satified anf t_- not,

    const abxy = ax * by - ay * bx;
    if (abxy == 0) return 0;
    const tmp = 2 * ay * (ax * cy - ay * cx) - by * abxy;
    if (tmp == 0) {
        return if (abxy > 0) 1 else -1;
    } else if (tmp > 0) {
        return if (dy * abxy * abxy < tmp * tmp) 0 else if (abxy > 0) 1 else -1;
    } else { // tmp < 0
        return if (dy * abxy * abxy <= tmp * tmp) 0 else if (abxy > 0) 1 else -1;
    }
}

fn solve1RootCrossing(p: Point(i32), p0: Point(i32), p1: Point(i32), p2: Point(i32), tilt: enum {up, down}) bool {
    const ay: i64 = p0.y + p2.y - 2 * p1.y;
    const by: i64 = (p1.y - p0.y) * 2;
    const cy: i64 = p0.y - p.y;
    const dy: i64 = by * by - 4 * ay * cy;
    std.debug.assert(dy >= 0);
    if (dy == 0) return false;
    const ax: i64 = p0.x + p2.x - 2 * p1.x;
    const bx: i64 = (p1.x - p0.x) * 2;
    const cx: i64 = p0.x - p.x;

    const abxy = ax * by - ay * bx;
    const tmp = 2 * ay * (ax * cy - ay * cx) - by * abxy;
    if (abxy == 0) return tmp <= 0;
    if ((abxy > 0) ^ (tilt == .up)) {
        if (tmp <= 0) return true;
        return dy * abxy * abxy >= tmp * tmp;
    } else {
        if (tmp >= 0) return false;
        return dy * abxy * abxy <= tmp * tmp;
    }
}

