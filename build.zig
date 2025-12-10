const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Library Module (for external users via zig fetch)
    // ========================================================================

    _ = b.addModule("zenmap", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Demo Executable
    // ========================================================================

    const exe = b.addExecutable(.{
        .name = "zenmap_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zenmap demo");
    run_step.dependOn(&run_cmd.step);

    // ========================================================================
    // Library Tests
    // ========================================================================

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // ========================================================================
    // Cross-compilation targets for demonstration
    // ========================================================================

    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    const cross_step = b.step("cross", "Build for all supported platforms");

    for (cross_targets) |cross_target| {
        const cross_exe = b.addExecutable(.{
            .name = b.fmt("zenmap_demo-{s}-{s}", .{
                @tagName(cross_target.cpu_arch.?),
                @tagName(cross_target.os_tag.?),
            }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(cross_target),
                .optimize = optimize,
            }),
        });
        cross_step.dependOn(&b.addInstallArtifact(cross_exe, .{}).step);
    }

    // ========================================================================
    // Check step (for CI - faster than full build)
    // ========================================================================

    const check_lib = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const check_step = b.step("check", "Check for compilation errors");
    check_step.dependOn(&check_lib.step);
}
