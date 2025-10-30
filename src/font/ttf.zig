const builtin = @import("builtin");
const std = @import("std");

const CharGlyphMapping = @import("CharGlyphMapping.zig");
const Glyph = @import("Glyph.zig");
const helpers = @import("../helpers.zig");

const ensureAlloc = helpers.ensureAlloc;
const ensureMonoIncrease = helpers.ensureMonoIncrease;
const native_endian = helpers.native_endian;
const readInts = helpers.readInts;
const readIntsAlloc = helpers.readIntAlloc;


pub const TableTag = enum(u32) {
    /// character to glyph mapping
    cmap = TagNameToU32("cmap"),
    /// glyph data
    glyf = TagNameToU32("glyf"),
    /// font header
    head = TagNameToU32("head"),
    /// horizontal header
    hhea = TagNameToU32("hhea"),
    /// horizontal metrics
    hmtx = TagNameToU32("hmtx"),
    /// index to location
    loca = TagNameToU32("loca"),
    /// maximum profile
    maxp = TagNameToU32("maxp"),
    /// naming
    name = TagNameToU32("name"),
    /// post script
    post = TagNameToU32("post"),
    /// control value
    cvt  = TagNameToU32("cvt "),
    /// font program
    fpgm = TagNameToU32("fpgm"),
    /// horizontal device metrics
    hdmx = TagNameToU32("hdmx"),
    /// kerning
    kern = TagNameToU32("kern"),
    /// OS/2
    OS_2 = TagNameToU32("OS/2"),
    /// control value program
    perp = TagNameToU32("perp"),
    _,

    fn TagNameToU32(name: *const [4]u8) u32 {
        return if (native_endian == .big) @bitCast(name.*) else @byteSwap(@as(u32, @bitCast(name.*)));
    }

    pub fn format(self: TableTag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const name: [4]u8 = if (native_endian == .big) @bitCast(@intFromEnum(self)) else @bitCast(@byteSwap(@intFromEnum(self)));
        return writer.print("tag`{s}`", .{name});
    }
};

pub const required_table_tags = [_]TableTag {.cmap, .glyf, .head, .hhea, .hmtx, .loca, .maxp, .name, .post};
pub const optional_table_tags = [_]TableTag {.cvt,  .fpgm, .hdmx, .kern, .OS_2, .perp};

pub const VersionNumber = extern struct {
    major: u16 align(1),
    minor: u16 align(1),
};

pub const OffsetSubtable = extern struct {
    /// a tag to indicate the OFA scaler to be used to rasterize this font
    scaler_type: u32 align(1),
    /// number of tables
    num_tables: u16 align(1),
    /// (maximum power of 2 <= numTables)*16
    search_range: u16 align(1),
    /// log2(maximum power of 2 <= numTables)
    entry_selector: u16 align(1),
    /// numTables*16-searchRange
    range_shift: u16 align(1),
};

pub const TableDirectoryEntry = extern struct {
    /// 4-byte identifier
    tag: TableTag align(1),
    /// checksum for this table
    check_sum: u32 align(1),
    /// offset from beginning of sfnt
    offset: u32 align(1),
    /// length of this table in byte (actual length not padded length)
    length: u32 align(1),

    pub fn findIndex(entries: []const TableDirectoryEntry, tag: TableTag) ?usize {
        return for (entries, 0..) |entry, idx| {
            if (entry.tag == tag) break idx;
        } else null;
    }
};

