const builtin = @import("builtin");
const std = @import("std");

const is_windows = builtin.os.tag == .windows;


pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "font-renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .link_libc = true,
            .optimize = optimize,
            .target = target,
        }),
    });

    // vulkan
    exe.root_module.addIncludePath(b.path("$VULKAN_SDK/include"));
    exe.root_module.addLibraryPath(b.path("$VULKAN_SDK/lib"));
    exe.root_module.linkSystemLibrary(if (is_windows) "vulkan-1" else "vulkan", .{});
    // glfw
    exe.root_module.addIncludePath(b.path("third-party/glfw-3.4/include"));
    exe.root_module.addLibraryPath(b.path("third-party/glfw-3.4/lib"));
    exe.root_module.linkSystemLibrary("glfw3", .{});
    if (is_windows) b.installBinFile("third-party/glfw-3.4/lib/glfw3.dll", "bin/glfw3.dll");

    b.installArtifact(exe);


    // check
    const check = b.step("check", "");
    const exe_check = b.addExecutable(.{
        .name = "font-renderer-check",
        .root_module = exe.root_module,
    });
    check.dependOn(&exe_check.step);
}
