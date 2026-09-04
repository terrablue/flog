const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("quickjs.h");
});

const fs = @import("../runtime/fs.zig");
const loader = @import("../runtime/module/loader.zig");
const resolver = @import("../runtime/module/resolver.zig");

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *c.JSRuntime,
    context: *c.JSContext,

    pub const RunError = error{AlreadyReported} || fs.ReadError || std.process.CurrentPathAllocError || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        _: *const std.process.Environ.Map,
    ) error{ OutOfMemory, EngineInitFailed }!*Engine {
        const runtime = c.JS_NewRuntime() orelse return error.EngineInitFailed;
        errdefer c.JS_FreeRuntime(runtime);

        const context = c.JS_NewContext(runtime) orelse return error.EngineInitFailed;
        errdefer c.JS_FreeContext(context);

        const self = try gpa.create(Engine);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .runtime = runtime,
            .context = context,
        };

        c.JS_SetModuleLoaderFunc(runtime, moduleNormalize, moduleLoad, self);
        installLog(context);
        return self;
    }

    pub fn deinit(self: *Engine) void {
        c.JS_FreeContext(self.context);
        c.JS_FreeRuntime(self.runtime);
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

        try evalModule(self, source_text, resolved_path);
    }

    pub fn eval(self: *Engine, source: []const u8, name: []const u8) RunError!void {
        try evalModule(self, source, name);
    }
};

fn installLog(ctx: *c.JSContext) void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const func = c.JS_NewCFunction(ctx, jsLog, "log", 1);
    _ = c.JS_SetPropertyStr(ctx, global, "log", func);
}

fn jsLog(
    ctx: ?*c.JSContext,
    _: c.JSValueConst,
    argc: c_int,
    argv: [*c]const c.JSValueConst,
) callconv(.c) c.JSValue {
    const context = ctx.?;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i != 0) _ = c.putchar(' ');
        const str = c.JS_ToCString(context, argv[@intCast(i)]) orelse continue;
        _ = c.printf("%s", str);
        c.JS_FreeCString(context, str);
    }
    _ = c.putchar('\n');
    return jsUndefined();
}

fn jsUndefined() c.JSValue {
    return .{
        .u = .{ .uint64 = 0 },
        .tag = c.JS_TAG_UNDEFINED,
    };
}

fn moduleNormalize(
    ctx: ?*c.JSContext,
    module_base_name: ?[*:0]const u8,
    module_name: ?[*:0]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) ?[*:0]u8 {
    const context = ctx.?;
    const engine: *Engine = @ptrCast(@alignCast(opaque_ptr.?));
    const specifier = std.mem.span(module_name.?);
    const from = std.mem.span(module_base_name.?);
    const from_dir = fs.dirname(from) orelse ".";

    const resolved = resolver.resolve(engine.gpa, from_dir, specifier) catch |err| switch (err) {
        error.OutOfMemory => {
            _ = c.JS_ThrowOutOfMemory(context);
            return null;
        },
        error.BareSpecifier => {
            _ = c.JS_ThrowReferenceError(context, "Bare module specifier '%s' is not supported yet", module_name);
            return null;
        },
    };
    defer engine.gpa.free(resolved);

    const out: [*]u8 = @ptrCast(c.js_malloc(context, resolved.len + 1) orelse return null);
    @memcpy(out[0..resolved.len], resolved);
    out[resolved.len] = 0;
    return @ptrCast(out);
}