pub const Head = extern struct {
    version: VersionNumber align(1),
    /// set by font manufacturer
    font_revision: extern struct { @"0": u16 align(1), @"1": u16 align(1) } align(1),
    check_sum_adjustment: u32 align(1),
    /// set to 0x5F0F3CF5
    magic_number: u32 align(1),
    flags: Flags align(1),
    /// range from 64 to 16384
    units_per_em: u16 align(1),
    /// international date
    created: i64 align(1),
    /// international date
    modified: i64 align(1),
    /// for all glyph bounding boxes
    x_min: u16 align(1),
    /// for all glyph bounding boxes
    y_min: u16 align(1),
    /// for all glyph bounding boxes
    x_max: u16 align(1),
    /// for all glyph bounding boxes
    y_max: u16 align(1),
    mac_style: MacStyle align(1),
    /// smallest readable size in pixels
    lowest_rec_pp_em: u16 align(1),
    font_direction_hint: FontDirectionHint align(1),
    index_to_loc_format: IndexToLocFormat align(1),
    /// 0 for current format
    glyph_data_format: i16 align(1),

    pub const Flags = packed struct(u16) {
        /// y value of 0 specifies baseline; the baselines for the font is at y= 0 (that is, the x-axis)
        y0_baseline: bool,
        /// x position of left most black bit is LSB; the x-position of the leftmost black bit is assumed to be the left side bearing
        left_most_black_bit_is_LSB: bool,
        /// scaled point size and actual point size will differ; instructions may use point size explicitly in place of pixels per em
        different_scaled_PS_and_actual_PS: bool,
        /// use integer scaling instead of fractional scaling
        use_integer_scaling: bool,
        /// allows fonts to alter device dependent widths (used by the Microsoft implementation of the TrueType scaler)
        alter_device_dependent_widths: bool,
        /// This bit should be set in fonts that are intended to e laid out vertically, and in which the glyphs have been drawn such that an x-coordinate of 0 corresponds to the desired vertical baseline
        vertical_layout: bool,
        _reserved1: u1,
        /// This bit should be set if the font requires layout for correct linguistic rendering
        required_layout: bool,
        /// This bit should be set for an AAT font which has one or more metamorphosis effects designated as happening by default
        has_default_metamorphosis_effect: bool,
        /// This bit should be set if the font contains any strong right-to-left glyphs
        contains_right_to_left_glyph: bool,
        /// This bit should be set if the font contains Indic-style rearrangement effects
        cantains_strong_indic_style_rearangement_effect: bool,
        bits_defined_by_adobe: u3,
        /// This bit should be set if the glyphs in the font are simply generic symbols for code point ranges, such as for a last resort font
        is_simply_generic: bool,
        _reserved: u1,
    };

    pub const MacStyle = packed struct(u16) {
        bold: bool,
        italic: bool,
        underline: bool,
        outline: bool,
        shadow: bool,
        /// narrow
        condensed: bool,
        extended: bool,
        _reserved: u9,
    };

    pub const FontDirectionHint = enum(i16) {
        mixed_directional = 0,
        only_strong_left_to_right = 1,
        left_to_right_and_neutrals = 2,
        only_string_right_to_left = -1,
        right_to_left_and_neutrals = -2,
    };

    pub const IndexToLocFormat = enum(i16) {
        short = 0,
        long = 1,
    };
};

pub const Maxp = extern struct {
    version: VersionNumber align(1),
    /// the number of glyphs in the font
    num_glyphs: u16 align(1),
    /// points in non-compound glyph
    max_points: u16 align(1),
    /// contours in non-compound glyph
    max_contours: u16 align(1),
    /// points in compound glyph
    max_component_points: u16 align(1),
    /// contours in compound glyph
    max_component_contours: u16 align(1),
    /// set to 2
    max_zones: u16 align(1),
    /// points used in Twilight Zone (Z0)
    max_twilight_points: u16 align(1),
    /// number of Storage Area locations
    max_storage: u16 align(1),
    /// number of FDEFs
    max_function_defs: u16 align(1),
    /// number of IDEFs
    max_instruction_defs: u16 align(1),
    /// maximum stack depth
    max_stack_elements: u16 align(1),
    /// byte count for glyph instructions
    max_size_of_instructions: u16 align(1),
    /// number of glyphs referenced at top level
    max_component_elements: u16 align(1),
    /// levels of recursion, set to 0 if font has only simple glyphs
    max_component_depth: u16 align(1),
};

/// note that the length loca table is one more than number of glyphs.
pub fn readLoca(reader: *std.Io.Reader, index_to_loc_format: Head.IndexToLocFormat, loca: []u32) !void {
    return switch (index_to_loc_format) {
        .long => readInts(reader, .big, u32, loca),
        .short => {
            const inline_buf = @as([*]u16, @ptrCast(loca))[0 .. loca.len];
            try readInts(reader, .big, u16, inline_buf);

            var index = loca.len - 1;
            while (true) {
                loca[index] = inline_buf[index] * 2;
                if (index == 0) break;
                index -= 1;
            }
        },
    };
}

pub const CmapIndex = extern struct {
    /// Version number (Set to zero)
    version: u16 align(1),
    /// Number of encoding subtables
    number_subtables: u16 align(1),
};

