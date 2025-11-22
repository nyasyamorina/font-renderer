const std = @import("std");

const Appli = @import("Appli.zig");
const CallbackContext = @import("CallbackContext.zig");
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

    //const glyph = try font.getGlyph('δ');
    //var triangle_glyph: TriangulatedGlyph = .init(glyph);
    //defer triangle_glyph.deinit();

    //var glyph_debug: Image.GlyphDebug = .render(glyph, 50);
    //defer glyph_debug.rgb.deinit();
    //const qoi_file = try std.fs.cwd().createFile("playground/glyph_debug.qoi", .{});
    //defer qoi_file.close();
    //const qoi_buf = helpers.ensureAlloc(helpers.allocator.alloc(u8, 4096));
    //defer helpers.allocator.free(qoi_buf);
    //var qoi_writer = qoi_file.writer(qoi_buf);
    //defer qoi_writer.interface.flush() catch {};
    //try qoi.saveRGB(&qoi_writer.interface, &glyph_debug.rgb.interface);

    var callback_ctx: CallbackContext = .{};
    var appli: Appli = try .init(&font, &callback_ctx, .{ .width = 800, .height = 800 }, "font renderer");
    defer appli.deinit();

    try appli.setChar('δ');
    try appli.setChar('β');
    try appli.mainLoop();
}
