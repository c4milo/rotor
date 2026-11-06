//! The seeded property test of `Dispatch` (decisions 26 and 27). A run draws random steps: pollers
//! added and removed, operations with a record noted, tasks queued by the program, ticks with a
//! batch of events in random order, abandoned ticks, and `discard_tasks`. Records, pollers and
//! tasks queue more tasks and note more operations from inside a tick. After every step the test
//! holds the real `Dispatch` to the reference model of `dispatch_test_model.zig`. A failure prints
//! the seed that replays it (non-negotiable 6). Split from `dispatch.zig` for the 500-line limit.
//!
//! The properties, with decision 27's numbers where its table has the property:
//!
//! - P3: the calls of each step, pollers, records and tasks, equal the model's, in order.
//! - The wait: `begin` returns 0 exactly when a poller worked or a task is queued.
//! - P7: `callbacks_outstanding` equals the operations with a record in flight plus `tasks.count`.
//! - P9: a task that a poller queues inside the budget runs in the same tick's `end`.
//! - `idle` is true exactly when no poller is added and no callback is outstanding.
//! - The events without a record come back at the front, in order, unchanged, with `dispatched`
//!   clear.
//! - P5 and P8: the same seed gives the same trace twice, and with every record elsewhere.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const dispatch_module = @import("dispatch.zig");
const Event = @import("event.zig").Event;
const Random = @import("random.zig").Random;
const Task = @import("tasks.zig").Task;
const model_module = @import("dispatch_test_model.zig");

const Completion = dispatch_module.Completion;
const Dispatch = dispatch_module.Dispatch;
const Poller = dispatch_module.Poller;
const Model = model_module.Model;
const PollerPlan = model_module.PollerPlan;
const Trace = model_module.Trace;
const Behaviour = model_module.Behaviour;
const first_free = model_module.first_free;
const pollers_pool = model_module.pollers_pool;
const operations_pool = model_module.operations_pool;
const tasks_pool = model_module.tasks_pool;
const batch_max = model_module.batch_max;

/// Steps in one run, and seeds in the test.
const steps = 300;
const seeds = 64;

/// A library's record of one operation.
const Record = struct {
    completion: Completion = .init(Record, "completion", called),
    id: u32,
    fixture: *Fixture,

    fn called(record: *Record, event: Event) void {
        record.fixture.on_record(record.id, event);
    }
};

const PollerRecord = struct {
    poller: Poller = .init(PollerRecord, "poller", polled),
    id: u32,
    fixture: *Fixture,

    fn polled(poller: *PollerRecord) bool {
        return poller.fixture.on_poll(poller.id);
    }
};

const TaskRecord = struct {
    task: Task = .init(TaskRecord, "task", ran),
    id: u32,
    fixture: *Fixture,

    fn ran(task: *TaskRecord) void {
        task.fixture.on_task(task.id);
    }
};

