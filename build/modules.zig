//! The module graph: one module per directory of `src/`, wired in dependency order. A module can
//! `@import` only what this file gives it, so the dependency direction is enforced by the build
//! and not by review (CLAUDE.md, Layout).
//!
//! One module is registered with `addModule` and the rest are created with `createModule`: only
//! `rotor`, the public API of `src/rotor/rotor.zig`, can be named by a dependent package. It picks this
//! host's backend and re-exports the loop, the types and the socket and buffer helpers. The
//! backends themselves stay private, because how one performs an operation is nobody else's
//! business, and a consumer that needs a backend of its own carries the surface rather than
//! reaching into these (decision 10).
//!
//! `core` imports nothing. `uring` imports `core`. `conformance` imports `core` and one backend,
//! which this file hands it as its `backend` import, so one suite tests every backend
//! (decision 10). `kqueue` imports `core`. docs/decisions/0001-interface.md names the module that
//! follows: `adapter`, after version one. `bench/` is outside `src/` and outside this graph;
//! build/bench.zig wires it.
const std = @import("std");

/// Each module's root is the file named after its directory (`src/core/core.zig`), which lists
/// the module's API as `pub const` declarations and runs every file's tests.
pub const Modules = struct {
    /// The public API: what a dependent package imports, and the only module it can name.
    rotor: *std.Build.Module,
    /// The types the caller sees, the slot table, the timer heap and the named limits.
    core: *std.Build.Module,
    /// The Linux backend, over io_uring. Its pure parts are tested on every host.
    uring: *std.Build.Module,
    /// The conformance suite with `uring` as the backend under test. It skips off Linux.
    conformance_uring: *std.Build.Module,
    /// The macOS backend, over kqueue. Its pure parts are tested on every host.
    kqueue: *std.Build.Module,
    /// The conformance suite with `kqueue` as the backend under test. It skips off macOS.
    conformance_kqueue: *std.Build.Module,
    /// The second Linux backend, over epoll, for a host that refuses io_uring (decision 20). Its
    /// pure parts are tested on every host.
    epoll: *std.Build.Module,
    /// The conformance suite with `epoll` as the backend under test. It skips off Linux, and unlike
    /// the `uring` suite it runs under Docker's default seccomp profile, which is the point of it.
    conformance_epoll: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Modules {
    const core = create(b, "src/core/core.zig", target, optimize);
    const uring = create(b, "src/uring/uring.zig", target, optimize);
    uring.addImport("core", core);
    const conformance_uring = create(b, "src/conformance/conformance.zig", target, optimize);
    conformance_uring.addImport("core", core);
    conformance_uring.addImport("backend", uring);
    const kqueue = create(b, "src/kqueue/kqueue.zig", target, optimize);
    kqueue.addImport("core", core);
    const epoll = create(b, "src/epoll/epoll.zig", target, optimize);
    epoll.addImport("core", core);
    const conformance_epoll = create(b, "src/conformance/conformance.zig", target, optimize);
    conformance_epoll.addImport("core", core);
    conformance_epoll.addImport("backend", epoll);
    const conformance_kqueue = create(b, "src/conformance/conformance.zig", target, optimize);
    conformance_kqueue.addImport("core", core);
    conformance_kqueue.addImport("backend", kqueue);
    // The public module sees both backends and chooses one by host. Nothing else imports both.
    const rotor = public(b, "rotor", "src/rotor/rotor.zig", target, optimize);
    rotor.addImport("core", core);
    rotor.addImport("uring", uring);
    // On Linux the public module falls back to epoll where the kernel refuses io_uring (decision 20,
    // open question 5, ruled by the owner on 2026-09-22), so it needs both Linux backends.
    rotor.addImport("epoll", epoll);
    rotor.addImport("kqueue", kqueue);
    return .{
        .rotor = rotor,
        .core = core,
        .uring = uring,
        .conformance_uring = conformance_uring,
        .kqueue = kqueue,
        .conformance_kqueue = conformance_kqueue,
        .epoll = epoll,
        .conformance_epoll = conformance_epoll,
    };
}

/// A module of this tree alone.
fn create(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
}

/// The module a dependent package can name. The target and the optimize mode are the ones this
/// build resolved, which for a dependency are the consumer's: it passes them to `b.dependency`
/// and `standardTargetOptions` reads them back here.
fn public(
    b: *std.Build,
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.addModule(name, .{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
}
