//! The task queue of decision 27: work that a library asks the loop to do once, later, in the
//! `end` of a tick. A task is a record in the library's own memory, linked into one FIFO through
//! its `next`. A task is not an operation: it takes no slot, makes no event, and never reaches the
//! kernel. The loop calls `run` exactly once for each `schedule`, unless the program discards the
//! queue first (decision 27, the once rule).
//!
//! One run of the queue starts at most `tasks_per_tick_max` tasks, and only tasks that were queued
//! when the run began. So a task that schedules itself runs once in each tick, and the tick ends.
//! Nothing here reads a clock: every choice is a function of the order of the calls. The loop
//! follows a task's address and compares two addresses for identity, and never decides anything
//! from an address's value (non-negotiable 2).
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("assertion_class.zig").assert_class_a;
const constants = @import("constants.zig");
const stall = @import("stall.zig");

const Heartbeat = stall.Heartbeat;

/// Work that a library asks the loop to do once, later. The library owns the record and puts it
/// inside its own struct, as it does with a `Completion`. Only the loop writes `next`.
/// Size 16 B, alignment 8.
pub const Task = struct {
    call: *const Call,
    /// The task after this one in the queue, or null at the tail and while the task is not queued.
    next: ?*Task = null,

    /// A static entry, as `Completion.Call` is (decision 28). Size 32 B, alignment 8.
    pub const Call = struct {
        name: [:0]const u8,
        function: *const fn (task: *Task) void,
        /// The units that one run costs before any `charge_task`, in 1 to `task_charge_max`
        /// (decision 30). The groups path reads it beside `function`.
        cost: u16 = 1,
        /// True for the task of a cross-core call (decision 32, ruling item 12). Its caller waits
        /// for `finish`, so `discard_tasks` halts on such a task. It sits in the padding.
        call_record: bool = false,
    };

    /// A task at `field` of `Parent` that calls `handler` with its parent. The compiler checks the
    /// field, the parent and the handler, and the call costs the same as one written by hand, after
    /// one load of the static `Call`. One run costs 1 unit (decision 30).
    pub fn init(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent) void,
    ) Task {
        return init_cost(Parent, field, handler, 1);
    }

    /// As `init`, with a cost of `cost` units for each run (decision 30). The compiler refuses 0
    /// and a cost above `task_charge_max`. One run costs at most `task_charge_max` units, `cost`
    /// and every `charge_task` together. So a task whose work varies counts its first `cost`
    /// slices as paid: it does at most `@max(cost, task_budget_left() + 1)` slices, and charges
    /// the slices less `cost` when they are more.
    pub fn init_cost(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent) void,
        comptime cost: u16,
    ) Task {
        comptime assert(@FieldType(Parent, field) == Task);
        if (cost == 0) @compileError("a task costs at least 1 unit");
        if (cost > constants.task_charge_max) @compileError("a task costs at most task_charge_max units");
        const Static = struct {
            fn function(task: *Task) void {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, task));
                handler(parent);
            }
            const call: Call = .{
                .name = stall.name_of(Parent, field),
                .function = function,
                .cost = cost,
            };
        };
        return .{ .call = &Static.call };
    }
};

comptime {
    assert(@sizeOf(Task) == 16);
    assert(@alignOf(Task) == 8);
    assert(@sizeOf(Task.Call) == 32);
    assert(@alignOf(Task.Call) == 8);
}

pub const ScheduleError = error{TasksFull};

