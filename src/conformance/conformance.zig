//! The conformance suite (decision 10, point 2): scenarios written against the surface every
//! backend carries, run against the real kernel. The build hands this module one backend as its
//! `backend` import, so the same file tests `uring` and `epoll` under Linux and `kqueue` under
//! macOS, and all three passing is what shows that they present the caller one behaviour
//! (decision 5).
//!
//! A scenario uses nothing but the backend's public surface: `Loop`, `Registry`, and the
//! synchronous calls of `sync`. On a host the backend cannot run on, every scenario skips.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");
const stall = @import("conformance_stall.zig");
const registry_life = @import("conformance_registry.zig");

pub const Loop = backend.Loop;
pub const Event = core.Event;
pub const Handle = core.Handle;
pub const Operation = core.Operation;

pub const RegistryLife = registry_life.RegistryLife;

pub const operations = 64;
pub const entries = 16;
const memory_bytes = Loop.memory_bytes(&.{ .operations = operations, .entries = entries });

/// The most rounds `Harness.collect` ticks before it gives up: with a 10 ms wait each, 2 s.
pub const collect_rounds_max = 200;
const collect_wait_ns = 10 * core.constants.ns_per_ms;

/// The environment variable that gives every harness loop a spin budget, in nanoseconds. The build
/// runs the suite once without it and once with it, so every scenario also runs on a loop that
/// polls before it blocks, and has to hand over the same events (decision 13, "How it is checked",
/// point 1).
pub const spin_variable = "ROTOR_CONFORMANCE_SPIN_NS";

/// The spin budget the environment asks for, or 0 when it asks for none. A value that is not a
/// budget halts the run: a second run that quietly spun for nothing would prove nothing.
pub fn spin_budget_ns() u64 {
    const text = std.testing.environ.getPosix(spin_variable) orelse return 0;
    const budget_ns = std.fmt.parseInt(u64, text, 10) catch @panic(spin_variable ++ " is not a number");
    if (budget_ns > core.constants.spin_budget_ns_max) @panic(spin_variable ++ " is over the most");
    return budget_ns;
}

/// One loop over static memory, and the waiting every scenario needs.
pub const Harness = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment),
    loop: Loop,

    pub fn init(harness: *Harness, id: core.LoopId, registry: ?*backend.Registry) !void {
        return harness.init_sampling(id, registry, .{});
    }

    /// A loop that performs a file operation inline, which on kqueue a caller must now ask for by
    /// name (decision 18): the default policy refuses, so that a stall is never invisible. On
    /// io_uring the option is checked and ignored, and the scenario reads the same thing either way.
    pub fn init_blocking(
        harness: *Harness,
        id: core.LoopId,
        registry: ?*backend.Registry,
    ) !void {
        try check_life(registry);
        try harness.loop.init(&harness.memory, &.{
            .operations = operations,
            .entries = entries,
            .id = id,
            .registry = registry,
            .file_policy = .blocking,
            .spin_budget_ns = spin_budget_ns(),
        });
    }

    /// A loop that samples as `sampling` says, for the scenarios that read its statistics.
    pub fn init_sampling(
        harness: *Harness,
        id: core.LoopId,
        registry: ?*backend.Registry,
        sampling: core.statistics.Options,
    ) !void {
        try check_life(registry);
        try harness.loop.init(&harness.memory, &.{
            .operations = operations,
            .entries = entries,
            .id = id,
            .registry = registry,
            .sampling = sampling,
            .spin_budget_ns = spin_budget_ns(),
        });
    }

    /// A loop with the spin budget `budget_ns`, whatever the environment asks, for the scenarios
    /// that check what a budget does (decision 13).
    pub fn init_spin(harness: *Harness, budget_ns: u64) !void {
        try harness.loop.init(&harness.memory, &.{
            .operations = operations,
            .entries = entries,
            .spin_budget_ns = budget_ns,
        });
    }

    pub fn deinit(harness: *Harness) void {
        end_in_flight(&harness.loop);
        harness.loop.deinit();
    }

    /// Refuses a loop on a registry when no `RegistryLife` is open, because nothing would close the
    /// wake the registry keeps for the loop (decision 4, amendment of 2026-11-06).
    fn check_life(registry: ?*backend.Registry) error{RegistryNotStarted}!void {
        if (registry == null) return;
        if (!registry_life.life_open()) return error.RegistryNotStarted;
    }

    /// Submits `batch` whole, or fails: no scenario fills the table.
    pub fn submit(harness: *Harness, batch: []const Operation, handles: []Handle) !void {
        const taken = harness.loop.submit(batch, handles);
        if (taken != batch.len) return error.TableFull;
    }

    /// One `tick` of the loop. It fails with `error.CallbackStalled` when a callback that
    /// `conformance_stall.zig` made ran past its limit.
    pub fn tick(harness: *Harness, events: []Event, wait_ns: u64) !u32 {
        const count = try harness.loop.tick(events, wait_ns);
        try stall.check();
        return count;
    }

    /// `drain` of the loop, with the stall check of `tick`. A stall comes before the error of the
    /// drain, because a task that stalled can be why tasks are still queued.
    pub fn drain(harness: *Harness, events: []Event) !void {
        const drained = harness.loop.drain(events);
        try stall.check();
        return drained;
    }

    /// Ticks until `events` is full, and fails when it is not full within the bound.
    pub fn collect(harness: *Harness, events: []Event) !void {
        var filled: usize = 0;
        var round: u32 = 0;
        while (filled < events.len and round < collect_rounds_max) : (round += 1) {
            filled += try harness.tick(events[filled..], collect_wait_ns);
        }
        if (filled < events.len) return error.EventsMissing;
    }

    /// Waits `nanoseconds` through the loop itself, with a timer, so another thread gets time to
    /// start: a scenario that posts across threads gives the other side that long.
    pub fn pause(harness: *Harness, nanoseconds: u64) !void {
        try harness.submit(&.{Operation.timer(0, nanoseconds, 0)}, &.{});
        var events: [1]Event = undefined;
        try harness.collect(&events);
    }

    /// The event among `events` that carries `user_data`.
    pub fn find(events: []const Event, user_data: u64) !Event {
        for (events) |event| {
            if (event.user_data == user_data and !event.flags.message) return event;
        }
        return error.EventNotFound;
    }
};

