const std = @import("std");

const Appli = @import("Appli.zig");
const Config = @import("Config.zig");
const Font = @import("font/Font.zig");
const glfw = @import("c/glfw.zig");
const helpers = @import("helpers.zig");
const qoi = @import("tools/qoi.zig");
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

    try renderGlyphToQoi(&font, 'α', 600, "playground/out.qoi");

    var appli: Appli = try .init(.{ .width = 800, .height = 600 });
    defer appli.deinit();
}

fn renderGlyphToQoi(font: *Font, char: u32, font_size: u16, qoi_filepath: []const u8) !void {
    const glyph = try font.getGlyph(char);

    var im = try renderGlyph(glyph, font.information, font_size);
    defer im.deinit(helpers.allocator);

    const qoi_file = try std.fs.cwd().createFile(qoi_filepath, .{});
    defer qoi_file.close();

    var buf: [512]u8 = undefined;
    var qoi_writer = qoi_file.writer(&buf);
    defer qoi_writer.interface.flush() catch {};

    try qoi.saveRGB(&qoi_writer.interface, &im.interface);
}

