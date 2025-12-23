const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "vulkan_tutorial",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // GLFW
    const glfw_dep = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const glfw_lib = glfw_dep.artifact("glfw");
    for (glfw_lib.root_module.include_dirs.items) |*included| {
        switch (included.*) {
            .path => exe.addIncludePath(included.path),
            else => {},
        }
    }
    exe.linkLibrary(glfw_lib);
    exe.root_module.addCMacro("GLFW_INCLUDE_NONE", "1");
    exe.root_module.addCMacro("GLFW_INCLUDE_VULKAN", "1");

    // Vulkan
    const vulkan_sdk_path = b.option([]const u8, "vulkan-sdk-path", "Path to Vulkan SDK");
    if (vulkan_sdk_path == null and builtin.os.tag == .windows) {
        std.debug.print("Missing required option -Dvulkan-sdk-path", .{});
        return error.MissingVulkanSDKPath;
    }
    if (vulkan_sdk_path != null) {
        exe.root_module.addIncludePath(.{ .cwd_relative = try std.fmt.allocPrint(b.allocator, "{s}/Include", .{vulkan_sdk_path.?}) });
        exe.root_module.addLibraryPath(.{ .cwd_relative = try std.fmt.allocPrint(b.allocator, "{s}/Lib", .{vulkan_sdk_path.?}) });
    }
    exe.root_module.linkSystemLibrary("vulkan", .{});

    b.installArtifact(exe);

    const glslc_vert = b.addSystemCommand(&.{"glslc"});
    glslc_vert.addFileInput(b.path("src/shader.vert"));
    glslc_vert.addFileArg(b.path("src/shader.vert"));
    glslc_vert.addArg("-o");
    glslc_vert.addFileArg(b.path("src/shader.vert.spv"));
    exe.step.dependOn(&glslc_vert.step);

    const glslc_frag = b.addSystemCommand(&.{"glslc"});
    glslc_frag.addFileInput(b.path("src/shader.frag"));
    glslc_frag.addFileArg(b.path("src/shader.frag"));
    glslc_frag.addArg("-o");
    glslc_frag.addFileArg(b.path("src/shader.frag.spv"));
    exe.step.dependOn(&glslc_frag.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
