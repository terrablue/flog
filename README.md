# Flog

Flog is an engine-agnostic **JavaScript** runtime with a minimal core.

## Design goals

* Minimal core with selectable JavaScript engines ✓
* Executable and module manager in one WIP
* Namespaced, officially supported standard library ([rcompat/rcompat][rcompat])
* Third-party, scoped module area TODO
* Sandboxing of applications (directory-level scoping) TODO

### Prerequisites

Flog uses `zig build` to manage the project and Git submodules to vendor
engine dependencies.

Flog uses Zig 0.16.0. Download Zig at
[https://ziglang.org/download](https://ziglang.org/download).

### Getting started

Clone the repository with its engine submodules:

```sh
git clone --recurse-submodules https://github.com/terrablue/flog.git
```

If the repository was cloned without them, initialize them with:

```sh
git submodule update --init --recursive
```

Build with Kiesel (the default engine), QuickJS, or MicroQuickJS:

```sh
zig build
zig build -Dengine=quickjs
zig build -Dengine=mquickjs -Doptimize=ReleaseFast
```

Zig 0.16.0 introduced a bug where the compiler fails if your home directory is
encrypted. To solve this, change the cache to outside your home directory:

```sh
zig build --cache-dir /tmp/mquickjs-zig-cache
```

Create an `app.js` file in the same directory:

```js
var a = 1
var b = 2
log(a + b)
```

Run flog with this file as the first argument. Help displays the selected engine:

```sh
./zig-out/bin/flog app.js
./zig-out/bin/flog help
```

Run unit and integration tests:

```sh
zig build test
bash ./run-tests.sh
```

The integration script covers Kiesel and QuickJS. MicroQuickJS currently supports
script and eval smoke tests only because it does not yet support ES modules.

### Resources

* IRC: Join the `#flog` channel on `irc.libera.chat`.

### License

MIT

[rfcs]: https://github.com/flogjs/rfcs
[rcompat]: https://github.com/rcompat/rcompat
