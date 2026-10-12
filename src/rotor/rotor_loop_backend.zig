//! The backend a process runs: the backends this build carries, the choice a process makes among
//! them, and the call by which a caller makes that choice itself. Split from `rotor_loop.zig` for
//! the 500-line limit.
//!
//! **On Linux a process runs one of two backends** (decision 20, open question 5, which Camilo
//! ruled on 2026-09-22: a fallback at init). `uring` where the kernel gives it a ring, and `epoll`
//! where the kernel refuses one, as Docker's default seccomp profile does. The choice is made once,
//! the first time anything needs it, and kept for the life of the process. Once and not per loop,
//! because the sockets `sync` opens before any loop exists must suit the backend the loops will
//! run: uring's sockets block, since the ring does the waiting, and epoll's must not, since its
//! loop makes each call itself. It is the one value rotor keeps outside the memory a caller hands
//! it.
//!
//! **A caller may make the choice itself**, with `require`, before anything else asks (decision 23,
//! which Camilo ruled on 2026-10-12). A program that sleeps in a wait of its own, with a loop
//! inside it, needs a backend whose loop has a descriptor that wait can hold, and io_uring's has
//! none (`Loop.wait_descriptor`).
//!
//! **The choice is reported, not silent.** `uring_ring.zig` promises never to fall back to a slower
//! path without saying so; `rotor.backend()` says which one this process runs.
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const uring = @import("uring");

const linux = builtin.os.tag == .linux;

comptime {
    if (!linux and !builtin.os.tag.isDarwin()) {
        @compileError("rotor has no backend for this operating system");
    }
}

/// A backend a process can run, as `rotor.backend()` reports it.
pub const Backend = enum { uring, epoll, kqueue };

/// The backends this build carries: one member of each union in `rotor_loop.zig` per value.
pub const Tag = if (linux) enum { uring, epoll } else enum { kqueue };

/// The module of the backend `tag` names.
pub fn module(comptime tag: Tag) type {
    return @field(modules, @tagName(tag));
}

/// Each backend's module under its tag's name, for `module`. A module this build does not carry is
/// never named, so it is never analysed.
const modules = struct {
    const uring = @import("uring");
    const epoll = @import("epoll");
    const kqueue = @import("kqueue");
};

/// The process's choice, kept in a file of its own: it is the one `var` under `src/` that every
/// thread shares (`rotor_choice.zig` says why).
const choice = @import("rotor_choice.zig");

/// The backend this process runs. On Linux it asks the kernel the first time, the way a uring loop
/// would ask, and keeps the answer; on Darwin there is nothing to ask. A choice `require` stored
/// first is the answer, and the kernel is not asked.
///
/// Two threads that ask first at once both ask the kernel, and the first answer stored is the one
/// every thread gets, so no two loops of a process can disagree.
pub fn chosen() Tag {
    if (comptime !linux) return .kqueue;
    const known = choice.load();
    if (known != choice.undecided) return @enumFromInt(known);
    const decided: Tag = if (uring.refused()) .epoll else .uring;
    return @enumFromInt(choice.settle(@intFromEnum(decided)));
}

/// Why `require` left the process's backend as it was.
pub const RequireError = error{
    /// This host cannot run the backend: it belongs to another operating system, or it is io_uring
    /// and the kernel refuses this process a ring.
    Unsupported,
    /// The process already runs another backend. The choice holds for the life of the process, so
    /// a caller requires a backend before anything else asks for one.
    OtherBackendChosen,
};

/// Makes `wanted` the backend this process runs, or says why it is not (decision 23). It stores
/// the choice when none is stored, and succeeds when the stored choice already is `wanted`, so a
/// second call with the same backend is harmless. It never falls back: a caller that names a
/// backend gets that one or an error, and an error stores nothing.
///
/// io_uring is asked for the way `chosen` asks, with a ring made and closed again, and only when
/// no choice is stored. A process short of descriptors or memory is short of them on any backend,
/// so that is not a refusal here either, and `Loop.init` reports it. epoll and kqueue are not
/// asked for: `Loop.init` reports a kernel that lacks what they need.
pub fn require(wanted: Backend) RequireError!void {
    const tag = std.meta.stringToEnum(Tag, @tagName(wanted)) orelse return error.Unsupported;
    // Darwin carries one backend, so there is nothing to store.
    if (comptime !linux) return;
    const undecided = choice.load() == choice.undecided;
    if (undecided and tag == .uring and uring.refused()) return error.Unsupported;
    // Another thread may have stored a choice since the load above: the first one stored stands.
    const standing = choice.settle(@intFromEnum(tag));
    if (standing != @intFromEnum(tag)) return error.OtherBackendChosen;
    assert(chosen() == tag);
}

const testing = std.testing;
const Loop = @import("rotor_loop.zig").Loop;

