const std = @import("std");

const CacheManager = @This();
const helpers = @import("helpers.zig");
const vk = @import("c/vk.zig");
const log = std.log.scoped(.CacheManager);


cache_dir: ?[]const u8,
pipeline_caches: [PipelineCacheName.count]PipelineCacheObject = [_]PipelineCacheObject {.{}} ** PipelineCacheName.count,


const CacheDataIdentifier = struct {
    len: usize,
    md5: [std.crypto.hash.Md5.digest_length]u8,

    fn init(data: []const u8) CacheDataIdentifier {
        var self: CacheDataIdentifier = .{
            .len = data.len,
            .md5 = undefined,
        };
        var hasher: std.crypto.hash.Md5 = .init(.{});
        hasher.update(data);
        hasher.final(&self.md5);
        return self;
    }

    fn isInited(self: CacheDataIdentifier) bool {
        return !std.meta.eql(self, std.mem.zeroes(CacheDataIdentifier));
    }

    fn identityTo(self: CacheDataIdentifier, other: CacheDataIdentifier) bool {
        if (self.len != other.len) return false;
        return std.mem.eql(u8, &self.md5, &other.md5);
    }
};

pub fn init(enable: bool) !CacheManager {
    if (enable) blk: {
        const base_dir = try std.fs.selfExeDirPathAlloc(helpers.allocator);
        defer helpers.allocator.free(base_dir);
        if (base_dir.len == 0) {
            log.err("failed to get the path of this application, disable caching", .{});
            break :blk;
        }

        const cache_dir = helpers.ensureAlloc(std.fs.path.join(helpers.allocator, &.{base_dir, ".cache"}));
        errdefer helpers.allocator.free(cache_dir);
        log.debug("cache dir: \"{s}\"", .{cache_dir});
        if (!std.fs.path.isAbsolute(cache_dir)) {
            log.err("gotted cache dir is not absolute, disable caching", .{});
            break :blk;
        }

        return .{ .cache_dir = cache_dir };
    }
    return .{ .cache_dir = null };
}

pub fn deinit(self: *CacheManager, device: vk.Device) void {
    for (&self.pipeline_caches) |*cache| cache.deinit(device);
    if (self.cache_dir) |cache_dir| helpers.allocator.free(cache_dir);
}

pub fn enabled(self: CacheManager) bool {
    return self.cache_dir != null;
}

fn loadCacheData(self: CacheManager, file_name: []const u8, output: *std.ArrayList(u8)) void {
    const cache_path = helpers.ensureAlloc(std.fs.path.join(helpers.allocator, &.{self.cache_dir.?, file_name}));
    defer helpers.allocator.free(cache_path);
    const cache_file = std.fs.openFileAbsolute(cache_path, .{}) catch |err| {
        log.info("cache file \"{s}\" not found, err: {t}", .{cache_path, err});
        return;
    };
    defer cache_file.close();

    var reader = cache_file.reader(&.{});
    reader.interface.appendRemainingUnlimited(helpers.allocator, output) catch |err| {
        log.err("failed to read cache file \"{s}\" into memory, err: {any} => {t}", .{cache_path, reader.err, err});
        return;
    };
    log.debug("loaded cache file \"{s}\"", .{cache_path});
}

fn saveCacheData(self: CacheManager, file_name: []const u8, data: []const u8) void {
    std.fs.makeDirAbsolute(self.cache_dir.?) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.err("failed to make cache dir, err: {t}", .{err});
            return;
        },
    };

    const cache_path = helpers.ensureAlloc(std.fs.path.join(helpers.allocator, &.{self.cache_dir.?, file_name}));
    defer helpers.allocator.free(cache_path);
    const cache_file = std.fs.createFileAbsolute(cache_path, .{}) catch |err| {
        log.err("failed to create cache file \"{s}\", err: {t}", .{cache_path, err});
        return;
    };
    defer cache_file.close();
    cache_file.writeAll(data) catch |err| log.warn("failed to write cache data into \"{s}\", err: {t}", .{cache_path, err});
    log.debug("saved cache file \"{s}\"", .{cache_path});
}


