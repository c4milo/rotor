//! The host's reactor under test, through the public module (decision 33): the names it declares
//! and prints, the view a library holds (decision 28), and a reactor that runs a record, a poller
//! and a task. Split from `rotor.zig` for the 500-line limit.
const std = @import("std");
const core = @import("core");
const reactor = @import("reactor");
const rotor = @import("rotor.zig");
const loop_test = @import("rotor_loop_test.zig");

const Event = rotor.Event;
const Loop = rotor.Loop;
const Operation = rotor.Operation;
const backend = rotor.backend;
const constants = rotor.constants;
const memory_alignment = rotor.memory_alignment;
const supported = rotor.supported;

/// The host's reactor (decision 33).
const HostReactor = rotor.Reactor(Loop);

const testing = std.testing;

/// The declarations of the host's reactor beyond the core's surface and the error sets of `Loop`:
/// the 16 names of the reactor, its 4 error sets, and its view and call types.
const reactor_names = [_][]const u8{
    "add_poller",     "remove_poller",            "schedule",                    "is_scheduled",
    "tasks_queued",   "task_budget_left",         "discard_tasks",               "schedule_in",
    "charge_task",    "reserve_scheduling_group", "set_scheduling_group_shares", "shared",
    "call",           "answer",                   "serve",                       "stop_serving",
    "AddPollerError", "ScheduleError",            "ReserveSchedulingGroupError", "CallError",
    "SharedLoop",     "Service",                  "CallRecord",
};

test "the host's reactor carries the loop's surface, the reactor's names and its view, and nothing else" {
    const surface = core.surface;
    try testing.expect(loop_test.named(HostReactor, &.{ &surface.loop_declarations, &loop_test.loop_error_sets, &reactor_names }));
    const count = surface.loop_declarations.len + loop_test.loop_error_sets.len + reactor_names.len;
    try testing.expectEqual(count, @typeInfo(HostReactor).@"struct".decls.len);
    // Two fields: the loop it holds, and its state.
    try testing.expectEqual(2, @typeInfo(HostReactor).@"struct".fields.len);
    try testing.expectEqual(@sizeOf(Loop) + @sizeOf(reactor.Dispatch), @sizeOf(HostReactor));
    comptime reactor.shared.check(HostReactor.SharedLoop);
    comptime reactor.shared.check(rotor.SharedLoop);
}

test "the host's reactor and its types print the names of decision 33" {
    try testing.expectEqualStrings("rotor.Reactor(rotor_loop.Loop)", @typeName(HostReactor));
    try testing.expectEqualStrings("rotor.Reactor(rotor_loop.Loop).SharedLoop", @typeName(rotor.SharedLoop));
    try testing.expectEqualStrings(
        "rotor.Reactor(rotor_loop.Loop).CallRecord(u64,u64)",
        @typeName(rotor.CallRecord(u64, u64)),
    );
    try testing.expectEqualStrings("reactor.Completion", @typeName(rotor.Completion));
    try testing.expectEqualStrings("core.WaitLimit", @typeName(rotor.WaitLimit));
    try testing.expectEqualStrings("core.SchedulingGroup", @typeName(rotor.SchedulingGroup));
}

const test_options: HostReactor.Options = .{ .loop = .{ .operations = 4 } };
const test_timer_ns = constants.ns_per_ms;
const test_wait_ns = 50 * constants.ns_per_ms;

test "a library's calls on the view reach the reactor, and its address is the reactor's" {
    if (!supported) return error.SkipZigTest;
    var memory: [HostReactor.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var host: HostReactor = undefined;
    try host.init(&memory, &test_options);
    defer host.deinit();
    const shared = host.shared();
    try testing.expectEqual(@intFromPtr(&host), @intFromPtr(shared));
    var events: [4]Event = undefined;
    try testing.expectEqual(1, shared.submit(&.{Operation.timer(7, test_timer_ns, 0)}, &.{}));
    try testing.expectEqual(1, host.in_flight());
    try testing.expectEqual(1, try host.tick(&events, test_wait_ns));
    try testing.expectEqual(host.now_ns(), shared.now_ns());
    try testing.expectEqual(0, shared.task_budget_left());
}

/// What the test of the host's reactor counts: one record, one poller and one task.
const Counts = struct {
    completion: rotor.Completion = .init(Counts, "completion", completed),
    poller: rotor.Poller = .init(Counts, "poller", polled),
    task: rotor.Task = .init(Counts, "task", ran),
    completions: u32 = 0,
    polls: u32 = 0,
    runs: u32 = 0,

    fn completed(counts: *Counts, _: rotor.Event) void {
        counts.completions += 1;
    }

    fn polled(counts: *Counts) rotor.WaitLimit {
        counts.polls += 1;
        return .none;
    }

    fn ran(counts: *Counts) void {
        counts.runs += 1;
    }
};

test "a reactor built through the public module runs a record, a poller and a task, and drains" {
    if (!supported) return error.SkipZigTest;
    var memory: [HostReactor.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var host: HostReactor = undefined;
    try host.init(&memory, &test_options);
    defer host.deinit();
    var counts: Counts = .{};
    var events: [4]rotor.Event = undefined;
    const shared = host.shared();
    try shared.add_poller(&counts.poller);
    try shared.schedule_in(.default, &counts.task);
    try testing.expectEqual(1, host.tasks_queued());
    try testing.expectEqual(0, host.in_flight());
    const timer = rotor.Completion.mark(&counts.completion, Operation.timer(0, constants.ns_per_ms, 0));
    try testing.expectEqual(1, shared.submit(&.{timer}, &.{}));
    try testing.expectEqual(1, host.in_flight());
    var round: u32 = 0;
    while (counts.completions == 0 and round < 100) : (round += 1) {
        try testing.expectEqual(0, try host.tick(&events, 10 * constants.ns_per_ms));
    }
    try testing.expectEqual(1, counts.completions);
    try testing.expectEqual(1, counts.runs);
    try testing.expect(counts.polls >= 1);
    shared.remove_poller(&counts.poller);
    try host.drain(&events);
    host.assert_empty();
    try testing.expectEqual(0, host.in_flight());
    try testing.expectEqual(backend() == .uring, host.wait_descriptor() == null);
    try testing.expect(host.statistics().sample_mask >= 1);
    _ = host.heartbeat();
}
