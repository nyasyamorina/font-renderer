const std = @import("std");

const Config = @import("Config.zig");
const Font = @import("font/Font.zig");
const glfw = @import("c/glfw.zig");
const helpers = @import("helpers.zig");
const VulkanContext = @import("VulkanContext.zig");

pub const ensureAlloc = helpers.ensureAlloc;
pub const std_options: std.Options = .{
    .logFn = helpers.logger,
    .fmt_max_depth = 10,
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

    var config_builder: Config.Builder = .init;
    defer config_builder.deinit(gpa.allocator());
    try config_builder.loadCmdLineArgs(gpa.allocator());
    const config = try config_builder.build();

    var font = try loadTTFFile(gpa.allocator(), config.font_file.value);
    defer font.deinit(gpa.allocator());

    //if (glfw.init() != glfw.true) return error.@"Failed to initialize glfw";
    //defer glfw.terminate();

    //var vk_ctx: VulkanContext = try .init(gpa.allocator(), &stdout.interface, &stdin.interface);
    //defer vk_ctx.deinit();

    //try vk_ctx.mainLoop();
    _ = &stdout; _ = &stdin;
}

fn loadTTFFile(allocator: std.mem.Allocator, file_path: []const u8) !Font {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const read_buffer = ensureAlloc(allocator.alloc(u8, 4096));
    defer allocator.free(read_buffer);
    var reader = file.reader(read_buffer);

    var font = try Font.initTTF(allocator, &reader);
    errdefer font.deinit(allocator);
    return font;
}