test "a kept choice is what every later ask gets, whatever the kernel would say now" {
    if (comptime !linux) return error.SkipZigTest;
    // Asking the kernel again could split one process's loops and sockets between two backends if
    // its answer changed, as a seccomp filter installed later would change it. So the answer kept
    // is the answer. Planted here as the opposite of what this kernel says, then restored.
    const kernel_says = chosen();
    const planted: Tag = if (kernel_says == .uring) .epoll else .uring;
    choice.plant(@intFromEnum(planted));
    defer choice.plant(@intFromEnum(kernel_says));
    try testing.expectEqual(planted, chosen());
    try testing.expectEqual(planted, chosen());
}

test "a kept choice is read, not asked again: a thousand asks cost far less than one probe" {
    if (comptime !linux) return error.SkipZigTest;
    // Every `sync` call that opens a socket asks, so asking the kernel each time would put several
    // system calls on each of them. The answer would not change, which is why only the cost shows.
    //
    // A kept answer is one atomic load, a few nanoseconds, so a burst of a thousand takes a few
    // microseconds. Asking the kernel again costs a refused `io_uring_setup` at the least, about a
    // microsecond under seccomp and far more where a ring is made and closed, so a burst that asked
    // every time takes a millisecond or more. The bound sits between, and the best of twenty bursts
    // decides, as the cost gates of `conformance_cost.zig` do: other work makes a burst slower and
    // never faster. The clock is the backend's test helper, because this module reads none.
    const asks = 1000;
    const attempts = 20;
    const bound_ns = 100 * core.constants.ns_per_us;
    const monotonic_ns = uring.testing.monotonic_ns;
    _ = chosen();
    var best_ns: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        const before = monotonic_ns();
        for (0..asks) |_| std.mem.doNotOptimizeAway(chosen());
        best_ns = @min(best_ns, monotonic_ns() - before);
    }
    try testing.expect(best_ns < bound_ns);
}

/// The backend `tag` names, as a caller names it.
fn backend_of(tag: Tag) Backend {
    return std.meta.stringToEnum(Backend, @tagName(tag)).?;
}

test "requiring the backend the process runs changes nothing, and requiring another is refused" {
    if (comptime !linux) {
        // One backend on Darwin: it is the one a process runs, and the Linux ones cannot run here.
        try require(.kqueue);
        try testing.expectError(error.Unsupported, require(.uring));
        try testing.expectError(error.Unsupported, require(.epoll));
        return;
    }
    const standing = chosen();
    const other: Backend = if (standing == .uring) .epoll else .uring;
    try require(backend_of(standing));
    try require(backend_of(standing));
    try testing.expectError(error.OtherBackendChosen, require(other));
    try testing.expectError(error.Unsupported, require(.kqueue));
    // A refusal stores nothing, so the process runs what it ran.
    try testing.expectEqual(standing, chosen());
}

const required_operations = 4;
const required_options: Loop.Options = .{ .operations = required_operations };
const required_timer_ns = core.constants.ns_per_ms;
const required_wait_ms = 50;
const required_wait_ns = required_wait_ms * core.constants.ns_per_ms;

test "a process that requires epoll before anything asks runs epoll, even where the kernel gives a ring" {
    if (comptime !linux) return error.SkipZigTest;
    // The test process has chosen already, so its choice is taken out for this test and put back
    // after. Where the kernel gives a ring, which is the Linux gate's run with io_uring, the choice
    // put back is `uring`: there this test shows the process running epoll although the kernel
    // gives a ring. Under the default seccomp profile the kernel refuses one, and the process would
    // run epoll without the requirement.
    const kernel_says = chosen();
    choice.plant(choice.undecided);
    defer choice.plant(@intFromEnum(kernel_says));
    try require(.epoll);
    try testing.expectEqual(Tag.epoll, chosen());

    // A loop made now is an epoll loop, with a descriptor a host can wait on, and it runs.
    var memory: [Loop.memory_bytes(required_options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, required_options);
    defer loop.deinit();
    try testing.expectEqual(Tag.epoll, std.meta.activeTag(loop.inner));
    try testing.expect(loop.wait_descriptor() != null);
    var events: [2]core.Event = undefined;
    try testing.expectEqual(1, loop.submit(&.{core.Operation.timer(7, required_timer_ns, 0)}, &.{}));
    try testing.expectEqual(1, try loop.tick(&events, required_wait_ns));
    try testing.expectEqual(7, events[0].user_data);
}

test "requiring io_uring where the kernel refuses a ring is an error, with no fallback to epoll" {
    if (comptime !linux) return error.SkipZigTest;
    // A process that chose epoll by itself runs on a kernel that refuses a ring: that is the only
    // way the fallback chooses it. The Linux gate's run under the default seccomp profile is that
    // process, and its run with io_uring is the other branch.
    const kernel_says = chosen();
    choice.plant(choice.undecided);
    defer choice.plant(@intFromEnum(kernel_says));
    if (kernel_says == .uring) {
        try require(.uring);
        try testing.expectEqual(Tag.uring, chosen());
        return;
    }
    try testing.expectError(error.Unsupported, require(.uring));
    // Nothing was stored: the caller asked for io_uring by name, so the process does not run epoll
    // in its place, and the caller may still require epoll itself.
    try testing.expectEqual(choice.undecided, choice.load());
    try require(.epoll);
    try testing.expectEqual(Tag.epoll, chosen());
}
