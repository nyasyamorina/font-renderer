const std = @import("std");

const Appli = @This();
const CallbackContext = @import("CallbackContext.zig");
const CacheManager = @import("CacheManager.zig");
const Config = @import("Config.zig");
const helpers = @import("helpers.zig");
const Font = @import("font/Font.zig");
const Point = @import("tools/geometry.zig").Point;
const TriangulatedGlyph = @import("tools/TriangulatedGlyph.zig");
const glfw = @import("c/glfw.zig");
const vk = @import("c/vk.zig");
const VulkanContext = @import("VulkanContext.zig");

const ensureVkSuccess = helpers.ensureVkSuccess;


font: *Font,
cb_ctx: *CallbackContext,
vk_ctx: VulkanContext,
cc_mng: CacheManager,
use_debug_shader: bool,
general_pipeline_layout: vk.PipelineLayout,
concave_pipeline: vk.Pipeline = null,
convex_pipeline: vk.Pipeline = null,
solid_pipeline: vk.Pipeline = null,
view_transform: ViewTransform,
transform_changed: bool = false,
glyph_objects: std.AutoArrayHashMapUnmanaged(u32, GlyphMapValue) = .empty,
total_transforms: std.ArrayList(Transform) = .empty,
frame_count: usize = 0,
cursor_pos: Point(f32) = .{ .x = 0, .y = 0 },
cursor_pos_last_update_frame: usize = 0,
prev_cursor_pos: ?Point(f32) = null,
curr_em_pos: f32 = 0,


const Transform = extern struct {
    scale: [2]f32 align(8) = .{1, 1},
    offset: [2]f32 align(8) = .{0, 0},

    fn init(scale: f32, offset: [2]f32) Transform {
        return .{ .scale = .{scale, scale}, .offset = offset };
    }
};
const ViewTransform = struct {
    global: Transform,
    aspect_ratio: f32,

    fn init(font_unit_per_em: u16, surface_extent: vk.Extent2D) ViewTransform {
        const scale = 1 / @as(f32, @floatFromInt(font_unit_per_em));
        const width: f32 = @floatFromInt(surface_extent.width);
        const height: f32 = @floatFromInt(surface_extent.height);
        return .{
            .global = .{
                .scale = .{scale, scale},
                .offset = .{-0.25, -0.25},
            },
            .aspect_ratio = width / height,
        };
    }

    fn combineWith(self: ViewTransform, local: Transform) Transform {
        return .{
            .scale = .{
                (local.scale[0] * self.global.scale[0]),
                (local.scale[1] * self.global.scale[1]) * self.aspect_ratio,
            },
            .offset = .{
                (local.offset[0] * self.global.scale[0] + self.global.offset[0]),
                (local.offset[1] * self.global.scale[1] + self.global.offset[1]) * self.aspect_ratio,
            },
        };
    }

    fn applyTo(self: ViewTransform, p: Point(f32)) Point(f32) {
        return .{
            .x = (p.x * self.global.scale[0] + self.global.offset[0]),
            .y = (p.y * self.global.scale[1] + self.global.offset[1]) * self.aspect_ratio,
        };
    }

    fn undoFrom(self: ViewTransform, p: Point(f32)) Point(f32) {
        return .{
            .x = (p.x                     - self.global.offset[0]) / self.global.scale[0],
            .y = (p.y / self.aspect_ratio - self.global.offset[1]) / self.global.scale[1],
        };
    }
};

const GlyphMapValue = struct {
    glyph_object: GlyphObject,
    box: Font.Glyph.Box,
    advance_width: i16,
    transforms: std.ArrayList(Transform) = .empty,
};

pub fn init(font: *Font, cb_ctx: *CallbackContext, window_size: vk.Extent2D, window_title: [*:0]const u8, config: *const Config) !Appli {
    if (glfw.init() != glfw.@"true") return error.@"failed to initialize glfw";
    errdefer glfw.terminate();

    var vk_ctx: VulkanContext = try .init(cb_ctx, window_size, window_title);
    errdefer vk_ctx.deinit();
    var cc_mng: CacheManager = try .init(config.enable_cache.value orelse false);
    errdefer cc_mng.deinit(vk_ctx.device);

    const pipeline_layout = try vk_ctx.createPipelineLayout(Transform);
    errdefer vk.destroyPipelineLayout(vk_ctx.device, pipeline_layout, null);
    var self: Appli = .{
        .font = font,
        .cb_ctx = cb_ctx,
        .cc_mng = cc_mng,
        .vk_ctx = vk_ctx,
        .use_debug_shader = config.debug_shader.value orelse false,
        .general_pipeline_layout = pipeline_layout,
        .view_transform = .init(font.information.units_per_em, vk_ctx.surface_info.extent),
    };

    try self.createGraphicsPipelines();
    return self;
}