/// The run queue: a FIFO through `Task.next`, in memory the libraries own. `Dispatch` holds it.
/// Size 24 B, alignment 8.
pub const Tasks = struct {
    head: ?*Task,
    tail: ?*Task,
    /// The tasks queued.
    count: u32,
    /// `tasks_per_tick_max` less the tasks the current run called and that returned. 0 outside a
    /// run, and at least 1 inside a task's call, so `charge_task` reads it to halt outside a task
    /// with no store of a phase (decision 30). `task_budget_left` is this less 1.
    left: u32,

    pub const empty: Tasks = .{ .head = null, .tail = null, .count = 0, .left = 0 };

    /// Appends `task`. Halts when the task is queued in this queue already. Returns `TasksFull`
    /// when `queued_max` tasks are queued, and then changes nothing.
    pub fn push(tasks: *Tasks, task: *Task, queued_max: u32) ScheduleError!void {
        assert_class_a(!tasks.holds(task));
        // A call's task is pushed with the higher limit (decision 32, ruling item 11).
        assert(queued_max <= constants.task_queue_length_max);
        if (tasks.count >= queued_max) return error.TasksFull;
        if (tasks.tail) |tail| tail.next = task else tasks.head = task;
        tasks.tail = task;
        tasks.count += 1;
    }

    /// True when `task` is in this queue. A task that is queued on another loop, and is not that
    /// queue's tail, also reads true: a task belongs to one loop while it is queued.
    pub fn holds(tasks: *const Tasks, task: *const Task) bool {
        return task.next != null or tasks.tail == task;
    }

    /// Runs at most `tasks_per_tick_max` tasks, and only those queued when it began. Returns the
    /// count it ran. The pop clears the task's link before the call, so the loop never writes the
    /// task after `run` returns: a handler may free its parent, or schedule the task again. Before
    /// each call it stores the task's name in `heartbeat`, and after the last one it counts the
    /// tasks it ran there and clears the name (decision 28).
    pub fn run(tasks: *Tasks, heartbeat: *Heartbeat) u32 {
        tasks.assert_shape();
        const started = @min(tasks.count, constants.tasks_per_tick_max);
        tasks.left = constants.tasks_per_tick_max;
        defer tasks.left = 0;
        for (0..constants.tasks_per_tick_max) |ran| {
            if (ran == started) break;
            assert_class_a(tasks.head != null and tasks.count >= 1);
            const task = tasks.head orelse break;
            tasks.head = task.next;
            task.next = null;
            if (tasks.head == null) tasks.tail = null;
            tasks.count -= 1;
            heartbeat.enter(&task.call.name);
            task.call.function(task);
            tasks.left -= 1;
        }
        if (started != 0) heartbeat.leave_tasks(started);
        return started;
    }

    /// Takes the head, which must exist, off the queue and clears its link: what the groups path
    /// of decision 30 does for `.default`. `run` keeps its own copy of these lines, so the path
    /// with one group stays decision 27's code.
    pub fn pop(tasks: *Tasks) *Task {
        assert_class_a(tasks.head != null and tasks.count >= 1);
        const task = tasks.head.?;
        tasks.head = task.next;
        task.next = null;
        if (tasks.head == null) tasks.tail = null;
        tasks.count -= 1;
        return task;
    }

    /// Unlinks every queued task without a call, and returns the count. The cold path of a
    /// shutdown whose tasks never stop (decision 27, "Shutdown"). Halts on the task of a call,
    /// whose caller waits for its `finish` (decision 32, class C).
    pub fn discard(tasks: *Tasks) u32 {
        tasks.assert_shape();
        const discarded = tasks.count;
        var unlinked: u32 = 0;
        while (unlinked < constants.task_queue_length_max) : (unlinked += 1) {
            const task = tasks.head orelse break;
            assert(!task.call.call_record);
            tasks.head = task.next;
            task.next = null;
        }
        assert(unlinked == discarded);
        tasks.* = .empty;
        return discarded;
    }

    /// Decision 8, class B, once in each run: the count, the head and the tail agree.
    pub fn assert_shape(tasks: *const Tasks) void {
        assert((tasks.count == 0) == (tasks.head == null));
        assert((tasks.head == null) == (tasks.tail == null));
        assert(tasks.count <= constants.task_queue_length_max);
    }

    /// Decision 8, class D, O(n): the queue's length is `count`, its last task is `tail`, and the
    /// walk ends within `task_queue_length_max` steps. The tests call it after every step.
    pub fn assert_queue(tasks: *const Tasks) void {
        tasks.assert_shape();
        var walked: u32 = 0;
        var last: ?*Task = null;
        var at = tasks.head;
        while (at) |task| : (at = task.next) {
            assert(walked < constants.task_queue_length_max);
            walked += 1;
            last = task;
        }
        assert(walked == tasks.count);
        assert(last == tasks.tail);
    }
};

comptime {
    assert(@sizeOf(Tasks) == 24);
    assert(@alignOf(Tasks) == 8);
}

const testing = std.testing;

/// A library's record in the tests: a task, and what its runs did.
const Work = struct {
    id: u32,
    task: Task = .init(Work, "task", ran),
    /// The ids of the tasks in the order they ran, shared by every `Work` of one test.
    trace: *Trace,
    /// Runs left in which the task schedules itself again.
    again: u32 = 0,
    /// The queue a task that schedules itself pushes to.
    queue: ?*Tasks = null,

    fn ran(work: *Work) void {
        work.trace.note(work.id);
        if (work.again == 0) return;
        work.again -= 1;
        work.queue.?.push(&work.task, constants.tasks_queued_max) catch unreachable;
    }
};

