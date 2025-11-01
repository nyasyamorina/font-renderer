const builtin = @import("builtin");
const std = @import("std");

const glfw = @import("c/glfw.zig");
const vk = @import("c/vk.zig");
const helpers = @import("helpers.zig");

const VulkanContext = @This();
const log = std.log.scoped(.VulkanContext);
const ensureAlloc = helpers.ensureAlloc;
const ensureVkSuccess = helpers.ensureVkSuccess;
const enable_validation = builtin.mode == .Debug;


window: ?*glfw.Window = null,
instance: vk.Instance = null,
debug_messenger: vk.DebugUtilsMessengerEXT = null,
surface: vk.SurfaceKHR = null,
physical_device: vk.PhysicalDevice = null,
device: vk.Device = null,
queue_families: QueueFamilies = undefined,
queues: Queues = .{},
command_pools: CommandPools = .{},
surface_info: SurfaceInfo = undefined,
swapchain: vk.SwapchainKHR = null,
swapchain_image_views: std.ArrayList(vk.ImageView) = .empty,
swapchain_operations: SwapchainOperations = .{},


pub const max_frames_in_flight = 2;

pub const InitError = error {
    VkNotSuccess,
    @"Failed to create window",
    @"Not support all instance extensions",
    @"Not support all instance layers",
    @"Failed to get instance proc addr",
    @"No suitable device available",
} || CreateSwapchainStuffError || std.Io.Writer.Error || std.Io.Reader.DelimiterError;

pub fn init(window_size: vk.Extent2D) InitError!VulkanContext {
    var self: VulkanContext = .{};

    try self.createWindow(window_size);
    errdefer glfw.destroyWindow(self.window);
    try self.createInstanceAndDebugMessenger();
    errdefer self.destroyInstanceAndDebugMessenger();
    try ensureVkSuccess("glfwCreateWindowSurface", glfw.createWindowSurface(self.instance, self.window, null, &self.surface));
    errdefer vk.destroySurfaceKHR(self.instance, self.surface, null);
    try self.pickAndCreateDevice();
    errdefer vk.destroyDevice(self.device, null);
    self.command_pools = try .init(self.device, self.queue_families);
    errdefer self.command_pools.deinit(self.device);
    try self.createSwapchainStuff(.{});
    errdefer self.destroySwapchainStuff(true);
    self.swapchain_operations = try .init(self.device, self.swapchain_image_views.items.len, 1);
    errdefer self.swapchain_operations.deinit(self.allocator, self.device);

    return self;
}

pub fn deinit(self: *VulkanContext) void {
    self.swapchain_operations.deinit(self.device);
    self.destroySwapchainStuff(true);
    self.command_pools.deinit(self.device);
    vk.destroyDevice(self.device, null);
    vk.destroySurfaceKHR(self.instance, self.surface, null);
    self.destroyInstanceAndDebugMessenger();
    glfw.destroyWindow(self.window);
}

pub const MainLoopError = error {
    VkNotSuccess,
};

pub fn mainLoop(self: *VulkanContext) MainLoopError!void {
    defer _ = vk.deviceWaitIdle(self.device);
    while (glfw.windowShouldClose(self.window) == vk.@"false") {
        glfw.pollEvents();
    }
}


pub const window_title = "ZigVkSoftRayTracing";
pub const window_init_width = 800;
pub const window_init_height = 600;

fn createWindow(self: *VulkanContext, window_size: vk.Extent2D) InitError!void {
    glfw.windowHint(glfw.client_api, glfw.no_api);
    glfw.windowHint(glfw.resizable, glfw.@"false");

    self.window = glfw.createWindow(@intCast(window_size.width), @intCast(window_size.height), window_title, null, null);
    if (self.window == null) return InitError.@"Failed to create window";
}