pub fn deinit(self: *Appli) void {
    self.total_transforms.deinit(helpers.allocator);

    for (self.glyph_objects.values()) |*v| {
        v.glyph_object.deinit(self.vk_ctx.device);
        v.transforms.deinit(helpers.allocator);
    }
    self.glyph_objects.deinit(helpers.allocator);

    self.destroyGraphicsPipelines();
    vk.destroyPipelineLayout(self.vk_ctx.device, self.general_pipeline_layout, null);

    self.cc_mng.deinit(self.vk_ctx.device);
    self.vk_ctx.deinit();
    glfw.terminate();
}

pub fn mainLoop(self: *Appli) !void {
    try self.vk_ctx.startMainLoop(self);
}


pub fn renderingFn(self: *Appli, command_buffer: vk.CommandBuffer) !void {
    self.frame_count +%= 1;

    self.applyAspectRatio();
    self.zoom();
    self.drag();
    if (self.transform_changed) {
        self.transform_changed = false;
        self.updateTotalTransforms();
    }
    //helpers.timer.report("transform_changed");

    var index: usize = 0;
    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.concave_pipeline);
    self.vk_ctx.setGraphicsPipelineDynamicStuff(command_buffer);
    for (self.glyph_objects.values()) |v| {
        const range = v.glyph_object.concave;
        if (range.len == 0) {
            index += v.transforms.items.len;
            continue;
        }
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &v.glyph_object.vertex_buffer, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, v.glyph_object.index_buffer, 0, vk.index_type_uint16);
        for (v.transforms.items) |_| {
            const total_transform = &self.total_transforms.items[index];
            index += 1;

            vk.cmdPushConstants(command_buffer, self.general_pipeline_layout, vk.shader_stage_vertex_bit, 0, @sizeOf(Transform), total_transform);
            vk.cmdDrawIndexed(command_buffer, range.len, 1, range.start, 0, 0);
        }
    }

    index = 0;
    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.convex_pipeline);
    self.vk_ctx.setGraphicsPipelineDynamicStuff(command_buffer);
    for (self.glyph_objects.values()) |v| {
        const range = v.glyph_object.convex;
        if (range.len == 0) {
            index += v.transforms.items.len;
            continue;
        }
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &v.glyph_object.vertex_buffer, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, v.glyph_object.index_buffer, 0, vk.index_type_uint16);
        for (v.transforms.items) |_| {
            const total_transform = &self.total_transforms.items[index];
            index += 1;

            vk.cmdPushConstants(command_buffer, self.general_pipeline_layout, vk.shader_stage_vertex_bit, 0, @sizeOf(Transform), total_transform);
            vk.cmdDrawIndexed(command_buffer, range.len, 1, range.start, 0, 0);
        }
    }

    index = 0;
    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.solid_pipeline);
    self.vk_ctx.setGraphicsPipelineDynamicStuff(command_buffer);
    for (self.glyph_objects.values()) |v| {
        const range = v.glyph_object.solid;
        if (range.len == 0) {
            index += v.transforms.items.len;
            continue;
        }
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &v.glyph_object.vertex_buffer, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, v.glyph_object.index_buffer, 0, vk.index_type_uint16);
        for (v.transforms.items) |_| {
            const total_transform = &self.total_transforms.items[index];
            index += 1;

            vk.cmdPushConstants(command_buffer, self.general_pipeline_layout, vk.shader_stage_vertex_bit, 0, @sizeOf(Transform), total_transform);
            vk.cmdDrawIndexed(command_buffer, range.len, 1, range.start, 0, 0);
        }
    }
    //helpers.timer.report("cmdDrawIndexed");
}

pub const GlyphObject = struct {
    memory: vk.DeviceMemory,
    vertex_buffer: vk.Buffer,
    index_buffer: vk.Buffer,
    concave: IndicesRange,
    convex: IndicesRange,
    solid: IndicesRange,

    const IndicesRange = struct {
        start: u32,
        len: u32,
    };

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
            .concave = .{
                .start = 0,
                .len = 3 * @as(u32, glyph.concave_count),
            },
            .convex = .{
                .start = 3 * @as(u32, glyph.concave_count),
                .len = 3 * @as(u32, glyph.convex_count),
            },
            .solid = .{
                .start = 3 * @as(u32, glyph.concave_count + glyph.convex_count),
                .len = 3 * @as(u32, glyph.solid_count),
            }
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
    const normal align(4) = @embedFile("shader.slang").*;
    const debug align(4) = @embedFile("debug.slang").*;
    const _ = std.debug.assert(normal.len % 4 == 0 and debug.len % 4 == 0);

    const entries = struct {
        const vertMain = "vertMain";
        const concaveMain = "concaveMain";
        const convexMain = "convexMain";
        const solidMain = "solidMain";
    };
};


