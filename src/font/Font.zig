const std = @import("std");

const CharGlyphMapping = @import("CharGlyphMapping.zig");
pub const Glyph = @import("Glyph.zig");
const helpers = @import("../helpers.zig");

const ensureAlloc = helpers.ensureAlloc;
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


pub const Information = struct {
    units_per_em: u16,
    y0_baseline: bool,
    loca_format: ttf.Head.IndexToLocFormat,
};

pub fn initTTF(file: std.fs.File, file_buffer_size: usize) !Font {
    log.debug("loading ttf file", .{});
    const file_buffer = ensureAlloc(helpers.allocator.alloc(u8, file_buffer_size));
    errdefer helpers.allocator.free(file_buffer);
    var file_reader = file.reader(file_buffer);
    const pos_begin = file_reader.logicalPos();

    const offset_subtable = try file_reader.interface.takeStruct(ttf.OffsetSubtable, .big);

    const table_directory = ensureAlloc(helpers.allocator.alloc(ttf.TableDirectoryEntry, offset_subtable.num_tables));
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

    const loca_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .loca) orelse return ttfTableEntryNotFound(.loca);
    const glyf_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .glyf) orelse return ttfTableEntryNotFound(.glyf);
    const glyphs = ensureAlloc(helpers.allocator.alloc(?Glyph, maxp.num_glyphs));
    errdefer helpers.allocator.free(glyphs);
    for (glyphs) |*glyph| glyph.* = null;

    return .{
        .file_reader = file_reader,
        .pos_loca = pos_begin + table_directory[loca_table_index].offset,
        .pos_glyf = pos_begin + table_directory[glyf_table_index].offset,
        .char_glyph_mapping = cg_map,
        .glyphs = glyphs,
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

    helpers.allocator.free(self.file_reader.interface.buffer);
    self.file_reader.interface = undefined;
}

pub fn getGlyph(self: *Font, char: u32) !Glyph {
    const glyph_index = self.char_glyph_mapping.getGlyph(char);
    if (self.glyphs[glyph_index] == null) {
        var track_stack: std.ArrayList(u16) = .empty;
        defer track_stack.deinit(helpers.allocator);
        try self.loadGlyph(glyph_index, &track_stack);
    }
    return self.glyphs[glyph_index].?;
}

fn loadGlyph(self: *Font, glyph_index: u16, track_stack: *std.ArrayList(u16)) !void {
    log.debug("loading glyph {d}", .{glyph_index});
    const glyph_offset = switch (self.information.loca_format) {
        .short => blk: {
            try self.file_reader.seekTo(self.pos_loca + @sizeOf(u16) * glyph_index);
            const value = try self.file_reader.interface.takeInt(u16, .big);
            break :blk value * 2;
        },
        .long => blk: {
            try self.file_reader.seekTo(self.pos_loca + @sizeOf(u32) * glyph_index);
            const value = try self.file_reader.interface.takeInt(u32, .big);
            break :blk value;
        },
    };

    try self.file_reader.seekTo(self.pos_glyf + glyph_offset);
    const desc = try self.file_reader.interface.takeStruct(ttf.GlyphDescription, .big);
    if (desc.number_of_contours == 0) {
        self.glyphs[glyph_index] = Glyph.initEmpty(desc);

    } else if (desc.number_of_contours > 0) {
        var data: ttf.SimpleGlyph = try .initFromReader(&self.file_reader.interface, @bitCast(desc.number_of_contours));
        defer data.deinit();
        self.glyphs[glyph_index] = try Glyph.initTTFSimple(desc, data);

    } else {
        var data: ttf.ComponentGlyph = try .initFromReader(&self.file_reader.interface);
        defer data.deinit();

        ensureAlloc(track_stack.append(helpers.allocator, glyph_index));
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


pub fn dumpTTFCmapSubtables(allocator: std.mem.Allocator, file: *std.fs.File.Reader, pos_cmap: u64, enties: []const ttf.CmapEncodingSubtable) !void {
    var subtable_offsets: std.ArrayList(u64) = .empty;
    defer subtable_offsets.deinit(allocator);
    outer: for (enties, 0..) |sub, idx| {
        try file.seekTo(pos_cmap + sub.offset);
        const format = try file.interface.takeEnum(ttf.CmapSubtable.FormatNumber, .big);
        std.debug.print("  subtable: {d}, format: {t}\n", .{idx, format});

        for (subtable_offsets.items) |offset| {
            if (offset == sub.offset) {
    std.debug.print("    <duplicated>\n", .{});
                continue :outer;
            }
        }
        try subtable_offsets.append(allocator, sub.offset);
        switch (format) {
            .format4 => {
                var cmap_subtable: ttf.CmapSubtable.Format4 = try .initFromReader(allocator, &file.interface);
                defer cmap_subtable.deinit(allocator);

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
                var cmap_subtable: ttf.CmapSubtable.Format12 = try .initFromReader(allocator, &file.interface);
                defer cmap_subtable.deinit(allocator);

                for (cmap_subtable.groups) |group| {
                    std.debug.print("    {d}..{d} -> {d}..{d}\n", .{group.start_char_code, group.end_char_code, group.start_glyph_code, group.start_glyph_code + (group.end_char_code - group.start_char_code)});
                }
            },
            else => std.debug.print("    <not supported>\n", .{}),
        }
    }

}

