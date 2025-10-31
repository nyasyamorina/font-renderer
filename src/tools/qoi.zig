const std = @import("std");

const Image = @import("Image.zig");


pub const Header = extern struct {
    magic: [4]u8,
    width: u32 align(1),
    height: u32 align(1),
    channels: Channels align(1),
    colorspace: Colorspace align(1),

    pub const Channels = enum(u8) {
        RGB = 3,
        RGBA = 4,
    };

    pub const Colorspace = enum(u8) {
        sRGB = 0,
        linear_RGB = 1,
    };
};


pub fn saveRGB(writer: *std.Io.Writer, image: *Image) std.Io.Writer.Error!void {
    try writer.writeStruct(Header {
        .magic = "qoif".*,
        .width = image.getWidth(),
        .height = image.getHeight(),
        .channels = .RGB,
        .colorspace = .sRGB,
    }, .big);
    const total = @as(usize, image.getWidth()) * image.getHeight();

    var running = std.mem.zeroes([64][3]u8);

    var prev: [3]u8 = undefined;
    var curr: [3]u8 = .{0, 0, 0};
    var ridx: u6 = 0;
    var next_idx: usize = 0;
    while (next_idx < total) {
        running[ridx] = curr;
        prev = curr;
        curr = image.getRGBLinear(next_idx);
        ridx = runningIndex(.{curr[0], curr[1], curr[2], 255});
        next_idx += 1;

        if (std.meta.eql(prev, curr)) {
            var run: u8 = 0;
            while (
                run < 0x3D and
                next_idx < total and
                std.meta.eql(prev, image.getRGBLinear(next_idx))
            ) {
                next_idx += 1;
                run += 1;
            }
            try writer.writeByte(0xC0 | run);
            continue;

        } else if (std.meta.eql(running[ridx], curr)) {
            try writer.writeByte(0x00 | ridx);
            continue;

        } else {
            const v3u8 = @Vector(3, u8);
            var dr, var dg, var db = @as(v3u8, curr) -% @as(v3u8, prev) +% @as(v3u8, @splat(2));
            if (dr < 4 and  dg < 4 and db < 4) {
                try writer.writeByte(0x40 | (dr << 4) | (dg << 2) | (db));
                continue;
            }

            dr +%= 8 -% dg; db +%= 8 -% dg; dg +%= 30;
            if (dr < 16 and dg < 64 and db < 16) {
                try writer.writeAll(&.{0x80 | dg, (dr << 4) | (db)});
                continue;
            }
        }

        try writer.writeAll(&.{0xFE, curr[0], curr[1], curr[2]});
    }
    try writer.writeInt(u64, 1, .big);
}

fn runningIndex(rgba: [4]u8) u6 {
    const r, const g, const b, const a = rgba;
    return @truncate(r *% 3 +% g *% 5 +% b *% 7 +% a *% 11);
}