/// The system under test: a `Dispatch`, and the records, pollers and tasks of the libraries that
/// share it. It keeps its own note of what is queued and what is in flight, as a library does,
/// and never reads the model.
const Fixture = struct {
    dispatch: Dispatch,
    seed: u64,
    /// The pools in reverse order of id, so the same seed runs with every record elsewhere.
    reversed: bool,
    records: [operations_pool]Record,
    pollers: [pollers_pool]PollerRecord,
    tasks: [tasks_pool]TaskRecord,
    plans: [pollers_pool]PollerPlan,
    queued: [tasks_pool]bool,
    in_flight: [operations_pool]bool,
    runs: [tasks_pool]u32,
    trace: Trace,

    fn init(fixture: *Fixture, seed: u64, reversed: bool) void {
        fixture.* = .{
            .dispatch = .empty,
            .seed = seed,
            .reversed = reversed,
            .records = undefined,
            .pollers = undefined,
            .tasks = undefined,
            .plans = @splat(.{}),
            .queued = @splat(false),
            .in_flight = @splat(false),
            .runs = @splat(0),
            .trace = .{},
        };
        for (0..operations_pool) |id| fixture.record(@intCast(id)).* = .{ .id = @intCast(id), .fixture = fixture };
        for (0..pollers_pool) |id| fixture.poller(@intCast(id)).* = .{ .id = @intCast(id), .fixture = fixture };
        for (0..tasks_pool) |id| fixture.task(@intCast(id)).* = .{ .id = @intCast(id), .fixture = fixture };
    }

    fn slot(fixture: *const Fixture, id: u32, len: usize) usize {
        return if (fixture.reversed) len - 1 - id else id;
    }

    fn record(fixture: *Fixture, id: u32) *Record {
        return &fixture.records[fixture.slot(id, operations_pool)];
    }

    fn poller(fixture: *Fixture, id: u32) *PollerRecord {
        return &fixture.pollers[fixture.slot(id, pollers_pool)];
    }

    fn task(fixture: *Fixture, id: u32) *TaskRecord {
        return &fixture.tasks[fixture.slot(id, tasks_pool)];
    }

    fn schedule(fixture: *Fixture, id: u32) void {
        std.debug.assert(!fixture.queued[id]);
        fixture.queued[id] = true;
        fixture.dispatch.schedule(&fixture.task(id).task) catch unreachable;
    }

    fn schedule_free(fixture: *Fixture) void {
        const id = first_free(&fixture.queued, 0) orelse return;
        fixture.schedule(id);
    }

    fn submit(fixture: *Fixture, operations: []const u32) void {
        for (operations) |operation| {
            std.debug.assert(!fixture.in_flight[operation]);
            fixture.in_flight[operation] = true;
        }
        fixture.dispatch.note_submitted(@intCast(operations.len));
    }

    fn on_record(fixture: *Fixture, id: u32, event: Event) void {
        fixture.trace.note(.record, id);
        if (!event.flags.more) fixture.in_flight[id] = false;
        if (event.result & model_module.plan_schedule != 0) fixture.schedule_free();
        if (event.result & model_module.plan_submit != 0) {
            if (first_free(&fixture.in_flight, 0)) |next| fixture.submit(&.{next});
        }
    }

    fn on_poll(fixture: *Fixture, id: u32) bool {
        fixture.trace.note(.poller, id);
        if (fixture.plans[id].queues) fixture.schedule_free();
        return fixture.plans[id].worked;
    }

    fn on_task(fixture: *Fixture, id: u32) void {
        fixture.queued[id] = false;
        fixture.trace.note(.task, id);
        fixture.runs[id] += 1;
        const behaviour = Behaviour.of(fixture.seed, id, fixture.runs[id]);
        for (0..behaviour.children) |_| {
            const child = first_free(&fixture.queued, 0) orelse break;
            fixture.schedule(child);
        }
        if (behaviour.again and !fixture.queued[id]) fixture.schedule(id);
    }

    /// The id of each queued task, walked from the head.
    fn queue_ids(fixture: *Fixture, ids: *[tasks_pool]u32) u32 {
        var len: u32 = 0;
        var at = fixture.dispatch.tasks.head;
        while (at) |queued| : (at = queued.next) {
            const parent: *TaskRecord = @alignCast(@fieldParentPtr("task", queued));
            ids[len] = parent.id;
            len += 1;
        }
        return len;
    }
};

