const std = @import("std");

const CharGlyphMapping = @import("CharGlyphMapping.zig");
pub const Glyph = @import("Glyph.zig");
const helpers = @import("../helpers.zig");

const FixedPointNumber = helpers.FixedPointNumber;
const Font = @This();
const log = std.log.scoped(.Font);

pub const ttf = @import("ttf.zig");
pub const i16f16 = FixedPointNumber(i32, 16);
pub const i2f14 = FixedPointNumber(i16, 14);


file_reader: std.fs.File.Reader,
information: Information,
char_glyph_mapping: CharGlyphMapping,
pos_loca: u64,
pos_glyf: u64,
glyphs: []?Glyph,
advance_widths: []i16,


pub const Information = struct {
    units_per_em: u16,
    y0_baseline: bool,
    loca_format: ttf.Head.IndexToLocFormat,
};

pub fn initTTF(file: std.fs.File, file_buffer_size: usize) !Font {
    log.debug("loading ttf file", .{});
    const file_buffer = helpers.alloc(u8, file_buffer_size);
    errdefer helpers.allocator.free(file_buffer);
    var file_reader = file.reader(file_buffer);
    const pos_begin = file_reader.logicalPos();

    const offset_subtable = try file_reader.interface.takeStruct(ttf.OffsetSubtable, .big);

    const table_directory = helpers.alloc(ttf.TableDirectoryEntry, offset_subtable.num_tables);
    defer helpers.allocator.free(table_directory);
    for (table_directory) |*entry| entry.* = try file_reader.interface.takeStruct(ttf.TableDirectoryEntry, .big);

    const head_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .head) orelse return ttfTableEntryNotFound(.head);
    try file_reader.seekTo(pos_begin + table_directory[head_table_index].offset);
    const head = try file_reader.interface.takeStruct(ttf.Head, .big);

    const maxp_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .maxp) orelse return ttfTableEntryNotFound(.maxp);
    try file_reader.seekTo(pos_begin + table_directory[maxp_table_index].offset);
    const maxp = try file_reader.interface.takeStruct(ttf.Maxp, .big);

    const cmap_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .cmap) orelse return ttfTableEntryNotFound(.cmap);
    const pos_cmap = pos_begin + table_directory[cmap_table_index].offset;
    var cg_map = try loadTTFCharGlyphMapping(&file_reader, pos_cmap);
    errdefer cg_map.deinit();
    //try dumpTTFCmapSubtables(&file_reader, pos_cmap);

    const loca_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .loca) orelse return ttfTableEntryNotFound(.loca);
    const glyf_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .glyf) orelse return ttfTableEntryNotFound(.glyf);
    const glyphs = helpers.alloc(?Glyph, maxp.num_glyphs);
    errdefer helpers.allocator.free(glyphs);
    @memset(glyphs, null);

    const hhea_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .hhea) orelse return ttfTableEntryNotFound(.hhea);
    try file_reader.seekTo(pos_begin + table_directory[hhea_table_index].offset);
    const hhea = try file_reader.interface.takeStruct(ttf.Hhea, .big);
    const hmtx_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .hmtx) orelse return ttfTableEntryNotFound(.hmtx);
    const pos_hmtx = pos_begin + table_directory[hmtx_table_index].offset;
    const advance_widths = try loadAdvanceWidths(&file_reader, pos_hmtx, maxp.num_glyphs, hhea.num_of_long_hor_metrics);
    errdefer helpers.allocator.free(advance_widths);

    return .{
        .file_reader = file_reader,
        .pos_loca = pos_begin + table_directory[loca_table_index].offset,
        .pos_glyf = pos_begin + table_directory[glyf_table_index].offset,
        .char_glyph_mapping = cg_map,
        .glyphs = glyphs,
        .advance_widths = advance_widths,
        .information = .{
            .units_per_em = head.units_per_em,
            .y0_baseline = head.flags.y0_baseline,
            .loca_format = head.index_to_loc_format,
        },
    };
}

