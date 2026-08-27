const builtin = @import("builtin");
const std = @import("std");

pub const EngineKind = enum {
    kiesel,
    quickjs,
    mquickjs,
};

pub fn build(b: *std.Build) void {
    if (builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) == .lt) {
        std.debug.print("Zig 0.16.0 is required, found {s}.\n", .{builtin.zig_version_string});
        std.process.exit(1);
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const engine = b.option(EngineKind, "engine", "JavaScript engine backend") orelse .kiesel;

    if (engine != .kiesel) {
        std.debug.print(
            "-Dengine={t} is not implemented yet; Phase 1 only supports kiesel.\n",
            .{engine},
        );
        std.process.exit(1);
    }

    const options = b.addOptions();
    options.addOption([]const u8, "engine", @tagName(engine));

    const kiesel = b.dependency("kiesel", .{
        .target = target,
        .optimize = optimize,
        .@"enable-intl" = false,
        .@"enable-temporal" = false,
        .@"build-cli" = false,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "build-options", .module = options.createModule() },
            .{ .name = "kiesel", .module = kiesel.module("kiesel") },
        },
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "flog",
        .root_module = root_module,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run flog");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
