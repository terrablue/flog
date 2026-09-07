const std = @import("std");

const App = @import("../runtime/app.zig").App;
const engine = @import("../runtime/engine.zig");

pub const version = @import("../root.zig").version;

pub const Command = union(enum) {
    help,
    invalid,
    run_file: []const u8,
    eval: []const u8,
};

pub fn parse(args: []const []const u8) Command {
    if (args.len == 0) return .help;

    if (args.len == 1) {
        if (isHelp(args[0])) return .help;
        return .{ .run_file = args[0] };
    }

    if (args.len == 2 and std.mem.eql(u8, args[0], "-e")) {
        return .{ .eval = args[1] };
    }

    return .invalid;
}

pub fn printHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("flog {s} ({s})\n\n", .{ version, @tagName(engine.backend) });
    try writer.writeAll(
        \\usage:  flog <file>.js              parse and execute <file>.js
        \\        flog -e <code>              evaluate <code>
        \\        flog help                   show this help
        \\
    );
}

pub fn run(app: *App, command: Command) !u8 {
    return switch (command) {
        .help, .invalid => unreachable,
        .run_file => |path| runFile(app, path),
        .eval => |source| runEval(app, source),
    };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help");
}

fn runFile(app: *App, path: []const u8) !u8 {
    app.runFile(path) catch |err| switch (err) {
        error.AlreadyReported => return 1,
        else => return err,
    };
    return 0;
}

fn runEval(app: *App, source: []const u8) !u8 {
    app.eval(source) catch |err| switch (err) {
        error.AlreadyReported => return 1,
        else => return err,
    };
    return 0;
}

test "parse" {
    const expectCommand = struct {
        fn expect(expected: Command, actual: Command) !void {
            const Tag = @typeInfo(Command).@"union".tag_type.?;
            try std.testing.expectEqual(@as(Tag, expected), @as(Tag, actual));
            switch (expected) {
                .help, .invalid => {},
                .run_file => |path| try std.testing.expectEqualStrings(path, actual.run_file),
                .eval => |source| try std.testing.expectEqualStrings(source, actual.eval),
            }
        }
    }.expect;

    try expectCommand(.help, parse(&.{}));
    try expectCommand(.help, parse(&.{"help"}));
    try expectCommand(.help, parse(&.{"-h"}));
    try expectCommand(.help, parse(&.{"--help"}));
    try expectCommand(.{ .run_file = "app.js" }, parse(&.{"app.js"}));
    try expectCommand(.{ .eval = "1+1" }, parse(&.{ "-e", "1+1" }));
    try expectCommand(.invalid, parse(&.{ "install", "std/console" }));
    try expectCommand(.invalid, parse(&.{ "-e", "a", "b" }));
}
