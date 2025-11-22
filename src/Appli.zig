const std = @import("std");

const Appli = @This();
const CallbackContext = @import("CallbackContext.zig");
const helpers = @import("helpers.zig");
const Font = @import("font/Font.zig");
const Point = @import("tools/geometry.zig").Point;
const TriangulatedGlyph = @import("tools/TriangulatedGlyph.zig");
const glfw = @import("c/glfw.zig");
const vk = @import("c/vk.zig");
const VulkanContext = @import("VulkanContext.zig");

const ensureAlloc = helpers.ensureAlloc;
const ensureVkSuccess = helpers.ensureVkSuccess;


font: *Font,
cb_ctx: *CallbackContext,
vk_ctx: VulkanContext,
general_pipeline_layout: vk.PipelineLayout,
curve_pipeline: vk.Pipeline,
solid_pipeline: vk.Pipeline,
global_transform: Transform,
transform_changed: bool = false,
glyph_objects: std.AutoArrayHashMapUnmanaged(u32, GlyphMapValue) = .empty,
total_transforms: std.ArrayList(Transform) = .empty,
frame_count: usize = 0,
cursor_pos: Point(f32) = undefined,
cursor_pos_last_update_frame: usize = 0,
prev_cursor_pos: ?Point(f32) = null,


const Transform = extern struct {
    offset: [2]f32 align(8) = .{0, 0},
    scale: f32 = 1,
};
const GlyphMapValue = struct {
    glyph_object: GlyphObject,
    box: Font.Glyph.Box,
    transforms: std.ArrayList(Transform) = .empty,
};

pub fn init(font: *Font, cb_ctx: *CallbackContext, window_size: vk.Extent2D, window_title: [*:0]const u8) !Appli {
    if (glfw.init() != glfw.@"true") return error.@"failed to initialize glfw";
    errdefer glfw.terminate();

    var vk_ctx: VulkanContext = try .init(cb_ctx, window_size, window_title);
    errdefer vk_ctx.deinit();

    const pipeline_layout = try vk_ctx.createPipelineLayout(Transform);
    errdefer vk.destroyPipelineLayout(vk_ctx.device, pipeline_layout, null);
    const curve_pipeline = try vk_ctx.createGraphicsPipeline(&shader.slang, shader.entries.vertMain, shader.entries.curveMain, pipeline_layout);
    errdefer vk.destroyPipeline(vk_ctx.device, curve_pipeline, null);
    const solid_pipeline = try vk_ctx.createGraphicsPipeline(&shader.slang, shader.entries.vertMain, shader.entries.solidMain, pipeline_layout);
    errdefer vk.destroyPipeline(vk_ctx.device, solid_pipeline, null);

    return .{
        .font = font,
        .cb_ctx = cb_ctx,
        .vk_ctx = vk_ctx,
        .general_pipeline_layout = pipeline_layout,
        .curve_pipeline = curve_pipeline,
        .solid_pipeline = solid_pipeline,
        .global_transform = .{
            .scale = 2 / @as(f32, @floatFromInt(font.information.units_per_em)),
            .offset = .{-1, -1},
        },
    };
}

pub fn deinit(self: *Appli) void {
    self.total_transforms.deinit(helpers.allocator);

    for (self.glyph_objects.values()) |*v| {
        v.glyph_object.deinit(self.vk_ctx.device);
        v.transforms.deinit(helpers.allocator);
    }
    self.glyph_objects.deinit(helpers.allocator);

    vk.destroyPipeline(self.vk_ctx.device, self.solid_pipeline, null);
    vk.destroyPipeline(self.vk_ctx.device, self.curve_pipeline, null);
    vk.destroyPipelineLayout(self.vk_ctx.device, self.general_pipeline_layout, null);
    self.vk_ctx.deinit();
    glfw.terminate();
}

pub fn mainLoop(self: *Appli) !void {
    try self.vk_ctx.startMainLoop(renderingFunc, @ptrCast(self));
}


