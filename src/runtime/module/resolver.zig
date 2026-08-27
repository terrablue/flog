const std = @import("std");

const fs = @import("../fs.zig");

pub const Error = error{BareSpecifier} || std.mem.Allocator.Error;

/// Resolve an import specifier against the referring module's directory.
///
/// - Absolute specifiers are returned as-is (copied).
/// - Specifiers containing `.` (relative paths, `./x.js`, `a.js`) resolve against `referrer_dir`.
/// - Bare specifiers with no `.` (e.g. `std/console`) are not supported until the registry lands.
pub fn resolve(
    gpa: std.mem.Allocator,
    referrer_dir: []const u8,
    specifier: []const u8,
) Error![]u8 {
    if (specifier.len == 0) return error.BareSpecifier;

    if (fs.isAbsolute(specifier)) {
        return gpa.dupe(u8, specifier);
    }

    if (std.mem.indexOfScalar(u8, specifier, '.') == null) {
        return error.BareSpecifier;
    }

    return fs.resolve(gpa, &.{ referrer_dir, specifier });
}

test "relative specifier" {
    const path = try resolve(std.testing.allocator, "/tmp/app", "./lib.js");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/app/lib.js", path);
}

test "sibling specifier without dot-slash" {
    const path = try resolve(std.testing.allocator, "/tmp/app", "lib.js");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/app/lib.js", path);
}

test "parent specifier" {
    const path = try resolve(std.testing.allocator, "/tmp/app/nested", "../assert.js");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/app/assert.js", path);
}

test "bare specifier is rejected" {
    try std.testing.expectError(error.BareSpecifier, resolve(std.testing.allocator, "/tmp", "std/console"));
}

test "absolute specifier" {
    const path = try resolve(std.testing.allocator, "/tmp", "/opt/mod.js");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/opt/mod.js", path);
}