pub const CmapEncodingSubtable = extern struct {
    /// Platform identifier
    platform_id: PlatformID align(1),
    /// Platform-specific encoding identifier
    platform_specific_id: u16 align(1),
    /// Offset of the mapping table
    offset: u32 align(1),

    pub fn isUnicode(self: CmapEncodingSubtable) bool {
        return switch (self.platform_id) {
            .unicode => self.platform_specific_id != 14,
            .microsoft => self.platform_specific_id == @intFromEnum(PlatformSpecificID.Windows.unicode_bmp) or self.platform_specific_id == @intFromEnum(PlatformSpecificID.Windows.unicode_ucs_4),
            else => false,
        };
    }

    pub const UnicodeBMPRestriction = enum {
        unknown,
        true,
        false,
    };
    pub fn isUnicodeRestrictedToBMP(self: CmapEncodingSubtable) UnicodeBMPRestriction {
        return switch (self.platform_id) {
            .unicode => switch (self.platform_specific_id) {
                @intFromEnum(PlatformSpecificID.Unicode.unicode2_0_bmp) => .true,
                @intFromEnum(PlatformSpecificID.Unicode.unicode2_0), @intFromEnum(PlatformSpecificID.Unicode.last_report) => .false,
                else => .unknown,
            },
            .microsoft => switch (self.platform_specific_id) {
                @intFromEnum(PlatformSpecificID.Windows.unicode_bmp) => .true,
                @intFromEnum(PlatformSpecificID.Windows.unicode_ucs_4) => .false,
                else => .unknown,
            },
            else => .unknown,
        };
    }

    pub fn isUnicodeVariationSequence(self:CmapEncodingSubtable) bool {
        return @as(PlatformID, @enumFromInt(self.platform_specific_id)) == .unicode and self.platform_specific_id == 14;
    }

    pub fn isUnicodeDiscarded(self: CmapEncodingSubtable) bool {
        return self.platform_id == .unicode and self.platform_specific_id == @intFromEnum(PlatformSpecificID.Unicode.iso_10646);
    }

    pub fn isTheBest(self: CmapEncodingSubtable) bool {
        return self.isUnicode() and 
            !self.isUnicodeDiscarded() and
            self.isUnicodeRestrictedToBMP() == .false;
    }

    pub fn isBetterThan(self: CmapEncodingSubtable, other: CmapEncodingSubtable) bool {
        if (!self.isUnicode()) return false;
        if (!other.isUnicode()) return true;
        if (self.isUnicodeDiscarded()) return false;
        if (other.isUnicodeDiscarded()) return true;
        return @intFromEnum(self.isUnicodeRestrictedToBMP()) >= @intFromEnum(other.isUnicodeRestrictedToBMP());
    }
};

