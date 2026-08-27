const std = @import("std");

const commands = @import("cli/commands.zig");
const App = @import("runtime/app.zig").App;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const environ_map = init.environ_map;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try collectArgs(init);
    defer gpa.free(args);

    const command = commands.parse(args);
    switch (command) {
        .help => {
            try commands.printHelp(stdout);
            try stdout.flush();
            return 0;
        },
        .invalid => {
            try stderr.writeAll("error: invalid arguments\n");
            try commands.printHelp(stderr);
            try stderr.flush();
            return 1;
        },
        .run_file, .eval => {
            const app = try App.init(gpa, io, environ_map);
            defer app.deinit();

            return commands.run(app, command) catch |err| switch (err) {
                error.FileNotFound => {
                    try stderr.writeAll("error: file not found\n");
                    try stderr.flush();
                    return 1;
                },
                error.IsDir => {
                    try stderr.writeAll("error: path is a directory\n");
                    try stderr.flush();
                    return 1;
                },
                error.AccessDenied => {
                    try stderr.writeAll("error: access denied\n");
                    try stderr.flush();
                    return 1;
                },
                else => return err,
            };
        },
    }
}

fn collectArgs(init: std.process.Init) ![]const []const u8 {
    const gpa = init.gpa;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |arg| {
        try list.append(gpa, arg);
    }
    return list.toOwnedSlice(gpa);
}
