const std = @import("std");


pub fn Point(comptime T: type) type {
    return extern struct {
        x: T,
        y: T,

        pub fn initMiddle(p0: @This(), p1: @This()) @This() {
            return .{
                .x = @divTrunc(p0.x + p1.x, 2),
                .y = @divTrunc(p0.y + p1.y, 2),
            };
        }

        pub fn to(self: @This(), comptime U: type) Point(U) {
            switch (@typeInfo(T)) {
                .int => switch (@typeInfo(U)) {
                    .int => return .{ .x = @intCast(self.x), .y = @intCast(self.y) },
                    .float => return .{ .x = @floatFromInt(self.x), .y = @floatFromInt(self.y) },
                    else => @compileError(@typeName(U) ++ " is not a numrical type"),
                },
                .float => switch (@typeInfo(U)) {
                    .int => return .{ .x = @intFromFloat(self.x), .y = @intFromFloat(self.y) },
                    .float => return .{ .x = self.x, .y = self.y },
                    else => @compileError(@typeName(U) ++ "is not a numrical type"),
                },
                else => @compileError(@typeName(T) ++ "is not a numrical type"),
            }
        }
    };
}

