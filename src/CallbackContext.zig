const std = @import("std");

const glfw = @import("c/glfw.zig");
const helpers = @import("helpers.zig");

const CallbackContext = @This();
const Appli = @import("./Appli.zig");


resized: bool = false,
dragding: bool = false,
scroll_accumulate: f64 = 0,
esc_pressed: bool = false,
change_msaa: bool = false,


pub export fn resizeCallback(window: ?*glfw.Window, width: c_int, height: c_int) callconv(.c) void {
    getSelf(window).resize(width, height);
}

pub export fn scrollCallback(window: ?*glfw.Window, x: f64, y: f64) callconv(.c) void {
    getSelf(window).scroll(x, y);
}

pub export fn mouseButtonCallback(window: ?*glfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    getSelf(window).mouseButton(@enumFromInt(button), @enumFromInt(action), @bitCast(mods));
}

pub export fn keyCallback(window: ?*glfw.Window, key: c_int, scancode: c_int, action: c_int, mods: c_int) void {
    getSelf(window).keyFn(@enumFromInt(key), scancode, @enumFromInt(action), @bitCast(mods));
}

fn getSelf(window: ?*glfw.Window) *CallbackContext {
    const user_ptr = glfw.getWindowUserPointer(window);
    return @ptrCast(@alignCast(user_ptr.?));
}


fn resize(self: *CallbackContext, width: c_int, height: c_int) void {
    self.resized = true;
    _ = .{width, height};
}

fn scroll(self: *CallbackContext, x: f64, y: f64) void {
    self.scroll_accumulate += y;
    _ = x;
}

fn mouseButton(self: *CallbackContext, button: glfw.MouseBotton, action: glfw.Action, mods: glfw.Mods) void {
    if (button == .left) {
        switch (action) {
            .press => self.dragding = true,
            .release => self.dragding = false,
            else => {},
        }
    }
    _ = mods;
}

fn keyFn(self: *CallbackContext, key: glfw.Key, scancode: c_int, action: glfw.Action, mods: glfw.Mods) void {
    if (key == .escape and action == .release) self.esc_pressed = true;
    if (key == .m and action == .press and mods.control) self.change_msaa = true;
    _ = scancode;
}
