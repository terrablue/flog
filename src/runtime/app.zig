const std = @import("std");

const engine_mod = @import("engine.zig");

pub const Engine = engine_mod.Engine;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    engine: *Engine,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
    ) (std.mem.Allocator.Error || error{ExceptionThrown})!*App {
        const engine = try Engine.init(gpa, io, environ_map);
        errdefer engine.deinit();

        const self = try gpa.create(App);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .engine = engine,
        };
        return self;
    }

    pub fn deinit(self: *App) void {
        self.engine.deinit();
        self.gpa.destroy(self);
    }

    pub fn runFile(self: *App, path: []const u8) Engine.RunError!void {
        return self.engine.runMainModule(path);
    }

    pub fn eval(self: *App, source: []const u8) Engine.RunError!void {
        return self.engine.eval(source, "eval");
    }
};
