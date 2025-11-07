const std = @import("std");

const Appli = @import("Appli.zig");
const Config = @import("Config.zig");
const Font = @import("font/Font.zig");
const glfw = @import("c/glfw.zig");
const helpers = @import("helpers.zig");
const Image = @import("tools/Image.zig");
const qoi = @import("tools/qoi.zig");
const TriangulatedGlyph = @import("tools/TriangulatedGlyph.zig");
const renderGlyph = @import("tools/render_glyph.zig").renderGlyph;

pub var gpa = if (helpers.in_safe_mode) std.heap.DebugAllocator(.{}).init else @as(void, undefined);
pub const std_options: std.Options = .{
    .logFn = helpers.logger,
    .fmt_max_depth = 10,
};


pub fn main() !void {
    if (helpers.in_safe_mode) helpers.allocator = gpa.allocator();
    defer if (helpers.in_safe_mode) { _ = gpa.deinit(); };

    var config_builder: Config.Builder = .init;
    defer config_builder.deinit();
    try config_builder.loadCmdLineArgs();
    const config = try config_builder.build();

    const ttf_file = try std.fs.cwd().openFile(config.font_file.value, .{});
    defer ttf_file.close();
    var font: Font = try .initTTF(ttf_file, 1024);
    defer font.deinit();

    const glyph = try font.getGlyph('α');

    try renderActualGlyphToQoi(glyph, "playground/winding.qoi");

    var appli: Appli = try .init(.{ .width = 800, .height = 600 }, "font renderer");
    defer appli.deinit();
}

fn renderActualGlyphToQoi(glyph: Font.Glyph, qoi_filepath: []const u8) !void {
    var glyph_info = TriangulatedGlyph.GlyphInfo.init(glyph);
    defer glyph_info.deinit();

    var im: Image.GlyphDebug = .init(glyph.box, 20, 150, .{255, 255, 0}, .{0, 255, 255});
    defer im.rgb.deinit();

    var h: u16 = 0;
    while (h < im.rgb.height) : (h += 1) {
        var w: u16 = 0;
        while (w < im.rgb.width) : (w += 1) {
            const idx = h * im.rgb.width + w;
            const y = glyph.box.y_max - @as(i16, @intCast(h)) + 1;
            const x = glyph.box.x_min + @as(i16, @intCast(w)) - 1;
            const winding = TriangulatedGlyph.windingInGlyph(glyph, glyph_info, .{ .x = x, .y = y });
            im.setWindingLinear(idx, winding);
        }
    }
    im.setGlyphPoints(glyph);

    const qoi_file = try std.fs.cwd().createFile(qoi_filepath, .{});
    defer qoi_file.close();

    var buf: [512]u8 = undefined;
    var qoi_writer = qoi_file.writer(&buf);
    defer qoi_writer.interface.flush() catch {};

    try qoi.saveRGB(&qoi_writer.interface, &im.rgb.interface);
}

