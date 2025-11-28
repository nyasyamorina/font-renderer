const builtin = @import("builtin");
const std = @import("std");

const glfw = @import("c/glfw.zig");
const vk = @import("c/vk.zig");
const helpers = @import("helpers.zig");

const VulkanContext = @This();
const Appli = @import("Appli.zig");
const CallbackContext = @import("CallbackContext.zig");
const Point = @import("tools/geometry.zig").Point;
const Vertex = @import("tools/TriangulatedGlyph.zig").Vertex;
const log = std.log.scoped(.VulkanContext);
const ensureAlloc = helpers.ensureAlloc;
const ensureVkSuccess = helpers.ensureVkSuccess;


cb_ctx: *CallbackContext,
window: ?*glfw.Window = null,
cursor: ?*glfw.Cursor = null,
instance: vk.Instance = null,
debug_messenger: vk.DebugUtilsMessengerEXT = null,
surface: vk.SurfaceKHR = null,
physical_device: vk.PhysicalDevice = null,
msaa_sample_count: vk.SampleCountFlagBits = vk.sample_count_1_bit,
sample_shading: bool = false,
color_image: vk.Image = null,
color_image_view: vk.ImageView = null,
color_image_memory: vk.DeviceMemory = null,
color_attachment_info: vk.RenderingAttachmentInfo = .{},
device_memory_types: []vk.MemoryType = &.{},
device: vk.Device = null,
queue_families: QueueFamilies = undefined,
queues: Queues = .{},
command_pools: CommandPools = .{},
surface_info: SurfaceInfo = undefined,
use_transparent_background: bool = false,
swapchain: vk.SwapchainKHR = null,
swapchain_images: std.ArrayList(vk.Image) = .empty,
swapchain_image_views: std.ArrayList(vk.ImageView) = .empty,
swapchain_operations: SwapchainOperations = undefined,
command_buffers: [max_frames_in_flight]vk.CommandBuffer = undefined,
in_flight_fences: [max_frames_in_flight]vk.Fence = undefined,
in_flight_frame: u32 = 0,
changed_extent: bool = false,


pub const max_frames_in_flight = 2;


pub fn init(cb_ctx: *CallbackContext, window_size: vk.Extent2D, window_title: [*:0]const u8) !VulkanContext {
    var self: VulkanContext = .{ .cb_ctx = cb_ctx };
    self.color_attachment_info = .{
        .sType = helpers.vkSType(vk.RenderingAttachmentInfo),
        .imageLayout = vk.image_layout_color_attachment_optimal,
        .resolveImageLayout = vk.image_layout_color_attachment_optimal,
        .loadOp = vk.attachment_load_op_clear,
        .storeOp = vk.attachment_store_op_store,
        .clearValue = .{ .color = .{ .float32 = .{0, 0, 0, 0} } },
    };

    try self.createWindow(window_size, window_title);
    errdefer glfw.destroyWindow(self.window);
    try self.createInstanceAndDebugMessenger(window_title);
    errdefer self.destroyInstanceAndDebugMessenger();
    try ensureVkSuccess("glfwCreateWindowSurface", glfw.createWindowSurface(self.instance, self.window, null, &self.surface));
    errdefer vk.destroySurfaceKHR(self.instance, self.surface, null);
    try self.pickAndCreateDevice();
    errdefer self.destroyDeviceAndInfo();
    self.command_pools = try .init(self.device, self.queue_families);
    errdefer self.command_pools.deinit(self.device);
    try self.createSwapchainStuff(.{});
    errdefer self.destroySwapchainStuff(true);
    self.swapchain_operations = try .init(self.device, self.swapchain_image_views.items.len, 1);
    errdefer self.swapchain_operations.deinit(self.device);
    try self.createRenderingObjects();
    errdefer self.destroyRenderingObjects();

    return self;
}

pub fn deinit(self: *VulkanContext) void {
    self.destroyMsaaStuff();
    self.destroyRenderingObjects();
    self.swapchain_operations.deinit(self.device);
    self.destroySwapchainStuff(true);
    self.command_pools.deinit(self.device);
    self.destroyDeviceAndInfo();
    vk.destroySurfaceKHR(self.instance, self.surface, null);
    self.destroyInstanceAndDebugMessenger();
    glfw.destroyCursor(self.cursor);
    glfw.destroyWindow(self.window);
}

pub fn startMainLoop(self: *VulkanContext, appli: *Appli) !void {
    defer _ = vk.deviceWaitIdle(self.device);
    while (glfw.windowShouldClose(self.window) == vk.@"false") : (self.in_flight_frame = (self.in_flight_frame + 1) % max_frames_in_flight) {
        if (self.cb_ctx.esc_pressed) glfw.setWindowShouldClose(self.window, glfw.@"true");
        if (self.surface_info.extent.width == 0 or self.surface_info.extent.height == 0) {
            var w: c_int = 0; var h: c_int = 0;
            while (w == 0 or h == 0) {
                glfw.getFramebufferSize(self.window, &w, &h);
                glfw.waitEvents();
            }
            try self.recreateSwapchainStuff(.{ .update_extent = true });
            continue;
        }

        //helpers.timer.restart();
        glfw.pollEvents();
        //helpers.timer.report("glfw.pollEvents");

        var update_pipeline = false;
        if (self.cb_ctx.change_msaa) blk: {
            self.cb_ctx.change_msaa = false;
            _ = vk.deviceWaitIdle(self.device);
            if (self.msaaRenderingEnabled()) {
                self.disableMsaaRendering();
            } else if (self.msaa_sample_count == vk.sample_count_1_bit) {
                log.warn("anisotropy sampling is not available on this device, msaa disabled", .{});
                break :blk;
            } else {
                self.enableMsaaRendering() catch |err| {
                    log.err("failed to enabling msaa: {t}", .{err});
                    self.disableMsaaRendering();
                    break :blk;
                };
            }
            update_pipeline = true;
        }
        if (self.cb_ctx.change_shader) {
            self.cb_ctx.change_shader = false;
            appli.use_debug_shader = !appli.use_debug_shader;
            log.debug("switching shader", .{});
            update_pipeline = true;
        }
        if (update_pipeline) {
            _ = vk.deviceWaitIdle(self.device);
            try appli.recreateGraphicsPipelines();
            //helpers.timer.report("recreateGraphicsPipelines");
        }

        const current_fence = self.in_flight_fences[self.in_flight_frame];
        try ensureVkSuccess("vkWaitForFences", vk.waitForFences(self.device, 1, &current_fence, vk.@"true", std.math.maxInt(u64)));
        //helpers.timer.report("vk.waitForFences");

        const acquire_result = self.swapchain_operations.acquireNextImage(self.device, self.swapchain, null, null);
        switch (acquire_result.result) {
            vk.success, vk.suboptimal_KHR => {},
            vk.error_out_of_date_KHR => {
                try self.recreateSwapchainStuff(.{ .update_extent = true });
                continue;
            },
            else => {
                std.log.scoped(.vk).err("unexpected result {d} returned from {s}", .{acquire_result.result, "vkAcquireNextImageKHR"});
                return error.VkNotSuccess;
            },
        }
        //helpers.timer.report("acquireNextImage");

        const current_command_buffer = self.command_buffers[self.in_flight_frame];
        try ensureVkSuccess("vkResetCommandBuffer", vk.resetCommandBuffer(current_command_buffer, 0));
        try ensureVkSuccess("vkResetFences", vk.resetFences(self.device, 1, &current_fence));

        try self.beginRendering(current_command_buffer, acquire_result.image_index);
        //helpers.timer.report("beginRendering");
        try appli.renderingFn(current_command_buffer);
        try self.endRendering(current_command_buffer, acquire_result.image_index);
        //helpers.timer.report("endRendering");

        try ensureVkSuccess("vkQueueSubmit", vk.queueSubmit(self.queues.graphics, 1, &.{
            .sType = vk.structure_type_submit_info,
            .commandBufferCount = 1,
            .pCommandBuffers = &current_command_buffer,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &acquire_result.acquire_semaphore,
            .pWaitDstStageMask = &@as(u32, vk.pipeline_stage_color_attachment_output_bit),
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &acquire_result.present_wait_semaphores[0],
        }, current_fence));

        const present_result = self.swapchain_operations.present(self.queues.present, self.swapchain, acquire_result);
        //helpers.timer.report("present");
        var recreate_swapchain = false;
        var recreate_swapchain_opts: CreateSwapchainStuffOptions = .{};
        switch (present_result) {
            vk.success => {
                if (self.cb_ctx.change_transparent) {
                    self.cb_ctx.change_transparent = false;
                    self.use_transparent_background = !self.use_transparent_background;
                    log.debug("switching background transparence", .{});
                    recreate_swapchain = true;
                }
                if (self.cb_ctx.resized) {
                    recreate_swapchain = true;
                    recreate_swapchain_opts.update_extent = true;
                }
            },
            vk.suboptimal_KHR, vk.error_out_of_date_KHR => {
                recreate_swapchain = true;
                recreate_swapchain_opts.update_extent = true;
            },
            else => {
                std.log.scoped(.vk).err("unexpected result {d} returned from {s}", .{acquire_result.result, "vkQueuePresentKHR"});
                return error.VkNotSuccess;
            },
        }
        if (recreate_swapchain){
            try self.recreateSwapchainStuff(recreate_swapchain_opts);
            //helpers.timer.report("recreateSwapchainStuff");
        }
    }
}

