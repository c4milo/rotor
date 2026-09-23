//! `Tables` under test: the half of a loop that is the same on every kernel.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const event_module = @import("event.zig");
const tables_module = @import("tables.zig");

const CancelAction = tables_module.CancelAction;
const core = @import("core.zig");

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const Tables = tables_module.Tables;
const core_statistics = @import("statistics.zig");
const TimerHeap = core.timer_heap.TimerHeap;

const capacity = 4;

const Fixture = struct {
    slots: [capacity]Slot,
    entries: [capacity]TimerHeap.Entry,
    starts: [capacity]u64,
    tables: Tables,
    buffer: [8]u8,

    fn init(fixture: *Fixture) void {
        fixture.init_sampling(.{ .sample_mask = 0 });
    }

    /// Every operation is sampled by default here, so a scenario that reads the statistics does
    /// not have to submit 32 of them.
    fn init_sampling(fixture: *Fixture, sampling: core_statistics.Options) void {
        fixture.tables.init(&fixture.slots, &fixture.entries, &fixture.starts, .{
            .id = 2,
            .sampling = sampling,
        });
        fixture.buffer = @splat(0);
    }

    fn timer(user_data: u64, after_ns: u64) Operation {
        return .{ .user_data = user_data, .kind = .{ .timer = .{ .after_ns = after_ns } } };
    }

    fn repeating(user_data: u64, after_ns: u64, repeat_ns: u64) Operation {
        return .{ .user_data = user_data, .kind = .{ .timer = .{
            .after_ns = after_ns,
            .repeat_ns = repeat_ns,
        } } };
    }

    fn receive(fixture: *Fixture, user_data: u64, timeout_ns: u64) Operation {
        return .{ .user_data = user_data, .timeout_ns = timeout_ns, .kind = .{ .receive = .{
            .socket = 3,
            .target = .{ .buffer = .{ .bytes = &fixture.buffer } },
        } } };
    }

    /// What a backend's flush does to the oldest queued slot: hands it to the kernel.
    fn hand_to_kernel(fixture: *Fixture) u32 {
        const tables = &fixture.tables;
        const index = tables.pending.peek().?;
        tables.take_pending(index);
        tables.hand_over(index, tables.table.at(index));
        return index;
    }
};

test "submit claims slots in order until the table is full, and counts what it took" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var batch: [capacity + 2]Operation = undefined;
    for (&batch, 0..) |*operation, index| operation.* = Fixture.timer(index, 1);
    var handles: [capacity + 2]Handle = undefined;
    try testing.expectEqual(@as(u32, capacity), tables.submit(&batch, &handles));
    try testing.expectEqual(@as(u32, capacity), tables.in_flight());
    try testing.expectEqual(@as(u32, capacity), tables.pending.count);
    try testing.expectEqual(@as(u64, capacity), tables.operation_sequence);
    try testing.expectEqual(@as(u32, 0), tables.submit(batch[capacity..], &.{}));
    for (handles[0..capacity], 0..) |handle, index| {
        try testing.expectEqual(@as(u64, index), tables.table.lookup(handle).?.user_data);
    }
    try testing.expectEqual(@as(?u32, 0), tables.pending.peek());
}

test "a result the loop produced waits for the drain, which hands it over and frees the slot" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    _ = tables.submit(&.{ Fixture.timer(10, 1), Fixture.timer(11, 1) }, &.{});
    const first = fixture.hand_to_kernel();
    const second = fixture.hand_to_kernel();
    tables.finish_local(second, 0);
    tables.finish_local(first, event_module.result_of(.canceled));
    try testing.expectEqual(@as(u32, 2), tables.in_flight());
    try testing.expectEqual(@as(u32, 0), tables.timers.count);

    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), tables.drain_finished(&events));
    try testing.expectEqual(@as(u64, 11), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), tables.in_flight());
    try testing.expectEqual(@as(u32, 1), tables.drain_finished(&events));
    try testing.expectEqual(@as(u64, 10), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), tables.drain_finished(&events));
    tables.assert_empty();
}

