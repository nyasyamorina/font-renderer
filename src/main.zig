const std = @import("std");

const config = @import("config.zig");
const glfw = @import("c/glfw.zig");
const helpers = @import("helpers.zig");
const VulkanContext = @import("VulkanContext.zig");

pub const ensureAlloc = helpers.ensureAlloc;
pub const std_options: std.Options = .{
    .logFn = helpers.logger,
};


pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const io_buffer_size = 512;
    const io_buffer_count = 2;
    const io_buffers = ensureAlloc(gpa.allocator().alloc([io_buffer_size]u8, io_buffer_count));
    defer gpa.allocator().free(io_buffers);

    var stdout = std.fs.File.stdout().writer(&io_buffers[0]);
    var stdin = std.fs.File.stdin().reader(&io_buffers[1]);

    if (glfw.init() != glfw.@"true") return error.@"Failed to initialize glfw";
    defer glfw.terminate();

    var vk_ctx: VulkanContext = try .init(gpa.allocator(), &stdout.interface, &stdin.interface);
    defer vk_ctx.deinit();

    try vk_ctx.mainLoop();
}