pub const CmapSubtable = struct {
    pub const FormatNumber = enum(u16) {
        format0 = 0,
        format2 = 2,
        format4 = 4,
        format6 = 6,
        format8 = 8,
        format10 = 10,
        format12 = 12,
        format13 = 13,
        format14 = 14,
    };

    pub const Format0 = extern struct {
        /// Length in bytes of the subtable (set to 262 for format 0)
        length: u16 align(1),
        /// Language code
        language: u16 align(1),
        /// An array that maps character codes to glyph index values
        glyph_index_array: [256]u8,
    };

    pub const Format2 = struct {
        /// Total table length in bytes
        length: u16,
        /// Language code
        language: u16,
        /// Array that maps high bytes to subHeaders: value is index * 8
        sub_header_keys: [256]u16,
        /// Variable length array of subHeader structures
        sub_headers: [][4]u16,
        /// Variable length array containing subarrays
        glyph_index_array: []u16,

        pub fn initFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !CmapSubtable.Format2 {
            _ = allocator; _ = reader;
            @compileError("not impl");
        }

        pub fn deinit(self: *CmapSubtable.Format2, allocator: std.mem.Allocator) void {
            allocator.free(self.sub_headers);
            self.sub_headers = undefined;
            allocator.free(self.glyph_index_array);
            self.glyph_index_array = undefined;
        }
    };

    pub const Format4 = struct {
        /// Length of subtable in bytes
        length: u16,
        /// Language code
        language: u16,
        /// 2 * segCount
        seg_count_x2: u16,
        /// 2 * (2**FLOOR(log2(segCount)))
        search_range: u16,
        /// log2(searchRange/2)
        entry_selector: u16,
        /// (2 * segCount) - searchRange
        range_shift: u16,
        /// Ending character code for each segment, last = 0xFFFF.
        end_code: []u16,
        //_reserved_pad: u16, // This value should be zero
        /// Starting character code for each segment
        start_code: []u16,
        /// Delta for all character codes in segment
        id_delta: []u16,
        /// Offset in bytes to glyph indexArray, or 0
        id_range_offset: []u16,
        /// Glyph index array
        glyph_index_array: []u16,

        pub fn initFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !CmapSubtable.Format4 {
            var self: CmapSubtable.Format4 = undefined;

            self.length, self.language = (try reader.takeStruct(extern struct { a: [2]u16 }, .big)).a;
            self.seg_count_x2, self.search_range, self.entry_selector, self.range_shift = (try reader.takeStruct(extern struct { a: [4]u16 }, .big)).a;
            std.debug.assert(self.seg_count_x2 & 1 == 0);
            const seg_count = self.seg_count_x2 / 2;

            const data_buf = ensureAlloc(allocator.alloc(u16, self.seg_count_x2 * 2));
            errdefer allocator.free(data_buf);
            self.end_code = data_buf[0..seg_count]; self.start_code = data_buf[seg_count..2*seg_count];
            self.id_delta = data_buf[2*seg_count..3*seg_count]; self.id_range_offset = data_buf[3*seg_count..];

            try readInts(reader, .big, u16, self.end_code);
            try reader.discardAll(@sizeOf(u16));
            try readInts(reader, .big, u16, self.start_code);
            try readInts(reader, .big, u16, self.id_delta);
            try readInts(reader, .big, u16, self.id_range_offset);
            ensureMonoIncrease(u16, self.end_code);
            std.debug.assert(self.end_code[seg_count - 1] == 0xFFFF);
            for (self.end_code, self.start_code) |end_code, start_code| std.debug.assert(end_code >= start_code);
            for (self.id_range_offset) |v| std.debug.assert(v & 1 == 0);

            var max_glyph_index_array_index: u16 = 0;
            for (self.end_code, self.start_code, self.id_range_offset, 0..) |end_code, start_code, range_offset, seg_idx| {
                if (range_offset != 0 and start_code <= end_code) {
                    const max_char_offset = end_code - start_code;
                    const max_index = seg_idx + range_offset / 2 - seg_count + max_char_offset;
                    max_glyph_index_array_index = @max(max_glyph_index_array_index, @as(u16, @intCast(max_index)));
                }
            }
            self.glyph_index_array = try readIntsAlloc(allocator, reader, .big, u16, max_glyph_index_array_index + 1);

            return self;
        }

        pub fn deinit(self: *CmapSubtable.Format4, allocator: std.mem.Allocator) void {
            allocator.free(self.end_code.ptr[0 .. self.seg_count_x2 * 2]);
            self.end_code = undefined;
            self.start_code = undefined;
            self.id_delta = undefined;
            self.id_range_offset = undefined;
            allocator.free(self.glyph_index_array);
            self.glyph_index_array = undefined;
        }

        pub fn glyphIndex(self: CmapSubtable.Format4, char: u16) u16 {
            const seg_count: u16 = @truncate(self.id_range_offset.len);
            // can use `seg_count_x2`, `search_range`, `entry_count` and `range_shift` to speed up `seg_idx` searching
            const seg_idx = for (self.end_code, 0..) |end, idx| {
                if (end >= char) break idx;
            } else unreachable;
            if (self.start_code[seg_idx] > char) return 0;

            const range_offset = self.id_range_offset[seg_idx];
            if (range_offset != 0) {
                const char_offset = char - self.start_code[seg_idx];
                const offset = seg_idx + range_offset / 2 - seg_count + char_offset;
                return self.id_delta[seg_idx] +% self.glyph_index_array[offset];
            } else {
                return self.id_delta[seg_idx] +% char;
            }
        }

        pub fn collectRangeMappingsAlloc(self: CmapSubtable.Format4, allocator: std.mem.Allocator) []CharGlyphMapping.RangeMapping {
            var mappings: std.ArrayList(CharGlyphMapping.RangeMapping) = .empty;
            errdefer mappings.deinit(allocator);

            for (self.end_code, self.start_code, self.id_delta, self.id_range_offset, 0..) |end_code, start_code, id_delta, id_range_offset, seg_idx| {
                if (id_range_offset != 0) {
                    const glyph_idx_arr_start = seg_idx + id_range_offset / 2 - self.id_range_offset.len;
                    ensureAlloc(mappings.ensureUnusedCapacity(allocator, end_code - start_code + 1));
                    for (self.glyph_index_array[glyph_idx_arr_start..][0..(end_code - start_code + 1)], 0..) |glyph_offset, char_offset| {
                        mappings.appendAssumeCapacity(.{
                            .end_char = @intCast(start_code + char_offset + 1),
                            .char_count = 1,
                            .end_glyph = id_delta +% glyph_offset +% 1,
                        });
                    }

                } else {
                    const start_glyph = id_delta +% start_code;
                    const end_glyph = id_delta +% end_code;
                    if (start_glyph > end_glyph) {
                        const mid_code = -%start_glyph;
                        ensureAlloc(mappings.ensureUnusedCapacity(allocator, 2));
                        mappings.appendAssumeCapacity(.{
                            .end_char = @as(u32, mid_code) + 1,
                            .char_count = mid_code - start_code + 1,
                            .end_glyph = 0,
                        });
                        mappings.appendAssumeCapacity(.{
                            .end_char = @as(u32, end_code) + 1,
                            .char_count = end_code - mid_code,
                            .end_glyph = end_glyph +% 1,
                        });
                    } else {
                        ensureAlloc(mappings.append(allocator, .{
                            .end_char = @as(u32, end_code) + 1,
                            .char_count = end_code - start_code + 1,
                            .end_glyph = end_glyph +% 1,
                        }));
                    }
                }
            }

            return ensureAlloc(mappings.toOwnedSlice(allocator));
        }
    };

    pub const Format6 = struct {
        /// Length in bytes
        length: u16,
        /// Language code
        language: u16,
        /// First character code of subrange
        first_code: u16,
        /// Number of character codes in subrange
        entry_count: u16,
        /// Array of glyph index values for character codes in the range
        glyph_index_array: []u16,

        pub fn initFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !CmapSubtable.Format6 {
            _ = allocator; _ = reader;
            @compileError("not impl");
        }

        pub fn deinit(self: *CmapSubtable.Format6, alloctor: std.mem.Allocator) void {
            alloctor.free(self.glyph_index_array);
            self.glyph_index_array = undefined;
        }
    };

    pub const Format8 = struct {
        /// Byte length of this subtable (including the header)
        length: u32,
        /// Language code
        language: u32,
        /// Tightly packed array of bits (8K bytes total) indicating whether the particular 16-bit (index) value is the start of a 32-bit character code
        is32: [65536]u8,
        /// groupings
        groups: []Group,

        pub const Group = extern struct {
            /// First character code in this group
            start_char_code: u32 align(1),
            /// Last character code in this group
            end_char_code: u32 align(1),
            /// Glyph index corresponding to the starting character code
            start_glyph_code: u32 align(1),
        };

        pub fn initFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !CmapSubtable.Format8 {
            _ = allocator; _ = reader;
            @compileError("not impl");
        }

        pub fn deinit(self: *CmapSubtable.Format8, allocator: std.mem.Allocator) void {
            allocator.free(self.groups);
            self.groups = undefined;
        }
    };

    pub const Format10 = struct {
        //_reserved: u16, // Set to 10
        /// Byte length of this subtable (including the header)
        length: u32,
        /// Language code
        language: u32,
        /// First character code covered
        start_char_code: u32,
        /// Array of glyph indices for the character codes covered
        glyphs: []u16,

        pub fn initFormReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !CmapSubtable.Format10 {
            _ = allocator; _ = reader;
            @compileError("not impl");
        }

        pub fn deinit(self: *CmapSubtable.Format10, allocator: std.mem.Allocator) void {
            allocator.free(self.glyphs);
            self.glyphs = undefined;
        }
    };

    pub const Format12 = struct {
        //_reserved: u16, // Set to 0
        /// Byte length of this subtable (including the header)
        length: u32,
        /// Language code
        language: u32,
        /// groupings
        groups: []Group,

        pub const Group = extern struct {
            /// First character code in this group
            start_char_code: u32 align(1),
            /// Last character code in this group
            end_char_code: u32 align(1),
            /// Glyph index corresponding to the starting character code; subsequent charcters are mapped to sequential glyphs
            start_glyph_code: u32 align(1),
        };

        pub fn initFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !CmapSubtable.Format12 {
            var self: CmapSubtable.Format12 = undefined;

            try reader.discardAll(@sizeOf(u16));
            self.length, self.language, const n_groups = (try reader.takeStruct(extern struct { a: [3]u32 }, .big)).a;

            self.groups = ensureAlloc(allocator.alloc(Group, n_groups));
            errdefer allocator.free(self.groups);
            try reader.readSliceAll(@as([*]u8, @ptrCast(self.groups))[0 .. @sizeOf(Group) * n_groups]);
            if (native_endian == .little) std.mem.byteSwapAllElements(Group, self.groups);
            for (self.groups[0..n_groups-1], self.groups[1..]) |left, right| std.debug.assert(left.end_char_code < right.end_char_code);
            for (self.groups) |group| std.debug.assert(group.end_char_code >= group.start_char_code);

            return self;
        }

        pub fn deinit(self: *CmapSubtable.Format12, allocator: std.mem.Allocator) void {
            allocator.free(self.groups);
            self.groups = undefined;
        }

        pub fn glyphIndex(self: CmapSubtable.Format12, char: u32) u32 {
            return for (self.groups) |group| {
                if (group.end_char_code >= char) {
                    break group.start_glyph_code + (char - group.start_char_code);
                }
            } else 0;
        }

        pub fn collectRangeMappingsAlloc(self: CmapSubtable.Format12, allocator: std.mem.Allocator) []CharGlyphMapping.RangeMapping {
            const mappings = ensureAlloc(allocator.alloc(CharGlyphMapping.RangeMapping, self.groups.len));
            for (self.groups, mappings) |group, *mapping| {
                mapping.* = .{
                    .end_char = group.end_char_code + 1,
                    .char_count = @intCast(group.end_char_code - group.start_char_code + 1),
                    .end_glyph = @as(u16, @intCast(group.start_glyph_code + (group.end_char_code - group.start_char_code))) +% 1,
                };
            }
            return mappings;
        }
    };

    /// Format13 is structurally identical to Format12, but with different glyph code intepretation
    pub const Format13 = struct {
        format12: CmapSubtable.Format12,

        pub fn glyphIndex(self: CmapSubtable.Format13, char: u32) u32 {
            return for (self.format12.groups) |group| {
                if (group.end_char_code >= char) {
                    break group.start_glyph_code;
                }
            } else 0;
        }
    };

    pub const Format14 = struct {
        /// Byte length of this subtable (including this header)
        length: u32,
        /// variation Selector Records
        var_selector_records: []VariationSelectorRecord,

        pub const VariationSelectorRecord = extern struct {
            /// Variation selector
            var_selector: u24 align(1),
            /// Offset to Default UVS Table
            default_uvs_offset: u32 align(1),
            /// Offset to Non-Default UVS Table
            non_default_uvs_offset: u32 align(1),
        };

        pub fn initFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !CmapSubtable.Format14 {
            _ = allocator; _ = reader;
            @compileError("not impl");
        }

        pub fn deinit(self: *CmapSubtable.Format14, allocator: std.mem.Allocator) void {
            allocator.free(self.var_selector_records);
            self.var_selector_records = undefined;
        }
    };
};