fn loadTTFCharGlyphMapping(file: *std.fs.File.Reader, pos_cmap: u64) !CharGlyphMapping {
    try file.seekTo(pos_cmap);
    const cmap_index = try file.interface.takeStruct(ttf.CmapIndex, .big);

    var choosed_encoding_subtable = try file.interface.takeStruct(ttf.CmapEncodingSubtable, .big);
    for (1 .. cmap_index.number_subtables) |_| {
        if (choosed_encoding_subtable.isTheBest()) break;
        const next = try file.interface.takeStruct(ttf.CmapEncodingSubtable, .big);
        if (next.isBetterThan(choosed_encoding_subtable)) choosed_encoding_subtable = next;
    } else if (!choosed_encoding_subtable.isUnicode()) {
        log.err("cannot find unicode 'cmap' subtable in ttf file", .{});
        return error.CorruptTTF;
    }

    try file.seekTo(pos_cmap + choosed_encoding_subtable.offset);
    const subtable_format = try file.interface.takeEnum(ttf.CmapSubtable.FormatNumber, .big);
    const glyph_mappings = switch (subtable_format) {
        .format4 => blk: {
            var subtable: ttf.CmapSubtable.Format4 = try .initFromReader(&file.interface);
            defer subtable.deinit();
            break :blk subtable.collectRangeMappingsAlloc();
        },
        .format12 => blk: {
            var subtable: ttf.CmapSubtable.Format12 = try .initFromReader(&file.interface);
            defer subtable.deinit();
            break :blk subtable.collectRangeMappingsAlloc();
        },
        else => {
            log.err("'cmap' subtable with {t} not supported yet", .{subtable_format});
            return error.NotSuficientTTFSupport;
        },
    };

    return CharGlyphMapping.initOwned(glyph_mappings);
}

fn loadAdvanceWidths(file: *std.fs.File.Reader, pos_hmtx: u64, num_of_glyph: u16, num_of_long_hor_metrics: u16) ![]i16 {
    //std.debug.assert(num_of_long_hor_metrics > 0);
    try file.seekTo(pos_hmtx);

    const advance_widths = helpers.alloc(i16, num_of_glyph);
    errdefer helpers.allocator.free(advance_widths);
    for (0 .. num_of_long_hor_metrics) |idx| {
        advance_widths[idx] = try file.interface.takeInt(i16, .big);
        try file.seekBy(@sizeOf(ttf.LongHorMetric) - @sizeOf(i16));
    }
    try helpers.readInts(&file.interface, .big, i16, advance_widths[num_of_long_hor_metrics..]);

    //const last = advance_widths[num_of_long_hor_metrics - 1];
    //for (advance_widths[num_of_long_hor_metrics..]) |width| std.debug.assert(width == last);

    return advance_widths;
}

fn ttfTableEntryNotFound(tag: ttf.TableTag) error {CorruptedTTF} {
    @branchHint(.cold);
    log.err("cannot find '{f}' table entry in ttf file", .{tag});
    return error.CorruptedTTF;
}

pub fn deinit(self: *Font) void {
    self.char_glyph_mapping.deinit();
    for (self.glyphs) |*maybe_glyph| {
        if (maybe_glyph.*) |*glyph| glyph.deinit();
    }
    helpers.allocator.free(self.glyphs);
    self.glyphs = undefined;

    helpers.allocator.free(self.advance_widths);
    self.advance_widths = undefined;
    helpers.allocator.free(self.file_reader.interface.buffer);
    self.file_reader.interface = undefined;
}

pub fn getGlyph(self: *Font, char: u32) !struct {Glyph, i16} {
    const glyph_index = self.char_glyph_mapping.getGlyph(char);
    if (self.glyphs[glyph_index] == null) {
        var track_stack: std.ArrayList(u16) = .empty;
        defer track_stack.deinit(helpers.allocator);
        try self.loadGlyph(glyph_index, &track_stack);
    }
    return .{self.glyphs[glyph_index].?, self.advance_widths[glyph_index]};
}

