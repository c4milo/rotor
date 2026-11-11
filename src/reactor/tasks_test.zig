//! The seeded property test of the task queue (decision 27): a run of random steps, checked step by
//! step against a plain reference model. A failure prints the seed that replays it
//! (non-negotiable 6). Split from `tasks.zig` for the 500-line limit.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const core = @import("core");
const Random = core.random.Random;
const tasks_module = @import("tasks.zig");

const Task = @import("reactor.zig").Task;
const Tasks = tasks_module.Tasks;
const Heartbeat = core.Heartbeat;

/// Records in one run. A task that would make a record past this makes none, in the queue and in
/// the model alike.
const records_max = 1024;

/// Steps in one run, and runs in one test.
const steps = 200;
const seeds = 64;

/// What a task does when it runs, a function of the seed and its id alone, so the queue and the
/// model agree without sharing a random stream.
const Behaviour = struct {
    /// New tasks it queues, each a fresh record.
    children: u32,
    /// True: it queues itself again on every run.
    forever: bool,

    fn of(seed: u64, id: u32) Behaviour {
        var random = Random.init(seed ^ (@as(u64, id) *% 0x9E37_79B9_7F4A_7C15));
        return .{ .children = @intCast(random.below(4)), .forever = random.chance(1, 64) };
    }
};

/// One run of the property: the system under test and the model, side by side.
const Run = struct {
    seed: u64,
    tasks: Tasks = .empty,
    /// What the run stores each task's name in, as a loop's `Dispatch` does.
    heartbeat: Heartbeat = .init(null),
    records: *[records_max]Record,
    /// The order of record ids in `records`: identity, or reversed, so the same seed runs with
    /// every task at another address.
    reversed: bool,
    made: u32 = 0,
    /// The ids the queue ran, in order.
    trace: std.ArrayListUnmanaged(u32) = .empty,
    /// The model: the queued ids in order, and the ids it ran.
    model: std.ArrayListUnmanaged(u32) = .empty,
    model_trace: std.ArrayListUnmanaged(u32) = .empty,
    scheduled: u64 = 0,
    discarded: u64 = 0,
    /// The model's own count of records, which must follow the queue's `make` exactly.
    model_count: u32 = 0,

    fn record(run: *Run, id: u32) *Record {
        return &run.records[if (run.reversed) records_max - 1 - id else id];
    }

    fn make(run: *Run) ?u32 {
        if (run.made == records_max) return null;
        const id = run.made;
        run.made += 1;
        run.record(id).* = .{ .id = id, .run = run };
        return id;
    }

    fn schedule(run: *Run, id: u32) void {
        run.tasks.push(&run.record(id).task, constants.tasks_queued_max) catch unreachable;
        run.scheduled += 1;
    }

    /// One `run` of the queue, and the same step in the model.
    fn step(run: *Run) !void {
        const before = run.tasks.count;
        const ran_before = run.trace.items.len;
        const started = run.tasks.run(&run.heartbeat);
        // P1: the run bound.
        try testing.expectEqual(@min(before, constants.tasks_per_tick_max), started);
        try testing.expectEqual(@as(usize, started), run.trace.items.len - ran_before);
        try run.model_step(started);
    }

    fn model_step(run: *Run, started: u32) !void {
        // The model takes the first `started` ids. What their runs queue goes to the back, after
        // the snapshot, so none of it runs in this step (P2).
        for (0..started) |_| {
            const id = run.model.orderedRemove(0);
            try run.model_trace.append(testing.allocator, id);
            const behaviour = Behaviour.of(run.seed, id);
            for (0..behaviour.children) |_| {
                const child = run.model_made() orelse break;
                try run.model.append(testing.allocator, child);
            }
            if (behaviour.forever) try run.model.append(testing.allocator, id);
        }
    }

    fn model_made(run: *Run) ?u32 {
        if (run.model_count == records_max) return null;
        run.model_count += 1;
        return run.model_count - 1;
    }

    fn check(run: *Run) !void {
        run.tasks.assert_queue();
        // P3: the queue ran the model's ids, in the model's order.
        try testing.expectEqualSlices(u32, run.model_trace.items, run.trace.items);
        try testing.expectEqual(@as(u32, @intCast(run.model.items.len)), run.tasks.count);
        try testing.expectEqual(run.model_count, run.made);
        // P6: conservation.
        const ran: u64 = run.trace.items.len;
        try testing.expectEqual(run.scheduled, ran + run.discarded + run.tasks.count);
    }

    fn deinit(run: *Run) void {
        run.trace.deinit(testing.allocator);
        run.model.deinit(testing.allocator);
        run.model_trace.deinit(testing.allocator);
    }
};

/// A task record: its run notes its id, then queues what its behaviour says.
const Record = struct {
    task: Task = .init(Record, "task", ran),
    id: u32,
    run: *Run,

    fn ran(rec: *Record) void {
        const run = rec.run;
        run.trace.append(testing.allocator, rec.id) catch unreachable;
        const behaviour = Behaviour.of(run.seed, rec.id);
        for (0..behaviour.children) |_| {
            const child = run.make() orelse break;
            run.schedule(child);
        }
        if (behaviour.forever) run.schedule(rec.id);
    }
};

/// Runs `steps` random steps from `seed` and returns a hash of the trace.
fn property_run(seed: u64, reversed: bool) !u64 {
    errdefer std.debug.print("task queue property failed: seed {d}, reversed {}\n", .{ seed, reversed });
    const records = try testing.allocator.create([records_max]Record);
    defer testing.allocator.destroy(records);
    var run: Run = .{ .seed = seed, .records = records, .reversed = reversed };
    defer run.deinit();
    var random = Random.init(seed);
    for (0..steps) |_| {
        switch (random.below(8)) {
            0...3 => {
                const id = run.make() orelse continue;
                _ = run.model_made();
                run.schedule(id);
                try run.model.append(testing.allocator, id);
            },
            4...6 => try run.step(),
            else => if (random.chance(1, 8)) {
                run.discarded += run.tasks.discard();
                run.model.clearRetainingCapacity();
            },
        }
        try run.check();
    }
    return std.hash.Wyhash.hash(seed, std.mem.sliceAsBytes(run.trace.items));
}

test "the task queue runs what the model runs, in its order, within its bound, for any seed" {
    for (0..seeds) |seed| {
        // P5 and P8: the same seed gives the same trace twice, and with every task elsewhere.
        const first = try property_run(seed, false);
        try testing.expectEqual(first, try property_run(seed, false));
        try testing.expectEqual(first, try property_run(seed, true));
    }
}
