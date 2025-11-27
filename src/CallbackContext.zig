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
char_remove_count: u32 = 0,


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

pub export fn charCallback(window: ?*glfw.Window, char: c_uint) void {
    getSelf(window).charFn(@intCast(char));
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
    switch (key) {
        .escape => { if (action == .release) self.esc_pressed = true; },
        .backspace => { if (action != .release) self.char_remove_count += 1; },
        .m => { if (mods.control and action == .press) self.change_msaa = true; },
        else => {},
    }
    //std.debug.print("key: {any}, action: {any}, mods: {any}\n", .{key, action, mods});
    _ = scancode;
}

fn charFn(self: *CallbackContext, char: u21) void {
    var utf8: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(char, &utf8) catch |err| {
        std.debug.print("utf8 err {d}: {t}\n", .{char, err});
        return;
    };
    std.debug.print("char: {s}\n", .{utf8[0..len]});
    _ = self;
}