pub fn renderingFunc(data: ?*anyopaque, command_buffer: vk.CommandBuffer) !void {
    const self: *Appli = @ptrCast(@alignCast(data.?));
    self.frame_count +%= 1;

    self.zoom();
    self.drag();
    if (self.transform_changed) {
        self.updateTotalTransforms();
        self.transform_changed = false;
    }

    var index: usize = 0;
    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.curve_pipeline);
    for (self.glyph_objects.values()) |v| {
        if (v.glyph_object.curve_count == 0) continue;
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &v.glyph_object.vertex_buffer, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, v.glyph_object.index_buffer, 0, vk.index_type_uint16);
        for (v.transforms.items) |_| {
            const total_transform = &self.total_transforms.items[index];
            index += 1;

            vk.cmdPushConstants(command_buffer, self.general_pipeline_layout, vk.shader_stage_vertex_bit, 0, @sizeOf(Transform), total_transform);
            vk.cmdDrawIndexed(command_buffer, v.glyph_object.curve_count, 1, 0, 0, 0);
        }
    }

    index = 0;
    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.solid_pipeline);
    for (self.glyph_objects.values()) |v| {
        if (v.glyph_object.solid_count == 0) continue;
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &v.glyph_object.vertex_buffer, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, v.glyph_object.index_buffer, 0, vk.index_type_uint16);
        for (v.transforms.items) |_| {
            const total_transform = &self.total_transforms.items[index];
            index += 1;

            vk.cmdPushConstants(command_buffer, self.general_pipeline_layout, vk.shader_stage_vertex_bit, 0, @sizeOf(Transform), total_transform);
            vk.cmdDrawIndexed(command_buffer, v.glyph_object.solid_count, 1, v.glyph_object.curve_count, 0, 0);
        }
    }
}

pub const GlyphObject = struct {
    memory: vk.DeviceMemory,
    vertex_buffer: vk.Buffer,
    index_buffer: vk.Buffer,
    curve_count: u32,
    solid_count: u32,

    pub fn init(ctx: VulkanContext, glyph: TriangulatedGlyph) !GlyphObject {
        const sizes: [2]u64 = .{
            @sizeOf(TriangulatedGlyph.Vertex) * glyph.vertices.len,
            @sizeOf([3]u16) * glyph.indices.items.len,
        };
        const buf_usages: [2]vk.BufferUsageFlags = .{
            vk.buffer_usage_transfer_dst_bit | vk.buffer_usage_vertex_buffer_bit,
            vk.buffer_usage_transfer_dst_bit | vk.buffer_usage_index_buffer_bit,
        };
        const mem_prop = vk.memory_property_device_local_bit;

        // create staging buffers
        const staging_usages = ([1]vk.BufferUsageFlags {vk.buffer_usage_transfer_src_bit}) ** 2;
        const staging_mem_prop = vk.memory_property_host_coherent_bit | vk.memory_property_host_visible_bit;
        var staging_bufs: [2]vk.Buffer = undefined;
        var offsets: [2]u64 = undefined;
        const staging_mem, const mem_size = try ctx.createBuffers(&sizes, &staging_usages, staging_mem_prop, &staging_bufs, &offsets);
        defer {
            vk.freeMemory(ctx.device, staging_mem, null);
            for (staging_bufs) |buf| vk.destroyBuffer(ctx.device, buf, null);
        }

        // transfer data into staging buffers
        {
            var data: ?[*]u8 = null;
            try ensureVkSuccess("vkMapMemory", vk.mapMemory(ctx.device, staging_mem, 0, mem_size, 0, @ptrCast(&data)));
            defer vk.unmapMemory(ctx.device, staging_mem);

            const vertices: [*]align(1) TriangulatedGlyph.Vertex = @ptrCast(&data.?[offsets[0]]);
            @memcpy(vertices, glyph.vertices);
            const indices: [*]align(1) [3]u16 = @ptrCast(&data.?[offsets[1]]);
            @memcpy(indices, glyph.indices.items);
        }

        // create actual buffers
        var bufs: [2]vk.Buffer = undefined;
        const mem, _ = try ctx.createBuffers(&sizes, &buf_usages, mem_prop, &bufs, &offsets);
        errdefer {
            vk.freeMemory(ctx.device, mem, null);
            for (bufs) |buf| vk.destroyBuffer(ctx.device, buf, null);
        }

        // copy data from staging buffers to actual buffers
        try ctx.copyBuffers(&staging_bufs, &bufs, &sizes);

        return .{
            .memory = mem,
            .vertex_buffer = bufs[0],
            .index_buffer = bufs[1],
            .curve_count = 3 * @as(u32, glyph.curve_count),
            .solid_count = @intCast(3 * (glyph.indices.items.len - glyph.curve_count)),
        };
    }

    pub fn deinit(self: *GlyphObject, device: vk.Device) void {
        vk.destroyBuffer(device, self.index_buffer, null);
        vk.destroyBuffer(device, self.vertex_buffer, null);
        vk.freeMemory(device, self.memory, null);
        self.* = std.mem.zeroes(GlyphObject);
    }
};

