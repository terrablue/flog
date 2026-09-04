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

    if (engine == .mquickjs and (optimize == .Debug or optimize == .ReleaseSafe)) {
        std.debug.print(
            "mquickjs requires -Doptimize=ReleaseFast or -Doptimize=ReleaseSmall (tagged-pointer JSValues).\n",
            .{},
        );
        std.process.exit(1);
    }

    const options = b.addOptions();
    options.addOption([]const u8, "engine", @tagName(engine));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "build-options", .module = options.createModule() },
        },
        .target = target,
        .optimize = optimize,
    });

    switch (engine) {
        .kiesel => {
            const kiesel = b.lazyDependency("kiesel", .{
                .target = target,
                .optimize = optimize,
                .@"enable-intl" = false,
                .@"enable-temporal" = false,
                .@"build-cli" = false,
            }) orelse return;
            root_module.addImport("kiesel", kiesel.module("kiesel"));
        },
        .quickjs => {
            const quickjs = b.lazyDependency("quickjs", .{}) orelse return;
            root_module.link_libc = true;
            root_module.addIncludePath(quickjs.path("."));
            root_module.addCMacro("CONFIG_VERSION", "\"2026-06-04\"");
            root_module.addCMacro("_GNU_SOURCE", "1");
            root_module.addCSourceFiles(.{
                .root = quickjs.path("."),
                .files = &.{
                    "quickjs.c",
                    "dtoa.c",
                    "libregexp.c",
                    "libunicode.c",
                    "cutils.c",
                },
                .flags = &.{
                    "-std=gnu11",
                    "-fwrapv",
                    "-Wno-everything",
                },
            });
            root_module.linkSystemLibrary("m", .{});
        },
        .mquickjs => {
            const mqjs = b.lazyDependency("zig_mquickjs", .{
                .target = target,
                .optimize = optimize,
                .@"build-cli" = false,
            }) orelse return;
            root_module.link_libc = true;
            root_module.addImport("mqjs_stdlib_data", mqjs.module("mqjs_stdlib_data"));
            root_module.addIncludePath(mqjs.path("include"));
            root_module.addIncludePath(mqjs.namedWriteFiles("generated_headers").getDirectory());
            root_module.linkLibrary(mqjs.artifact("mquickjs"));
        },
    }

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