test "a cancel ends a timer, leaves a queued slot to the flush and an operation to the backend" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var handles: [3]Handle = undefined;
    _ = tables.submit(&.{
        Fixture.timer(1, 5), fixture.receive(2, 0), fixture.receive(3, 0),
    }, &handles);
    const timer_index = fixture.hand_to_kernel();
    const receive_index = fixture.hand_to_kernel();

    const timer_slot = tables.cancellable(handles[0]).?;
    try testing.expectEqual(CancelAction.none, tables.request_cancel(timer_index, timer_slot));
    try testing.expectEqual(Slot.State.finishing, timer_slot.state);
    try testing.expectEqual(event_module.result_of(.canceled), timer_slot.result);
    try testing.expectEqual(@as(u32, 0), tables.timers.count);
    try testing.expectEqual(@as(?*Slot, null), tables.cancellable(handles[0]));

    const receive_slot = tables.cancellable(handles[1]).?;
    const first_request = tables.request_cancel(receive_index, receive_slot);
    try testing.expectEqual(CancelAction.backend, first_request);
    const second_request = tables.request_cancel(receive_index, receive_slot);
    try testing.expectEqual(CancelAction.none, second_request);
    try testing.expectEqual(Slot.State.submitted, receive_slot.state);

    const queued_slot = tables.cancellable(handles[2]).?;
    const queued_request = tables.request_cancel(handles[2].index, queued_slot);
    try testing.expectEqual(CancelAction.none, queued_request);
    try testing.expectEqual(Slot.State.queued, queued_slot.state);
    try testing.expect(queued_slot.flags.cancel_requested);
}

test "next_pending ends a cancelled slot and arms a timer, and answers the rest" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var handles: [3]Handle = undefined;
    const batch = [_]Operation{
        fixture.receive(1, 0),
        Fixture.timer(2, constants.ns_per_s),
        fixture.receive(3, 0),
    };
    try testing.expectEqual(@as(u32, 3), tables.submit(&batch, &handles));
    const cancelled = handles[0].index;
    const action = tables.request_cancel(cancelled, tables.table.at(cancelled));
    try testing.expectEqual(CancelAction.none, action);

    // The cancelled receive ends and the timer is armed, and neither is answered: no kernel takes
    // them. The second receive is, still queued until the backend takes it.
    const next = tables.next_pending().?;
    try testing.expectEqual(handles[2].index, next);
    try testing.expectEqual(Slot.State.finishing, tables.table.at(cancelled).state);
    try testing.expectEqual(Slot.State.submitted, tables.table.at(handles[1].index).state);
    try testing.expect(tables.timers.is_armed(handles[1].index));
    try testing.expectEqual(Slot.State.queued, tables.table.at(next).state);

    tables.take_pending(next);
    tables.hand_over(next, tables.table.at(next));
    try testing.expectEqual(@as(?u32, null), tables.next_pending());
    // A slot the kernel refused for now goes back, and is answered again.
    tables.requeue(next);
    try testing.expectEqual(next, tables.next_pending().?);

    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), tables.drain_finished(&events));
    try testing.expectError(error.Canceled, events[0].outcome());
}

test "due timers finish in deadline order, and an operation whose deadline passed is returned" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    _ = tables.submit(&.{
        Fixture.timer(30, 30),   Fixture.timer(10, 10),
        fixture.receive(20, 20), Fixture.timer(99, 99),
    }, &.{});
    for (0..4) |_| _ = fixture.hand_to_kernel();
    try testing.expectEqual(@as(u32, 4), tables.timers.count);

    tables.now_ns = 9;
    try testing.expectEqual(@as(?u32, null), tables.next_expired());
    tables.now_ns = 30;
    const expired = tables.next_expired().?;
    try testing.expectEqual(@as(u64, 20), tables.table.at(expired).user_data);
    try testing.expect(tables.table.at(expired).flags.timed_out);
    try testing.expectEqual(@as(?u32, null), tables.next_expired());
    try testing.expectEqual(@as(u32, 1), tables.timers.count);

    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 2), tables.drain_finished(&events));
    try testing.expectEqual(@as(u64, 10), events[0].user_data);
    try testing.expectEqual(@as(u64, 30), events[1].user_data);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());
}

