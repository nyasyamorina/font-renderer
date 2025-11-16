const std = @import("std");

const Appli = @This();
const helpers = @import("helpers.zig");
const Font = @import("font/Font.zig");
const TriangulatedGlyph = @import("tools/TriangulatedGlyph.zig");
const glfw = @import("c/glfw.zig");
const vk = @import("c/vk.zig");
const VulkanContext = @import("VulkanContext.zig");

const ensureAlloc = helpers.ensureAlloc;
const ensureVkSuccess = helpers.ensureVkSuccess;


vk_ctx: VulkanContext,
general_pipeline_layout: vk.PipelineLayout,
curve_pipeline: vk.Pipeline,
solid_pipeline: vk.Pipeline,
glyph_objects: std.ArrayList(GlyphObject) = .empty,


pub fn init(window_size: vk.Extent2D, window_title: [*:0]const u8) !Appli {
    if (glfw.init() != glfw.@"true") return error.@"failed to initialize glfw";
    errdefer glfw.terminate();

    var vk_ctx: VulkanContext = try .init(window_size, window_title);
    errdefer vk_ctx.deinit();

    const pipeline_layout = try vk_ctx.createPipelineLayout();
    errdefer vk.destroyPipelineLayout(vk_ctx.device, pipeline_layout, null);
    const curve_pipeline = try vk_ctx.createGraphicsPipeline(&shader.slang, shader.entries.vertMain, shader.entries.curveMain, pipeline_layout);
    errdefer vk.destroyPipeline(vk_ctx.device, curve_pipeline, null);
    const solid_pipeline = try vk_ctx.createGraphicsPipeline(&shader.slang, shader.entries.vertMain, shader.entries.solidMain, pipeline_layout);
    errdefer vk.destroyPipeline(vk_ctx.device, solid_pipeline, null);

    return .{
        .vk_ctx = vk_ctx,
        .general_pipeline_layout = pipeline_layout,
        .curve_pipeline = curve_pipeline,
        .solid_pipeline = solid_pipeline,
    };
}

pub fn deinit(self: *Appli) void {
    for (self.glyph_objects.items) |*obj| obj.deinit(self.vk_ctx.device);
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
    const self: *const Appli = @ptrCast(@alignCast(data.?));

    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.curve_pipeline);
    for (self.glyph_objects.items) |obj| {
        if (obj.curve_count == 0) continue;
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &obj.vertex_buffer, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, obj.index_buffer, 0, vk.index_type_uint16);
        vk.cmdDrawIndexed(command_buffer, obj.curve_count, 1, 0, 0, 0);
    }

    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.solid_pipeline);
    for (self.glyph_objects.items) |obj| {
        if (obj.solid_count == 0) continue;
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &obj.vertex_buffer, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, obj.index_buffer, 0, vk.index_type_uint16);
        vk.cmdDrawIndexed(command_buffer, obj.solid_count, 1, obj.curve_count, 0, 0);
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