pub const PlatformID = enum(u16) {
    unicode = 0,
    macintosh = 1,
    microsoft = 3,
};

pub const PlatformSpecificID = struct {
    pub const Unicode = enum(u16) {
        /// Version 1.0 semantics
        v1_0 = 0,
        /// Version 1.1 semantics
        v1_1 = 1,
        /// ISO 10646 1993 semantics (deprecated)
        iso_10646 = 2,
        /// Unicode 2.0 or later semantics (BMP only)
        unicode2_0_bmp = 3,
        /// Unicode 2.0 or later semantics (non-BMP characters allowed)
        unicode2_0 = 4,
        /// Unicode Variation Sequences
        unicode_var = 5,
        /// Last Resort
        last_report = 6,
        _
    };

    pub const Windows = enum(u16) {
        /// Symbol
        symbol = 0,
        /// Unicode BMP-only (UCS-2)
        unicode_bmp = 1,
        /// Shift-JIS
        shift_jis = 2,
        /// PRC
        prc = 3,
        /// BigFive
        big5 = 4,
        /// Johab
        johab = 5,
        /// Unicode UCS-4
        unicode_ucs_4 = 10,
        _
    };
};

pub const GlyphDescription = extern struct {
    /// If the number of contours is positive or zero, it is a single glyph;
    /// If the number of contours less than zero, the glyph is compound
    number_of_contours: i16 align(1),
    /// Minimum x for coordinate data
    x_min: i16 align(1),
    /// Minimum y for coordinate data
    y_min: i16 align(1),
    /// Maximum x for coordinate data
    x_max: i16 align(1),
    /// Maximum y for coordinate data
    y_max: i16 align(1),
};

