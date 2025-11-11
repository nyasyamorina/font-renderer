const builtin = @import("builtin");
const std = @import("std");

const is_windows = builtin.os.tag == .windows;


pub fn build(b: *std.Build) !void {
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
    const vulkan_sdk = try std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK");
    exe.root_module.addIncludePath(.{ .cwd_relative = try std.fs.path.join(b.allocator, &.{vulkan_sdk, "include"}) });
    exe.root_module.addLibraryPath(.{ .cwd_relative = try std.fs.path.join(b.allocator, &.{vulkan_sdk, "lib"}) });
    exe.root_module.linkSystemLibrary(if (is_windows) "vulkan-1" else "vulkan", .{});
    // glfw
    exe.root_module.addIncludePath(b.path("third-party/glfw-3.4/include"));
    if (is_windows) exe.root_module.addLibraryPath(b.path("third-party/glfw-3.4/lib"));
    exe.root_module.linkSystemLibrary("glfw3", .{});
    if (is_windows) b.installBinFile("third-party/glfw-3.4/lib/glfw3.dll", "bin/glfw3.dll");

    try compileSlangShader(b, exe, "shader.slang", &.{"vertMain", "concaveMain", "convexMain"});

    b.installArtifact(exe);


    // check
    const check = b.step("check", "");
    const exe_check = b.addExecutable(.{
        .name = "font-renderer-check",
        .root_module = exe.root_module,
    });
    check.dependOn(&exe_check.step);
}

fn compileSlangShader(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8, enties: []const []const u8) !void {
    const src_in = try std.fmt.allocPrint(b.allocator, "src/shaders/{s}", .{name});
    const build_out = try std.fmt.allocPrint(b.allocator, "{s}.spv", .{name});

    var build_shader = b.addSystemCommand(&.{ "slangc" }); // should be in VULKAN_SDK
    build_shader.addFileArg(b.path(src_in));
    build_shader.addArgs(&.{"-target", "spirv"});
    build_shader.addArgs(&.{"-profile", "spirv_1_4"});
    build_shader.addArg("-emit-spirv-directly");
    build_shader.addArg("-fvk-use-entrypoint-name");
    for (enties) |entry| build_shader.addArgs(&.{"-entry", entry});
    build_shader.addArg("-o");
    const spv = build_shader.addOutputFileArg(build_out);

    exe.root_module.addAnonymousImport(name, .{ .root_source_file = spv });
}