fn beginRendering(self: *VulkanContext, command_buffer: vk.CommandBuffer, swapchain_image_index: u32) !void {
    try ensureVkSuccess("vkBeginCommandBuffer", vk.beginCommandBuffer(command_buffer, &.{ .sType = helpers.vkSType(vk.CommandBufferBeginInfo) }));

    vk.cmdPipelineBarrier2(command_buffer, &.{
        .sType = helpers.vkSType(vk.DependencyInfo),
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &.{
            .sType = helpers.vkSType(vk.ImageMemoryBarrier2),
            .srcStageMask = vk.pipeline_stage_2_top_of_pipe_bit,
            .dstStageMask = vk.pipeline_stage_2_color_attachment_output_bit,
            .srcAccessMask = 0,
            .dstAccessMask = vk.access_2_color_attachment_write_bit,
            .image = self.swapchain_images.items[swapchain_image_index],
            .oldLayout = vk.image_layout_undefined,
            .newLayout = vk.image_layout_color_attachment_optimal,
            .srcQueueFamilyIndex = vk.queue_family_ignored,
            .dstQueueFamilyIndex = vk.queue_family_ignored,
            .subresourceRange = .{
                .aspectMask = vk.image_aspect_color_bit,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        },
    });

    const swapchain_image_view = self.swapchain_image_views.items[swapchain_image_index];
    if (self.msaaRenderingEnabled()) {
        self.color_attachment_info.resolveImageView = swapchain_image_view;
    } else {
        self.color_attachment_info.imageView = swapchain_image_view;
    }
    vk.cmdBeginRendering(command_buffer, &.{
        .sType = helpers.vkSType(vk.RenderingInfo),
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.surface_info.extent,
        },
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &self.color_attachment_info,
    });
}

