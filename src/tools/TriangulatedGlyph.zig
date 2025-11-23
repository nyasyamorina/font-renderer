const std = @import("std");

const vk = @import("../c/vk.zig");
const Glyph = @import("../font/Glyph.zig");
const helpers = @import("../helpers.zig");
const geometry = @import("geometry.zig");
const TriangulatedGlyph = @This();

const ensureAlloc = helpers.ensureAlloc;
const Point = geometry.Point;
const Triangulation = geometry.Triangulation;


vertices: []Vertex,
indices: std.ArrayList([3]u16),
concave_count: u16,
convex_count: u16,
solid_count: u16,


pub const Vertex = extern struct {
    position: Point(i16) align(4),
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
            .format = vk.format_r32_uint,
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
    var vertex_count: u16 = 0;
    var curve_count: u16 = 0;
    for (glyph.contours) |contour| {
        vertex_count += @intCast(contour.points.len);
        curve_count += @intCast(contour.points.len / 2);
    }

    var vertices = helpers.alloc(Vertex, vertex_count);
    errdefer helpers.allocator.free(vertices);
    var indices: std.ArrayList([3]u16) = .empty;
    errdefer indices.deinit(helpers.allocator);
    ensureAlloc(indices.ensureUnusedCapacity(helpers.allocator, curve_count));

    var triangulation: Triangulation = .init(vertices);
    defer triangulation.deinit();

    var concave_count: u16 = 0;
    var convex_count: u16 = 0;
    var vertex_idx: u16 = 0;
    for (glyph.contours) |contour| {
        const count = contour.points.len / 2;
        for (0..count) |curve_idx| {
            const p0 = contour.points[2 * curve_idx + 0].to(i32);
            const p1 = contour.points[2 * curve_idx + 1].to(i32);
            const p2 = contour.points[2 * curve_idx + 2].to(i32);

            switch (std.math.order((p1.x - p0.x) * (p2.y - p0.y), (p1.y - p0.y) * (p2.x - p0.x))) {
                .lt => { // clockwise curve, normally it means this curve is convex
                    {
                        indices.items.len += 1;
                        indices.items[indices.items.len - 1] = .{vertex_idx + 0, vertex_idx + 2, vertex_idx + 1};
                    }
                    convex_count += 1;
                    triangulation.addEdge(.{vertex_idx + 0, vertex_idx + 2});
                },
                .eq => { // stright line
                    triangulation.addEdge(.{vertex_idx + 0, vertex_idx + 2});
                },
                .gt => { // conter-clockwise, normally it means this curve is concave
                    {
                        indices.items.len += 1;
                        indices.items[indices.items.len - 1] = indices.items[concave_count];
                        indices.items[concave_count] = .{vertex_idx + 0, vertex_idx + 1, vertex_idx + 2};
                    }
                    concave_count += 1;
                    triangulation.addEdge(.{vertex_idx + 0, vertex_idx + 1});
                    triangulation.addEdge(.{vertex_idx + 1, vertex_idx + 2});
                },
            }

            const p0_is_tex_y_axis = curve_idx & 1 != 0;
            vertices[vertex_idx + 0] = .{
                .position = contour.points[2 * curve_idx + 0],
                .tex_coord = .{ .x = @intFromBool(!p0_is_tex_y_axis), .y = @intFromBool(p0_is_tex_y_axis) },
            };
            vertices[vertex_idx + 1] = .{
                .position = contour.points[2 * curve_idx + 1],
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            vertex_idx += 2;
        }

        // the last point in contour
        const is_tex_y_axis = count & 1 != 0;
        vertices[vertex_idx] = .{
            .position = contour.points[contour.points.len - 1],
            .tex_coord = .{ .x = @intFromBool(!is_tex_y_axis), .y = @intFromBool(is_tex_y_axis) },
        };
        vertex_idx += 1;
        triangulation.endContour();
    }

    triangulation.run(&indices);

    return .{
        .vertices = vertices,
        .indices = indices,
        .concave_count = concave_count,
        .convex_count = convex_count,
        .solid_count = @intCast(indices.items.len - (concave_count + convex_count)),
    };
}

pub fn deinit(self: *TriangulatedGlyph) void {
    helpers.allocator.free(self.vertices);
    self.vertices = undefined;
    self.indices.deinit(helpers.allocator);
}
