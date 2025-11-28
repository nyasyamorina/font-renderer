const std = @import("std");

const Config = @This();
const helpers = @import("helpers.zig");
const log = std.log.scoped(.Config);

const fields = @typeInfo(Config).@"struct".fields;


font_file: Option([]const u8, "font_file", 'f'),
text: Option(?[]const u8, "text", 't'),
enable_cache: Option(?bool, "cache", 'c'),
debug_shader: Option(?bool, "debug", 'd'),


pub const OptionType = enum {
    string,
    int,
    float,
    bool,

    pub fn get(comptime T: type) OptionType {
        switch (@typeInfo(T)) {
            .int => return .int,
            .float => return .float,
            .bool => return .bool,
            .optional => |info| return get(info.child),
            .pointer => |info| {
                if (info.child == u8 and info.is_const) {
                    switch (info.size) {
                        .c, .many, .slice => return .string,
                        else => {},
                    }
                }
            },
            else => {},
        }
        @compileError("not specify OptionType for " ++ @typeName(T));
    }
};

pub fn Option(comptime T: type, comptime _long_name: []const u8, comptime _short_name: ?u8) type {
    return struct {
        value: @This().Value,

        pub const Value = T;
        pub const is_optional = @typeInfo(@This().Value) == .optional;
        pub const option_type = OptionType.get(T);
        pub const long_name = _long_name;
        pub const short_name = _short_name;

        pub fn match(str: []const u8) bool {
            return matchOptionName(str, @This().long_name, @This().short_name);
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (option_type != .string) return;
            if (@This().is_optional) {
                if (self.value) |v| {
                    allocator.free(v);
                }
            } else {
                allocator.free(self.value);
            }
        }
    };
}

fn matchOptionName(str: []const u8, long_name: []const u8, short_name: ?u8) bool {
    if (str.len < 2 or str[0] != '-') return false;
    if (str[1] == '-') { // long name
        return std.mem.eql(u8, str[1..], long_name);
    } else if (short_name) |char| { // short name
        return str[1] == char and str.len == 2;
    } else {
        return false;
    }
}

pub const Builder = struct {
    config: Config,
    init_flags: FieldFlags(),
    free_flags: FieldFlags(),

    pub const init: Builder = blk: {
        var self: Builder = undefined;
        for (@typeInfo(Config).@"struct".fields) |field| {
            if (field.defaultValue()) |default_value| {
                @field(self.config, field.name) = default_value;
                @field(self.init_flags, field.name) = true;
            } else if (@typeInfo(field.type.Value) == .optional) {
                @field(self.config, field.name).value = null;
                @field(self.init_flags, field.name) = true;
            }
        }
        break :blk self;
    };

    fn FieldFlags() type {
        const  Field = std.builtin.Type.StructField;
        comptime var bitfields: [Config.fields.len]Field = undefined;

        inline for (Config.fields, &bitfields) |field, *bitfield| {
            bitfield.* = .{
                .name = field.name,
                .type = bool,
                .is_comptime = field.is_comptime,
                .alignment = 0,
                .default_value_ptr = &false,
            };
        }

        return @Type(.{ .@"struct" = .{
            .fields = &bitfields,
            .decls = &.{},
            .is_tuple = false,
            .layout = .@"packed",
        } });
    }

    /// must call `Config.Builder.deinit` to free memories if build failed
    pub fn build(self: *const Builder) !*const Config {
        var all_ok = true;
        inline for (Config.fields) |field| {
            if (!field.is_comptime) {
                if (!@field(self.init_flags, field.name)) {
                    log.err("missing necessary option: `" ++ field.type.long_name ++ "`", .{});
                    all_ok = false;
                }
            }
        }
        if (!all_ok) return error.@"Faield to build config";
        return &self.config;
    }

    pub fn deinit(self: *Builder) void {
        inline for (Config.fields) |field| {
            if (@field(self.free_flags, field.name)) {
                @field(self.config, field.name).deinit(helpers.allocator);
            }
        }
    }

    pub fn loadCmdLineArgs(self: *Builder) !void {
        var arg_iter = helpers.ensureAlloc(std.process.argsWithAllocator(helpers.allocator));
        defer arg_iter.deinit();
        _ = arg_iter.next(); // this program path

        // command line args should not contain duplicate flags
        var duplicate_flags: FieldFlags() = .{};
        var all_ok = true;
        next_arg: while (arg_iter.next()) |arg| {
            inline for (Config.fields) |field| {
                const option = &@field(self.config, field.name);
                const _Option = field.type;
                const init_flag = &@field(self.init_flags, field.name);
                const free_flag = &@field(self.free_flags, field.name);
                const duplicate_flag = &@field(duplicate_flags, field.name);

                if (_Option.match(arg)) {
                    if (duplicate_flag.*) {
                        log.err("find duplicate command line arg: `" ++ field.name ++ "`", .{});
                        all_ok = false;
                    }
                    duplicate_flag.* = true;

                    // set value into option
                    if (_Option.option_type == .bool) {
                        option.value = true;
                        continue :next_arg;
                    }
                    if (arg_iter.next()) |value_str| {
                        option.value = switch (_Option.option_type) {
                            .bool => unreachable,
                            .int => std.fmt.parseInt(_Option.Value, value_str, 0) catch |err| {
                                log.err("failed to parse \"{s}\" into {s} for command lint arg {s}: {t}", .{value_str, @typeName(_Option.Value), arg, err});
                                all_ok = false;
                                continue :next_arg;
                            },
                            .float => std.fmt.parseFloat(_Option.Value, value_str) catch |err| {
                                log.err("failed to parse \"{s}\" into {s} for command lint arg {s}: {t}", .{value_str, @typeName(_Option.Value), arg, err});
                                all_ok = false;
                                continue :next_arg;
                            },
                            .string => str: {
                                const string = helpers.ensureAlloc(helpers.allocator.dupe(u8, value_str));
                                free_flag.* = true;
                                break :str string;
                            },
                        };
                        init_flag.* = true;

                    } else {
                        log.err("missing value for command line arg: `{s}`", .{arg});
                        all_ok = false;
                    }
                    continue :next_arg;
                }
            } else {
                log.err("unknown command line arg: {s}", .{arg});
                all_ok = false;
                break :next_arg;
            }
        }
        if (!all_ok) return error.@"Failed to load command line arguments";
    }
};
