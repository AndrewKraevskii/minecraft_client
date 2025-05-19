const std = @import("std");

const sokol = @import("sokol");

const shaders: []const []const u8 = &.{
    "src/shaders/cube.glsl",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_geo_math = b.dependency("geo_math", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_imgui = b.dependency("imgui", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
    });
    const dep_sokol_2d = b.dependency("sokol_2d", .{
        .target = target,
        .optimize = optimize,
    });
    dep_sokol.artifact("sokol_clib").addIncludePath(dep_imgui.path("src"));
    dep_sokol_2d.module("sokol_2d").addImport("sokol", dep_sokol.module("sokol"));

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/Game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "geo_math", .module = dep_geo_math.module("geo_math") },
            .{ .name = "sokol_2d", .module = dep_sokol_2d.module("sokol_2d") },
            .{ .name = "imgui", .module = dep_imgui.module("cimgui") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "minecraft_protocol",
        .root_module = exe_mod,
        .use_llvm = false,
    });
    inline for (shaders) |shader| {
        // shader compilation step
        const shd_step = try sokol.shdc.compile(b, .{
            .dep_shdc = dep_sokol.builder.dependency("shdc", .{}),
            .input = b.path(shader),
            .output = b.path(shader ++ ".zig"),
            .slang = .{
                .glsl430 = true,
                .hlsl4 = true,
                .metal_macos = true,
                .glsl310es = true,
            },
        });

        exe.step.dependOn(&shd_step.step);
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
