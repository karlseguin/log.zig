const std = @import("std");

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const lib = b.addStaticLibrary(.{
		.name = "logz",
		.root_source_file = .{ .path = "src/logz.zig" },
		.target = target,
		.optimize = optimize,
	});
	lib.install();

	const tests = b.addTest(.{
		.root_source_file = .{ .path = "src/logz.zig" },
		.target = target,
		.optimize = optimize,
	});

	const test_step = b.step("test", "Run tests");
	test_step.dependOn(&tests.step);
}
