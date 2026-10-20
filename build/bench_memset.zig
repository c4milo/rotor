//! Links bench/harness/memset.zig into a benchmark program as a separate object. On Linux, the
//! object exports a `memset` that stores 32 bytes at a time. The linker uses it in place of
//! compiler_rt's `memset`, which stores one byte at a time. Every program under bench/ links it,
//! the C candidates too. Thus all candidates of a comparison fill memory with the same code. The
//! library does not link it, because a library that exports `memset` collides with the program of
//! its caller. build.zig stays short (CLAUDE.md, Layout), so this file holds the wiring.
const std = @import("std");

/// The file that exports the programs' `memset`.
const source = "bench/harness/memset.zig";

/// Links the `memset` object into `module` when `module` targets Linux. The object uses the
/// target and the optimize mode of `module`. Each executable that `module` builds then contains
/// it. Other systems get no object, so their programs stay the same: macOS takes `memset` from
/// libSystem, which does not store one byte at a time.
pub fn link(b: *std.Build, module: *std.Build.Module) void {
    if (module.resolved_target.?.result.os.tag != .linux) return;
    const object = b.addObject(.{
        .name = "bench_memset",
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = module.resolved_target.?,
            .optimize = module.optimize.?,
        }),
    });
    module.addObject(object);
}