test "arm uses a timer's delay and an operation's deadline, and leaves an armed slot alone" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    tables.now_ns = 100;
    const batch = [_]Operation{
        Fixture.timer(1, 7), fixture.receive(2, 50), fixture.receive(3, 0),
    };
    _ = tables.submit(&batch, &.{});
    const timer_index = fixture.hand_to_kernel();
    const timed_index = fixture.hand_to_kernel();
    _ = fixture.hand_to_kernel();
    try testing.expectEqual(@as(u32, 2), tables.timers.count);
    try testing.expectEqual(@as(?u64, 107), tables.timers.earliest_ns());
    tables.timers.disarm(timer_index);
    try testing.expectEqual(@as(?u64, 150), tables.timers.earliest_ns());
    // A slot resubmitted later keeps the deadline it was given first.
    tables.now_ns = 140;
    tables.arm(timed_index, tables.table.at(timed_index));
    try testing.expectEqual(@as(?u64, 150), tables.timers.earliest_ns());
}

test "a tick may wait only when nothing is queued, and never past the nearest deadline" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    const second = constants.ns_per_s;
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(0));
    try testing.expectEqual(@as(?u64, second), tables.wait_bound(second));
    _ = tables.submit(&.{Fixture.timer(1, 40)}, &.{});
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(second));
    const index = fixture.hand_to_kernel();
    try testing.expectEqual(@as(?u64, 40), tables.wait_bound(second));
    try testing.expectEqual(@as(?u64, 25), tables.wait_bound(25));
    tables.now_ns = 40;
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(second));
    tables.timers.disarm(index);
    tables.finish_local(index, 0);
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(second));
}

test "an operation may name a registered descriptor once the loop has noted how many it has" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    try testing.expectEqual(@as(u32, 0), tables.descriptors_registered);
    tables.note_descriptors(3);
    try testing.expectEqual(@as(u32, 3), tables.descriptors_registered);

    var operation = fixture.receive(7, 0);
    operation.descriptor_registered = true;
    operation.kind.receive.socket = 2;
    try testing.expectEqual(@as(u32, 1), tables.submit(&.{operation}, &.{}));
    const slot = tables.table.at(tables.pending.peek().?);
    try testing.expect(slot.flags.descriptor_registered);
    try testing.expectEqual(@as(i32, 2), slot.descriptor);
}

test "next_cancellable walks the slots a cancel can still reach, and skips the finishing" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    try testing.expectEqual(@as(?u32, null), tables.next_cancellable(0));
    const batch = [_]Operation{ Fixture.timer(1, 5), Fixture.timer(2, 5), Fixture.timer(3, 5) };
    var handles: [batch.len]Handle = undefined;
    try testing.expectEqual(@as(u32, batch.len), tables.submit(&batch, &handles));
    // The first is handed to the kernel, the second finishes, the third stays queued.
    const submitted = fixture.hand_to_kernel();
    const finishing = tables.pending.pop(tables.table.slots).?;
    tables.finish_local(finishing, 0);
    const queued = tables.pending.peek().?;

    var reached: [capacity]u32 = undefined;
    var count: u32 = 0;
    var from: u32 = 0;
    while (tables.next_cancellable(from)) |index| : (from = index + 1) {
        reached[count] = index;
        count += 1;
    }
    try testing.expectEqual(@as(u32, 2), count);
    const low = @min(submitted, queued);
    const high = @max(submitted, queued);
    try testing.expectEqualSlices(u32, &.{ low, high }, reached[0..count]);
    try testing.expectEqual(@as(?u32, null), tables.next_cancellable(tables.table.capacity()));
}

test "a cancel replaces a repeating timer's queued fire, and that event is its final one" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var handles: [2]Handle = undefined;
    _ = tables.submit(&.{ Fixture.repeating(1, 5, 5), Fixture.timer(2, 5) }, &handles);
    const repeating_index = fixture.hand_to_kernel();
    _ = fixture.hand_to_kernel();
    // Both are due: each fire waits on `finished`, and no drain has handed either over.
    tables.now_ns = 5;
    try testing.expectEqual(@as(?u32, null), tables.next_expired());

    // The one-shot timer's final event is queued, so no cancel reaches it. The repeating timer's
    // queued fire says `more`, so a cancel and `cancel_all` both reach it (decision 5, rule 7).
    try testing.expectEqual(@as(?*Slot, null), tables.cancellable(handles[1]));
    try testing.expectEqual(@as(?u32, repeating_index), tables.next_cancellable(0));
    try testing.expectEqual(@as(?u32, null), tables.next_cancellable(repeating_index + 1));
    const slot = tables.cancellable(handles[0]).?;
    try testing.expectEqual(CancelAction.none, tables.request_cancel(repeating_index, slot));
    try testing.expectEqual(Slot.State.finishing, slot.state);
    try testing.expectEqual(event_module.result_of(.canceled), slot.result);
    try testing.expectEqual(@as(?*Slot, null), tables.cancellable(handles[0]));
    try testing.expectEqual(@as(?u32, null), tables.next_cancellable(0));

    // Equal deadlines leave the heap in the order they were armed.
    var events: [2]Event = undefined;
    try testing.expectEqual(@as(u32, 2), tables.drain_finished(&events));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expect(!events[0].flags.more);
    try testing.expectEqual(@as(u64, 2), events[1].user_data);
    try testing.expectEqual(@as(u32, 0), try events[1].outcome());
    try testing.expectEqual(@as(u32, 0), tables.timers.count);
    tables.assert_empty();
}

