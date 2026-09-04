const std = @import("std");

const kiesel = @import("kiesel");

const fs = @import("../runtime/fs.zig");
const loader = @import("../runtime/module/loader.zig");
const resolver = @import("../runtime/module/resolver.zig");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Diagnostics = kiesel.language.Diagnostics;
const ImportedModulePayload = kiesel.language.ImportedModulePayload;
const ImportedModuleReferrer = kiesel.language.ImportedModuleReferrer;
const Module = kiesel.language.Module;
const ModuleRequest = kiesel.language.ModuleRequest;
const Realm = kiesel.execution.Realm;
const ScriptOrModule = kiesel.execution.ScriptOrModule;
const SourceTextModule = kiesel.language.SourceTextModule;
const String = kiesel.types.String;
const Value = kiesel.types.Value;
const finishLoadingImportedModule = kiesel.language.finishLoadingImportedModule;
const fmtParseError = kiesel.language.fmtParseError;
const fmtParseErrorHint = kiesel.language.fmtParseErrorHint;

const HostDefined = struct {
    base_dir: []const u8,
};

var module_cache: ModuleRequest.HashMap(Module) = .empty;

pub const Engine = struct {
    platform: *Agent.Platform,
    agent: Agent,
    gpa: std.mem.Allocator,

    pub const RunError = error{AlreadyReported} || Agent.Error || fs.ReadError || std.process.CurrentPathAllocError || std.Io.Writer.Error;

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
    ) (std.mem.Allocator.Error || error{ ExceptionThrown, EngineInitFailed })!*Engine {
        if (kiesel.build_options.enable_libgc) {
            kiesel.gc.disableWarnings();
        }

        const self = try gpa.create(Engine);
        errdefer gpa.destroy(self);

        const platform = try gpa.create(Agent.Platform);
        errdefer gpa.destroy(platform);
        platform.* = .default(io, environ_map);

        self.* = .{
            .platform = platform,
            .agent = try Agent.init(gpa, io, platform, .{}),
            .gpa = gpa,
        };

        installHostHooks(&self.agent);
        try Realm.initializeHostDefinedRealm(&self.agent, .{});
        try installLog(&self.agent);
        return self;
    }

    pub fn deinit(self: *Engine) void {
        module_cache.deinit(self.agent.gc_allocator);
        module_cache = .empty;
        self.agent.deinit();
        self.platform.deinit();
        self.gpa.destroy(self.platform);
        self.gpa.destroy(self);
    }

    pub fn runMainModule(self: *Engine, path: []const u8) RunError!void {
        const agent = &self.agent;
        const cwd = try fs.currentPathAlloc(self.gpa, agent.io);
        defer self.gpa.free(cwd);

        const resolved_path = if (fs.isAbsolute(path))
            try self.gpa.dupe(u8, path)
        else
            try fs.resolve(self.gpa, &.{ cwd, path });
        defer self.gpa.free(resolved_path);

        const source_text = try loader.loadJs(self.gpa, agent.io, resolved_path);
        defer self.gpa.free(source_text);

        const base_dir = fs.dirname(resolved_path) orelse cwd;
        try evaluateModule(agent, source_text, resolved_path, base_dir);
    }

    pub fn eval(self: *Engine, source: []const u8, name: []const u8) RunError!void {
        const agent = &self.agent;
        const cwd = try fs.currentPathAlloc(self.gpa, agent.io);
        defer self.gpa.free(cwd);

        const source_text = try std.fmt.allocPrint(self.gpa, "{f}", .{
            std.unicode.fmtUtf8(source),
        });
        defer self.gpa.free(source_text);

        try evaluateModule(agent, source_text, name, cwd);
    }
};

fn installHostHooks(agent: *Agent) void {
    agent.host_hooks.hostLoadImportedModule = loadImportedModule;
}

fn installLog(agent: *Agent) std.mem.Allocator.Error!void {
    const realm = agent.currentRealm();
    try realm.global_object.defineBuiltinFunction(agent, "log", log, 1, realm);
}

fn log(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const stdout = agent.platform.stdout;
    for (0..arguments.count()) |i| {
        if (i != 0) stdout.writeByte(' ') catch {};
        const string = try arguments.get(i).toString(agent);
        stdout.print("{f}", .{string.fmtRaw()}) catch {};
    }
    stdout.writeByte('\n') catch {};
    stdout.flush() catch {};
    return .undefined;
}

fn loadImportedModule(
    agent: *Agent,
    referrer: ImportedModuleReferrer,
    module_request: ModuleRequest,
    _: ?*anyopaque,
    payload: ImportedModulePayload,
) std.mem.Allocator.Error!void {
    const result = loadImportedModuleInner(agent, referrer, module_request);
    try finishLoadingImportedModule(agent, referrer, module_request, payload, result);
}