fn createInstanceAndDebugMessenger(self: *VulkanContext) InitError!void {
    // App Info
    const app_info: vk.ApplicationInfo = .{
        .sType = vk.structure_type_application_info,
        .pApplicationName = window_title,
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
        const extensions_properties = ensureAlloc(helpers.allocator.alloc(vk.ExtensionProperties, count));
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
        if (!supported) return InitError.@"Not support all instance extensions";
    }

    // All layers supported?
    if (layer_names.items.len > 0) {
        count = 0;
        try ensureVkSuccess("vkEnumerateInstanceLayerProperties", vk.enumerateInstanceLayerProperties(&count, null));
        const layers_properties = ensureAlloc(helpers.allocator.alloc(vk.LayerProperties, count));
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
        if (!supported) return InitError.@"Not support all instance layers";
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
        } else return InitError.@"Failed to get instance proc addr";
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

fn pickAndCreateDevice(self: *VulkanContext) InitError!void {
    // select physical device
    var count: u32 = 0;
    try ensureVkSuccess("vkEnumeratePhysicalDevices", vk.enumeratePhysicalDevices(self.instance, &count, null));
    switch (count) {
        0 => {
            log.err("vulkan supported device not found", .{});
            return InitError.@"No suitable device available";
        },
        1 => {
            try ensureVkSuccess("vkEnumeratePhysicalDevices", vk.enumeratePhysicalDevices(self.instance, &count, &self.physical_device));
            if (!self.checkPhysicalDeviceSuitabilities(self.physical_device)) {
                var properties: vk.PhysicalDeviceProperties = .{};
                vk.getPhysicalDeviceProperties(self.physical_device, &properties);
                log.err("the only vulkan supported device: \"{s}\" is not suitable for this application", .{properties.deviceName});
                return InitError.@"No suitable device available";
            }
        },
        else => {
            log.info("{d} devices detected", .{count});
            const devices = ensureAlloc(helpers.allocator.alloc(vk.PhysicalDevice, count));
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
            }
        },
    }

    // physical device features
    const vulkan13_features: vk.PhysicalDeviceVulkan13Features = .{
        .sType = vk.structure_type_physical_device_vulkan_1_3_features,
        .synchronization2 = vk.@"true",
    };
    const device_features: vk.PhysicalDeviceFeatures2 = .{
        .sType = vk.structure_type_physical_device_features_2,
        .pNext = @constCast(@ptrCast(&vulkan13_features)),
    };

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

    const device_info: vk.DeviceCreateInfo = .{
        .sType = vk.structure_type_device_create_info,
        .pNext = @ptrCast(&device_features),
        .enabledExtensionCount = device_extensions.len,
        .ppEnabledExtensionNames = &device_extensions,
        .queueCreateInfoCount = @intCast(unique_queue_families.count()),
        .pQueueCreateInfos = &queue_infos,
    };
    try ensureVkSuccess("", vk.createDevice(self.physical_device, &device_info, null, &self.device));

    vk.getDeviceQueue(self.device, self.queue_families.compute, 0, &self.queues.compute);
    vk.getDeviceQueue(self.device, self.queue_families.present, 0, &self.queues.present);
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
    var vulkan13_features: vk.PhysicalDeviceVulkan13Features = .{
        .sType = vk.structure_type_physical_device_vulkan_1_3_features,
    };
    var device_features: vk.PhysicalDeviceFeatures2 = .{
        .sType = vk.structure_type_physical_device_features_2,
        .pNext = @ptrCast(&vulkan13_features)
    };
    vk.getPhysicalDeviceFeatures2(device, &device_features);
    if (vulkan13_features.synchronization2 != vk.@"true") {
        log.err("device does not support synchronization2 feature", .{});
        return false;
    }

    // check device extensions
    var count: u32 = 0;
    ensureVkSuccess("vkEnumerateDeviceExtensionProperties", vk.enumerateDeviceExtensionProperties(device, null, &count, null)) catch return false;
    const extensions_properties = ensureAlloc(helpers.allocator.alloc(vk.ExtensionProperties, count));
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

    return true;
}

pub const QueueFamilies = struct {
    compute: u32,
    present: u32,

    fn init(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilies {
        var compute: ?u32 = null;
        var present: ?u32 = null;

        var count: u32 = 0;
        vk.getPhysicalDeviceQueueFamilyProperties(device, &count, null);
        const queue_families_properties = ensureAlloc(helpers.allocator.alloc(vk.QueueFamilyProperties, count));
        defer helpers.allocator.free(queue_families_properties);
        vk.getPhysicalDeviceQueueFamilyProperties(device, &count, queue_families_properties.ptr);

        for (queue_families_properties, 0..) |properties, idx| {
            const queue_family: u32 = @truncate(idx);

            if (compute == null or compute == present) {
                if (properties.queueFlags & vk.queue_compute_bit != 0) compute = queue_family;
            }

            if (present == null or present == compute) {
                var present_supported: vk.Bool32 = vk.@"false";
                try ensureVkSuccess("vkGetPhysicalDeviceSurfaceSupportKHR", vk.getPhysicalDeviceSurfaceSupportKHR(device, queue_family, surface, &present_supported));
                if (present_supported == vk.@"true") present = queue_family;
            }

            if (compute != null and present != null and compute != present) break;
        } else {
            if (compute == null or present == null) {
                @branchHint(.unlikely);
                if (compute == null) log.err("{s} queue family not found", .{"compute"});
                if (present == null) log.err("{s} queue family not found", .{"present"});
                return error.@"Not all queue families were found";
            }
        }
        return .{ .compute = compute.?, .present = present.? };
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
    compute: vk.Queue = null,
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
        const formats = ensureAlloc(helpers.allocator.alloc(vk.SurfaceFormatKHR, count));
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
        const modes = ensureAlloc(helpers.allocator.alloc(vk.PresentModeKHR, count));
        defer helpers.allocator.free(modes);
        try ensureVkSuccess("vkGetPhysicalDeviceSurfacePresentModesKHR", vk.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, modes.ptr));

        const target_mode = vk.present_mode_mailbox_KHR;
        return for (modes) |mode| {
            if (mode == target_mode) break target_mode;
        } else vk.present_mode_fifo_KHR; // this mode must exist by vulkan standard
    }
};

