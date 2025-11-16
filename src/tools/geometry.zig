const std = @import("std");

const helpers = @import("../helpers.zig");
const Vertex = @import("TriangulatedGlyph.zig").Vertex;


pub fn Point(comptime T: type) type {
    return extern struct {
        x: T,
        y: T,

        pub fn initMiddle(p0: @This(), p1: @This()) @This() {
            return .{
                .x = @divTrunc(p0.x + p1.x, 2),
                .y = @divTrunc(p0.y + p1.y, 2),
            };
        }

        pub fn to(self: @This(), comptime U: type) Point(U) {
            switch (@typeInfo(T)) {
                .int => switch (@typeInfo(U)) {
                    .int => return .{ .x = @intCast(self.x), .y = @intCast(self.y) },
                    .float => return .{ .x = @floatFromInt(self.x), .y = @floatFromInt(self.y) },
                    else => @compileError(@typeName(U) ++ " is not a numrical type"),
                },
                .float => switch (@typeInfo(U)) {
                    .int => return .{ .x = @intFromFloat(self.x), .y = @intFromFloat(self.y) },
                    .float => return .{ .x = self.x, .y = self.y },
                    else => @compileError(@typeName(U) ++ "is not a numrical type"),
                },
                else => @compileError(@typeName(T) ++ "is not a numrical type"),
            }
        }

        pub fn sub(self: @This(), other: @This()) @This() {
            return .{ .x = self.x - other.x, .y = self.y - other.y };
        }

        pub fn dot(self: @This(), other: @This()) T {
            return self.x * other.x + self.y * other.y;
        }
    };
}