pub const SimpleGlyph = struct {
    /// Array of last point indices of each contour
    end_pts_of_contours: []u16,
    /// Array of instructions for this glyph
    instructions: []u8,
    /// If set, the point is on the curve;
    /// Otherwise, it is off the curve.
    on_curve: std.DynamicBitSetUnmanaged,
    /// Array of abdolut coordinates;
    coordinates: []Glyph.Contour.Point,

    pub const OutlineFlags = packed struct(u8) {
        /// If set, the point is on the curve;
        /// Otherwise, it is off the curve.
        on_curve: bool,
        /// If set, the corresponding x-coordinate is 1 byte long;
        /// Otherwise, the corresponding x-coordinate is 2 bytes long
        x_short_vector: bool,
        /// If set, the corresponding y-coordinate is 1 byte long;
        /// Otherwise, the corresponding y-coordinate is 2 bytes long
        y_short_vector: bool,
        /// If set, the next byte specifies the number of additional times this set of flags is to be repeated. In this way, the number of flags listed can be smaller than the number of points in a character.
        repeat: bool,
        x_extra: bool,
        y_extra: bool,
        _reserved: u2,
    };

    pub fn initFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader, contours_count: u16) !SimpleGlyph {
        std.debug.assert(contours_count > 0);
        var self: SimpleGlyph = undefined;

        self.end_pts_of_contours = try readIntsAlloc(allocator, reader, .big, u16, contours_count);
        errdefer allocator.free(self.end_pts_of_contours);
        ensureMonoIncrease(u16, self.end_pts_of_contours);
        const point_count = @as(u32, self.end_pts_of_contours[contours_count - 1]) + 1;

        const instruction_length = try reader.takeInt(u16, .big);
        self.instructions = try readIntsAlloc(allocator, reader, .big, u8, instruction_length);
        errdefer allocator.free(self.instructions);

        var flags: std.ArrayList(OutlineFlags) = .empty;
        defer flags.deinit(allocator);
        while (flags.items.len < point_count) {
            const flag: OutlineFlags = @bitCast(try reader.takeByte());
            if (flag.repeat) {
                const repeat = try reader.takeByte();
                ensureAlloc(flags.appendNTimes(allocator, flag, @as(u16, repeat) + 1));
            } else {
                ensureAlloc(flags.append(allocator, flag));
            }
        }
        std.debug.assert(flags.items.len == point_count);

        self.on_curve = ensureAlloc(std.DynamicBitSetUnmanaged.initEmpty(allocator, point_count));
        errdefer self.on_curve.deinit(allocator);
        for (flags.items, 0..) |flag, idx| {
            if (flag.on_curve) self.on_curve.set(idx);
        }

        self.coordinates = ensureAlloc(allocator.alloc(Glyph.Contour.Point, point_count));
        errdefer allocator.free(self.coordinates);
        // x
        var x_abs: i16 = 0;
        for (flags.items, self.coordinates) |flag, *pos| {
            if (flag.x_short_vector) {
                const value = try reader.takeByte();
                x_abs += if (flag.x_extra) value else -@as(i16, value);
            } else if (!flag.x_extra) {
                x_abs += try reader.takeInt(i16, .big);
            }
            pos.x = x_abs;
        }
        // y
        var y_abs: i16 = 0;
        for (flags.items, self.coordinates) |flag, *pos| {
            if (flag.y_short_vector) {
                const value = try reader.takeByte();
                y_abs += if (flag.y_extra) value else -@as(i16, value);
            } else if (!flag.y_extra) {
                y_abs += try reader.takeInt(i16, .big);
            }
            pos.y = y_abs;
        }

        return self;
    }

    pub fn deinit(self: *SimpleGlyph, allocator: std.mem.Allocator) void {
        allocator.free(self.end_pts_of_contours);
        self.end_pts_of_contours = undefined;
        allocator.free(self.instructions);
        self.instructions = undefined;
        self.on_curve.deinit(allocator);
        allocator.free(self.coordinates);
        self.coordinates = undefined;
    }
};