/// The most runs one test's `Trace` notes.
const trace_max = 256;

const Trace = struct {
    ids: [trace_max]u32 = undefined,
    len: u32 = 0,

    fn note(trace: *Trace, id: u32) void {
        trace.ids[trace.len] = id;
        trace.len += 1;
    }
};

test "tasks run in the order of their pushes, each once, and the queue empties" {
    var trace: Trace = .{};
    var works: [3]Work = undefined;
    var tasks: Tasks = .empty;
    var heartbeat: Heartbeat = .init(null);
    for (&works, 0..) |*work, id| {
        work.* = .{ .id = @intCast(id), .trace = &trace };
        try tasks.push(&work.task, constants.tasks_queued_max);
        tasks.assert_queue();
    }
    try testing.expectEqual(@as(u32, 3), tasks.run(&heartbeat));
    tasks.assert_queue();
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, trace.ids[0..trace.len]);
    try testing.expectEqual(@as(u32, 0), tasks.run(&heartbeat));
    try testing.expectEqual(@as(u32, 3), trace.len);
    try testing.expect(tasks.head == null and tasks.tail == null);
}

test "one run starts at most tasks_per_tick_max tasks, and the rest wait for the next" {
    var trace: Trace = .{};
    const queued = constants.tasks_per_tick_max + 5;
    var works: [queued]Work = undefined;
    var tasks: Tasks = .empty;
    var heartbeat: Heartbeat = .init(null);
    for (&works, 0..) |*work, id| {
        work.* = .{ .id = @intCast(id), .trace = &trace };
        try tasks.push(&work.task, constants.tasks_queued_max);
    }
    try testing.expectEqual(constants.tasks_per_tick_max, tasks.run(&heartbeat));
    try testing.expectEqual(@as(u32, 5), tasks.count);
    tasks.assert_queue();
    try testing.expectEqual(@as(u32, 5), tasks.run(&heartbeat));
    for (trace.ids[0..trace.len], 0..) |id, order| try testing.expectEqual(@as(u32, @intCast(order)), id);
}

test "a task that schedules itself runs once in each run, after the tasks queued before it" {
    var trace: Trace = .{};
    var tasks: Tasks = .empty;
    var heartbeat: Heartbeat = .init(null);
    var looping: Work = .{ .id = 7, .trace = &trace, .again = 3, .queue = &tasks };
    var other: Work = .{ .id = 8, .trace = &trace };
    try tasks.push(&looping.task, constants.tasks_queued_max);
    try tasks.push(&other.task, constants.tasks_queued_max);
    try testing.expectEqual(@as(u32, 2), tasks.run(&heartbeat));
    try testing.expectEqualSlices(u32, &.{ 7, 8 }, trace.ids[0..trace.len]);
    // The task pushed itself again from its own run, which the run's snapshot does not start.
    try testing.expectEqual(@as(u32, 1), tasks.count);
    try testing.expectEqual(@as(u32, 1), tasks.run(&heartbeat));
    try testing.expectEqual(@as(u32, 1), tasks.run(&heartbeat));
    try testing.expectEqual(@as(u32, 1), tasks.run(&heartbeat));
    try testing.expectEqual(@as(u32, 0), tasks.run(&heartbeat));
    try testing.expectEqualSlices(u32, &.{ 7, 8, 7, 7, 7 }, trace.ids[0..trace.len]);
}

test "a full queue refuses one more push and changes nothing" {
    var trace: Trace = .{};
    var works: [5]Work = undefined;
    var tasks: Tasks = .empty;
    for (works[0..4], 0..) |*work, id| {
        work.* = .{ .id = @intCast(id), .trace = &trace };
        try tasks.push(&work.task, 4);
    }
    works[4] = .{ .id = 4, .trace = &trace };
    try testing.expectError(error.TasksFull, tasks.push(&works[4].task, 4));
    tasks.assert_queue();
    try testing.expectEqual(@as(u32, 4), tasks.count);
    try testing.expect(!tasks.holds(&works[4].task));
}

/// What a freed task's memory is filled with.
const freed_pattern: u8 = 0xaa;