const CreateSwapchainStuffOptions = packed struct {
    old_swapchain: vk.SwapchainKHR = null,
    update_extent: bool = false,
};

pub const CreateSwapchainStuffError = error {
    VkNotSuccess,
};

fn createSwapchainStuff(self: *VulkanContext, opts: CreateSwapchainStuffOptions) CreateSwapchainStuffError!void {
    defer if (opts.old_swapchain) |sc| vk.destroySwapchainKHR(self.device, sc, null);
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
        .compositeAlpha = vk.composite_alpha_opaque_bit_KHR,
        .oldSwapchain = opts.old_swapchain,
    };
    try ensureVkSuccess("vkCreateSwapchainKHR", vk.createSwapchainKHR(self.device, &swapchain_info, null, &self.swapchain));
    errdefer vk.destroySwapchainKHR(self.device, self.swapchain, null);

    // swapchain images
    var count: u32 = 0;
    try ensureVkSuccess("vkGetSwapchainImagesKHR", vk.getSwapchainImagesKHR(self.device, self.swapchain, &count, null));
    const swapchain_images = ensureAlloc(helpers.allocator.alloc(vk.Image, count));
    defer helpers.allocator.free(swapchain_images);
    try ensureVkSuccess("vkGetSwapchainImagesKHR", vk.getSwapchainImagesKHR(self.device, self.swapchain, &count, swapchain_images.ptr));

    // swapchain image views
    ensureAlloc(self.swapchain_image_views.ensureUnusedCapacity(helpers.allocator, count));
    errdefer for (self.swapchain_image_views.items) |image_view| vk.destroyImageView(self.device, image_view, null);
    for (swapchain_images) |image| self.swapchain_image_views.appendAssumeCapacity(try self.createImageView(image, self.surface_info.format.format, vk.image_aspect_color_bit, 1));
}

fn destroySwapchainStuff(self: *VulkanContext, cleanup: bool) void {
    for (self.swapchain_image_views.items) |image_view| vk.destroyImageView(self.device, image_view, null);
    if (cleanup) { self.swapchain_image_views.clearAndFree(helpers.allocator); }
    else { self.swapchain_image_views.clearRetainingCapacity(); }

    if (cleanup) vk.destroySwapchainKHR(self.device, self.swapchain, null);
}

pub fn createImageView(self: VulkanContext, image: vk.Image, format: vk.Format, aspect_flags: vk.ImageAspectFlags, mip_levels: u32) error {VkNotSuccess}!vk.ImageView {
    const view_info: vk.ImageViewCreateInfo = .{
        .sType = vk.structure_type_image_view_create_info,
        .image = image,
        .viewType = vk.image_view_type_2d,
        .format = format,
        .subresourceRange = .{
            .aspectMask = aspect_flags,
            .baseMipLevel = 0,
            .levelCount = mip_levels,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    var image_view: vk.ImageView = null;
    try ensureVkSuccess("vkCreateImageView", vk.createImageView(self.device, &view_info, null, &image_view));
    return image_view;
}

pub const CommandPools = struct {
    compute: vk.CommandPool = null,

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
            .compute = try createOne(device, queue_families.compute, vk.command_pool_create_reset_command_buffer_bit),
        };
    }

    pub fn deinit(self: *CommandPools, device: vk.Device) void {
        vk.destroyCommandPool(device, self.compute, null);
        self.compute = null;
    }
};

pub const SwapchainOperations = struct {
    swapchain: vk.SwapchainKHR = null,
    acquire_image_semaphore: vk.Semaphore = null,
    image_available_semaphores: std.ArrayList(vk.Semaphore) = .empty,
    present_wait_semaphores: std.ArrayList(vk.Semaphore) = .empty,
    present_wait_semaphore_count: u32 = 0,

    fn init(device: vk.Device, swapchain_image_count: usize, present_wait_semaphore_count: u32) error {VkNotSuccess}!SwapchainOperations {
        var self: SwapchainOperations = .{};
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
        std.mem.swap(&self.acquire_image_semaphore, &self.image_available_semaphores.items[image_index]);
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

