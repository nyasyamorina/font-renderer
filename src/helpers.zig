const std = @import("std");

const vk = @import("c/vk.zig");


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
    const error_count = std.meta.tags(@typeInfo(@TypeOf(allocate_result)).error_union.error_set).len;
    if (error_count == 0) {
        return allocate_result catch unreachable;
    } else if (error_count == 1) {
        return allocate_result catch |err| switch (err) {
            error.OutOfMemory => @panic("OOM"),
        };
    } else {
        @compileError("this method can only call after memory allocations");
    }
}

