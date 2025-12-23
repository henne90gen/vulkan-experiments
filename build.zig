const std = @import("std");

fn createGLFW(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const glfw = b.addModule("glfw", .{
        .root_source_file = b.path("src/glfw.zig"),
        .target = target,
        .optimize = optimize,
    });

    const glfw_dep = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const glfw_lib = glfw_dep.artifact("glfw");
    for (glfw_lib.root_module.include_dirs.items) |*included| {
        switch (included.*) {
            .path => glfw.addIncludePath(included.path),
            else => {},
        }
    }

    glfw.linkLibrary(glfw_lib);

    glfw.addCMacro("GLFW_INCLUDE_NONE", "1");
    glfw.addCMacro("GLFW_INCLUDE_VULKAN", "1");

    return glfw;
}

fn createVulkan(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const vulkan = b.addModule("vulkan", .{
        .root_source_file = b.path("src/vulkan.zig"),
        .target = target,
        .optimize = optimize,
    });

    vulkan.linkSystemLibrary("vulkan", .{});

    return vulkan;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const glfw = createGLFW(b, target, optimize);
    const vulkan = createVulkan(b, target, optimize);
    const exe = b.addExecutable(.{
        .name = "vulkan_tutorial",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glfw", .module = glfw },
                .{ .name = "vulkan", .module = vulkan },
            },
        }),
    });

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

    const mod_tests = b.addTest(.{
        .root_module = glfw,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