pub fn addChar(self: *Appli, char: u32) !void {
    const entry = try (self.glyph_objects.getOrPut(helpers.allocator, char));

    if (!entry.found_existing) {
        const glyph = try self.font.getGlyph(char);
        var triangle_glyph: TriangulatedGlyph = .init(glyph.@"0");
        defer triangle_glyph.deinit();

        var glyph_object: GlyphObject = try .init(self.vk_ctx, triangle_glyph);
        errdefer glyph_object.deinit(self.vk_ctx.device);

        entry.value_ptr.* = .{
            .glyph_object = glyph_object,
            .box = glyph.@"0".box,
            .advance_width = glyph.@"1",
        };
    }

    const transform = self.getTransform(char);
    helpers.ensureAlloc(entry.value_ptr.transforms.append(helpers.allocator, transform));
    helpers.ensureAlloc(self.total_transforms.ensureUnusedCapacity(helpers.allocator, 1));
    self.total_transforms.items.len += 1;
    self.transform_changed = true;
}

fn getTransform(self: *Appli, char: u32) Transform {
    const curr_em_pos = self.curr_em_pos;
    const transform: Transform = .{ .offset = .{curr_em_pos, 0} };

    const value = self.glyph_objects.get(char).?;
    self.curr_em_pos += @floatFromInt(value.advance_width);

    return transform;
}

fn updateTotalTransforms(self: *Appli) void {
    var index: usize = 0;
    for (self.glyph_objects.values()) |v| {
        for (v.transforms.items) |local| {
            self.total_transforms.items[index] = self.view_transform.combineWith(local);
            index += 1;
        }
    }
}


fn applyAspectRatio(self: *Appli) void {
    if (!self.vk_ctx.changed_extent) return;
    self.view_transform.aspect_ratio = @as(f32, @floatFromInt(self.vk_ctx.surface_info.extent.width)) / @as(f32, @floatFromInt(self.vk_ctx.surface_info.extent.height));
    self.transform_changed = true;
    self.vk_ctx.changed_extent = false;
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

    const scale = std.math.pow(f32, zoom_factor, @as(f32, @floatCast(scroll)));
    const cursor = self.vk_ctx.getCursor();
    const zoom_center = self.view_transform.undoFrom(cursor);

    self.view_transform.global.offset[0] += self.view_transform.global.scale[0] * (1 - scale) * zoom_center.x;
    self.view_transform.global.offset[1] += self.view_transform.global.scale[1] * (1 - scale) * zoom_center.y;
    self.view_transform.global.scale[0] *= scale; self.view_transform.global.scale[1] *= scale;
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
        if (diff.x != 0 or diff.y != 0) { // ? values near to 0 also cause this cond to be false ?
            self.view_transform.global.offset[0] += diff.x;
            self.view_transform.global.offset[1] += diff.y / self.view_transform.aspect_ratio;
            self.transform_changed = true;
        }
    }
    self.prev_cursor_pos = curr_pos;
}


fn createGraphicsPipelines(self: *Appli) !void {
    const shader_code = if (self.use_debug_shader) &shader.debug else &shader.normal;

    const concave_cache = self.cc_mng.getPipelineCache(self.vk_ctx.device, .concave);
    self.concave_pipeline = try self.vk_ctx.createGraphicsPipeline(concave_cache, shader_code, shader.entries.vertMain, shader.entries.concaveMain, self.general_pipeline_layout);
    errdefer vk.destroyPipeline(self.vk_ctx.device, self.concave_pipeline, null);
    self.cc_mng.updatePipelineCache(self.vk_ctx.device, .concave);

    const convex_cache = self.cc_mng.getPipelineCache(self.vk_ctx.device, .convex);
    self.convex_pipeline = try self.vk_ctx.createGraphicsPipeline(convex_cache, shader_code, shader.entries.vertMain, shader.entries.convexMain, self.general_pipeline_layout);
    errdefer vk.destroyPipeline(self.vk_ctx.device, self.convex_pipeline, null);
    self.cc_mng.updatePipelineCache(self.vk_ctx.device, .convex);

    const solid_cache = self.cc_mng.getPipelineCache(self.vk_ctx.device, .solid);
    self.solid_pipeline = try self.vk_ctx.createGraphicsPipeline(solid_cache, shader_code, shader.entries.vertMain, shader.entries.solidMain, self.general_pipeline_layout);
    errdefer vk.destroyPipeline(self.vk_ctx.device, self.solid_pipeline, null);
    self.cc_mng.updatePipelineCache(self.vk_ctx.device, .solid);
}

fn destroyGraphicsPipelines(self: *Appli) void {
    vk.destroyPipeline(self.vk_ctx.device, self.concave_pipeline, null);
    self.concave_pipeline = null;
    vk.destroyPipeline(self.vk_ctx.device, self.convex_pipeline, null);
    self.convex_pipeline = null;
    vk.destroyPipeline(self.vk_ctx.device, self.solid_pipeline, null);
    self.solid_pipeline = null;
}

pub fn recreateGraphicsPipelines(self: *Appli) !void {
    self.destroyGraphicsPipelines();
    try self.createGraphicsPipelines();
}
