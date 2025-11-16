const builtin = @import("builtin");
const std = @import("std");

const vk = @import("c/vk.zig");

pub const native_endian = builtin.target.cpu.arch.endian();
pub const in_safe_mode = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub var allocator: std.mem.Allocator = if (in_safe_mode) undefined else std.heap.smp_allocator;


pub fn logger(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const scope_name = switch (scope) {
        .default => "",
        else => "(" ++ @tagName(scope) ++ ")",
    };
    const log_format = scope_name ++ " [" ++ comptime level.asText() ++ "]: " ++ format ++ "\n";
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    var stderr = std.fs.File.stderr().writer(&.{});
    nosuspend stderr.interface.print(log_format, args) catch {};
}


pub fn ensureVkSuccess(comptime name: []const u8, result: vk.Result) !void {
    if (result != vk.success) {
        @branchHint(.cold);
        const log = std.log.scoped(.vk);
        log.err("failed to execute {s} with result code {d}", .{name, result});
        return error.VkNotSuccess;
    }
}

pub fn ensureAlloc(allocate_result: anytype) @typeInfo(@TypeOf(allocate_result)).error_union.payload {
    const errors = @typeInfo(@typeInfo(@TypeOf(allocate_result)).error_union.error_set).error_set.?;
    switch (errors.len) {
        0 => return allocate_result catch unreachable,
        1 => {
            comptime std.debug.assert(std.mem.eql(u8, errors[0].name, "OutOfMemory"));
            return allocate_result catch {
                @branchHint(.cold);
                @panic("OOM");
            };
        },
        inline else => @compileError("this method can only call after memory allocations"),
    }
}
pub fn alloc(comptime T: type, count: usize) []T {
    return ensureAlloc(allocator.alloc(T, count));
}

/// ensure array elements are monotonically increasing
pub fn ensureMonoIncrease(comptime T: type, arr: []const T) void {
    if (in_safe_mode) {
        if (arr.len < 2) return;
        for (arr[0 .. arr.len-1], arr[1..]) |left, right| {
            if (left >= right) unreachable;
        }
    }
}


pub fn FixedPointNumber(comptime T: type, comptime _bias_bits: comptime_int) type {
    std.debug.assert(_bias_bits >= 0);
    return extern struct {
        data: @This().Data,

        pub const zero: @This() = .init(0);
        pub const one: @This() = .init(1);

        pub const Data = T;
        pub const bias_bits = _bias_bits;
        pub const bias = blk: {
            var b: comptime_float = 1;
            var t: comptime_float = 0.5;
            var i: comptime_int = @This().bias_bits;
            while (i != 0) {
                if (i & 1 != 0) b *= t;
                t *= t;
                i >>= 1;
            }
            break :blk b;
        };

        pub fn init(value: anytype) @This() {
            switch (@typeInfo(@TypeOf(value))) {
                .comptime_int => {
                    return .{ .data = @intCast(value << bias_bits) };
                },
                .int => |info| {
                    comptime std.debug.assert(info.bits - (if (info.signedness == .signed) 1 else 0) > bias_bits);
                    const tmp: Data = @intCast(value);
                    const ov = @shlWithOverflow(tmp, bias_bits);
                    if (ov.@"1" != 0) unreachable;
                    return .{ .data = ov.@"0" };
                },
                .comptime_float, .float => {
                    const tmp = value / bias;
                    return .{ .data = @intFromFloat(tmp) };
                },
                else => @compileError(@typeName(@TypeOf(value)) ++ " cannot be convert to " ++ @typeName(@This())),
            }
        }

        /// discard the decimal part
        pub fn toInt(self: @This(), comptime Int: type) Int {
            return @intCast(self.data >> bias_bits);
        }

        pub fn toFloat(self: @This(), comptime F: type) F {
            const f: F = @floatFromInt(self.data);
            return f * @This().bias;
        }

        pub fn roundToInt(self: @This(), comptime Int: type) Int {
            if (bias_bits == 0) return @intCast(self.data);
            const base: Int = @intCast(self.data >> bias_bits);
            if (self.data < 0) {
                if (self.data == std.math.minInt(Data)) return base;
                return if ((-self.data) & (@as(Data, 1) << (bias_bits - 1)) == 0) base else base - 1;
            } else {
                return if (self.data & (@as(Data, 1) << (bias_bits - 1)) == 0) base else base + 1;
            }
        }

        pub fn cmp(self: @This(), other: @This()) std.math.Order {
            return if (self.data < other.data) .lt else if (self.data > other.data) .gt else .eq;
        }
    };
}


