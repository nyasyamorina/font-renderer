const std = @import("std");

const CharGlyphMapping = @import("CharGlyphMapping.zig");
const Glyph = @import("Glyph.zig");
const helper = @import("../helpers.zig");

const ensureAlloc = helper.ensureAlloc;
const FixedPointNumber = helper.FixedPointNumber;
const Font = @This();
const log = std.log.scoped(.Font);

pub const ttf = @import("ttf.zig");
pub const i16f16 = FixedPointNumber(i32, 16);
pub const i2f14 = FixedPointNumber(i16, 14);


unit_per_em: u16,
char_glyph_mapping: CharGlyphMapping,
glyphs: []Glyph,


pub fn initTTF(allocator: std.mem.Allocator, file: *std.fs.File.Reader) !Font {
    const pos_begin = file.logicalPos();
    errdefer file.seekTo(pos_begin) catch {};

    const offset_subtable = try file.interface.takeStruct(ttf.OffsetSubtable, .big);

    const table_directory = ensureAlloc(allocator.alloc(ttf.TableDirectoryEntry, offset_subtable.num_tables));
    defer allocator.free(table_directory);
    for (table_directory) |*entry| entry.* = try file.interface.takeStruct(ttf.TableDirectoryEntry, .big);
    for (table_directory) |entry| std.debug.print("  {f}: {any}\n", .{entry.tag, entry});

    const head_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .head) orelse return ttfTableEntryNotFound(.head);
    try file.seekTo(pos_begin + table_directory[head_table_index].offset);
    const head = try file.interface.takeStruct(ttf.Head, .big);
    std.debug.print("head: {any}\n", .{head});

    const maxp_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .maxp) orelse return ttfTableEntryNotFound(.maxp);
    try file.seekTo(pos_begin + table_directory[maxp_table_index].offset);
    const maxp = try file.interface.takeStruct(ttf.Maxp, .big);
    std.debug.print("maxp: {any}\n", .{maxp});

    const cmap_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .cmap) orelse return ttfTableEntryNotFound(.cmap);
    const pos_cmap = pos_begin + table_directory[cmap_table_index].offset;
    var cg_map = try loadTTFCharGlyphMapping(allocator, file, pos_cmap);
    errdefer cg_map.deinit(allocator);

    const loca_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .loca) orelse return ttfTableEntryNotFound(.loca);
    const glyf_table_index = ttf.TableDirectoryEntry.findIndex(table_directory, .glyf) orelse return ttfTableEntryNotFound(.glyf);
    const pos_loca = pos_begin + table_directory[loca_table_index].offset;
    const pos_glyf = pos_begin + table_directory[glyf_table_index].offset;
    const glyphs = try loadTTFGlyphs(allocator, file, pos_loca, pos_glyf, maxp.num_glyphs, head.index_to_loc_format);
    errdefer {
        for (glyphs) |*glyph| glyph.deinit(allocator);
        allocator.free(glyphs);
    }

    return .{
        .unit_per_em = head.units_per_em,
        .char_glyph_mapping = cg_map,
        .glyphs = glyphs,
    };
}

fn loadTTFCharGlyphMapping(allocator: std.mem.Allocator, file: *std.fs.File.Reader, pos_cmap: u64) !CharGlyphMapping {
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
            var subtable: ttf.CmapSubtable.Format4 = try .initFromReader(allocator, &file.interface);
            defer subtable.deinit(allocator);
            break :blk subtable.collectRangeMappingsAlloc(allocator);
        },
        .format12 => blk: {
            var subtable: ttf.CmapSubtable.Format12 = try .initFromReader(allocator, &file.interface);
            defer subtable.deinit(allocator);
            break :blk subtable.collectRangeMappingsAlloc(allocator);
        },
        else => {
            log.err("'cmap' subtable with {t} not supported yet", .{subtable_format});
            return error.NotSuficientTTFSupport;
        },
    };

    return CharGlyphMapping.initOwned(allocator, glyph_mappings);
}

fn loadTTFGlyphs(allocator: std.mem.Allocator, file: *std.fs.File.Reader, pos_loca: u64, pos_glyf: u64, glyph_count: u16, index_to_loc_format: ttf.Head.IndexToLocFormat) ![]Glyph {
    try file.seekTo(pos_loca);
    const loca = ensureAlloc(allocator.alloc(u32, glyph_count + 1));
    defer allocator.free(loca);
    try ttf.readLoca(&file.interface, index_to_loc_format, loca);

    var component_glyphs: Glyph.TTFComponentGlyphSet = .empty;
    defer {
        var iter = component_glyphs.iterator();
        while (iter.next()) |entry| entry.value_ptr.@"1".deinit(allocator);
        component_glyphs.deinit(allocator);
    }

    const glyph_buf = ensureAlloc(allocator.alloc(Glyph, glyph_count));
    errdefer allocator.free(glyph_buf);
    var glyphs: std.ArrayList(Glyph) = .initBuffer(glyph_buf);
    errdefer for (glyphs.items, 0..) |*glyph, idx| {
        if (component_glyphs.contains(@truncate(idx))) continue;
        glyph.deinit(allocator);
    };

    for (loca[0..glyph_count], 0..) |glyph_offset, idx| {
        try file.seekTo(pos_glyf + glyph_offset);
        const desc = try file.interface.takeStruct(ttf.GlyphDescription, .big);
        if (desc.number_of_contours == 0) {
            glyphs.appendAssumeCapacity(.initEmpty(desc));
        } else if (desc.number_of_contours > 0) {
            var data: ttf.SimpleGlyph = try .initFromReader(allocator, &file.interface, @bitCast(desc.number_of_contours));
            defer data.deinit(allocator);
            glyphs.appendAssumeCapacity(try .initTTFSimple(allocator, desc, data));
        } else {
            glyphs.appendAssumeCapacity(undefined); // place holder
            const data: ttf.ComponentGlyph = try .initFromReader(allocator, &file.interface);
            ensureAlloc(component_glyphs.put(allocator, @truncate(idx), .{desc, data}));
        }
    }
    try Glyph.resolveTTFComponentGlyphs(allocator, glyph_buf, &component_glyphs);

    return glyph_buf;
}

fn ttfTableEntryNotFound(tag: ttf.TableTag) error {CorruptedTTF} {
    @branchHint(.cold);
    log.err("cannot find '{f}' table entry in ttf file", .{tag});
    return error.CorruptedTTF;
}

pub fn deinit(self: *Font, allocator: std.mem.Allocator) void {
    self.char_glyph_mapping.deinit(allocator);
    for (self.glyphs) |*glyph| glyph.deinit(allocator);
    allocator.free(self.glyphs);
    self.glyphs = undefined;
}

pub fn getGlyph(self: Font, char: u32) *const Glyph {
    const glyph_index = self.char_glyph_mapping.getGlyph(char);
    return &self.glyphs[glyph_index];
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

