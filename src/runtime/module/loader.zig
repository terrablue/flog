const std = @import("std");

const fs = @import("../fs.zig");

pub const Error = fs.ReadError;

pub fn loadJs(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Error![]u8 {
    return fs.readFileUtf8(gpa, io, path);
}

pub fn isJs(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs");
}

test "isJs" {
    try std.testing.expect(isJs("app.js"));
    try std.testing.expect(isJs("mod.mjs"));
    try std.testing.expect(!isJs("data.json"));
}