pub const Triangulation = struct {
    vertices: []const Vertex,
    contour_edges: std.ArrayList([2]u16) = .empty,
    contour_start_index: u16 = 0,
    vertex_sorted_indices: std.ArrayList(u16) = .empty,
    vertex_contour_connections: std.ArrayList(struct {u16, u16, std.math.Order}) = .empty,
    edge_manager: EdgeManager = .{},

    pub fn init(vertices: []const Vertex) Triangulation {
        return .{ .vertices = vertices };
    }

    pub fn deinit(self: *Triangulation) void {
        self.contour_edges.deinit(helpers.allocator);
        self.vertex_sorted_indices.deinit(helpers.allocator);
        self.vertex_contour_connections.deinit(helpers.allocator);
        self.edge_manager.inv_vertex_sorted_indices.deinit(helpers.allocator);
    }

    pub fn addEdge(self: *Triangulation, edge: [2]u16) void {
        helpers.ensureAlloc(self.contour_edges.append(helpers.allocator, edge));
    }

    pub fn endContour(self: *Triangulation) void {
        const end_edge = &self.contour_edges.items[self.contour_edges.items.len - 1];
        const next_contour_start_index = end_edge[1] + 1;
        // the last point in contour is actually the same point as the first one, just may have different `tex_coord`
        end_edge[1] = self.contour_start_index;
        self.contour_start_index = next_contour_start_index;
    }

    pub fn run(self: *Triangulation, output_to: *std.ArrayList([3]u16)) void {
        self.sortVertices();

        var runner: Runner = .init;
        defer runner.deinit();

        var skip_contour_edge_count: u16 = 0;
        var new_edge_count: u16 = undefined;
        for (self.vertex_sorted_indices.items) |new_index| {
            new_edge_count = 0;
            runner.addVertex(new_index);

            // connect new point to old points to form new edge
            for (self.contour_edges.items[skip_contour_edge_count ..]) |edge| {
                if (edge[0] != new_index) break;
                runner.connectContourEdge(edge);
                new_edge_count += 1;
            }
            skip_contour_edge_count += new_edge_count;
            for (runner.vertices.keys()) |index| {
                if (self.canConnect(skip_contour_edge_count, runner.edges.keys(), new_index, index)) {
                    runner.connectEdge(.{new_index, index});
                    new_edge_count += 1;
                }
            }

            // check new edges with old edges can form new triangle or not
            // note that any new triangle must be formed by 2 new edges and 1 old edge
            if (new_edge_count < 2) continue;
            const edges = runner.edges.keys();
            const new_edges_start = edges.len - new_edge_count;
            const new_edges = edges[new_edges_start ..];
            for (0 .. new_edges.len - 1) |new_edge1| {
                for (new_edge1 + 1 .. new_edges.len) |new_edge2| {
                    const p1 = new_edges[new_edge1][1];
                    const p2 = new_edges[new_edge2][1];

                    const old_edge = self.edge_manager.edge(.{p1, p2});
                    if (runner.edges.getIndex(old_edge)) |old_edge_idx| {
                        const triangle = self.clockwiseTriangle(.{new_index, p1, p2});
                        helpers.ensureAlloc(output_to.append(helpers.allocator, triangle));
                        runner.countTriangle(new_edges_start + new_edge1, new_edges_start + new_edge2, old_edge_idx);
                    }
                }
            }
            runner.removeUnsed();
        }
    }

    const Runner = struct {
        vertices: std.AutoArrayHashMapUnmanaged(u16, u16) = .empty,
        edges: std.AutoArrayHashMapUnmanaged([2]u16, u8) = .empty,
        removes: std.ArrayList(usize) = .empty,

        const init: Runner = .{};
        fn deinit(self: *Runner) void {
            self.vertices.deinit(helpers.allocator);
            self.edges.deinit(helpers.allocator);
            self.removes.deinit(helpers.allocator);
        }

        pub fn addVertex(self: *Runner, vertex_index: u16) void {
            helpers.ensureAlloc(self.vertices.put(helpers.allocator, vertex_index, 0));
        }

        pub fn connectContourEdge(self: *Runner, edge: [2]u16) void {
            helpers.ensureAlloc(self.edges.put(helpers.allocator, edge, 1));
            self.increaseVertexCount(edge);
        }
        pub fn connectEdge(self: *Runner, edge: [2]u16) void {
            helpers.ensureAlloc(self.edges.put(helpers.allocator, edge, 2));
            self.increaseVertexCount(edge);
        }
        fn increaseVertexCount(self: *Runner, edge: [2]u16) void {
            const e0 = self.vertices.getEntry(edge[0]).?;
            e0.value_ptr.* += 1;
            const e1 = self.vertices.getEntry(edge[1]).?;
            e1.value_ptr.* += 1;
        }

        fn countTriangle(self: *Runner, edge_index1: usize, edge_index2: usize, edge_index3: usize) void {
            self.edges.values()[edge_index1] -= 1;
            self.edges.values()[edge_index2] -= 1;
            self.edges.values()[edge_index3] -= 1;
        }

        fn removeUnsed(self: *Runner) void {
            self.removes.clearRetainingCapacity();
            for (self.edges.values(), 0..) |edge_count, idx| {
                if (edge_count == 0) helpers.ensureAlloc(self.removes.append(helpers.allocator, idx));
            }
            if (self.removes.items.len == 0) return; // prevent remove the first added vertex
            var iter = std.mem.reverseIterator(self.removes.items);
            while (iter.next()) |idx| {
                const edge = self.edges.keys()[idx];
                self.edges.swapRemoveAt(idx);

                self.vertices.getEntry(edge[0]).?.value_ptr.* -= 1;
                self.vertices.getEntry(edge[1]).?.value_ptr.* -= 1;
            }

            self.removes.clearRetainingCapacity();
            for (self.vertices.values(), 0..) |vertex_count, idx| {
                if (vertex_count == 0) helpers.ensureAlloc(self.removes.append(helpers.allocator, idx));
            }
            iter = std.mem.reverseIterator(self.removes.items);
            while (iter.next()) |idx| self.vertices.swapRemoveAt(idx);
        }
    };

    const EdgeManager = struct {
        inv_vertex_sorted_indices: std.ArrayList(u16) = .empty,

        fn init(self: *EdgeManager, vertex_count: u16, vertex_sorted_indices: []const u16) void {
            helpers.ensureAlloc(self.inv_vertex_sorted_indices.ensureTotalCapacity(helpers.allocator, vertex_count));
            self.inv_vertex_sorted_indices.items.len = vertex_count;

            for (vertex_sorted_indices, 0..) |index, inv_index| {
                self.inv_vertex_sorted_indices.items[index] = @intCast(inv_index);
            }
        }

        fn invIndex(self: EdgeManager, index: u16) u16 {
            return self.inv_vertex_sorted_indices.items[index];
        }

        fn edge(self: EdgeManager, e: [2]u16) [2]u16 {
            return if (self.invIndex(e[0]) < self.invIndex(e[1])) .{e[1], e[0]} else e;
        }
    };

    fn sortVertices(self: *Triangulation) void {
        self.vertex_sorted_indices.clearRetainingCapacity();
        helpers.ensureAlloc(self.vertex_sorted_indices.ensureUnusedCapacity(helpers.allocator, self.vertices.len));
        helpers.ensureAlloc(self.vertex_contour_connections.ensureTotalCapacity(helpers.allocator, self.vertices.len));
        self.vertex_contour_connections.items.len = self.vertices.len;

        var included = helpers.alloc(bool, self.vertices.len);
        defer helpers.allocator.free(included);
        for (included) |*i| i.* = false;
        for (self.contour_edges.items) |edge| {
            included[edge[0]] = true;
            included[edge[1]] = true;
            self.vertex_contour_connections.items[edge[0]].@"1" = edge[1];
            self.vertex_contour_connections.items[edge[1]].@"0" = edge[0];
        }
        for (self.vertex_contour_connections.items, included, 0..) |*conn, i, index| {
            if (!i) continue;
            const o = self.vertices[index].position.to(i32);
            const xo = self.vertices[conn.@"0"].position.to(i32).sub(o);
            const yo = self.vertices[conn.@"1"].position.to(i32).sub(o);
            conn.@"2" = std.math.order(xo.x * yo.y, xo.y * yo.x);
            self.vertex_sorted_indices.appendAssumeCapacity(@intCast(index));
        }
        std.mem.sortUnstable(u16, self.vertex_sorted_indices.items, self.vertices, struct {
            fn isLessThan(v: []const Vertex, l: u16, r: u16) bool {
                return v[l].position.x < v[r].position.x;
            }
        }.isLessThan);

        self.edge_manager.init(@intCast(self.vertices.len), self.vertex_sorted_indices.items);
        for (self.contour_edges.items) |*edge| edge.* = self.edge_manager.edge(edge.*);
        std.mem.sortUnstable([2]u16, self.contour_edges.items, self.edge_manager, struct {
            fn isLessThan(edge_manager: EdgeManager, l: [2]u16, r: [2]u16) bool {
                return edge_manager.invIndex(l[0]) < edge_manager.invIndex(r[0]);
            }
        }.isLessThan);
    }

    fn canConnect(self: Triangulation, skip_contour_edge_count: u16, on_going_edges: []const [2]u16, from: u16, to: u16) bool {
        const from_contour_conn = self.vertex_contour_connections.items[from];
        if (to == from_contour_conn[0] or to == from_contour_conn[1]) return false;

        if (!self.onRightSide(from, to) or !self.onRightSide(to, from)) return false;

        for (on_going_edges) |edge| {
            if (edge[0] == from or edge[0] == to or edge[1] == from or edge[1] == to) continue;
            if (self.isCross(.{from, to}, edge)) return false;
        }
        for (self.contour_edges.items[skip_contour_edge_count ..]) |edge| {
            std.debug.assert(!(edge[0] == from or edge[0] == to));
            if (edge[1] == from or edge[1] == to) continue;
            if (self.isCross(.{from, to}, edge)) return false;
        }

        return true;
    }

    fn onRightSide(self: Triangulation, origin: u16, target: u16) bool {
        const origin_conn = self.vertex_contour_connections.items[origin];
        const o = self.vertices[origin].position.to(i32);
        const xo = self.vertices[origin_conn.@"0"].position.to(i32).sub(o);
        const yo = self.vertices[origin_conn.@"1"].position.to(i32).sub(o);
        const po = self.vertices[target].position.to(i32).sub(o);

        const tmp = std.math.order(xo.x * po.y, xo.y * po.x);
        const cmp: std.math.CompareOperator = switch (origin_conn.@"2") {
            .eq => return tmp == .gt,
            .lt => switch (tmp) {
                .gt => return true,
                .eq => return xo.dot(po) < 0,
                .lt => .lt,
            },
            .gt => switch (tmp) {
                .lt, .eq => return false,
                .gt => .gt,
            },
        };
        return std.math.compare(@as(f32, @floatFromInt(xo.dot(po))) * std.math.sqrt(@as(f32, @floatFromInt(yo.dot(yo)))), cmp, @as(f32, @floatFromInt(xo.dot(yo))) * std.math.sqrt(@as(f32, @floatFromInt(po.dot(po)))));
    }

    fn isCross(self: Triangulation, edge1: [2]u16, edge2: [2]u16) bool {
        const e1o = self.vertices[edge1[0]].position.to(i32);
        const e2o = self.vertices[edge2[0]].position.to(i32);
        const do = e2o.sub(e1o);
        const d1 = self.vertices[edge1[1]].position.to(i32).sub(e1o);
        const d2 = self.vertices[edge2[1]].position.to(i32).sub(e2o);
        const f = d1.x * d2.y - d1.y * d2.x;
        const g1 = do.x * d2.y - do.y * d2.x;
        const g2 = do.x * d1.y - do.y * d1.x;

        switch (std.math.order(f, 0)) {
            .eq => return false,
            .gt => return g1 > 0 and g2 > 0 and g1 < f and g2 < f,
            .lt => return g1 < 0 and g2 < 0 and g1 > f and g2 > f,
        }
    }

    fn clockwiseTriangle(self: Triangulation, face: [3]u16) [3]u16 {
        const o = self.vertices[face[0]].position.to(i32);
        const xo = self.vertices[face[1]].position.to(i32).sub(o);
        const yo = self.vertices[face[2]].position.to(i32).sub(o);

        return if (xo.x * yo.y < xo.y * yo.x) .{face[0], face[2], face[1]} else face;
    }
};