fn moduleLoad(
    ctx: ?*c.JSContext,
    module_name: ?[*:0]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) ?*c.JSModuleDef {
    const context = ctx.?;
    const engine: *Engine = @ptrCast(@alignCast(opaque_ptr.?));
    const path = std.mem.span(module_name.?);

    const source_text = loader.loadJs(engine.gpa, engine.io, path) catch {
        _ = c.JS_ThrowReferenceError(context, "Failed to import '%s'", module_name);
        return null;
    };
    defer engine.gpa.free(source_text);

    const source_z = engine.gpa.dupeZ(u8, source_text) catch {
        _ = c.JS_ThrowOutOfMemory(context);
        return null;
    };
    defer engine.gpa.free(source_z);

    const flags: c_int = c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY;
    const value = c.JS_Eval(context, source_z.ptr, source_z.len, module_name, flags);
    if (isException(value)) return null;

    const module_def: *c.JSModuleDef = @ptrCast(@alignCast(value.u.ptr));
    c.JS_FreeValue(context, value);
    return module_def;
}

fn evalModule(self: *Engine, source: []const u8, name: []const u8) Engine.RunError!void {
    const source_z = try self.gpa.dupeZ(u8, source);
    defer self.gpa.free(source_z);
    const name_z = try self.gpa.dupeZ(u8, name);
    defer self.gpa.free(name_z);

    const flags: c_int = c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY;
    var value = c.JS_Eval(self.context, source_z.ptr, source_z.len, name_z.ptr, flags);
    if (isException(value)) {
        try dumpException(self);
        return error.AlreadyReported;
    }

    value = c.JS_EvalFunction(self.context, value);
    value = try awaitValue(self, value);
    if (isException(value) or c.JS_HasException(self.context) != 0) {
        c.JS_FreeValue(self.context, value);
        try dumpException(self);
        return error.AlreadyReported;
    }
    c.JS_FreeValue(self.context, value);
}

fn isException(value: c.JSValue) bool {
    return value.tag == c.JS_TAG_EXCEPTION;
}

fn awaitValue(self: *Engine, obj: c.JSValue) Engine.RunError!c.JSValue {
    const current = obj;
    while (true) {
        const state = c.JS_PromiseState(self.context, current);
        if (state == c.JS_PROMISE_FULFILLED) {
            const ret = c.JS_PromiseResult(self.context, current);
            c.JS_FreeValue(self.context, current);
            return ret;
        } else if (state == c.JS_PROMISE_REJECTED) {
            const ret = c.JS_Throw(self.context, c.JS_PromiseResult(self.context, current));
            c.JS_FreeValue(self.context, current);
            return ret;
        } else if (state == c.JS_PROMISE_PENDING) {
            var job_ctx: ?*c.JSContext = null;
            const err = c.JS_ExecutePendingJob(self.runtime, &job_ctx);
            if (err < 0) {
                try dumpException(self);
                c.JS_FreeValue(self.context, current);
                return error.AlreadyReported;
            }
            if (err == 0) {
                return current;
            }
        } else {
            return current;
        }
    }
}

fn dumpException(self: *Engine) std.Io.Writer.Error!void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(self.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exception = c.JS_GetException(self.context);
    defer c.JS_FreeValue(self.context, exception);

    try stderr.writeAll("Uncaught exception: ");
    if (c.JS_IsError(self.context, exception) != 0) {
        const message = c.JS_GetPropertyStr(self.context, exception, "message");
        defer c.JS_FreeValue(self.context, message);
        if (c.JS_IsUndefined(message) == 0) {
            if (c.JS_ToCString(self.context, message)) |str| {
                defer c.JS_FreeCString(self.context, str);
                try stderr.print("{s}\n", .{str});
            }
        }
        const stack = c.JS_GetPropertyStr(self.context, exception, "stack");
        defer c.JS_FreeValue(self.context, stack);
        if (c.JS_IsUndefined(stack) == 0) {
            if (c.JS_ToCString(self.context, stack)) |str| {
                defer c.JS_FreeCString(self.context, str);
                try stderr.print("{s}\n", .{str});
            }
        }
    } else if (c.JS_ToCString(self.context, exception)) |str| {
        defer c.JS_FreeCString(self.context, str);
        try stderr.print("{s}\n", .{str});
    } else {
        try stderr.writeAll("(unknown)\n");
    }
    try stderr.flush();
}
