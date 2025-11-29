const std = @import("std");

const vk = @import("../c/vk.zig");
const Glyph = @import("../font/Glyph.zig");
const helpers = @import("../helpers.zig");
const geometry = @import("geometry.zig");
const TriangulatedGlyph = @This();

const Point = geometry.Point;
const Triangulation = geometry.Triangulation;


vertices: std.ArrayList(Vertex),
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

    var vertices: std.ArrayList(Vertex) = .empty;
    errdefer vertices.deinit(helpers.allocator);
    helpers.ensureAlloc(vertices.ensureUnusedCapacity(helpers.allocator, vertex_count));
    var indices: std.ArrayList([3]u16) = .empty;
    errdefer indices.deinit(helpers.allocator);
    helpers.ensureAlloc(indices.ensureUnusedCapacity(helpers.allocator, curve_count));

    var triangulation: Triangulation = .init;
    defer triangulation.deinit();

    var concave_count: u16 = 0;
    var convex_count: u16 = 0;
    for (glyph.contours) |contour| {
        const count = contour.points.len / 2;
        for (0..count) |curve_idx| {
            const p0 = contour.points[2 * curve_idx + 0].to(i32);
            const p1 = contour.points[2 * curve_idx + 1].to(i32);
            const p2 = contour.points[2 * curve_idx + 2].to(i32);

            const p0_index: u16 = @intCast(vertices.items.len);
            switch (std.math.order((p1.x - p0.x) * (p2.y - p0.y), (p1.y - p0.y) * (p2.x - p0.x))) {
                .lt => { // clockwise curve, normally it means this curve is convex
                    {
                        indices.items.len += 1;
                        indices.items[indices.items.len - 1] = .{p0_index, p0_index+2, p0_index+1};
                    }
                    convex_count += 1;
                    triangulation.addEdge(.{p0_index, p0_index+2});
                },
                .eq => { // stright line
                    triangulation.addEdge(.{p0_index, p0_index+2});
                },
                .gt => { // conter-clockwise, normally it means this curve is concave
                    {
                        indices.items.len += 1;
                        indices.items[indices.items.len - 1] = indices.items[concave_count];
                        indices.items[concave_count] = .{p0_index, p0_index+1, p0_index+2};
                    }
                    concave_count += 1;
                    triangulation.addEdge(.{p0_index, p0_index+1});
                    triangulation.addEdge(.{p0_index+1, p0_index+2});
                },
            }

            const p0_is_tex_y_axis = curve_idx & 1 != 0;
            vertices.appendAssumeCapacity(.{
                .position = contour.points[2 * curve_idx + 0],
                .tex_coord = .{ .x = @intFromBool(!p0_is_tex_y_axis), .y = @intFromBool(p0_is_tex_y_axis) },
            });
            vertices.appendAssumeCapacity(.{
                .position = contour.points[2 * curve_idx + 1],
                .tex_coord = .{ .x = 0, .y = 0 },
            });
        }

        // the last point in contour
        const is_tex_y_axis = count & 1 != 0;
        vertices.appendAssumeCapacity(.{
            .position = contour.points[contour.points.len - 1],
            .tex_coord = .{ .x = @intFromBool(!is_tex_y_axis), .y = @intFromBool(is_tex_y_axis) },
        });
        triangulation.endContour();
    }

    if (vertices.items.len > 0) {
        //triangulation.preProcessContour(&vertices);
        triangulation.run(vertices.items, &indices);
    }

    return .{
        .vertices = vertices,
        .indices = indices,
        .concave_count = concave_count,
        .convex_count = convex_count,
        .solid_count = @intCast(indices.items.len - (concave_count + convex_count)),
    };
}

pub fn deinit(self: *TriangulatedGlyph) void {
    self.vertices.deinit(helpers.allocator);
    self.indices.deinit(helpers.allocator);
}