fn endRendering(self: VulkanContext, command_buffer: vk.CommandBuffer, swapchain_image_index: u32) !void {
    vk.cmdEndRendering(command_buffer);

    vk.cmdPipelineBarrier2(command_buffer, &.{
        .sType = helpers.vkSType(vk.DependencyInfo),
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &.{
            .sType = helpers.vkSType(vk.ImageMemoryBarrier2),
            .srcStageMask = vk.pipeline_stage_2_color_attachment_output_bit,
            .dstStageMask = vk.pipeline_stage_2_bottom_of_pipe_bit,
            .srcAccessMask = vk.access_2_color_attachment_write_bit,
            .dstAccessMask = 0,
            .image = self.swapchain_images.items[swapchain_image_index],
            .oldLayout = vk.image_layout_color_attachment_optimal,
            .newLayout = vk.image_layout_present_src_KHR,
            .srcQueueFamilyIndex = vk.queue_family_ignored,
            .dstQueueFamilyIndex = vk.queue_family_ignored,
            .subresourceRange = .{
                .aspectMask = vk.image_aspect_color_bit,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        },
    });

    try ensureVkSuccess("vkEndCommandBuffer", vk.endCommandBuffer(command_buffer));
}

pub fn setGraphicsPipelineDynamicStuff(self: VulkanContext, command_buffer: vk.CommandBuffer) void {
    vk.cmdSetViewport(command_buffer, 0, 1, &.{
        .x = 0, .y = 0,
        .width = @floatFromInt(self.surface_info.extent.width), .height = @floatFromInt(self.surface_info.extent.height),
        .minDepth = 0, .maxDepth = 1,
    });
    vk.cmdSetScissor(command_buffer, 0, 1, &.{
        .extent = self.surface_info.extent,
        .offset = .{ .x = 0, .y = 0 },
    });
}


pub fn msaaRenderingEnabled(self: VulkanContext) bool {
    return self.color_attachment_info.resolveMode != 0;
}

pub fn enableMsaaRendering(self: *VulkanContext) !void {
    std.debug.assert(!self.msaaRenderingEnabled());
    log.debug("enabling msaa", .{});
    try self.createMsaaStuff();
    self.color_attachment_info.imageView = self.color_image_view;
    self.color_attachment_info.resolveMode = vk.resolve_mode_average_bit;
}

pub fn recreateMsaaStuff(self: *VulkanContext) !void {
    self.destroyMsaaStuff();
    if (self.msaaRenderingEnabled()) {
        try self.createMsaaStuff();
        self.color_attachment_info.imageView = self.color_image_view;
        self.color_attachment_info.resolveMode = vk.resolve_mode_average_bit;
    }
}

pub fn disableMsaaRendering(self: *VulkanContext) void {
    log.debug("disabling msaa", .{});
    self.destroyMsaaStuff();
    self.color_attachment_info.resolveImageView = null;
    self.color_attachment_info.resolveMode = 0;
}

fn createMsaaStuff(self: *VulkanContext) !void {
    errdefer self.destroyMsaaStuff();

    const info: Image2DInfo = .{
        .tiling = vk.image_tiling_optimal,
        .usage = vk.image_usage_transient_attachment_bit | vk.image_usage_color_attachment_bit,
        .aspects = vk.image_aspect_color_bit,
        .extent = self.surface_info.extent,
        .format = self.surface_info.format.format,
        .sample_count = self.msaa_sample_count,
    };
    self.color_image, self.color_image_memory = try self.createImage(info, vk.memory_property_device_local_bit);
    self.color_image_view = try self.createImageView(self.color_image, info);

    const command_buffer = try self.beginSingleTimeCommands();
    defer vk.freeCommandBuffers(self.device, self.command_pools.graphics, 1, &command_buffer);
    vk.cmdPipelineBarrier2(command_buffer, &.{
        .sType = helpers.vkSType(vk.DependencyInfo),
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &.{
            .sType = helpers.vkSType(vk.ImageMemoryBarrier2),
            .srcStageMask = vk.pipeline_stage_2_top_of_pipe_bit,
            .dstStageMask = vk.pipeline_stage_2_color_attachment_output_bit,
            .srcAccessMask = 0,
            .dstAccessMask = vk.access_2_color_attachment_write_bit,
            .image = self.color_image,
            .oldLayout = vk.image_layout_undefined,
            .newLayout = vk.image_layout_color_attachment_optimal,
            .srcQueueFamilyIndex = vk.queue_family_ignored,
            .dstQueueFamilyIndex = vk.queue_family_ignored,
            .subresourceRange = .{
                .aspectMask = vk.image_aspect_color_bit,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        },
    });
    try self.endSingleTimeCommands(command_buffer);
}

fn destroyMsaaStuff(self: *VulkanContext) void {
    if (self.color_image_view) |view| {vk.destroyImageView(self.device, view, null);}
    self.color_image_view = null;
    if (self.color_image_memory) |mem| vk.freeMemory(self.device, mem, null);
    self.color_image_memory = null;
    if (self.color_image) |im| vk.destroyImage(self.device, im, null);
    self.color_image = null;
}


fn createWindow(self: *VulkanContext, window_size: vk.Extent2D, window_title: [*:0]const u8) !void {
    glfw.windowHint(glfw.client_api, glfw.no_api);
    glfw.windowHint(glfw.resizable, glfw.@"true");
    glfw.windowHint(glfw.transparent_framebuffer, glfw.@"true");

    self.window = glfw.createWindow(@intCast(window_size.width), @intCast(window_size.height), window_title, null, null);
    if (self.window == null) return error.FailedToCreateWindow;

    glfw.setInputMode(self.window, glfw.cursor, glfw.cursor_normal);
    self.cursor = glfw.createStandardCursor(glfw.arrow_cursor);
    if (self.cursor == null) log.warn("failed to create standard cursor", .{});
    glfw.setCursor(self.window, self.cursor);

    glfw.setWindowUserPointer(self.window, @ptrCast(self.cb_ctx));
    _ = glfw.setFramebufferSizeCallback(self.window, &CallbackContext.resizeCallback);
    _ = glfw.setScrollCallback(self.window, &CallbackContext.scrollCallback);
    _ = glfw.setMouseButtonCallback(self.window, &CallbackContext.mouseButtonCallback);
    _ = glfw.setKeyCallback(self.window, &CallbackContext.keyCallback);
    _ = glfw.setCharCallback(self.window, &CallbackContext.charCallback);
}


fn createInstanceAndDebugMessenger(self: *VulkanContext, appli_name: [*:0]const u8) !void {
    // App Info
    const app_info: vk.ApplicationInfo = .{
        .sType = vk.structure_type_application_info,
        .pApplicationName = appli_name,
        .applicationVersion = vk.makeVersion(1, 0, 0),
        .pEngineName = "NoEngine",
        .engineVersion = vk.makeVersion(1, 0, 0),
        .apiVersion = vk.api_version_1_4,
    };

    // Instance extensions
    var extension_names: std.ArrayList([*c]const u8) = .empty;
    defer extension_names.deinit(helpers.allocator);

    var count: u32 = 0;
    const glfw_extensions = glfw.getRequiresInstanceExtensions(&count);
    ensureAlloc(extension_names.appendSlice(helpers.allocator, glfw_extensions[0..count]));

    if (builtin.target.os.tag == .macos) try extension_names.append(self.allocator, vk.KHR_portability_enumeration_extension_name);

    // Instance layers
    var layer_names: std.ArrayList([*c]const u8) = .empty;
    defer layer_names.deinit(helpers.allocator);

    // Debug stuff
    var debug_info: vk.DebugUtilsMessengerCreateInfoEXT = undefined;
    if (enabled_validation) {
        ensureAlloc(extension_names.append(helpers.allocator, vk.EXT_debug_utils_extension_name));
        ensureAlloc(layer_names.ensureUnusedCapacity(helpers.allocator, validation_layers.len));
        for (validation_layers) |layer| layer_names.appendAssumeCapacity(layer.ptr);
        debug_info = getDebugUtilsMessengerCreateInfoEXT();
    }

    // All extensions supported?
    var supported = true;
    if (extension_names.items.len > 0) {
        count = 0;
        try ensureVkSuccess("vkEnumerateInstanceExtensionProperties", vk.enumerateInstanceExtensionProperties(null, &count, null));
        const extensions_properties = helpers.alloc(vk.ExtensionProperties, count);
        defer helpers.allocator.free(extensions_properties);
        try ensureVkSuccess("vkEnumerateInstanceExtensionProperties", vk.enumerateInstanceExtensionProperties(null, &count, extensions_properties.ptr));

        for (extension_names.items) |extension_name| {
            for (extensions_properties) |properties| {
                if (std.mem.orderZ(u8, @ptrCast(extension_name), @ptrCast(&properties.extensionName)) == .eq) break;
            } else {
                log.err("not supported instance extension: {s}", .{extension_name});
                supported = false;
            }
        }
        if (!supported) return error.NotSupportAllInstanceExtensions;
    }

    // All layers supported?
    if (layer_names.items.len > 0) {
        count = 0;
        try ensureVkSuccess("vkEnumerateInstanceLayerProperties", vk.enumerateInstanceLayerProperties(&count, null));
        const layers_properties = helpers.alloc(vk.LayerProperties, count);
        defer helpers.allocator.free(layers_properties);
        try ensureVkSuccess("vkEnumerateInstanceLayerProperties", vk.enumerateInstanceLayerProperties(&count, layers_properties.ptr));

        for (layer_names.items) |layer_name| {
            for (layers_properties) |properties| {
                if (std.mem.orderZ(u8, @ptrCast(layer_name), @ptrCast(&properties.layerName)) == .eq) break;
            } else {
                log.err("not supported instance layer: {s}", .{layer_name});
                supported = false;
            }
        }
        if (!supported) return error.NotSupportAllInstanceLayers;
    }

    const instance_info: vk.InstanceCreateInfo = .{
        .sType = vk.structure_type_instance_craete_info,
        .pNext = if (enabled_validation) @ptrCast(&debug_info) else null,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = @intCast(extension_names.items.len),
        .ppEnabledExtensionNames = extension_names.items.ptr,
        .enabledLayerCount = @intCast(layer_names.items.len),
        .ppEnabledLayerNames = layer_names.items.ptr,
    };
    try ensureVkSuccess("vkCreateInstance", vk.createInstance(&instance_info, null, &self.instance));
    errdefer vk.destroyInstance(self.instance, null);

    if (enabled_validation) {
        const fn_create: vk.PFN_createDebugUtilsMessengerEXT = @ptrCast(vk.getInstanceProcAddr(self.instance, vk.name_createDebugUtilsMessengerEXT));
        if (fn_create) |create| {
            try ensureVkSuccess("vkCreateDebugUtilsMessengerEXT", create(self.instance, &debug_info, null, &self.debug_messenger));
        } else return error.FailedToGetInstanceProcAddr;
    }
}

fn destroyInstanceAndDebugMessenger(self: VulkanContext) void {
    if (enabled_validation) {
        const fn_destroy: vk.PFN_destroyDebugUtilsMessengerEXT = @ptrCast(vk.getInstanceProcAddr(self.instance, vk.name_destroyDebugUtilsMessengerEXT));
        if (fn_destroy) |destroy| destroy(self.instance, self.debug_messenger, null);
    }
    vk.destroyInstance(self.instance, null);
}

pub const enabled_validation = builtin.mode == .Debug;
pub const VkDebugLogger = if (enabled_validation) *std.Io.Writer else void;
const VkDebugMessenger = if (enabled_validation) vk.DebugUtilsMessengerEXT else void;

pub const validation_layers = [_][:0]const u8 {
    "VK_LAYER_KHRONOS_validation",
};

export fn vkDebugUtilsCallback(m_severity: vk.DebugUtilsMessageSeverityFlagBitsEXT, m_types: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: [*c]const vk.DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(.c) vk.Bool32 {
    if (!enabled_validation) return vk.@"false";

    const level = switch (m_severity) {
        vk.debug_utils_message_severity_error_bit_EXT => std.log.Level.err,
        vk.debug_utils_message_severity_warning_bit_EXT => std.log.Level.warn,
        vk.debug_utils_message_severity_info_bit_EXT => std.log.Level.info,
        vk.debug_utils_message_severity_verbose_bit_EXT => std.log.Level.debug,
        else => unreachable,
    };

    var msg_types_buffer: [52]u8 = undefined;
    var msg_types: std.ArrayList(u8) = .initBuffer(&msg_types_buffer);

    const type_msg = [_]struct {vk.DebugUtilsMessageTypeFlagBitsEXT, []const u8} {
        .{vk.debug_utils_message_type_device_address_binding_bit_EXT, "DeviceAddressBinding"},
        .{vk.debug_utils_message_type_general_bit_EXT, "General"},
        .{vk.debug_utils_message_type_performance_bit_EXT, "Performance"},
        .{vk.debug_utils_message_type_validation_bit_EXT, "Validation"},
    };
    comptime var max_msg_types_len = 0;
    inline for (type_msg) |tm| {
        max_msg_types_len += tm.@"1".len + 1;
        if (m_types & tm.@"0" != 0) msg_types.appendSliceAssumeCapacity(tm.@"1" ++ "|");
    }
    comptime std.debug.assert(max_msg_types_len <= msg_types_buffer.len);

    const log_format = "|{s}> {s}: {s}";
    const log_args = .{msg_types.items, callback_data.*.pMessageIdName, callback_data.*.pMessage};
    const log_vk = std.log.scoped(.vk);
    switch (level) {
        .err => log_vk.err(log_format, log_args),
        .warn => log_vk.warn(log_format, log_args),
        .info => log_vk.info(log_format, log_args),
        .debug => log_vk.debug(log_format, log_args),
    }

    return vk.@"false";
}

fn getDebugUtilsMessengerCreateInfoEXT() vk.DebugUtilsMessengerCreateInfoEXT {
    if (!enabled_validation) comptime unreachable;
    return .{
        .sType = vk.structure_type_debug_utils_messenger_create_info_EXT,
        .messageSeverity = vk.debug_utils_message_severity_verbose_bit_EXT | vk.debug_utils_message_severity_info_bit_EXT | vk.debug_utils_message_severity_warning_bit_EXT | vk.debug_utils_message_severity_error_bit_EXT,
        .messageType = vk.debug_utils_message_type_general_bit_EXT | vk.debug_utils_message_type_performance_bit_EXT | vk.debug_utils_message_type_validation_bit_EXT,
        .pfnUserCallback = &vkDebugUtilsCallback,
    };
}


pub const device_extensions = [_][*:0]const u8 {
    vk.KHR_swapchain_extension_name,
    vk.KHR_spirv_1_4_extension_name,
    vk.KHR_synchronization_2_extension_name,
};

pub const device_features = blk: {
    var tmp: helpers.PhysicalDeviceFeatures(&.{vk.PhysicalDeviceFeatures2, vk.PhysicalDeviceVulkan12Features, vk.PhysicalDeviceVulkan13Features}) = .init;
    tmp.features.@"2".features.shaderInt16 = vk.@"true";
    tmp.features.vulkan12.shaderInt8 = vk.@"true";
    tmp.features.vulkan13.dynamicRendering = vk.@"true";
    tmp.features.vulkan13.synchronization2 = vk.@"true";
    break :blk tmp;
};

fn pickAndCreateDevice(self: *VulkanContext) !void {
    // select physical device
    var count: u32 = 0;
    try ensureVkSuccess("vkEnumeratePhysicalDevices", vk.enumeratePhysicalDevices(self.instance, &count, null));
    switch (count) {
        0 => {
            log.err("vulkan supported device not found", .{});
            return error.NoSuitableDeviceAvailable;
        },
        1 => {
            try ensureVkSuccess("vkEnumeratePhysicalDevices", vk.enumeratePhysicalDevices(self.instance, &count, &self.physical_device));
            if (!self.checkPhysicalDeviceSuitabilities(self.physical_device)) {
                var properties: vk.PhysicalDeviceProperties = .{};
                vk.getPhysicalDeviceProperties(self.physical_device, &properties);
                log.err("the only vulkan supported device: \"{s}\" is not suitable for this application", .{properties.deviceName});
                return error.NoSuitableDeviceAvailable;
            }
        },
        else => {
            log.info("{d} devices detected", .{count});
            const devices = helpers.alloc(vk.PhysicalDevice, count);
            defer helpers.allocator.free(devices);
            try ensureVkSuccess("vkEnumeratePhysicalDevices", vk.enumeratePhysicalDevices(self.instance, &count, devices.ptr));

            for (devices) |device| {
                if (self.checkPhysicalDeviceSuitabilities(device)) {
                    self.physical_device = device;
                    break;
                } else {
                    var properties: vk.PhysicalDeviceProperties = .{};
                    vk.getPhysicalDeviceProperties(device, &properties);
                    log.warn("device \"{s}\" is not suitable for this application, skip", .{properties.deviceName});
                }
            } else {
                log.err("all devices are not suitable for this application", .{});
                return error.NoSuitableDeviceAvailable;
            }
        },
    }

    // get memory types;
    var mem_prop: vk.PhysicalDeviceMemoryProperties = .{};
    vk.getPhysicalDeviceMemoryProperties(self.physical_device, &mem_prop);
    self.device_memory_types = helpers.alloc(vk.MemoryType, mem_prop.memoryTypeCount);
    errdefer helpers.allocator.free(self.device_memory_types);
    @memcpy(self.device_memory_types, mem_prop.memoryTypes[0 .. mem_prop.memoryTypeCount]);

    // queues
    var unique_queue_families = self.queue_families.uniqueSetAlloc();
    defer unique_queue_families.deinit(helpers.allocator);
    var queue_infos: [@typeInfo(QueueFamilies).@"struct".fields.len]vk.DeviceQueueCreateInfo = undefined;
    for (unique_queue_families.keys(), 0..) |queue_family, idx| {
        queue_infos[idx] = .{
            .sType = vk.structure_type_device_queue_create_info,
            .queueFamilyIndex = queue_family,
            .queueCount = 1,
            .pQueuePriorities = &@as(f32, 0),
        };
    }

    var enabled_features = device_features;
    enabled_features.features.@"2".features.samplerAnisotropy = if (self.msaa_sample_count != vk.sample_count_1_bit) vk.@"true" else vk.false;
    enabled_features.features.@"2".features.sampleRateShading = if (self.sample_shading) vk.@"true" else vk.@"false";
    const device_info: vk.DeviceCreateInfo = .{
        .sType = vk.structure_type_device_create_info,
        .pNext = @ptrCast(enabled_features.buildChain()),
        .enabledExtensionCount = device_extensions.len,
        .ppEnabledExtensionNames = &device_extensions,
        .queueCreateInfoCount = @intCast(unique_queue_families.count()),
        .pQueueCreateInfos = &queue_infos,
    };
    try ensureVkSuccess("vkCreateDevice", vk.createDevice(self.physical_device, &device_info, null, &self.device));

    vk.getDeviceQueue(self.device, self.queue_families.graphics, 0, &self.queues.graphics);
    vk.getDeviceQueue(self.device, self.queue_families.present, 0, &self.queues.present);
}

fn destroyDeviceAndInfo(self: *VulkanContext) void {
    vk.destroyDevice(self.device, null);
    helpers.allocator.free(self.device_memory_types);
    self.device_memory_types = &.{};
}

fn findMemoryType(self: VulkanContext, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    var index: u5 = 0;
    while (index < self.device_memory_types.len) : (index += 1) {
        if (type_filter & (@as(u32, 1) << index) != 0 and (self.device_memory_types[index].propertyFlags & properties) == properties) {
            return index;
        }
    } else return error.FailedToFindMemoryType;
}

fn checkPhysicalDeviceSuitabilities(self: *VulkanContext, device: vk.PhysicalDevice) bool {
    // check device api version
    var device_properties: vk.PhysicalDeviceProperties = .{};
    vk.getPhysicalDeviceProperties(device, &device_properties);
    if (device_properties.apiVersion < vk.api_version_1_3) {
        log.err("device not support vulkan api 1.3+", .{});
        return false;
    }

    // check device features (depende on device vk api 1.3+)
    var check_features: @TypeOf(device_features) = .init;
    vk.getPhysicalDeviceFeatures2(device, check_features.buildChain());
    if (!check_features.check(device_features)) return false;
    const has_anisotropy = check_features.features.@"2".features.samplerAnisotropy != vk.@"false";
    const has_sample_shading = check_features.features.@"2".features.sampleRateShading != vk.@"false";

    // check device extensions
    var count: u32 = 0;
    ensureVkSuccess("vkEnumerateDeviceExtensionProperties", vk.enumerateDeviceExtensionProperties(device, null, &count, null)) catch return false;
    const extensions_properties = helpers.alloc(vk.ExtensionProperties, count);
    defer helpers.allocator.free(extensions_properties);
    ensureVkSuccess("vkEnumerateDeviceExtensionProperties", vk.enumerateDeviceExtensionProperties(device, null, &count, extensions_properties.ptr)) catch return false;

    var success = true;
    for (device_extensions) |extension| {
        for (extensions_properties) |properties| {
            if (std.mem.orderZ(u8, extension, @ptrCast(&properties.extensionName)) == .eq) break;
        } else {
            log.err("not support device extension: {s}", .{extension});
            success = false;
        }
    }
    if (!success) return false;

    // swapchain info (depende on extension vk.KHR_swapchain_extension_name)
    self.surface_info.extent, self.surface_info.target_swapchain_image_count, self.surface_info.pre_transform = SurfaceInfo.chooseCapabilityStuff(device, self.surface, self.window) catch return false;
    self.surface_info.format = SurfaceInfo.chooseFormat(device, self.surface) catch return false;
    self.surface_info.present_mode = SurfaceInfo.choosePresentMode(device, self.surface) catch return false;

    // queue families
    self.queue_families = QueueFamilies.init(device, self.surface) catch return false;

    // msaa sample count and sample rate shading
    if (has_anisotropy) {
        var properties: vk.PhysicalDeviceProperties = .{};
        vk.getPhysicalDeviceProperties(self.physical_device, &properties);
        const msaa_supported = properties.limits.framebufferColorSampleCounts;
        if (msaa_supported >= 2) {
            self.msaa_sample_count = @as(vk.SampleCountFlagBits, 1) << std.math.log2_int(vk.SampleCountFlags, msaa_supported);
            log.debug("maximum msaa sample count: {d}", .{self.msaa_sample_count});

            self.sample_shading = has_sample_shading;
            if (!has_sample_shading) log.warn(
                \\device supports anisotropy (msaa), but not for sample shading,
                \\  this means sawtooth may still exist when msaa enabled.
            , .{});
        }
    }

    return true;
}

pub const QueueFamilies = struct {
    graphics: u32,
    present: u32,

    fn init(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilies {
        var graphics: ?u32 = null;
        var present: ?u32 = null;

        var count: u32 = 0;
        vk.getPhysicalDeviceQueueFamilyProperties(device, &count, null);
        const queue_families_properties = helpers.alloc(vk.QueueFamilyProperties, count);
        defer helpers.allocator.free(queue_families_properties);
        vk.getPhysicalDeviceQueueFamilyProperties(device, &count, queue_families_properties.ptr);

        for (queue_families_properties, 0..) |properties, idx| {
            const queue_family: u32 = @truncate(idx);

            if (graphics == null or graphics == present) {
                if (properties.queueFlags & vk.queue_graphics_bit != 0) graphics = queue_family;
            }

            if (present == null or present == graphics) {
                var present_supported: vk.Bool32 = vk.@"false";
                try ensureVkSuccess("vkGetPhysicalDeviceSurfaceSupportKHR", vk.getPhysicalDeviceSurfaceSupportKHR(device, queue_family, surface, &present_supported));
                if (present_supported == vk.@"true") present = queue_family;
            }

            if (graphics != null and present != null and graphics != present) break;
        } else {
            if (graphics == null or present == null) {
                @branchHint(.unlikely);
                if (graphics == null) log.err("{s} queue family not found", .{"graphics"});
                if (present == null) log.err("{s} queue family not found", .{"present"});
                return error.@"Not all queue families were found";
            }
        }
        return .{ .graphics = graphics.?, .present = present.? };
    }

    pub fn asSlice(self: *const QueueFamilies) *const [@typeInfo(QueueFamilies).@"struct".fields.len]u32 {
        return @ptrCast(self);
    }

    pub fn uniqueSetAlloc(self: QueueFamilies) std.AutoArrayHashMapUnmanaged(u32, void) {
        var set: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        ensureAlloc(set.ensureUnusedCapacity(helpers.allocator, @typeInfo(QueueFamilies).@"struct".fields.len));
        inline for (self.asSlice()) |queue_family| {
            set.putAssumeCapacity(queue_family, undefined);
        }
        return set;
    }
};

pub const Queues = struct {
    graphics: vk.Queue = null,
    present: vk.Queue = null,
};

pub const SurfaceInfo = struct {
    extent: vk.Extent2D,
    target_swapchain_image_count: u32,
    pre_transform: vk.SurfaceTransformFlagBitsKHR,
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,

    fn chooseCapabilityStuff(device: vk.PhysicalDevice, surface: vk.SurfaceKHR, window: ?*glfw.Window) !struct {vk.Extent2D, u32, vk.SurfaceTransformFlagBitsKHR} {
        var capabilities: vk.SurfaceCapabilitiesKHR = .{};
        try ensureVkSuccess("vkGetPhysicalDeviceSurfaceCapabilitiesKHR", vk.getPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capabilities));

        const extent = if (capabilities.currentExtent.width != std.math.maxInt(u32))
            capabilities.currentExtent
        else blk: {
            var w: c_int = 0;
            var h: c_int = 0;
            glfw.getFramebufferSize(window, &w, &h);

            const min_extent = capabilities.minImageExtent;
            const max_extent = capabilities.maxImageExtent;
            const width = std.math.clamp(@as(u32, @intCast(w)), min_extent.width, max_extent.width);
            const height = std.math.clamp(@as(u32, @intCast(h)), min_extent.height, max_extent.height);
            break :blk vk.Extent2D { .width = width, .height = height };
        };

        const max_image_count = if (capabilities.maxImageCount == 0) std.math.maxInt(u32) else capabilities.maxImageCount;
        const count = @min(max_image_count, capabilities.minImageCount + 1);

        return .{extent, count, capabilities.currentTransform};
    }

    fn chooseFormat(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !vk.SurfaceFormatKHR {
        var count: u32 = 0;
        try ensureVkSuccess("vkGetPhysicalDeviceSurfaceFormatsKHR", vk.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, null));
        if (count == 0) {
            log.err("device does not support any surface formats", .{});
            return error.@"surface format not found";
        }
        const formats = helpers.alloc(vk.SurfaceFormatKHR, count);
        defer helpers.allocator.free(formats);
        try ensureVkSuccess("vkGetPhysicalDeviceSurfaceFormatsKHR", vk.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, formats.ptr));

        const target_format: vk.SurfaceFormatKHR = .{ .format = vk.format_b8g8r8a8_srgb, .colorSpace = vk.color_space_srgb_nonlinear_KHR };
        return for (formats) |format| {
            if (std.meta.eql(target_format, format)) break target_format;
        } else formats[0];
    }

    fn choosePresentMode(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !vk.PresentModeKHR {
        var count: u32 = 0;
        try ensureVkSuccess("vkGetPhysicalDeviceSurfacePresentModesKHR", vk.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, null));
        if (count == 0) {
            log.err("device does not support any present modes", .{});
            return error.@"present mode not found";
        }
        const modes = helpers.alloc(vk.PresentModeKHR, count);
        defer helpers.allocator.free(modes);
        try ensureVkSuccess("vkGetPhysicalDeviceSurfacePresentModesKHR", vk.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, modes.ptr));

        const target_mode = vk.present_mode_mailbox_KHR;
        return for (modes) |mode| {
            if (mode == target_mode) break target_mode;
        } else vk.present_mode_fifo_KHR; // this mode must exist by vulkan standard
    }
};

const CreateSwapchainStuffOptions = packed struct {
    update_extent: bool = false,
};

pub const CreateSwapchainStuffError = error {
    VkNotSuccess,
};

fn createSwapchainStuff(self: *VulkanContext, opts: CreateSwapchainStuffOptions) CreateSwapchainStuffError!void {
    const old_swapchain = self.swapchain;
    defer if (old_swapchain) |old| vk.destroySwapchainKHR(self.device, old, null);
    if (opts.update_extent) {
        self.surface_info.extent, _, _ = try SurfaceInfo.chooseCapabilityStuff(self.physical_device, self.surface, self.window);
    }

    // swapchain
    var unique_queue_families = self.queue_families.uniqueSetAlloc();
    defer unique_queue_families.deinit(helpers.allocator);
    const swapchain_info: vk.SwapchainCreateInfoKHR = .{
        .sType = vk.structure_type_swapchain_create_info_KHR,
        .surface = self.surface,
        .imageExtent = self.surface_info.extent,
        .minImageCount = self.surface_info.target_swapchain_image_count,
        .imageFormat = self.surface_info.format.format,
        .imageColorSpace = self.surface_info.format.colorSpace,
        .imageArrayLayers = 1,
        .imageUsage = vk.image_usage_color_attachment_bit,
        .presentMode = self.surface_info.present_mode,
        .preTransform = self.surface_info.pre_transform,
        .clipped = vk.@"true",
        .imageSharingMode = if (unique_queue_families.count() < 2) vk.sharing_mode_exclusive else vk.sharing_mode_concurrent,
        .queueFamilyIndexCount = @intCast(unique_queue_families.count()),
        .pQueueFamilyIndices = unique_queue_families.keys().ptr,
        .compositeAlpha = if (self.use_transparent_background) vk.composite_alpha_pre_multiplied_bit_KHR else vk.composite_alpha_opaque_bit_KHR,
        .oldSwapchain = old_swapchain,
    };
    try ensureVkSuccess("vkCreateSwapchainKHR", vk.createSwapchainKHR(self.device, &swapchain_info, null, &self.swapchain));
    errdefer vk.destroySwapchainKHR(self.device, self.swapchain, null);
    self.changed_extent = old_swapchain != null and opts.update_extent;

    // swapchain images
    var count: u32 = 0;
    try ensureVkSuccess("vkGetSwapchainImagesKHR", vk.getSwapchainImagesKHR(self.device, self.swapchain, &count, null));
    ensureAlloc(self.swapchain_images.ensureUnusedCapacity(helpers.allocator, count));
    try ensureVkSuccess("vkGetSwapchainImagesKHR", vk.getSwapchainImagesKHR(self.device, self.swapchain, &count, &self.swapchain_images.items.ptr[self.swapchain_images.items.len]));
    self.swapchain_images.items.len += count;

    // swapchain image views
    ensureAlloc(self.swapchain_image_views.ensureUnusedCapacity(helpers.allocator, count));
    errdefer for (self.swapchain_image_views.items) |image_view| vk.destroyImageView(self.device, image_view, null);
    for (self.swapchain_images.items) |image| self.swapchain_image_views.appendAssumeCapacity(try self.createImageView(image, .{
        .tiling = undefined,
        .usage = undefined,
        .aspects = vk.image_aspect_color_bit,
        .extent = self.surface_info.extent,
        .format = self.surface_info.format.format,
    }));
}

fn destroySwapchainStuff(self: *VulkanContext, cleanup: bool) void {
    for (self.swapchain_image_views.items) |image_view| vk.destroyImageView(self.device, image_view, null);
    if (cleanup) {
        self.swapchain_image_views.clearAndFree(helpers.allocator);
        self.swapchain_images.clearAndFree(helpers.allocator);
        vk.destroySwapchainKHR(self.device, self.swapchain, null);
    }
    else {
        self.swapchain_images.clearRetainingCapacity();
        self.swapchain_image_views.clearRetainingCapacity();
    }
}

fn recreateSwapchainStuff(self: *VulkanContext, opts: CreateSwapchainStuffOptions) !void {
    _ = vk.deviceWaitIdle(self.device);
    self.destroySwapchainStuff(false);
    try self.createSwapchainStuff(opts);
    if (opts.update_extent) try self.recreateMsaaStuff();
    self.cb_ctx.resized = false;
}

pub const CommandPools = struct {
    graphics: vk.CommandPool = null,

    pub fn createOne(device: vk.Device, queue_family: u32, flags: vk.CommandPoolCreateFlags) error {VkNotSuccess}!vk.CommandPool {
        const command_pool_info: vk.CommandPoolCreateInfo = .{
            .sType = vk.structure_type_command_pool_create_info,
            .flags = flags,
            .queueFamilyIndex = queue_family,
        };
        var command_pool: vk.CommandPool = null;
        try ensureVkSuccess("", vk.createCommandPool(device, &command_pool_info, null, &command_pool));
        return command_pool;
    }

    pub fn init(device: vk.Device, queue_families: QueueFamilies) error {VkNotSuccess}!CommandPools {
        return .{
            .graphics = try createOne(device, queue_families.graphics, vk.command_pool_create_reset_command_buffer_bit),
        };
    }

    pub fn deinit(self: *CommandPools, device: vk.Device) void {
        vk.destroyCommandPool(device, self.graphics, null);
        self.graphics = null;
    }
};

pub const SwapchainOperations = struct {
    swapchain: vk.SwapchainKHR = null,
    acquire_image_semaphore: vk.Semaphore = null,
    image_available_semaphores: std.ArrayList(vk.Semaphore) = .empty,
    present_wait_semaphores: std.ArrayList(vk.Semaphore) = .empty,
    present_wait_semaphore_count: u32,

    fn init(device: vk.Device, swapchain_image_count: usize, present_wait_semaphore_count: u32) error {VkNotSuccess}!SwapchainOperations {
        var self: SwapchainOperations = .{ .present_wait_semaphore_count = present_wait_semaphore_count };
        errdefer self.deinit(device);
        ensureAlloc(self.image_available_semaphores.ensureUnusedCapacity(helpers.allocator, swapchain_image_count));
        ensureAlloc(self.present_wait_semaphores.ensureUnusedCapacity(helpers.allocator, swapchain_image_count * present_wait_semaphore_count));

        self.acquire_image_semaphore = try createSemaphore(device);
        for (0..swapchain_image_count) |_| self.image_available_semaphores.appendAssumeCapacity(try createSemaphore(device));
        for (0..(swapchain_image_count * present_wait_semaphore_count)) |_| self.present_wait_semaphores.appendAssumeCapacity(try createSemaphore(device));

        return self;
    }

    fn deinit(self: *SwapchainOperations, device: vk.Device) void {
        vk.destroySemaphore(device, self.acquire_image_semaphore, null);
        for (self.image_available_semaphores.items) |semaphore| vk.destroySemaphore(device, semaphore, null);
        for (self.present_wait_semaphores.items) |semaphore| vk.destroySemaphore(device, semaphore, null);
        self.image_available_semaphores.deinit(helpers.allocator);
        self.present_wait_semaphores.deinit(helpers.allocator);
    }

    pub const AcquireResult = struct {
        result: vk.Result,
        image_index: u32,
        acquire_semaphore: vk.Semaphore,
        present_wait_semaphores: []vk.Semaphore,
    };

    fn acquireNextImage(self: *SwapchainOperations, device: vk.Device, swapchain: vk.SwapchainKHR, timeout: ?u64, signle_fence: vk.Fence) AcquireResult {
        var image_index: u32 = 0;
        const result = vk.acquireNextImageKHR(device, swapchain, timeout orelse std.math.maxInt(u64), self.acquire_image_semaphore, signle_fence, &image_index);
        std.mem.swap(vk.Semaphore, &self.acquire_image_semaphore, &self.image_available_semaphores.items[image_index]);
        return .{
            .result = result,
            .image_index = image_index,
            .acquire_semaphore = self.image_available_semaphores.items[image_index],
            .present_wait_semaphores = self.present_wait_semaphores.items[image_index * self.present_wait_semaphore_count..][0..self.present_wait_semaphore_count],
        };
    }

    fn present(self: SwapchainOperations, queue: vk.Queue, swapchain: vk.SwapchainKHR, acquire_result: AcquireResult) vk.Result {
        const present_info: vk.PresentInfoKHR = .{
            .sType = vk.structure_type_present_info_KHR,
            .swapchainCount = 1,
            .pSwapchains = &swapchain,
            .pImageIndices = &acquire_result.image_index,
            .waitSemaphoreCount = self.present_wait_semaphore_count,
            .pWaitSemaphores = acquire_result.present_wait_semaphores.ptr,
        };
        return vk.queuePresentKHR(queue, &present_info);
    }
};

pub fn createSemaphore(device: vk.Device) error {VkNotSuccess}!vk.Semaphore {
    const semaphore_info: vk.SemaphoreCreateInfo = .{
        .sType = vk.structure_type_semaphore_create_info,
    };
    var semephore: vk.Semaphore = null;
    try ensureVkSuccess("vkCreateSemaphore", vk.createSemaphore(device, &semaphore_info, null, &semephore));
    return semephore;
}
pub fn createFence(device: vk.Device, signled: bool) error {VkNotSuccess}!vk.Fence {
    const fence_info: vk.FenceCreateInfo = .{
        .sType = vk.structure_type_fence_create_info,
        .flags = if (signled) vk.fence_create_signaled_bit else 0,
    };
    var fence: vk.Fence = null;
    try ensureVkSuccess("vkCreateFence", vk.createFence(device, &fence_info, null, &fence));
    return fence;
}

pub fn createRenderingObjects(self: *VulkanContext) !void {
    try ensureVkSuccess("vkAllocateCommandBuffers", vk.allocateCommandBuffers(self.device, &.{
        .sType = vk.structure_type_command_buffer_allocate_info,
        .commandPool = self.command_pools.graphics,
        .level = vk.command_buffer_level_primary,
        .commandBufferCount = max_frames_in_flight,
    }, &self.command_buffers));

    @memset(&self.in_flight_fences, null);
    errdefer for (self.in_flight_fences) |fence| {
        if (fence == null) break;
        vk.destroyFence(self.device, fence, null);
    };
    for (&self.in_flight_fences) |*fence| fence.* = try createFence(self.device, true);
}

pub fn destroyRenderingObjects(self: *VulkanContext) void {
    for (&self.in_flight_fences) |fence| vk.destroyFence(self.device, fence, null);
    @memset(&self.command_buffers, null);
}


pub fn beginSingleTimeCommands(self: VulkanContext) !vk.CommandBuffer {
    const alloc_info: vk.CommandBufferAllocateInfo = .{
        .sType = vk.structure_type_command_buffer_allocate_info,
        .level = vk.command_buffer_level_primary,
        .commandPool = self.command_pools.graphics,
        .commandBufferCount = 1,
    };
    var command_buffer: vk.CommandBuffer = null;
    try ensureVkSuccess("vkAllocateCommandBuffers", vk.allocateCommandBuffers(self.device, &alloc_info, &command_buffer));
    errdefer vk.freeCommandBuffers(self.device, self.command_pools.graphics, 1, &command_buffer);

    const begin_info: vk.CommandBufferBeginInfo = .{
        .sType = vk.structure_type_command_buffer_begin_info,
        .flags = vk.command_buffer_usage_one_time_submit_bit,
    };
    try ensureVkSuccess("vkBeginCommandBuffer", vk.beginCommandBuffer(command_buffer, &begin_info));

    return command_buffer;
}

pub fn endSingleTimeCommands(self: VulkanContext, command_buffer: vk.CommandBuffer) !void {
    try ensureVkSuccess("vkEndCommandBuffer", vk.endCommandBuffer(command_buffer));

    const submit_info: vk.SubmitInfo = .{
        .sType = vk.structure_type_submit_info,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };
    try ensureVkSuccess("vkQueueSubmit", vk.queueSubmit(self.queues.graphics, 1, &submit_info, null));
    try ensureVkSuccess("vkQueueWaitIdle", vk.queueWaitIdle(self.queues.graphics));
}

pub fn createBuffer(self: VulkanContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags) !struct {vk.Buffer, vk.DeviceMemory} {
    const buffer_info: vk.BufferCreateInfo = .{
        .sType = vk.structure_type_buffer_create_info,
        .sharingMode = vk.sharing_mode_exclusive,
        .usage = usage,
        .size = size,
    };

    var buffer: vk.Buffer = null;
    try ensureVkSuccess("vkCreatebuffer", vk.createBuffer(self.device, &buffer_info, null, &buffer));
    errdefer vk.destroyBuffer(self.device, buffer, null);

    var mem_requirements: vk.MemoryRequirements = .{};
    vk.getBufferMemoryRequirements(self.device, buffer, &mem_requirements);

    const alloc_info: vk.MemoryAllocateInfo = .{
        .sType = vk.structure_type_memory_allocate_info,
        .memoryTypeIndex = try self.findMemoryType(mem_requirements.memoryTypeBits, properties),
        .allocationSize = mem_requirements.size,
    };

    var memory: vk.DeviceMemory = null;
    try ensureVkSuccess("vkAllocateMemory", vk.allocateMemory(self.device, &alloc_info, null, &memory));
    errdefer vk.freeMemory(self.device, memory, null);

    try ensureVkSuccess("vkBindBufferMemory", vk.bindBufferMemory(self.device, buffer, memory, 0));
    return .{buffer, memory};
}

pub fn copyBuffer(self: VulkanContext, src_buffer: vk.Buffer, dst_buffer: vk.Buffer, size: vk.DeviceSize) !void {
    const command_buffer = try self.beginSingleTimeCommands();
    defer vk.freeCommandBuffers(self.device, self.command_pools.graphics, 1, &command_buffer);

    const copy_region: vk.BufferCopy = .{
        .size = size,
    };
    vk.cmdCopyBuffer(command_buffer, src_buffer, dst_buffer, 1, &copy_region);
    try self.endSingleTimeCommands(command_buffer);
}


pub fn createBuffers(self: VulkanContext, sizes: []const vk.DeviceSize, usages: []const vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, out_buffers: []vk.Buffer, out_offsets: []vk.DeviceSize) !struct {vk.DeviceMemory, vk.DeviceSize} {
    @memset(out_buffers, null);
    errdefer for (out_buffers) |buf| {
        if (buf == null) break;
        vk.destroyBuffer(self.device, buf, null);
    };

    var mem_req: vk.MemoryRequirements = .{};
    var total_size: vk.DeviceSize = 0;
    for (sizes, usages, out_buffers, out_offsets) |size, usage, *buf, *offset| {
        try ensureVkSuccess("vkCreatebuffer", vk.createBuffer(self.device, &.{
            .sType = vk.structure_type_buffer_create_info,
            .sharingMode = vk.sharing_mode_exclusive,
            .usage = usage,
            .size = @max(1, size),
        }, null, buf));
        offset.* = total_size;
        vk.getBufferMemoryRequirements(self.device, buf.*, &mem_req);
        total_size += mem_req.size;
    }

    var mem: vk.DeviceMemory = null;
    try ensureVkSuccess("vkAllocateMemory", vk.allocateMemory(self.device, &.{
        .sType = vk.structure_type_memory_allocate_info,
        .memoryTypeIndex = try self.findMemoryType(mem_req.memoryTypeBits, properties),
        .allocationSize = total_size,
    }, null, &mem));
    errdefer vk.freeMemory(self.device, mem, null);

    for (out_buffers, out_offsets) |buf, offset| {
        try ensureVkSuccess("vkBindBufferMemory", vk.bindBufferMemory(self.device, buf, mem, offset));
    }
    return .{mem, total_size};
}

pub fn copyBuffers(self: VulkanContext, src: []const vk.Buffer, dst: []const vk.Buffer, sizes: []const vk.DeviceSize) !void {
    const command_buffer = try self.beginSingleTimeCommands();
    defer vk.freeCommandBuffers(self.device, self.command_pools.graphics, 1, &command_buffer);

    for (src, dst, sizes) |s, d, size| {
        if (size == 0) continue;
        vk.cmdCopyBuffer(command_buffer, s, d, 1, &.{ .size = size });
    }

    try self.endSingleTimeCommands(command_buffer);
}


fn createShaderModule(self: VulkanContext, code: []align(4) const u8) !vk.ShaderModule {
    const create_info: vk.ShaderModuleCreateInfo = .{
        .sType = vk.structure_type_shader_module_create_info,
        .codeSize = code.len,
        .pCode = @ptrCast(code.ptr),
    };

    var shader_module: vk.ShaderModule = null;
    try ensureVkSuccess("vkCreateShaderModule", vk.createShaderModule(self.device, &create_info, null, &shader_module));
    return shader_module;
}

pub fn createPipelineLayout(self: VulkanContext, comptime PushVertexConstantObject: ?type) !vk.PipelineLayout {
    const pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
        .sType = vk.structure_type_pipeline_layout_create_info,
        //.setLayoutCount = 1,
        //.pSetLayouts = &self.descriptor_set_layout,
        .pushConstantRangeCount = if (PushVertexConstantObject) |_| 1 else 0,
        .pPushConstantRanges = if (PushVertexConstantObject) |PSO| &.{
            .stageFlags = vk.shader_stage_vertex_bit,
            .offset = 0,
            .size = @sizeOf(PSO),
        } else null,
    };

    var pipeline_layout: vk.PipelineLayout = null;
    try ensureVkSuccess("vkCreatePipelineLayout", vk.createPipelineLayout(self.device, &pipeline_layout_info, null, &pipeline_layout));
    return pipeline_layout;
}