/// How long the loop in `counted` has been running when it takes its first operation.
const uptime_ns = 3 * constants.ns_per_s;

/// Runs `operations` timers through a loop and returns what it counted. `advance_ns` is how far
/// the clock moves between the submit and the drain, which is the latency each one records.
fn counted(
    fixture: *Fixture,
    sampling: core_statistics.Options,
    operations: u32,
    advance_ns: u64,
) *const core_statistics.Statistics {
    fixture.init_sampling(sampling);
    const tables = &fixture.tables;
    // A loop that has been up a while: a start stamp that was never written reads as 0, and a
    // latency measured from 0 is then nothing like the real one.
    tables.now_ns = uptime_ns;
    var events: [capacity]Event = undefined;
    var submitted: u32 = 0;
    while (submitted < operations) : (submitted += 1) {
        // The clock only ever moves forward, as a loop's does, so two runs of one workload that
        // took different times submit their operations at different times.
        tables.now_ns += advance_ns;
        _ = tables.submit(&.{Fixture.timer(submitted, 1)}, &.{});
        const index = tables.pending.pop(tables.table.slots).?;
        tables.now_ns += advance_ns;
        tables.finish_local(index, 0);
        _ = tables.drain_finished(&events);
    }
    return &tables.statistics;
}

test "sampling takes one operation in the mask's count, chosen by the sequence alone" {
    var fixture: Fixture = undefined;
    const timer_kind = @intFromEnum(Operation.Code.timer);

    // 64 operations at 1 in 32 are sampled twice: sequence 0 and sequence 32.
    const every_32 = counted(&fixture, .{ .sample_mask = 31 }, 64, 0);
    try testing.expectEqual(@as(u64, 2), every_32.sampled[timer_kind]);
    try testing.expectEqual(@as(u64, 32), every_32.scale());

    // The phase moves which ones, never how many.
    const phased = counted(&fixture, .{ .sample_mask = 31, .sample_phase = 7 }, 64, 0);
    try testing.expectEqual(@as(u64, 2), phased.sampled[timer_kind]);

    const every_one = counted(&fixture, .{ .sample_mask = 0 }, 10, 0);
    try testing.expectEqual(@as(u64, 10), every_one.sampled[timer_kind]);
    try testing.expectEqual(@as(u64, 1), every_one.scale());

    const every_4 = counted(&fixture, .{ .sample_mask = 3 }, 9, 0);
    try testing.expectEqual(@as(u64, 3), every_4.sampled[timer_kind]);
}

test "the same calls give the same statistics, whatever the clock did between them" {
    var fixture: Fixture = undefined;
    // Two runs of one workload that differ only in how long the host took: the slow one's clock
    // reads differently at every submit. Decision 9's rule 2 is that the sampling decision reads
    // the sequence and never the clock, so the two runs sample the same operations.
    const sampling: core_statistics.Options = .{ .sample_mask = 3 };
    const quick = (counted(&fixture, sampling, 16, 0)).sampled;
    var slow_fixture: Fixture = undefined;
    const slow_ns = 5 * constants.ns_per_ms;
    const slow = (counted(&slow_fixture, sampling, 16, slow_ns)).sampled;
    try testing.expectEqualSlices(u64, &quick, &slow);
}