/// A task that frees its own record in `run`: it fills the record with a pattern, as a library
/// that reuses the memory would. A queue that wrote the task after the call would leave the pattern
/// broken, and one that read it would follow a broken link.
const Freed = struct {
    task: Task = .init(Freed, "task", ran),
    runs: u32 = 0,

    fn ran(freed: *Freed) void {
        freed.runs += 1;
        const runs = freed.runs;
        @memset(std.mem.asBytes(&freed.task), freed_pattern);
        freed.runs = runs;
    }
};

test "the queue never writes or reads a task after its run returns" {
    var tasks: Tasks = .empty;
    var heartbeat: Heartbeat = .init(null);
    var freed: Freed = .{};
    var trace: Trace = .{};
    var after: Work = .{ .id = 1, .trace = &trace };
    try tasks.push(&freed.task, constants.tasks_queued_max);
    try tasks.push(&after.task, constants.tasks_queued_max);
    try testing.expectEqual(@as(u32, 2), tasks.run(&heartbeat));
    try testing.expectEqual(@as(u32, 1), freed.runs);
    try testing.expectEqualSlices(u32, &.{1}, trace.ids[0..trace.len]);
    for (std.mem.asBytes(&freed.task)) |byte| try testing.expectEqual(freed_pattern, byte);
}

/// A task that records `left` as it runs: the starts left after it, plus 1.
const Budget = struct {
    task: Task = .init(Budget, "task", ran),
    tasks: *const Tasks,
    seen: u32 = std.math.maxInt(u32),

    fn ran(budget: *Budget) void {
        budget.seen = budget.tasks.left;
    }
};

test "left counts the run's returns down from the budget, is at least 1 in a call, and 0 outside" {
    var tasks: Tasks = .empty;
    var heartbeat: Heartbeat = .init(null);
    try testing.expectEqual(@as(u32, 0), tasks.left);
    var alone: Budget = .{ .tasks = &tasks };
    try tasks.push(&alone.task, constants.tasks_queued_max);
    _ = tasks.run(&heartbeat);
    try testing.expectEqual(constants.tasks_per_tick_max, alone.seen);
    try testing.expectEqual(@as(u32, 0), tasks.left);

    var three: [3]Budget = @splat(.{ .tasks = &tasks });
    for (&three) |*budget| try tasks.push(&budget.task, constants.tasks_queued_max);
    _ = tasks.run(&heartbeat);
    try testing.expectEqual(constants.tasks_per_tick_max, three[0].seen);
    try testing.expectEqual(constants.tasks_per_tick_max - 2, three[2].seen);

    var full: [constants.tasks_per_tick_max]Budget = @splat(.{ .tasks = &tasks });
    for (&full) |*budget| try tasks.push(&budget.task, constants.tasks_queued_max);
    _ = tasks.run(&heartbeat);
    try testing.expectEqual(@as(u32, 1), full[constants.tasks_per_tick_max - 1].seen);
    try testing.expectEqual(@as(u32, 0), tasks.left);
}

test "the head that schedules itself again runs once in this run and once in the next" {
    var trace: Trace = .{};
    var tasks: Tasks = .empty;
    var heartbeat: Heartbeat = .init(null);
    var head: Work = .{ .id = 3, .trace = &trace, .again = 1, .queue = &tasks };
    var second: Work = .{ .id = 4, .trace = &trace };
    try tasks.push(&head.task, constants.tasks_queued_max);
    try tasks.push(&second.task, constants.tasks_queued_max);
    _ = tasks.run(&heartbeat);
    tasks.assert_queue();
    _ = tasks.run(&heartbeat);
    try testing.expectEqualSlices(u32, &.{ 3, 4, 3 }, trace.ids[0..trace.len]);
}

test "discard unlinks every task without a call, and each may be pushed again" {
    var trace: Trace = .{};
    var works: [3]Work = undefined;
    var tasks: Tasks = .empty;
    var heartbeat: Heartbeat = .init(null);
    for (&works, 0..) |*work, id| {
        work.* = .{ .id = @intCast(id), .trace = &trace };
        try tasks.push(&work.task, constants.tasks_queued_max);
    }
    try testing.expectEqual(@as(u32, 3), tasks.discard());
    try testing.expectEqual(@as(u32, 0), trace.len);
    for (&works) |*work| try testing.expect(work.task.next == null and !tasks.holds(&work.task));
    try tasks.push(&works[1].task, constants.tasks_queued_max);
    try testing.expectEqual(@as(u32, 1), tasks.run(&heartbeat));
    try testing.expectEqualSlices(u32, &.{1}, trace.ids[0..trace.len]);
}
