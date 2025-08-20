const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_opts = .{ .target = target, .optimize = optimize };
    const metrics_module = b.dependency("metrics", dep_opts).module("metrics");

    const logz_module = b.addModule("logz", .{
        .root_source_file = b.path("src/logz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "metrics", .module = metrics_module }},
    });

    const lib_test = b.addTest(.{
        .root_module = logz_module,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple }, // add this line
    });
    lib_test.root_module.addImport("metrics", metrics_module);
    const run_test = b.addRunArtifact(lib_test);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);
}
