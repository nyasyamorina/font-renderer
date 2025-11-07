const std = @import("std");

const Appli = @This();
const Font = @import("font/Font.zig");
const glfw = @import("c/glfw.zig");
const vk = @import("c/vk.zig");
const VulkanContext = @import("VulkanContext.zig");


vk_ctx: VulkanContext,


pub fn init(window_size: vk.Extent2D, window_title: [*:0]const u8) !Appli {
    if (glfw.init() != glfw.@"true") return error.@"failed to initialize glfw";
    errdefer glfw.terminate();

    var vk_ctx: VulkanContext = try .init(window_size, window_title);
    errdefer vk_ctx.deinit();

    return .{
        .vk_ctx = vk_ctx,
    };
}

pub fn deinit(self: *Appli) void {
    self.vk_ctx.deinit();
    glfw.terminate();
}

pub fn mainLoop(self: *Appli) !void {
    _ = self;
}

pub fn addGlyph(self: *Appli,font_info: Font.Information, glyph: Font.Glyph, font_size: u16) !void {
    _ = self; _ = font_info; _ = glyph; _ = font_size;
}