/// One run of the property: the driver's random stream, the model and the fixture.
const Run = struct {
    random: Random,
    model: *Model,
    fixture: *Fixture,
    /// The `user_data` of the next event without a record, so their order shows in the output.
    plain_serial: u64 = 0,

    fn step(run: *Run) !void {
        switch (run.random.below(16)) {
            0 => try run.add_poller(),
            1 => run.remove_poller(),
            2...4 => run.schedule(),
            5...7 => run.submit(),
            8...14 => try run.tick(),
            else => try run.discard(),
        }
    }

    fn add_poller(run: *Run) !void {
        const id = first_free(&run.model.added, run.random.below(pollers_pool)) orelse return;
        const poller = &run.fixture.poller(id).poller;
        if (run.model.add_poller(id)) {
            try run.fixture.dispatch.add_poller(poller);
        } else {
            try testing.expectError(error.PollersFull, run.fixture.dispatch.add_poller(poller));
        }
    }

    fn remove_poller(run: *Run) void {
        if (run.model.poller_count == 0) return;
        const index: u32 = @intCast(run.random.below(run.model.poller_count));
        const id = run.model.remove_poller(index);
        run.fixture.dispatch.remove_poller(&run.fixture.poller(id).poller);
    }

    /// The program queues up to 24 tasks between ticks.
    fn schedule(run: *Run) void {
        const count = run.random.between(1, 24);
        for (0..count) |_| {
            const id = first_free(&run.model.queued, run.random.below(tasks_pool)) orelse return;
            run.model.schedule(id);
            run.fixture.schedule(id);
        }
    }

    /// The program submits up to 4 operations with a record in one batch.
    fn submit(run: *Run) void {
        var operations: [4]u32 = undefined;
        const count = run.random.between(1, operations.len);
        var len: usize = 0;
        for (0..count) |_| {
            const id = first_free(&run.model.in_flight, run.random.below(operations_pool)) orelse break;
            run.model.submit(id);
            operations[len] = id;
            len += 1;
        }
        run.fixture.submit(operations[0..len]);
    }

    fn discard(run: *Run) !void {
        if (!run.random.chance(1, 2)) return;
        try testing.expectEqual(run.model.discard(), run.fixture.dispatch.discard_tasks());
        run.fixture.queued = @splat(false);
    }

    fn tick(run: *Run) !void {
        var plans: [pollers_pool]PollerPlan = undefined;
        for (&plans) |*plan| plan.* = .{ .worked = run.random.chance(1, 4), .queues = run.random.chance(1, 3) };
        run.fixture.plans = plans;
        const wait_ns = run.random.between(1, 1_000_000_000);
        const runs_before = run.fixture.runs;
        // The wait that `begin` returns.
        const expected_wait = run.model.begin(&plans, wait_ns);
        try testing.expectEqual(expected_wait, run.fixture.dispatch.begin(wait_ns));
        if (run.random.chance(1, 8)) {
            run.model.abandon();
            run.fixture.dispatch.abandon();
            return;
        }
        var events: [batch_max]Event = undefined;
        var operations: [batch_max]u32 = undefined;
        const len = run.build_batch(&events, &operations);
        run.model.end(events[0..len], operations[0..len]);
        const kept = run.fixture.dispatch.end(events[0..len]);
        try run.check_kept(events[0..kept]);
        // P9: each task a poller queued inside the budget ran once in this `end`.
        for (run.model.poller_tasks[0..run.model.poller_tasks_len]) |id| {
            try testing.expectEqual(runs_before[id] + 1, run.fixture.runs[id]);
        }
    }

    fn check_kept(run: *Run, kept: []const Event) !void {
        try testing.expectEqual(run.model.kept_len, @as(u32, @intCast(kept.len)));
        for (kept, run.model.kept[0..kept.len]) |actual, expected| {
            try testing.expect(!actual.flags.dispatched);
            try testing.expectEqual(std.mem.toBytes(expected), std.mem.toBytes(actual));
        }
    }

    /// A batch as a reap hands it over: events of the operations in flight, `more` ones first and
    /// a final one last for each, with events without a record, in random order.
    fn build_batch(run: *Run, events: *[batch_max]Event, operations: *[batch_max]u32) u32 {
        var labels: [batch_max]u32 = undefined;
        var counts: [operations_pool]u32 = @splat(0);
        var finals: [operations_pool]bool = @splat(false);
        var len = run.choose_operations(&labels, &counts, &finals);
        const plain = run.random.below(5);
        for (0..plain) |_| {
            if (len == batch_max) break;
            labels[len] = operations_pool;
            len += 1;
        }
        run.shuffle(labels[0..len]);
        var emitted: [operations_pool]u32 = @splat(0);
        for (labels[0..len], 0..) |label, index| {
            operations[index] = label;
            if (label == operations_pool) {
                events[index] = run.plain_event();
                continue;
            }
            emitted[label] += 1;
            const final = finals[label] and emitted[label] == counts[label];
            events[index] = run.record_event(label, !final);
        }
        return len;
    }

    /// Picks the operations in flight that this batch names, and how many events each one gets.
    fn choose_operations(
        run: *Run,
        labels: *[batch_max]u32,
        counts: *[operations_pool]u32,
        finals: *[operations_pool]bool,
    ) u32 {
        var len: u32 = 0;
        for (0..operations_pool) |operation| {
            if (!run.model.in_flight[operation] or !run.random.chance(1, 2)) continue;
            const final = run.random.chance(3, 4);
            const total: u32 = @intCast(run.random.below(3) + @intFromBool(final));
            if (total == 0 or len + total > batch_max) continue;
            for (0..total) |_| {
                labels[len] = @intCast(operation);
                len += 1;
            }
            counts[operation] = total;
            finals[operation] = final;
        }
        return len;
    }

    /// Fisher-Yates, drawn from the run's stream.
    fn shuffle(run: *Run, labels: []u32) void {
        var index = labels.len;
        while (index > 1) {
            index -= 1;
            const other = run.random.below(index + 1);
            std.mem.swap(u32, &labels[index], &labels[other]);
        }
    }

    fn plain_event(run: *Run) Event {
        run.plain_serial += 1;
        const result: i32 = @as(i32, @intCast(run.random.below(2000))) - 1000;
        return .{ .user_data = run.plain_serial, .result = result, .flags = .{
            .more = run.random.chance(1, 2),
            .buffer = run.random.chance(1, 4),
            .message = run.random.chance(1, 4),
            .buffer_id = @intCast(run.random.below(64)),
        } };
    }

    fn record_event(run: *Run, operation: u32, more: bool) Event {
        const plan: i32 = @intCast(run.random.below(model_module.plans_count));
        const address = @intFromPtr(&run.fixture.record(operation).completion);
        return .{ .user_data = address, .result = plan, .flags = .{ .more = more, .dispatched = true } };
    }

    /// Holds the dispatch to the model after a step.
    fn check(run: *Run) !void {
        const dispatch = &run.fixture.dispatch;
        const model = run.model;
        dispatch.tasks.assert_queue();
        try testing.expect(!dispatch.ticking and !dispatch.polling);
        // P3: the calls, and the queue in its order.
        try testing.expectEqualSlices(u32, model.trace.items(), run.fixture.trace.items());
        var ids: [tasks_pool]u32 = undefined;
        const queued = run.fixture.queue_ids(&ids);
        try testing.expectEqualSlices(u32, model.queue[0..model.queue_len], ids[0..queued]);
        // P7.
        try testing.expectEqual(model.queue_len, dispatch.tasks.count);
        try testing.expectEqual(model.owed(), dispatch.callbacks_outstanding);
        try testing.expectEqual(model.idle(), dispatch.idle());
        try testing.expectEqual(model.poller_count, dispatch.poller_count);
        for (model.pollers[0..model.poller_count], dispatch.pollers[0..dispatch.poller_count]) |id, poller| {
            try testing.expectEqual(&run.fixture.poller(id).poller, poller);
        }
    }
};

/// Runs `steps` random steps from `seed`, and returns a hash of every call made.
fn property_run(seed: u64, reversed: bool) !u64 {
    errdefer std.debug.print("dispatch property failed: seed {d}, reversed {}\n", .{ seed, reversed });
    var model: Model = .{ .seed = seed };
    var fixture: Fixture = undefined;
    fixture.init(seed, reversed);
    var run: Run = .{ .random = .init(seed), .model = &model, .fixture = &fixture };
    var hasher: std.hash.Wyhash = .init(seed);
    for (0..steps) |_| {
        try run.step();
        try run.check();
        hasher.update(std.mem.sliceAsBytes(fixture.trace.items()));
        fixture.trace.len = 0;
        model.trace.len = 0;
    }
    return hasher.final();
}

test "dispatch calls what the model calls, owes what it owes, and keeps plain events in order" {
    for (0..seeds) |seed| {
        const first = try property_run(seed, false);
        try testing.expectEqual(first, try property_run(seed, false));
        try testing.expectEqual(first, try property_run(seed, true));
    }
}