test "a sampled operation's latency lands in the bucket of the time the loop held" {
    var fixture: Fixture = undefined;
    const timer_kind = @intFromEnum(Operation.Code.timer);

    const immediate = counted(&fixture, .{ .sample_mask = 0 }, 4, 0);
    try testing.expectEqual(@as(u32, 4), immediate.latency[timer_kind][0]);

    var micro_fixture: Fixture = undefined;
    const micro = counted(&micro_fixture, .{ .sample_mask = 0 }, 3, constants.ns_per_us);
    const bucket = core_statistics.bucket_of(constants.ns_per_us);
    try testing.expectEqual(@as(u32, 3), micro.latency[timer_kind][bucket]);
    try testing.expectEqual(@as(u32, 0), micro.latency[timer_kind][0]);
}

test "operations in flight together each keep their own start, whatever slot they took" {
    var fixture: Fixture = undefined;
    fixture.init_sampling(.{ .sample_mask = 0 });
    const tables = &fixture.tables;
    const timer_kind = @intFromEnum(Operation.Code.timer);

    // Two operations submitted far apart and finished at one moment. Their latencies differ by
    // the gap, so each has to be measured from its own start and not from the other's.
    const gap_ns = 1 << 20;
    tables.now_ns = uptime_ns;
    _ = tables.submit(&.{Fixture.timer(1, 1)}, &.{});
    const first = fixture.hand_to_kernel();
    tables.now_ns = uptime_ns + gap_ns;
    _ = tables.submit(&.{Fixture.timer(2, 1)}, &.{});
    const second = fixture.hand_to_kernel();
    try testing.expect(first != second);

    const short_ns = 1 << 15;
    tables.now_ns = uptime_ns + gap_ns + short_ns;
    tables.finish(first, tables.table.at(first));
    tables.finish(second, tables.table.at(second));
    const latency = tables.statistics.latency[timer_kind];
    try testing.expectEqual(@as(u32, 1), latency[core_statistics.bucket_of(gap_ns + short_ns)]);
    try testing.expectEqual(@as(u32, 1), latency[core_statistics.bucket_of(short_ns)]);
}

test "a multishot operation is counted once and records no latency" {
    var fixture: Fixture = undefined;
    fixture.init_sampling(.{ .sample_mask = 0 });
    const tables = &fixture.tables;
    const receive_kind = @intFromEnum(Operation.Code.receive);

    var multishot = fixture.receive(1, 0);
    multishot.kind.receive.target = .{ .group = 0 };
    multishot.kind.receive.multishot = true;
    _ = tables.submit(&.{multishot}, &.{});
    const index = fixture.hand_to_kernel();
    try testing.expect(tables.table.at(index).flags.multishot);

    tables.now_ns += constants.ns_per_s;
    tables.finish(index, tables.table.at(index));
    try testing.expectEqual(@as(u64, 1), tables.statistics.sampled[receive_kind]);
    var recorded: u32 = 0;
    for (tables.statistics.latency[receive_kind]) |count| recorded += count;
    try testing.expectEqual(@as(u32, 0), recorded);
}

test "an operation the loop never sampled is counted nowhere, and events are the same either way" {
    var fixture: Fixture = undefined;
    // Sample nothing this run: phase 1 of a mask of 1 never matches sequence 0.
    const none = counted(&fixture, .{ .sample_mask = 1, .sample_phase = 1 }, 1, 0);
    try testing.expectEqual(@as(u64, 0), none.sampled[@intFromEnum(Operation.Code.timer)]);

    // The caller's events do not depend on whether the loop measured them (rule 1).
    var sampled_fixture: Fixture = undefined;
    var events: [2]Event = undefined;
    const measured: core_statistics.Options = .{ .sample_mask = 0 };
    const unmeasured: core_statistics.Options = .{ .sample_mask = 1, .sample_phase = 1 };
    for ([_]core_statistics.Options{ measured, unmeasured }) |sampling| {
        sampled_fixture.init_sampling(sampling);
        const tables = &sampled_fixture.tables;
        _ = tables.submit(&.{ Fixture.timer(11, 1), Fixture.timer(12, 1) }, &.{});
        while (tables.pending.pop(tables.table.slots)) |index| tables.finish_local(index, 0);
        try testing.expectEqual(@as(u32, 2), tables.drain_finished(&events));
        try testing.expectEqual(@as(u64, 11), events[0].user_data);
        try testing.expectEqual(@as(u64, 12), events[1].user_data);
    }
}