fn loadImportedModuleInner(
    agent: *Agent,
    referrer: ImportedModuleReferrer,
    module_request: ModuleRequest,
) Agent.Error!Module {
    const script_or_module: ScriptOrModule = switch (referrer) {
        .script => |script| .{ .script = script },
        .module => |source_text_module| .{
            .module = .{ .source_text_module = source_text_module },
        },
        .realm => unreachable,
    };

    const specifier_utf8 = try module_request.specifier.toUtf8(agent.gc_allocator);
    defer agent.gc_allocator.free(specifier_utf8);

    const module_path = resolveReferrerPath(agent, script_or_module, specifier_utf8) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.BareSpecifier => {
            return agent.throwException(
                .internal_error,
                "Bare module specifier '{s}' is not supported yet",
                .{specifier_utf8},
            );
        },
    };

    const cache_key: ModuleRequest = .{
        .specifier = try String.fromUtf8(agent, module_path),
        .attributes = module_request.attributes,
    };
    if (module_cache.get(cache_key)) |module| return module;

    const source_text = loader.loadJs(agent.gpa, agent.io, module_path) catch |err| {
        return agent.throwException(
            .internal_error,
            "Failed to import '{s}': {t}",
            .{ module_path, err },
        );
    };
    defer agent.gpa.free(source_text);

    const module = try parseSourceTextModule(agent, source_text, module_path);
    try module_cache.putNoClobber(agent.gc_allocator, cache_key, module);
    return module;
}

fn resolveReferrerPath(
    agent: *Agent,
    script_or_module: ScriptOrModule,
    specifier: []const u8,
) (resolver.Error)![]const u8 {
    const host_defined_ptr = switch (script_or_module) {
        .script => |script| script.host_defined,
        .module => |module| switch (module) {
            .source_text_module => |m| m.host_defined,
            .synthetic_module => unreachable,
        },
    };
    const host_defined: *HostDefined = @ptrCast(@alignCast(host_defined_ptr.?));
    return resolver.resolve(agent.gc_allocator, host_defined.base_dir, specifier);
}

fn parseSourceTextModule(
    agent: *Agent,
    source_text: []const u8,
    path: []const u8,
) Agent.Error!Module {
    const realm = agent.currentRealm();
    const host_defined = try agent.gc_allocator.create(HostDefined);
    host_defined.* = .{
        .base_dir = try agent.gc_allocator.dupe(u8, fs.dirname(path) orelse "."),
    };

    var diagnostics = Diagnostics.init(agent.gpa);
    defer diagnostics.deinit();

    const source_text_module = SourceTextModule.parse(source_text, realm, host_defined, .{
        .diagnostics = &diagnostics,
        .file_name = fs.basename(path),
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseError => {
            const parse_error = diagnostics.errors.items[0];
            return agent.throwException(.syntax_error, "{f}", .{fmtParseError(parse_error)});
        },
    };
    return .{ .source_text_module = source_text_module };
}

fn evaluateModule(
    agent: *Agent,
    source_text: []const u8,
    path: []const u8,
    base_dir: []const u8,
) Engine.RunError!void {
    const stderr = agent.platform.stderr;
    const realm = agent.currentRealm();

    const host_defined = try agent.gc_allocator.create(HostDefined);
    host_defined.* = .{
        .base_dir = try agent.gc_allocator.dupe(u8, base_dir),
    };

    var diagnostics = Diagnostics.init(agent.gpa);
    defer diagnostics.deinit();

    const source_text_module = SourceTextModule.parse(source_text, realm, host_defined, .{
        .diagnostics = &diagnostics,
        .file_name = path,
    }) catch |err| switch (err) {
        error.ParseError => {
            const parse_error = diagnostics.errors.items[0];
            try stderr.print("{f}\nUncaught exception: {f}\n", .{
                fmtParseErrorHint(parse_error, source_text),
                fmtParseError(parse_error),
            });
            try stderr.flush();
            return error.AlreadyReported;
        },
        error.OutOfMemory => |e| return e,
    };
    const module: Module = .{ .source_text_module = source_text_module };

    const cache_key: ModuleRequest = .{
        .specifier = try String.fromUtf8(agent, path),
        .attributes = &.{},
    };
    try module_cache.putNoClobber(agent.gc_allocator, cache_key, module);

    defer agent.drainJobQueue();

    var promise = module.loadRequestedModules(agent, null) catch |err| {
        return reportException(agent, err);
    };
    switch (promise.fields.promise_state) {
        .pending => unreachable,
        .rejected => {
            agent.exception = .{
                .value = promise.fields.promise_result,
                .stack_trace = &.{},
            };
            return reportException(agent, error.ExceptionThrown);
        },
        .fulfilled => {},
    }

    module.link(agent) catch |err| {
        return reportException(agent, err);
    };

    promise = module.evaluate(agent) catch |err| {
        return reportException(agent, err);
    };
    switch (promise.fields.promise_state) {
        .pending => unreachable,
        .rejected => {
            agent.exception = .{
                .value = promise.fields.promise_result,
                .stack_trace = &.{},
            };
            return reportException(agent, error.ExceptionThrown);
        },
        .fulfilled => {},
    }
}

fn reportException(agent: *Agent, err: Agent.Error) Engine.RunError {
    const stderr = agent.platform.stderr;
    switch (err) {
        error.OutOfMemory => {
            try stderr.writeAll("Out of memory\n");
            try stderr.flush();
            return error.AlreadyReported;
        },
        error.ExceptionThrown => {
            const exception = agent.clearException();
            try stderr.print("Uncaught exception: {f}\n", .{
                exception.fmtPretty(agent, null),
            });
            try stderr.flush();
            return error.AlreadyReported;
        },
    }
}
