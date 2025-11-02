const std = @import("std");

const helpers = @import("../helpers.zig");

const CharGlyphMapping = @This();
const ensureAlloc = helpers.ensureAlloc;


branches: []Branch,
mappings: []RangeMapping,


pub const RangedOrder = enum {
    in_range,
    too_small,
    too_big,
};

pub const Branch = struct {
    start_char: u32,
    end_char: u32,
    to_smaller: Index,
    to_bigger: Index,

    pub fn order(self: Branch, char: u32) RangedOrder {
        return if (char < self.start_char) .too_small else if (char < self.end_char) .in_range else .too_big;
    }
};

pub const Index = struct {
    index: u16,
    to_mapping: bool,
};

pub const RangeMapping = struct {
    end_char: u32,
    char_count: u16,
    end_glyph: u16,

    pub fn order(self: RangeMapping, char: u32) RangedOrder {
        return if (char < self.end_char) if (self.end_char - char <= self.char_count) .in_range else .too_small else .too_big;
    }

    pub fn getGlyph(self: RangeMapping, char: u32) ?u16 {
        return if (self.order(char) == .in_range) self.end_glyph -% @as(u16, @truncate(self.end_char - char)) else null;
    }
};

pub fn initOwned(mappings: []RangeMapping) CharGlyphMapping {
    return .{
        .branches = buildBraches(mappings),
        .mappings = mappings,
    };
}

pub fn deinit(self: *CharGlyphMapping) void {
    helpers.allocator.free(self.branches);
    self.branches = undefined;
    helpers.allocator.free(self.mappings);
    self.mappings = undefined;
}

pub fn getChar(self: CharGlyphMapping, glyph: u16) ?u32 {
    for (self.mappings) |mapping| {
        if (glyph < mapping.end_glyph and mapping.end_glyph - glyph <= mapping.char_count) {
            return mapping.end_char - (mapping.end_glyph - glyph);
        }
    }
    return null;
}

pub fn getGlyph(self: CharGlyphMapping, char: u32) u16 {
    if (self.branches[0].order(char) != .in_range) return 0;
    var branch_idx: u16 = 0;
    while (true) {
        const to_smaller = self.branches[branch_idx].to_smaller;
        if (to_smaller.to_mapping) {
            if (self.mappings[to_smaller.index].getGlyph(char)) |glyph| return glyph;
        } else if (self.branches[to_smaller.index].order(char) == .in_range) {
            branch_idx = to_smaller.index;
            continue;
        }

        const to_bigger = self.branches[branch_idx].to_bigger;
        if (to_bigger.to_mapping) {
            if (self.mappings[to_bigger.index].getGlyph(char)) |glyph| return glyph;
        } else if (self.branches[to_bigger.index].order(char) == .in_range) {
            branch_idx = to_bigger.index;
            continue;
        }

        return 0;
    }
}

fn buildBraches(mappings: []const RangeMapping) []Branch {
    const branches = ensureAlloc(helpers.allocator.alloc(Branch, @max(1, mappings.len - 1)));
    if (mappings.len == 1) {
        branches[0] = .{
            .start_char = mappings[0].end_char - mappings[0].char_count,
            .end_char = mappings[0].end_char,
            .to_smaller = .{ .index = 0, .to_mapping = true },
            .to_bigger = .{ .index = 0, .to_mapping = true },
        };
        return branches;
    } else { // check mappings are validate
        for (mappings[0 .. mappings.len - 1], mappings[1..]) |left, right| {
            std.debug.assert(left.end_char < right.end_char);
            std.debug.assert(right.end_char - left.end_char >= right.char_count);
        }
    }
    const branch_ranges = ensureAlloc(helpers.allocator.alloc(struct {u16, u16}, branches.len));
    defer helpers.allocator.free(branch_ranges);
    branch_ranges[0] = .{0, @intCast(mappings.len)};

    var process_idx: u16 = 0;
    var empty_idx: u16 = 1;
    while (process_idx < branches.len) {
        const curr_layer_end = empty_idx;
        for (branches[process_idx..curr_layer_end], branch_ranges[process_idx..curr_layer_end]) |*branch, branch_range| {
            branch.start_char = mappings[branch_range.@"0"].end_char - mappings[branch_range.@"0"].char_count;
            branch.end_char = mappings[branch_range.@"1" - 1].end_char;
            const split_idx = splitRange(mappings[branch_range.@"0" .. branch_range.@"1"]) + branch_range.@"0";
            // to small
            if (split_idx == branch_range.@"0" + 1) {
                branch.to_smaller = .{ .index = split_idx - 1, .to_mapping = true };
            } else {
                branch_ranges[empty_idx] = .{branch_range.@"0", split_idx};
                branch.to_smaller = .{ .index = empty_idx, .to_mapping = false };
                empty_idx += 1;
            }
            // to big
            if (split_idx == branch_range.@"1" - 1) {
                branch.to_bigger = .{ .index = split_idx, .to_mapping = true };
            } else {
                branch_ranges[empty_idx] = .{split_idx, branch_range.@"1"};
                branch.to_bigger = .{ .index = empty_idx, .to_mapping = false };
                empty_idx += 1;
            }
        }
        process_idx = curr_layer_end;
    }

    return branches;
}

fn splitRange(mappings: []const RangeMapping) u16 {
    std.debug.assert(mappings.len > 1);
    if (mappings.len == 2) return 1;

    const middle = ((mappings[0].end_char - mappings[0].char_count) + (mappings[mappings.len-1].end_char - 1)) / 2;

    var range_info: struct {u16, RangedOrder} = .{@intCast(mappings.len / 2), mappings[mappings.len / 2].order(middle)};
    while (true) {
        if (range_info.@"0" == mappings.len - 1) return range_info.@"0";
        if (range_info.@"0" == 0) return 1;
        switch (range_info.@"1") {
            .in_range => {
                const curr = mappings[range_info.@"0"];
                if (curr.end_char - middle <= curr.char_count / 2) {
                    return range_info.@"0" + 1;
                } else {
                    return range_info.@"0";
                }
            },
            .too_small => {
                const prev_order = mappings[range_info.@"0" - 1].order(middle);
                if (prev_order == .too_big) return range_info.@"0";
                range_info = .{range_info.@"0" - 1, prev_order};
            },
            .too_big => {
                const next_order = mappings[range_info.@"0" + 1].order(middle);
                if (next_order == .too_small) return range_info.@"0" + 1;
                range_info = .{range_info.@"0" + 1, next_order};
            },
        }
    }
}

