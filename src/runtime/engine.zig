const std = @import("std");

const build_options = @import("build-options");

pub const Backend = enum {
    kiesel,
    quickjs,
    mquickjs,
};

pub const backend: Backend = std.meta.stringToEnum(Backend, build_options.engine) orelse .kiesel;

pub const Engine = switch (backend) {
    .kiesel => @import("../engines/kiesel.zig").Engine,
    .quickjs => @import("../engines/quickjs.zig").Engine,
    .mquickjs => @import("../engines/mquickjs.zig").Engine,
};
