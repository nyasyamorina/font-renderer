const std = @import("std");

const helper = @import("../helpers.zig");
const Image = @This();

const ensureAlloc = helper.ensureAlloc;


vtable: *const VTable,


pub const VTable = struct {
    getWidth: *const fn (image: *Image) u32,
    getHeight: *const fn (image: *Image) u32,
    getRGBLinear: *const fn (image: *Image, index: usize) [3]u8,
    getRGB: *const fn (image: *Image, x: u32, y: u32) [3]u8 = &defaultGetRGB,
};

fn defaultGetRGB(image: *Image, x: u32, y: u32) [3]u8 {
    const width = image.getWidth();
    const index = @as(usize, y) * width + x;
    return image.getRGBLinear(index);
}


pub fn getWidth(self: *Image) u32 {
    return self.vtable.getWidth(self);
}

pub fn getHeight(self: *Image) u32 {
    return self.vtable.getHeight(self);
}

pub fn getRGB(self: *Image, x: u32, y: u32) [3]u8 {
    return self.vtable.getRGB(self, x, y);
}

pub fn getRGBLinear(self: *Image, index: usize) [3]u8 {
    return self.vtable.getRGBLinear(self, index);
}


pub const Gray = struct {
    width: u32,
    height: u32,
    data: []u8,
    interface: Image,

    pub fn initInterface() Image {
        return .{ .vtable = &.{
            .getWidth = &implGetWidth,
            .getHeight = &implGetHeight,
            .getRGBLinear = &implGetRGBLinear,
        } };
    }

    pub fn init(allocatoor: std.mem.Allocator, width: u32, height: u32) Image.Gray {
        const data = ensureAlloc(allocatoor.alloc(u8, @as(usize, width) * height));
        return .{ .width = width, .height = height, .data = data, .interface = initInterface() };
    }

    pub fn deinit(self: *Image.Gray, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.data = undefined;
    }

    fn implGetWidth(image: *Image) u32 {
        const self: *const Image.Gray = @fieldParentPtr("interface", image);
        return self.width;
    }

    fn implGetHeight(image: *Image) u32 {
        const self: *const Image.Gray = @fieldParentPtr("interface", image);
        return self.height;
    }

    fn implGetRGBLinear(image: *Image, index: usize) [3]u8 {
        const self: *const Image.Gray = @fieldParentPtr("interface", image);
        const val = self.data[index];
        return .{val, val, val};
    }
};