pub fn readInts(reader: *std.Io.Reader, endian: std.builtin.Endian, comptime Int: type, arr: []Int) std.Io.Reader.Error!void {
    const n_bytes = @divExact(@typeInfo(Int).int.bits, 8);
    try reader.readSliceAll(@as([*]u8, @ptrCast(arr))[0 .. n_bytes * arr.len]);
    if (endian != native_endian) { for (arr) |*ele| ele.* = @byteSwap(ele.*); }
}

pub fn readIntAlloc(ally: std.mem.Allocator, reader: *std.Io.Reader, endian: std.builtin.Endian, comptime Int: type, n: usize) std.Io.Reader.Error![]Int {
    const arr = ensureAlloc(ally.alloc(Int, n));
    errdefer ally.free(arr);
    try readInts(reader, endian, Int, arr);
    return arr;
}


pub fn PhysicalDeviceFeatures(comptime FeatureTypes: []const type) type {
    _ = std.debug.assert(FeatureTypes[0] == vk.PhysicalDeviceFeatures2);
    return struct {
        features: Features,

        pub const Features = blk: {
            var fields: [FeatureTypes.len]std.builtin.Type.StructField = undefined;
            for (&fields, FeatureTypes) |*field, ftype| {
                field.* = .{
                    .type = ftype,
                    .name = featureType2FieldName(ftype),
                    .default_value_ptr = @ptrCast(&ftype {
                        .sType = vkSType(ftype),
                    }),
                    .is_comptime = false,
                    .alignment = @alignOf(ftype),
                };
            }
            break :blk @Type( .{ .@"struct" = .{
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
                .layout = .@"extern",
            } });
        };

        pub const init: @This() = .{ .features = .{} };

        pub fn buildChain(self: *@This()) *vk.PhysicalDeviceFeatures2 {
            var prev_ptr: ?*anyopaque = null;
            inline for (0 .. FeatureTypes.len) |rev_idx| {
                const ftype = FeatureTypes[FeatureTypes.len - 1 - rev_idx];
                const field_name = comptime featureType2FieldName(ftype);
                //@field(self.features, field_name).sType = vkSType(ftype);
                @field(self.features, field_name).pNext = prev_ptr;
                prev_ptr = @ptrCast(&@field(self.features, field_name));
            }
            return &self.features.@"2";
        }

        pub fn check(self: @This(), target: @This()) bool {
            const log = std.log.scoped(.CheckPhysicalDeviceFeatures);
            var pass = true;
            inline for (FeatureTypes) |ftype| {
                const field_name = comptime featureType2FieldName(ftype);
                const ftype2 = if (ftype == vk.PhysicalDeviceFeatures2) vk.PhysicalDeviceFeatures else ftype;
                const self_f = if (ftype == vk.PhysicalDeviceFeatures2) @field(self.features, field_name).features else @field(self.features, field_name);
                const target_f = if (ftype == vk.PhysicalDeviceFeatures2) @field(target.features, field_name).features else @field(target.features, field_name);

                inline for (@typeInfo(ftype2).@"struct".fields) |field| {
                    if (field.type == vk.Bool32) {
                        if (@field(target_f, field.name) == vk.@"true" and
                            @field(self_f, field.name) != vk.@"true") {
                            log.err("device not cantain feature: \"{s}.{s}\"", .{@typeName(ftype), field.name});
                            pass = false;
                        }
                    }
                }
            }
            return pass;
        }

        pub fn featureType2FieldName(comptime ftype: type) [:0]const u8 {
            return switch (ftype) {
                vk.PhysicalDeviceFeatures2 => "2",
                vk.PhysicalDeviceVulkan11Features => "vulkan11",
                vk.PhysicalDeviceVulkan12Features => "vulkan12",
                vk.PhysicalDeviceVulkan13Features => "vulkan13",
                vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT => "extended_dynamic_state",
                vk.PhysicalDevice16BitStorageFeatures => "storage_16bit",
                else => @compileError(@typeName(ftype) ++ " not supported yet"),
            };
        }
    };
}

