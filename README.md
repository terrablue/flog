# Flog

Flog is an engine-agnostic **JavaScript** runtime with a minimal core. 

## Design goals

* Minimal core as a thin wrapper around QuickJS ✓
* Executable and module manager in one WIP
* Namespaced, officially supported standard library ([flogjs/std][std])
* Third-party, scoped module area TODO
* Sandboxing of applications (directory-level scoping) TODO

### Prerequisites

Flog uses `zig build` to manage dependencies and build the project. 

Flog uses Zig 0.16.0. Download Zig at [https://ziglang.org/download](https://ziglang.org/download) . Newer versions may or may not work.

### Getting started

```
zig build                                          # kiesel (default)
zig build -Dengine=quickjs                         # native QuickJS
zig build -Dengine=mquickjs -Doptimize=ReleaseFast # MicroQuickJS (eval only)
```

Zig 0.16.0 introduced a bug where the compiler fails if your home directory is encrypted. To solve this change the cache to outside your home directory using `--cache-dir /tmp/mquickjs-zig-cache`

Create an `app.js` file in the same directory.

```js
var a = 1
var b = 2
log(a + b)
```

You can now run flog with this file as the first argument.

```sh
./zig-out/bin/flog app.js
```

### Resources

* IRC: Join the `#flog` channel on `irc.libera.chat`.

### License

MIT

[rfcs]: https://github.com/flogjs/rfcs
[std]: https://github.com/flogjs/std
[dl]: https://ziglang.org/builds/zig-linux-x86_64-0.11.0-dev.1646+3f7e9ff59.tar.xz