fn loadGlyph(self: *Font, glyph_index: u16, track_stack: *std.ArrayList(u16)) !void {
    log.debug("loading glyph {d}", .{glyph_index});
    const glyph_offset = switch (self.information.loca_format) {
        .short => blk: {
            try self.file_reader.seekTo(self.pos_loca + @sizeOf(u16) * glyph_index);
            const value = (try self.file_reader.interface.takeStruct(extern struct {a: [2]u16}, .big)).a;
            if (value[0] == value[1]) {
                self.glyphs[glyph_index] = .initEmpty();
                return;
            }
            break :blk value[0] * 2;
        },
        .long => blk: {
            try self.file_reader.seekTo(self.pos_loca + @sizeOf(u32) * glyph_index);
            const value = (try self.file_reader.interface.takeStruct(extern struct {a: [2]u32}, .big)).a;
            if (value[0] == value[1]) {
                self.glyphs[glyph_index] = .initEmpty();
                return;
            }
            break :blk value[0];
        },
    };

    try self.file_reader.seekTo(self.pos_glyf + glyph_offset);
    const desc = try self.file_reader.interface.takeStruct(ttf.GlyphDescription, .big);
    if (desc.number_of_contours == 0) {
        self.glyphs[glyph_index] = Glyph.initEmpty();

    } else if (desc.number_of_contours > 0) {
        var data: ttf.SimpleGlyph = try .initFromReader(&self.file_reader.interface, @bitCast(desc.number_of_contours));
        defer data.deinit();
        self.glyphs[glyph_index] = try Glyph.initTTFSimple(desc, data);

    } else {
        var data: ttf.ComponentGlyph = try .initFromReader(&self.file_reader.interface);
        defer data.deinit();

        helpers.ensureAlloc(track_stack.append(helpers.allocator, glyph_index));
        for (data.parts) |part| {
            for (track_stack.items) |pass_index| {
                if (pass_index == part.glyph_index) {
                    log.err("loop component glyph dependencies detected", .{});
                    return error.@"loop component glyph dependencies";
                }
            }
            if (self.glyphs[part.glyph_index] == null) try self.loadGlyph(part.glyph_index, track_stack);
        }

        self.glyphs[glyph_index] = try Glyph.initTTFComponent(desc, data, self.glyphs);
    }
}


pub fn dumpTTFCmapSubtables(file: *std.fs.File.Reader, pos_cmap: u64) !void {
    try file.seekTo(pos_cmap);
    const cmap_index = try file.interface.takeStruct(ttf.CmapIndex, .big);

    const entries = helpers.alloc(ttf.CmapEncodingSubtable, cmap_index.number_subtables);
    defer helpers.allocator.free(entries);
    for (entries) |*entry| entry.* = try file.interface.takeStruct(ttf.CmapEncodingSubtable, .big);

    var subtable_offsets: std.ArrayList(u64) = .empty;
    defer subtable_offsets.deinit(helpers.allocator);
    outer: for (entries, 0..) |sub, idx| {
        try file.seekTo(pos_cmap + sub.offset);
        const format = try file.interface.takeEnum(ttf.CmapSubtable.FormatNumber, .big);
        std.debug.print("  subtable: {d}, format: {t}\n", .{idx, format});

        for (subtable_offsets.items) |offset| {
            if (offset == sub.offset) {
                std.debug.print("    <duplicated>\n", .{});
                continue :outer;
            }
        }
        try subtable_offsets.append(helpers.allocator, sub.offset);
        switch (format) {
            .format4 => {
                var cmap_subtable: ttf.CmapSubtable.Format4 = try .initFromReader(&file.interface);
                defer cmap_subtable.deinit();

                for (cmap_subtable.start_code, cmap_subtable.end_code, cmap_subtable.id_delta, cmap_subtable.id_range_offset, 0..) |start_code, end_code, id_delta, id_range_offset, seg_idx| {
                    std.debug.print("    {d}..{d} -> ", .{start_code, end_code});
                    if (id_range_offset != 0) {
                        std.debug.print("{{", .{});
                        const glyph_idx_arr_start = seg_idx + id_range_offset / 2 - cmap_subtable.id_range_offset.len;
                        for (cmap_subtable.glyph_index_array[glyph_idx_arr_start..][0..(end_code - start_code + 1)]) |offset| {
                            std.debug.print("{d},", .{id_delta +% offset});
                        }
                        std.debug.print("}}", .{});
                    } else {
                        std.debug.print("{d}..{d}", .{id_delta +% start_code, id_delta +% end_code});
                    }
                    std.debug.print("\n", .{});
                }
            },
            .format12 => {
                var cmap_subtable: ttf.CmapSubtable.Format12 = try .initFromReader(&file.interface);
                defer cmap_subtable.deinit();

                for (cmap_subtable.groups) |group| {
                    std.debug.print("    {d}..{d} -> {d}..{d}\n", .{group.start_char_code, group.end_char_code, group.start_glyph_code, group.start_glyph_code + (group.end_char_code - group.start_char_code)});
                }
            },
            else => std.debug.print("    <not supported>\n", .{}),
        }
    }

}