pub fn vkSType(comptime T: type) vk.StructureType {
    return switch (T) {
        vk.ApplicationInfo => vk.structure_type_application_info,
        vk.BufferCreateInfo => vk.structure_type_buffer_create_info,
        vk.CommandBufferAllocateInfo => vk.structure_type_command_buffer_allocate_info,
        vk.CommandBufferBeginInfo => vk.structure_type_command_buffer_begin_info,
        vk.CommandPoolCreateInfo => vk.structure_type_command_pool_create_info,
        vk.ComputePipelineCreateInfo => vk.structure_type_comput_pipeline_create_info,
        vk.DebugUtilsMessengerCreateInfoEXT => vk.structure_type_debug_utils_messenger_create_info_EXT,
        vk.DependencyInfo => vk.structure_type_dependency_info,
        vk.DescriptorPoolCreateInfo => vk.structure_type_descriptor_pool_create_info,
        vk.DescriptorSetAllocateInfo => vk.structure_type_descriptor_set_allocate_info,
        vk.DescriptorSetLayoutCreateInfo => vk.structure_type_descriptor_set_layout_create_info,
        vk.DeviceCreateInfo => vk.structure_type_device_create_info,
        vk.DeviceQueueCreateInfo => vk.structure_type_device_queue_create_info,
        vk.FenceCreateInfo => vk.structure_type_fence_create_info,
        vk.FramebufferCreateInfo => vk.structure_type_framebuffer_create_info,
        vk.GraphicsPipelineCreateInfo => vk.structure_type_graphics_pipeline_create_info,
        vk.ImageCreateInfo => vk.structure_type_image_create_info,
        vk.ImageMemoryBarrier => vk.structure_type_image_memory_barrier,
        vk.ImageMemoryBarrier2 => vk.structure_type_image_memory_barrier_2,
        vk.ImageViewCreateInfo => vk.structure_type_image_view_create_info,
        vk.InstanceCreateInfo => vk.structure_type_instance_craete_info,
        vk.MemoryAllocateInfo => vk.structure_type_memory_allocate_info,
        vk.PhysicalDevice16BitStorageFeatures => vk.structure_type_physical_device_16bit_storage_features,
        vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT => vk.structure_type_physical_device_extended_dynamic_state_features_EXT,
        vk.PhysicalDeviceFeatures2 => vk.structure_type_physical_device_features_2,
        vk.PhysicalDeviceVulkan11Features => vk.structure_type_physical_device_vulkan_1_1_features,
        vk.PhysicalDeviceVulkan12Features => vk.structure_type_physical_device_vulkan_1_2_features,
        vk.PhysicalDeviceVulkan13Features => vk.structure_type_physical_device_vulkan_1_3_features,
        vk.PipelineColorBlendStateCreateInfo => vk.structure_type_pipeline_color_blend_state_create_info,
        vk.PipelineDepthStencilStateCreateInfo => vk.structure_type_pipeline_depth_ctensil_state_create_info,
        vk.PipelineDynamicStateCreateInfo => vk.structure_type_pipeline_dynamic_state_create_info,
        vk.PipelineInputAssemblyStateCreateInfo => vk.structure_type_pipeline_input_assembly_state_create_info,
        vk.PipelineLayoutCreateInfo => vk.structure_type_pipeline_layout_create_info,
        vk.PipelineMultisampleStateCreateInfo => vk.structure_type_pipeline_multisample_state_create_info,
        vk.PipelineRasterizationStateCreateInfo => vk.structure_type_pipeline_rasterization_state_create_info,
        vk.PipelineRenderingCreateInfo => vk.structure_type_pipeline_rendering_create_info,
        vk.PipelineShaderStageCreateInfo => vk.structure_type_pipeline_shader_stage_create_info,
        vk.PipelineVertexInputStateCreateInfo => vk.structure_type_pipeline_vertex_input_state_create_info,
        vk.PipelineViewportStateCreateInfo => vk.structure_type_pipeline_viewport_state_create_info,
        vk.PresentInfoKHR => vk.structure_type_present_info_KHR,
        vk.RenderPassBeginInfo => vk.structure_type_render_pass_begin_info,
        vk.RenderPassCreateInfo => vk.structure_type_render_pass_create_info,
        vk.RenderingAttachmentInfo => vk.structure_type_rendering_attachment_info,
        vk.RenderingInfo => vk.structure_type_rendering_info,
        vk.SamplerCreateInfo => vk.structure_type_sampler_create_info,
        vk.SemaphoreCreateInfo => vk.structure_type_semaphore_create_info,
        vk.ShaderModuleCreateInfo => vk.structure_type_shader_module_create_info,
        vk.SubmitInfo => vk.structure_type_submit_info,
        vk.SwapchainCreateInfoKHR => vk.structure_type_swapchain_create_info_KHR,
        vk.WriteDescriptorSet => vk.structure_type_write_descriptor_set,
        else => @compileError(@typeName(T) ++ " is not indexing structure type"),
    };
}

