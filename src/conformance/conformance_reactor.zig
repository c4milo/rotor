//! The harness of the reactor's scenarios (decision 33, "`SharedLoop` and the conformance suite"):
//! one `reactor.Reactor(backend.Loop)` over static memory, as `Harness` holds one loop. A scenario
//! that names a record, a poller, a task, a scheduling group, a cross-core call or the view of a
//! library runs on this harness, and the core's scenarios run on `Harness`. Split from
//! `conformance.zig` for the 500-line limit.
const std = @import("std");
const core = @import("core");
const reactor_module = @import("reactor");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const stall = @import("conformance_stall.zig");
const registry_life = @import("conformance_registry.zig");

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Reactor = conformance.Reactor;

const memory_bytes = Reactor.memory_bytes(&.{
    .loop = .{ .operations = conformance.operations, .entries = conformance.entries },
});

/// One reactor over static memory, and the waiting every scenario needs. Its calls are the calls
/// of `Harness`, on the reactor.
pub const ReactorHarness = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment),
    reactor: Reactor,

    pub fn init(harness: *ReactorHarness, id: core.LoopId, registry: ?*backend.Registry) !void {
        return harness.init_sampling(id, registry, .{});
    }

    /// A reactor whose loop performs a file operation inline, as `Harness.init_blocking`.
    pub fn init_blocking(
        harness: *ReactorHarness,
        id: core.LoopId,
        registry: ?*backend.Registry,
    ) !void {
        try check_life(registry);
        try harness.reactor.init(&harness.memory, &.{ .loop = .{
            .operations = conformance.operations,
            .entries = conformance.entries,
            .id = id,
            .registry = registry,
            .file_policy = .blocking,
            .spin_budget_ns = conformance.spin_budget_ns(),
        } });
    }

    /// A reactor whose loop samples as `sampling` says, as `Harness.init_sampling`.
    pub fn init_sampling(
        harness: *ReactorHarness,
        id: core.LoopId,
        registry: ?*backend.Registry,
        sampling: core.statistics.Options,
    ) !void {
        try check_life(registry);
        try harness.reactor.init(&harness.memory, &.{ .loop = .{
            .operations = conformance.operations,
            .entries = conformance.entries,
            .id = id,
            .registry = registry,
            .sampling = sampling,
            .spin_budget_ns = conformance.spin_budget_ns(),
        } });
    }

    /// A reactor whose loop reserves the named groups of `table`, as `Harness.init_named`.
    pub fn init_named(harness: *ReactorHarness, table: *const reactor_module.scheduling.NamedTable) !void {
        try harness.reactor.init(&harness.memory, &.{
            .loop = .{
                .operations = conformance.operations,
                .entries = conformance.entries,
                .spin_budget_ns = conformance.spin_budget_ns(),
            },
            .named_groups = table.*,
        });
    }

    /// A reactor whose loop has the spin budget `budget_ns`, as `Harness.init_spin`.
    pub fn init_spin(harness: *ReactorHarness, budget_ns: u64) !void {
        try harness.reactor.init(&harness.memory, &.{ .loop = .{
            .operations = conformance.operations,
            .entries = conformance.entries,
            .spin_budget_ns = budget_ns,
        } });
    }

    pub fn deinit(harness: *ReactorHarness) void {
        end_in_flight(&harness.reactor);
        harness.reactor.deinit();
    }

    /// Refuses a reactor on a registry when no `RegistryLife` is open, as `Harness` does.
    fn check_life(registry: ?*backend.Registry) error{RegistryNotStarted}!void {
        if (registry == null) return;
        if (!registry_life.life_open()) return error.RegistryNotStarted;
    }

    /// Submits `batch` whole, or fails: no scenario fills the table.
    pub fn submit(harness: *ReactorHarness, batch: []const Operation, handles: []Handle) !void {
        const taken = harness.reactor.submit(batch, handles);
        if (taken != batch.len) return error.TableFull;
    }

    /// One `tick` of the reactor. It fails with `error.CallbackStalled` when a callback that
    /// `conformance_stall.zig` made ran past its limit.
    pub fn tick(harness: *ReactorHarness, events: []Event, wait_ns: u64) !u32 {
        const count = try harness.reactor.tick(events, wait_ns);
        try stall.check();
        return count;
    }

    /// `drain` of the reactor, with the stall check of `tick`.
    pub fn drain(harness: *ReactorHarness, events: []Event) !void {
        const drained = harness.reactor.drain(events);
        try stall.check();
        return drained;
    }

    /// Ticks until `events` is full, and fails when it is not full within the bound.
    pub fn collect(harness: *ReactorHarness, events: []Event) !void {
        var filled: usize = 0;
        var round: u32 = 0;
        while (filled < events.len and round < conformance.collect_rounds_max) : (round += 1) {
            filled += try harness.tick(events[filled..], conformance.collect_wait_ns);
        }
        if (filled < events.len) return error.EventsMissing;
    }

    /// Waits `nanoseconds` through the reactor itself, with a timer, as `Harness.pause`.
    pub fn pause(harness: *ReactorHarness, nanoseconds: u64) !void {
        try harness.submit(&.{Operation.timer(0, nanoseconds, 0)}, &.{});
        var events: [1]Event = undefined;
        try harness.collect(&events);
    }

    /// The event among `events` that carries `user_data`.
    pub const find = conformance.Harness.find;
};

/// What a harness of type `H` holds: a `*Reactor` for a `ReactorHarness`, and a `*Loop` for a
/// `Harness`.
fn Driven(comptime H: type) type {
    return if (@hasField(H, "reactor")) *Reactor else *conformance.Loop;
}

/// The reactor or the loop that `harness` holds, for a helper that both kinds of scenario call.
pub fn driven(harness: anytype) Driven(@TypeOf(harness.*)) {
    if (comptime @hasField(@TypeOf(harness.*), "reactor")) return &harness.reactor;
    return &harness.loop;
}

/// Ends what a scenario left in flight on `reactor`, as `conformance.end_in_flight` does for a
/// loop.
pub fn end_in_flight(reactor: *Reactor) void {
    const left = reactor.in_flight();
    if (left == 0) return;
    std.log.err("{d} operations were in flight at deinit; the scenario cancels them", .{left});
    reactor.cancel_all();
    var scratch: [8]Event = undefined;
    reactor.drain(&scratch) catch |failure| std.log.err("the drain failed: {t}", .{failure});
}
