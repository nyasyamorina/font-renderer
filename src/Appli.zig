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
concave_pipeline: vk.Pipeline,
convex_pipeline: vk.Pipeline,
glyph_objects: std.ArrayList(GlyphObject) = .empty,


pub fn init(window_size: vk.Extent2D, window_title: [*:0]const u8) !Appli {
    if (glfw.init() != glfw.@"true") return error.@"failed to initialize glfw";
    errdefer glfw.terminate();

    var vk_ctx: VulkanContext = try .init(window_size, window_title);
    errdefer vk_ctx.deinit();

    const pipeline_layout = try vk_ctx.createPipelineLayout();
    errdefer vk.destroyPipelineLayout(vk_ctx.device, pipeline_layout, null);
    const concave_pipeline = try vk_ctx.createGraphicsPipeline(&shader.slang, shader.entries.vertMain, shader.entries.concaveMain, pipeline_layout);
    errdefer vk.destroyPipeline(vk_ctx.device, concave_pipeline, null);
    const convex_pipeline = try vk_ctx.createGraphicsPipeline(&shader.slang, shader.entries.vertMain, shader.entries.convexMain, pipeline_layout);
    errdefer vk.destroyPipeline(vk_ctx.device, convex_pipeline, null);

    return .{
        .vk_ctx = vk_ctx,
        .general_pipeline_layout = pipeline_layout,
        .concave_pipeline = concave_pipeline,
        .convex_pipeline = convex_pipeline,
    };
}

pub fn deinit(self: *Appli) void {
    for (self.glyph_objects.items) |*obj| obj.deinit(self.vk_ctx.device);
    self.glyph_objects.deinit(helpers.allocator);

    vk.destroyPipeline(self.vk_ctx.device, self.convex_pipeline, null);
    vk.destroyPipeline(self.vk_ctx.device, self.concave_pipeline, null);
    vk.destroyPipelineLayout(self.vk_ctx.device, self.general_pipeline_layout, null);
    self.vk_ctx.deinit();
    glfw.terminate();
}

pub fn mainLoop(self: *Appli) !void {
    try self.vk_ctx.startMainLoop(renderingFunc, @ptrCast(self));
}

pub fn renderingFunc(data: ?*anyopaque, command_buffer: vk.CommandBuffer) !void {
    const self: *const Appli = @ptrCast(@alignCast(data.?));

    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.concave_pipeline);
    for (self.glyph_objects.items) |obj| {
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &obj.vertex_buffer.vk, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, obj.concave_index_buffer.vk, 0, vk.index_type_uint16);
        vk.cmdDrawIndexed(command_buffer, obj.concave_index_buffer.count, 1, 0, 0, 0);
    }

    vk.cmdBindPipeline(command_buffer, vk.pipeline_bind_point_graphics, self.convex_pipeline);
    for (self.glyph_objects.items) |obj| {
        vk.cmdBindVertexBuffers(command_buffer, 0, 1, &obj.vertex_buffer.vk, &@as(u64, 0));
        vk.cmdBindIndexBuffer(command_buffer, obj.convex_index_buffer.vk, 0, vk.index_type_uint16);
        vk.cmdDrawIndexed(command_buffer, obj.convex_index_buffer.count, 1, 0, 0, 0);
    }
}

pub const GlyphObject = struct {
    memory: vk.DeviceMemory,
    vertex_buffer: Buffer,
    concave_index_buffer: Buffer,
    convex_index_buffer: Buffer,

    pub const Buffer = struct {
        vk: vk.Buffer,
        size: usize,
        memory_offset: u64,
        count: u32,
    };

    pub fn init(ctx: VulkanContext, glyph: TriangulatedGlyph, scale: f32) !GlyphObject {
        const sizes: [3]u64 = .{
            @sizeOf(TriangulatedGlyph.Vertex) * glyph.vertices.len,
            @sizeOf([3]u16) * glyph.concave_indices.len,
            @sizeOf([3]u16) * glyph.convex_indices.len,
        };
        const buf_usages: [3]vk.BufferUsageFlags = .{
            vk.buffer_usage_transfer_dst_bit | vk.buffer_usage_vertex_buffer_bit,
            vk.buffer_usage_transfer_dst_bit | vk.buffer_usage_index_buffer_bit,
            vk.buffer_usage_transfer_dst_bit | vk.buffer_usage_index_buffer_bit,
        };
        const mem_prop = vk.memory_property_device_local_bit;

        // create staging buffers
        const staging_usages = ([1]vk.BufferUsageFlags {vk.buffer_usage_transfer_src_bit}) ** 3;
        const staging_mem_prop = vk.memory_property_host_coherent_bit | vk.memory_property_host_visible_bit;
        var staging_bufs: [3]vk.Buffer = undefined;
        var offsets: [3]u64 = undefined;
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
            for (glyph.vertices, vertices[0 .. glyph.vertices.len]) |src, *dst| dst.* = .{
                .position = .{ .x = scale * src.position.x, .y = scale * src.position.y },
                .tex_coord = src.tex_coord,
            };

            const concave_indices: [*]align(1) [3]u16 = @ptrCast(&data.?[offsets[1]]);
            @memcpy(concave_indices, glyph.concave_indices);

            const convex_indices: [*]align(1) [3]u16 = @ptrCast(&data.?[offsets[2]]);
            @memcpy(convex_indices, glyph.convex_indices);
        }

        // create actual buffers
        var bufs: [3]vk.Buffer = undefined;
        const mem, _ = try ctx.createBuffers(&sizes, &buf_usages, mem_prop, &bufs, &offsets);
        errdefer {
            vk.freeMemory(ctx.device, mem, null);
            for (bufs) |buf| vk.destroyBuffer(ctx.device, buf, null);
        }

        // copy data from staging buffers to actual buffers
        try ctx.copyBuffers(&staging_bufs, &bufs, &sizes);

        return .{
            .memory = mem,
            .vertex_buffer = .{
                .vk = bufs[0],
                .size = @intCast(sizes[0]),
                .memory_offset = offsets[0],
                .count = @intCast(glyph.vertices.len),
            },
            .concave_index_buffer = .{
                .vk = bufs[1],
                .size = @intCast(sizes[1]),
                .memory_offset = offsets[1],
                .count = @intCast(3 * glyph.concave_indices.len),
            },
            .convex_index_buffer = .{
                .vk = bufs[2],
                .size = @intCast(sizes[2]),
                .memory_offset = offsets[2],
                .count = @intCast(3 * glyph.convex_indices.len),
            },
        };
    }

    pub fn deinit(self: *GlyphObject, device: vk.Device) void {
        vk.freeMemory(device, self.memory, null);
        vk.destroyBuffer(device, self.vertex_buffer.vk, null);
        vk.destroyBuffer(device, self.concave_index_buffer.vk, null);
        vk.destroyBuffer(device, self.convex_index_buffer.vk, null);
        self.* = std.mem.zeroes(GlyphObject);
    }
};


const shader = struct {
    const slang align(4) = @embedFile("shader.slang").*;
    const _ = std.debug.assert(slang.len % 4 == 0);

    const entries = struct {
        const vertMain = "vertMain";
        const concaveMain = "concaveMain";
        const convexMain = "convexMain";
    };
};

