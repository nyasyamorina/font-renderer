const builtin = @import("builtin");
const std = @import("std");

const vk = @import("c/vk.zig");

pub const native_endian = builtin.target.cpu.arch.endian();
pub const in_safe_mode = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;


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
    return struct {
        data: @This().Data,

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

        pub fn toFloat(self: @This(), comptime F: type) F {
            const f: F = @floatFromInt(self.data);
            return f * @This().bias;
        }
    };
}


pub fn readInts(reader: *std.Io.Reader, endian: std.builtin.Endian, comptime Int: type, arr: []Int) std.Io.Reader.Error!void {
    const n_bytes = @divExact(@typeInfo(Int).int.bits, 8);
    try reader.readSliceAll(@as([*]u8, @ptrCast(arr))[0 .. n_bytes * arr.len]);
    if (endian != native_endian) { for (arr) |*ele| ele.* = @byteSwap(ele.*); }
}

pub fn readIntAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader, endian: std.builtin.Endian, comptime Int: type, n: usize) std.Io.Reader.Error![]Int {
    const arr = ensureAlloc(allocator.alloc(Int, n));
    errdefer allocator.free(arr);
    try readInts(reader, endian, Int, arr);
    return arr;
}