pub const ComponentGlyph = struct {
    parts: []PartDescription,
    instructions: []u8,
    matrics_index: ?u16,

    pub const PartDescription = struct {
        flag: ComponentFlag,
        glyph_index: u16,
        argument1: u16,
        argument2: u16,
        transformation: [4]i16,

        pub const ComponentFlag = packed struct(u16) {
            arg_1_and_arg_2_are_words: bool,
            args_are_xy_values: bool,
            round_xy_to_grid: bool,
            we_have_a_scale: bool,
            _reserved1: u1,
            more_components: bool,
            we_have_an_x_and_y_scale: bool,
            we_have_a_two_by_two: bool,
            we_have_instructions: bool,
            use_my_metrics: bool,
            overlap_compound: bool,
            _reserved2: u5,
        };

        pub fn initFromReader(reader: *std.Io.Reader) !PartDescription {
            var self: PartDescription = undefined;

            const flag_, self.glyph_index = (try reader.takeStruct(extern struct { a: [2]u16 }, .big)).a;
            self.flag = @bitCast(flag_);

            if (self.flag.arg_1_and_arg_2_are_words) {
                self.argument1, self.argument2 = (try reader.takeStruct(extern struct { a: [2]u16 }, .big)).a;
            } else {
                self.argument1, self.argument2 = (try reader.takeStruct(extern struct { a: [2]u8 }, .big)).a;
            }

            if (self.flag.we_have_a_scale) {
                std.debug.assert(!self.flag.we_have_an_x_and_y_scale);
                std.debug.assert(!self.flag.we_have_a_two_by_two);
                const s = try reader.takeInt(i16, .big);
                self.transformation = .{s, 0, 0, s};
            } else if (self.flag.we_have_an_x_and_y_scale) {
                std.debug.assert(!self.flag.we_have_a_two_by_two);
                const x, const y = (try reader.takeStruct(extern struct { a: [2]i16 }, .big)).a;
                self.transformation = .{x, 0, 0, y};
            } else if (self.flag.we_have_a_two_by_two) {
                self.transformation = (try reader.takeStruct( extern struct { a: [4]i16 }, .big)).a;
            } else {
                self.transformation = .{1, 0, 0, 1};
            }

            return self;
        }
    };

    pub fn initFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !ComponentGlyph {
        var self: ComponentGlyph = undefined;

        var parts: std.ArrayList(PartDescription) = .empty;
        defer parts.deinit(allocator);
        while (true) {
            ensureAlloc(parts.append(allocator, try .initFromReader(reader)));
            if (!parts.getLast().flag.more_components) break;
        }

        self.instructions = &.{};
        errdefer allocator.free(self.instructions);
        if (parts.getLast().flag.we_have_instructions) {
            const instruction_count = try reader.takeInt(u16, .big);
            self.instructions = try reader.readAlloc(allocator, instruction_count);
        }

        if (helpers.in_safe_mode) {
            self.matrics_index = null;
            for (parts.items, 0..) |part, idx| {
                if (part.flag.use_my_metrics) {
                    if (self.matrics_index != null) unreachable; // ? should be only one component part have this flag set ?
                    self.matrics_index = @intCast(idx);
                }
            }
        } else {
            self.matrics_index = for (parts.items, 0..) |part, idx| {
                if (part.flag.use_my_metrics) break @intCast(idx);
            } else null;
        }

        self.parts = ensureAlloc(parts.toOwnedSlice(allocator));
        return self;
    }

    pub fn deinit(self: *ComponentGlyph, allocator: std.mem.Allocator) void {
        allocator.free(self.parts);
        self.parts = undefined;
        allocator.free(self.instructions);
        self.instructions = undefined;
    }
};