pub fn createGraphicsPipeline(self: VulkanContext, pipeline_cache: vk.PipelineCache, shader_code: []align(4) const u8, vert_entry: [*:0]const u8, frag_entry: [*:0]const u8, pipeline_layout: vk.PipelineLayout) !vk.Pipeline {
    const shader_module = try self.createShaderModule(shader_code);
    defer vk.destroyShaderModule(self.device, shader_module, null);

    const vert_shader_stage_info: vk.PipelineShaderStageCreateInfo = .{
        .sType = vk.structure_type_pipeline_shader_stage_create_info,
        .stage = vk.shader_stage_vertex_bit,
        .module = shader_module,
        .pName = vert_entry,
    };
    const frag_shader_stage_info: vk.PipelineShaderStageCreateInfo = .{
        .sType = vk.structure_type_pipeline_shader_stage_create_info,
        .stage = vk.shader_stage_fragment_bit,
        .module = shader_module,
        .pName = frag_entry,
    };
    const shader_stages = [_]vk.PipelineShaderStageCreateInfo {
        vert_shader_stage_info,
        frag_shader_stage_info,
    };

    const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
        .sType = vk.structure_type_pipeline_vertex_input_state_create_info,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &Vertex.binding_description,
        .vertexAttributeDescriptionCount = Vertex.attribute_descriptions.len,
        .pVertexAttributeDescriptions = &Vertex.attribute_descriptions,
    };
    const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
        .sType = vk.structure_type_pipeline_input_assembly_state_create_info,
        .topology = vk.primitive_topology_triangle_list,
        .primitiveRestartEnable = vk.@"false",
    };

    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.surface_info.extent.width),
        .height = @floatFromInt(self.surface_info.extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    const scissor: vk.Rect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.surface_info.extent,
    };
    const viewport_state: vk.PipelineViewportStateCreateInfo = .{
        .sType = vk.structure_type_pipeline_viewport_state_create_info,
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };

    const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
        .sType = helpers.vkSType(vk.PipelineDynamicStateCreateInfo),
        .dynamicStateCount = 2,
        .pDynamicStates = &[2]vk.DynamicState {
            vk.dynamic_state_viewport,
            vk.dynamic_state_scissor,
        },
    };

    const rasterizer: vk.PipelineRasterizationStateCreateInfo = .{
        .sType = vk.structure_type_pipeline_rasterization_state_create_info,
        .depthClampEnable = vk.@"false",
        .rasterizerDiscardEnable = vk.@"false",
        .polygonMode = vk.polygon_mode_fill,
        .lineWidth = 1,
        .cullMode = vk.cull_mode_back_bit,
        .frontFace = vk.front_face_counter_clockwise,
        .depthBiasEnable = vk.@"false",
    };

    const multisampling: vk.PipelineMultisampleStateCreateInfo = .{
        .sType = vk.structure_type_pipeline_multisample_state_create_info,
        .rasterizationSamples = if (self.msaaRenderingEnabled()) self.msaa_sample_count else vk.sample_count_1_bit,
        .sampleShadingEnable = if (self.msaaRenderingEnabled() and self.sample_shading) vk.@"true" else vk.@"false",
        .minSampleShading = if (self.msaaRenderingEnabled() and self.sample_shading) 1 else 0,
    };

    const color_blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .colorWriteMask = vk.color_component_r_bit | vk.color_component_g_bit | vk.color_component_b_bit | vk.color_component_a_bit,
        .blendEnable = vk.@"true",
        .srcColorBlendFactor = vk.blend_factor_src_alpha,
        .dstColorBlendFactor = vk.blend_factor_one_minus_src_alpha,
        .colorBlendOp = vk.blend_op_add,
        .srcAlphaBlendFactor = vk.blend_factor_one,
        .dstAlphaBlendFactor = vk.blend_factor_zero,
        .alphaBlendOp = vk.blend_op_add,
    };
    const color_blending: vk.PipelineColorBlendStateCreateInfo = .{
        .sType = vk.structure_type_pipeline_color_blend_state_create_info,
        .logicOpEnable = vk.@"false",
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{0, 0, 0, 0},
    };

    const pipeline_rendering_create_info: vk.PipelineRenderingCreateInfo = .{
        .sType = vk.structure_type_pipeline_rendering_create_info,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &self.surface_info.format.format,
    };

    const pipeline_info: vk.GraphicsPipelineCreateInfo = .{
        .sType = vk.structure_type_graphics_pipeline_create_info,
        .stageCount = 2,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .pNext = @ptrCast(&pipeline_rendering_create_info),
        .layout = pipeline_layout,
    };

    var pipeline: vk.Pipeline = null;
    try ensureVkSuccess("vkCreateGraphicsPipelines", vk.createGraphicsPipelines(self.device, pipeline_cache, 1, &pipeline_info, null, &pipeline));
    return pipeline;
}


