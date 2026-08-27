const std = @import("std");

pub const ReadError = std.Io.File.OpenError || std.Io.Reader.LimitedAllocError || std.mem.Allocator.Error;

pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ReadError![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    const reader = &file_reader.interface;
    return reader.allocRemaining(gpa, .unlimited);
}

/// Reads a file and replaces invalid UTF-8 sequences with U+FFFD.
pub fn readFileUtf8(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ReadError![]u8 {
    const raw = try readFile(gpa, io, path);
    defer gpa.free(raw);
    return std.fmt.allocPrint(gpa, "{f}", .{std.unicode.fmtUtf8(raw)});
}

pub fn currentPathAlloc(gpa: std.mem.Allocator, io: std.Io) std.process.CurrentPathAllocError![:0]u8 {
    return std.process.currentPathAlloc(io, gpa);
}

pub fn resolve(gpa: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error![]u8 {
    return std.Io.Dir.path.resolve(gpa, paths);
}

pub fn isAbsolute(path: []const u8) bool {
    return std.Io.Dir.path.isAbsolute(path);
}

pub fn dirname(path: []const u8) ?[]const u8 {
    return std.Io.Dir.path.dirname(path);
}

pub fn basename(path: []const u8) []const u8 {
    return std.Io.Dir.path.basename(path);
}

test "dirname of nested path" {
    const dir = dirname("/tmp/app/main.js");
    try std.testing.expectEqualStrings("/tmp/app", dir.?);
}