pub const PipelineCacheName = enum {
    concave,
    convex,
    solid,

    pub const count = @typeInfo(PipelineCacheName).@"enum".fields.len;
    pub const max_name_len = blk: {
        var max = 0;
        for (@typeInfo(PipelineCacheName).@"enum".fields) |field| max = @max(max, field.name.len);
        break :blk max;
    };
};

pub const PipelineCacheObject = struct {
    id: CacheDataIdentifier = std.mem.zeroes(CacheDataIdentifier),
    vk: vk.PipelineCache = null,
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *PipelineCacheObject, device: vk.Device) void {
        vk.destroyPipelineCache(device, self.vk, null);
        self.buf.deinit(helpers.allocator);
    }

    const cache_file_ext = ".dat";
    fn cacheFileName(name: PipelineCacheName) struct {[PipelineCacheName.max_name_len + cache_file_ext.len]u8, usize} {
        var buf: [PipelineCacheName.max_name_len + cache_file_ext.len]u8 = std.mem.zeroes([PipelineCacheName.max_name_len + cache_file_ext.len]u8);
        @memcpy(@as([*]u8, @ptrCast(&buf)), @tagName(name));
        const base_len = @tagName(name).len;
        @memcpy(@as([*]u8, @ptrCast(&buf[base_len])), cache_file_ext);
        return .{buf, base_len + cache_file_ext.len};
    }
};

pub fn getPipelineCache(self: *CacheManager, device: vk.Device, name: PipelineCacheName) vk.PipelineCache {
    if (!self.enabled()) return null;
    const cache = &self.pipeline_caches[@intFromEnum(name)];
    if (cache.id.isInited()) return cache.vk;

    const buf, const name_len = PipelineCacheObject.cacheFileName(name);
    cache.buf.clearRetainingCapacity();
    self.loadCacheData(buf[0..name_len], &cache.buf);
    cache.id = .init(cache.buf.items);

    var pipeline_cache: vk.PipelineCache = null;
    helpers.ensureVkSuccess("vkCreatePipelineCache", vk.createPipelineCache(device, &.{
        .sType = helpers.vkSType(vk.PipelineCacheCreateInfo),
        .pInitialData = @ptrCast(cache.buf.items),
        .initialDataSize = cache.buf.items.len,
    }, null, &pipeline_cache)) catch {
        log.err("failed to create pipeline cache for pipeline `{t}`", .{name});
        pipeline_cache = null;
    };
    cache.vk = pipeline_cache;
    return pipeline_cache;
}

pub fn updatePipelineCache(self: *CacheManager, device: vk.Device, name: PipelineCacheName) void {
    if (!self.enabled()) return;
    const cache = &self.pipeline_caches[@intFromEnum(name)];
    if (cache.vk == null) return;

    var len: usize = 0;
    helpers.ensureVkSuccess("vkGetPipelineCacheData", vk.getPipelineCacheData(device, cache.vk, &len, null)) catch {
        log.err("faild to get pipeline cache data size for pipeline `{t}`", .{name});
        return;
    };
    if (len == 0) {
        log.debug("? 0 size of pipeline cache ?", .{});
        return;
    }
    helpers.ensureAlloc(cache.buf.resize(helpers.allocator, len));
    helpers.ensureVkSuccess("vkGetPipelineCacheData", vk.getPipelineCacheData(device, cache.vk, &len, @ptrCast(cache.buf.items))) catch {
        log.err("failed to write pipeline cache data into buffer for pipeline `{t}`", .{name});
        return;
    };

    const new_id: CacheDataIdentifier = .init(cache.buf.items);
    if (cache.id.identityTo(new_id)) return;

    const buf, const name_len = PipelineCacheObject.cacheFileName(name);
    self.saveCacheData(buf[0..name_len], cache.buf.items);
}
