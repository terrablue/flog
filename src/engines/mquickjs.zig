const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stddef.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("mquickjs.h");
});

const stdlib_data = @import("mqjs_stdlib_data");
const fs = @import("../runtime/fs.zig");
const loader = @import("../runtime/module/loader.zig");

const HEAP_SIZE = 2 * 1024 * 1024;

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mem_buf: []align(8) u8,
    context: *c.JSContext,

    pub const RunError = error{AlreadyReported} || fs.ReadError || std.process.CurrentPathAllocError || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        _: *const std.process.Environ.Map,
    ) error{ OutOfMemory, EngineInitFailed }!*Engine {
        stdlib_data.relocate();

        const mem_buf = try gpa.alignedAlloc(u8, .fromByteUnits(8), HEAP_SIZE);
        errdefer gpa.free(mem_buf);

        const context = c.JS_NewContext(mem_buf.ptr, mem_buf.len, @ptrCast(&stdlib_data.js_stdlib)) orelse
            return error.EngineInitFailed;

        c.JS_SetLogFunc(context, jsLogFunc);

        const self = try gpa.create(Engine);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .mem_buf = mem_buf,
            .context = context,
        };

        const log_src = "var log = print;\n";
        const log_val = c.JS_Eval(context, log_src, log_src.len, "flog-log", 0);
        if (c.JS_IsException(log_val) != 0) {
            c.JS_FreeContext(context);
            gpa.destroy(self);
            gpa.free(mem_buf);
            return error.EngineInitFailed;
        }

        return self;
    }

    pub fn deinit(self: *Engine) void {
        c.JS_FreeContext(self.context);
        self.gpa.free(self.mem_buf);
        self.gpa.destroy(self);
    }

    pub fn runMainModule(self: *Engine, path: []const u8) RunError!void {
        const cwd = try fs.currentPathAlloc(self.gpa, self.io);
        defer self.gpa.free(cwd);

        const resolved_path = if (fs.isAbsolute(path))
            try self.gpa.dupe(u8, path)
        else
            try fs.resolve(self.gpa, &.{ cwd, path });
        defer self.gpa.free(resolved_path);

        const source_text = try loader.loadJs(self.gpa, self.io, resolved_path);
        defer self.gpa.free(source_text);

        try evalScript(self, source_text, resolved_path);
    }

    pub fn eval(self: *Engine, source: []const u8, name: []const u8) RunError!void {
        try evalScript(self, source, name);
    }
};

fn evalScript(self: *Engine, source: []const u8, name: []const u8) Engine.RunError!void {
    const source_z = try self.gpa.dupeZ(u8, source);
    defer self.gpa.free(source_z);
    const name_z = try self.gpa.dupeZ(u8, name);
    defer self.gpa.free(name_z);

    const val = c.JS_Eval(self.context, source_z.ptr, source_z.len, name_z.ptr, 0);
    if (c.JS_IsException(val) != 0) {
        try dumpException(self);
        return error.AlreadyReported;
    }
}

fn dumpException(self: *Engine) std.Io.Writer.Error!void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(self.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("Uncaught exception: ");
    try stderr.flush();
    const obj = c.JS_GetException(self.context);
    c.JS_PrintValueF(self.context, obj, c.JS_DUMP_LONG);
    _ = c.putchar('\n');
}

fn jsLogFunc(_: ?*anyopaque, buf: ?*const anyopaque, buf_len: usize) callconv(.c) void {
    _ = c.fwrite(buf, 1, buf_len, c.stdout);
}

fn throwTypeError(ctx: *c.JSContext, comptime msg: [:0]const u8) c.JSValue {
    return c.JS_ThrowError(ctx, c.JS_CLASS_TYPE_ERROR, msg);
}

fn getTimeMs() i64 {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
    }
    return 0;
}

fn getDateMs() i64 {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
    }
    return getTimeMs();
}

export fn js_print(
    ctx: *c.JSContext,
    this_val: *c.JSValue,
    argc: c_int,
    argv: [*]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i != 0) _ = c.putchar(' ');
        const v = argv[@intCast(i)];
        if (c.JS_IsString(ctx, v) != 0) {
            var buf: c.JSCStringBuf = undefined;
            var len: usize = undefined;
            const str = c.JS_ToCStringLen(ctx, &len, v, &buf);
            _ = c.fwrite(str, 1, len, c.stdout);
        } else {
            c.JS_PrintValueF(ctx, argv[@intCast(i)], c.JS_DUMP_LONG);
        }
    }
    _ = c.putchar('\n');
    return c.JS_UNDEFINED;
}

export fn js_gc(
    ctx: *c.JSContext,
    this_val: *c.JSValue,
    argc: c_int,
    argv: [*]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    c.JS_GC(ctx);
    return c.JS_UNDEFINED;
}

export fn js_date_constructor(
    ctx: *c.JSContext,
    this_val: *c.JSValue,
    argc: c_int,
    argv: [*]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    var arg_count = argc;
    arg_count &= ~c.FRAME_CF_CTOR;
    var val: f64 = undefined;
    if (arg_count == 0) {
        val = @floatFromInt(getDateMs());
    } else if (arg_count == 1 and c.JS_IsNumber(ctx, argv[0]) != 0) {
        if (c.JS_ToNumber(ctx, &val, argv[0]) != 0)
            return c.JS_EXCEPTION;
    } else {
        return throwTypeError(ctx, "unsupported Date() parameter");
    }
    return c.JS_NewDate(ctx, val);
}

export fn js_date_now(
    ctx: *c.JSContext,
    this_val: *c.JSValue,
    argc: c_int,
    argv: [*]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    return c.JS_NewInt64(ctx, getDateMs());
}

export fn js_performance_now(
    ctx: *c.JSContext,
    this_val: *c.JSValue,
    argc: c_int,
    argv: [*]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    return c.JS_NewInt64(ctx, getTimeMs());
}

export fn js_load(
    ctx: *c.JSContext,
    this_val: *c.JSValue,
    argc: c_int,
    argv: [*]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    return throwTypeError(ctx, "load() is not supported in flog");
}

export fn js_setTimeout(
    ctx: *c.JSContext,
    this_val: *c.JSValue,
    argc: c_int,
    argv: [*]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    return c.JS_NewInt32(ctx, 0);
}

export fn js_clearTimeout(
    ctx: *c.JSContext,
    this_val: *c.JSValue,
    argc: c_int,
    argv: [*]c.JSValue,
) callconv(.c) c.JSValue {
    _ = ctx;
    _ = this_val;
    _ = argc;
    _ = argv;
    return c.JS_UNDEFINED;
}