const Image2DInfo = struct {
    extent: vk.Extent2D,
    mip_levels: u32 = 1,
    sample_count: vk.SampleCountFlagBits = vk.sample_count_1_bit,
    format: vk.Format,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    aspects: vk.ImageAspectFlags,
};

pub fn createImage(self: VulkanContext, info: Image2DInfo, mem_properties: vk.MemoryPropertyFlags) !struct {vk.Image, vk.DeviceMemory} {
    var image: vk.Image = null;
    try ensureVkSuccess("vkCreateImage", vk.createImage(self.device, &.{
        .sType = helpers.vkSType(vk.ImageCreateInfo),
        .imageType = vk.image_type_2d,
        .arrayLayers = 1,
        .initialLayout = vk.image_layout_undefined,
        .sharingMode = vk.sharing_mode_exclusive,
        .mipLevels = info.mip_levels,
        .format = info.format,
        .tiling = info.tiling,
        .usage = info.usage,
        .samples = info.sample_count,
        .extent = .{ .width = info.extent.width, .height = info.extent.height, .depth = 1 },
    }, null, &image));
    errdefer vk.destroyImage(self.device, image, null);

    var mem_requirements: vk.MemoryRequirements = .{};
    vk.getImageMemoryRequirements(self.device, image, &mem_requirements);

    var memory: vk.DeviceMemory = null;
    try ensureVkSuccess("vkAllocateMemory", vk.allocateMemory(self.device, &.{
        .sType = helpers.vkSType(vk.MemoryAllocateInfo),
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try self.findMemoryType(mem_requirements.memoryTypeBits, mem_properties),
    }, null, &memory));
    errdefer vk.freeMemory(self.device, memory, null);

    try ensureVkSuccess("vkBindImageMemory", vk.bindImageMemory(self.device, image, memory, 0));
    return .{image, memory};
}

pub fn createImageView(self: VulkanContext, image: vk.Image, info: Image2DInfo) !vk.ImageView {
    var image_view: vk.ImageView = null;
    try ensureVkSuccess("vkCreateImageView", vk.createImageView(self.device, &.{
        .sType = vk.structure_type_image_view_create_info,
        .image = image,
        .viewType = vk.image_view_type_2d,
        .format = info.format,
        .subresourceRange = .{
            .aspectMask = info.aspects,
            .baseMipLevel = 0,
            .levelCount = info.mip_levels,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    }, null, &image_view));
    return image_view;
}


pub fn getCursor(self: VulkanContext) Point(f32) {
    var cursor_x: f64 = 0; var cursor_y: f64 = 0;
    glfw.getCursorPos(self.window, &cursor_x, &cursor_y);
    const screen_x = @as(f32, @floatCast(cursor_x)) / @as(f32, @floatFromInt(self.surface_info.extent.width));
    const screen_y = @as(f32, @floatCast(cursor_y)) / @as(f32, @floatFromInt(self.surface_info.extent.height));
    const frame_x = 2 * screen_x - 1;
    const frame_y = 1 - 2 * screen_y;
    return .{ .x = frame_x, .y = frame_y };
}