/// Ends what a scenario left in flight, so `deinit` does not halt (decision 5, rule 7). A scenario
/// whose check failed returns before it collects its events. `deinit` then halted on what was still
/// in flight, so the failure showed as a crash in `tables.zig` and not as the failed check. The
/// error this logs fails the test, so a scenario that passed and left an operation in flight still
/// fails.
///
/// It cancels every operation and ticks until each has its final event. A loop that stays in
/// flight after `drain` gives up halts in `deinit`, as before.
pub fn end_in_flight(loop: *Loop) void {
    const left = loop.in_flight();
    if (left == 0) return;
    std.log.err("{d} operations were in flight at deinit; the scenario cancels them", .{left});
    loop.cancel_all();
    var scratch: [8]Event = undefined;
    loop.drain(&scratch) catch |failure| std.log.err("the drain failed: {t}", .{failure});
}

/// Writes the path of a scenario's file into `buffer`, and removes a file already at that path.
/// The path names this process by its id, and `sync.open_file` creates with O_EXCL. A run that
/// was killed before its `defer` leaves its file. A later run with the same process id then failed
/// every scenario of that file with `PathAlreadyExists`.
pub fn scratch_path(buffer: []u8, comptime format: []const u8, arguments: anytype) ![:0]const u8 {
    const path = try std.fmt.bufPrintZ(buffer, format, arguments);
    backend.testing.remove_file(path);
    return path;
}

/// Creates an empty file at the path `format` names, as a run killed before its `defer` leaves
/// one, and returns that path. A scenario that calls this removes the file in its own `defer`.
pub fn plant_stale_file(buffer: []u8, comptime format: []const u8, arguments: anytype) ![:0]const u8 {
    const path = try std.fmt.bufPrintZ(buffer, format, arguments);
    const file = try backend.sync.open_file(path, .{ .create = true, .direct = false });
    backend.sync.close_now(file);
    return path;
}

/// Plants a stale file at the path `format` names for this process, and requires `scratch` to
/// return that path and a create there to succeed. A scenario file whose path is a function of its
/// own calls this from a test, so a path made without `scratch_path` fails.
pub fn expect_stale_file_removed(
    comptime format: []const u8,
    scratch: *const fn (buffer: []u8) anyerror![:0]const u8,
) !void {
    var buffers: [2][96]u8 = undefined;
    const arguments = .{ backend.testing.directory, backend.testing.process_id() };
    const stale = try plant_stale_file(&buffers[0], format, arguments);
    defer backend.testing.remove_file(stale);
    const path = try scratch(&buffers[1]);
    try std.testing.expectEqualStrings(stale, path);
    const file = try backend.sync.open_file(path, .{ .create = true, .direct = false });
    backend.sync.close_now(file);
}

/// True when the backend cannot run on this host, and the scenario must skip.
pub fn unsupported() bool {
    return !backend.supported;
}

test {
    _ = @import("conformance_cost.zig");
    _ = @import("conformance_spin.zig");
    _ = @import("conformance_loop.zig");
    _ = @import("conformance_offload.zig");
    _ = @import("conformance_offload_limit.zig");
    _ = @import("conformance_offload_held.zig");
    _ = @import("conformance_offload_close.zig");
    _ = @import("conformance_tcp.zig");
    _ = @import("conformance_file.zig");
    _ = @import("conformance_group.zig");
    _ = @import("conformance_families.zig");
    _ = @import("conformance_post.zig");
    _ = @import("conformance_post_now.zig");
    _ = @import("conformance_fair.zig");
    _ = @import("conformance_fair_readiness.zig");
    _ = @import("conformance_registered.zig");
    _ = @import("conformance_remote.zig");
    _ = @import("conformance_statistics.zig");
    _ = @import("conformance_reuse_port.zig");
    _ = @import("conformance_timers.zig");
    _ = @import("conformance_udp.zig");
    _ = @import("conformance_udp_coalesce.zig");
    _ = @import("conformance_udp_burst.zig");
    _ = @import("conformance_buffer_release.zig");
    _ = @import("conformance_dispatch.zig");
    _ = @import("conformance_shuffle.zig");
    _ = @import("conformance_dispatch_local.zig");
    _ = @import("conformance_tasks.zig");
    _ = @import("conformance_stall.zig");
    _ = @import("conformance_stall_watch.zig");
    _ = @import("conformance_shutdown.zig");
    _ = @import("conformance_shutdown_cancel.zig");
    _ = @import("conformance_limits.zig");
    _ = @import("conformance_program.zig");
    _ = @import("conformance_storm.zig");
    _ = @import("conformance_wait_descriptor.zig");
    _ = @import("conformance_wake_reuse.zig");
    _ = @import("conformance_wait_limit.zig");
    _ = @import("conformance_registry.zig");
}