const shader = struct {
    const slang align(4) = @embedFile("shader.slang").*;
    const _ = std.debug.assert(slang.len % 4 == 0);

    const entries = struct {
        const vertMain = "vertMain";
        const curveMain = "curveMain";
        const solidMain = "solidMain";
    };
};


pub fn setChar(self: *Appli, char: u32) !void {
    const entry = try (self.glyph_objects.getOrPut(helpers.allocator, char));

    if (!entry.found_existing) {
        const glyph = try self.font.getGlyph(char);
        var triangle_glyph: TriangulatedGlyph = .init(glyph);
        defer triangle_glyph.deinit();

        var glyph_object: GlyphObject = try .init(self.vk_ctx, triangle_glyph);
        errdefer glyph_object.deinit(self.vk_ctx.device);

        entry.value_ptr.* = .{ .glyph_object = glyph_object, .box = glyph.box };
    }

    const transform = self.getTransform(entry.value_ptr.box);
    helpers.ensureAlloc(entry.value_ptr.transforms.append(helpers.allocator, transform));
    helpers.ensureAlloc(self.total_transforms.ensureUnusedCapacity(helpers.allocator, 1));
    self.total_transforms.items.len += 1;
    self.transform_changed = true;
}

fn getTransform(self: *Appli, box: Font.Glyph.Box) Transform {
    _ = self; _ = box;
    return .{};
}

fn updateTotalTransforms(self: *Appli) void {
    var index: usize = 0;
    for (self.glyph_objects.values()) |v| {
        for (v.transforms.items) |local| {
            self.total_transforms.items[index] = combineTransfrom(local, self.global_transform);
            index += 1;
        }
    }
}

fn combineTransfrom(local: Transform, global: Transform) Transform {
    return .{
        .scale = local.scale * global.scale,
        .offset = .{
            local.offset[0] * global.scale + global.offset[0],
            local.offset[1] * global.scale + global.offset[1],
        },
    };
}


fn cursorPosition(self: *Appli) Point(f32) {
    if (self.frame_count != self.cursor_pos_last_update_frame) self.cursor_pos = self.vk_ctx.getCursor();
    return self.cursor_pos;
}

pub const zoom_factor = 1.15;
fn zoom(self: *Appli) void {
    if (self.cb_ctx.scroll_accumulate == 0) return;
    const scroll = self.cb_ctx.scroll_accumulate;
    self.cb_ctx.scroll_accumulate = 0;

    const z = std.math.pow(f32, zoom_factor, @as(f32, @floatCast(scroll)));
    const cursor = self.vk_ctx.getCursor();
    self.global_transform.scale *= z;
    self.global_transform.offset[0] += (1 - z) * (cursor.x - self.global_transform.offset[0]);
    self.global_transform.offset[1] += (1 - z) * (cursor.y - self.global_transform.offset[1]);
    self.transform_changed = true;
}

fn drag(self: *Appli) void {
    if (!self.cb_ctx.dragding) {
        self.prev_cursor_pos = null;
        return;
    }

    const curr_pos = self.cursorPosition();
    if (self.prev_cursor_pos) |prev_pos| {
        const diff = curr_pos.sub(prev_pos);
        if (diff.x != 0 and diff.y != 0) {
            self.global_transform.offset[0] += diff.x;
            self.global_transform.offset[1] += diff.y;
            self.transform_changed = true;
        }
    }
    self.prev_cursor_pos = curr_pos;
}
