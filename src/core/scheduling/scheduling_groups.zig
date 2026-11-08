//! The table of scheduling groups of one loop (decision 30): one lane for each group, and the end
//! mark that closes the queue of each group other than `.default`. Each loop carves one `Groups`
//! from its memory with `Layout.take`, and `Tables` holds a pointer to it, as it holds the
//! heartbeat. A program with no group other than `.default` touches no line of it in a tick.
//!
//! Lane 0, `.default`, keeps its queue in `Dispatch.tasks`, decision 27's FIFO, and uses only its
//! `startable`, `deficit` and `shares` here. Groups 1 to 15 end their queues at `&end_mark` and not
//! at null. So a task that is queued in any group has a `next` that is not null, or is the tail of
//! `.default`, and `Tasks.holds` finds a task queued twice in any two groups of one loop.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("../assertion_class.zig").assert_class_a;
const constants = @import("../constants.zig");
const scheduling = @import("scheduling.zig");
const tasks_module = @import("../tasks.zig");

const NamedTable = scheduling.NamedTable;
const ReserveSchedulingGroupError = scheduling.ReserveSchedulingGroupError;
const SchedulingGroup = scheduling.SchedulingGroup;
const ScheduleError = tasks_module.ScheduleError;
const Task = tasks_module.Task;
const Tasks = tasks_module.Tasks;

/// One group of one loop. Size 32 B, alignment 8.
pub const Lane = struct {
    /// The queue of a group other than `.default`, which ends at the end mark. Null when empty.
    head: ?*Task,
    tail: ?*Task,
    /// The tasks queued in the group. Lane 0 keeps it at 0: `Dispatch.tasks.count` holds it.
    count: u32,
    /// The tasks the run that is open may still start in the group: its count when the run began.
    startable: u32,
    /// The group's credit in hundredths of a unit, which persists across ticks. Below 0 it is debt.
    deficit: i32,
    /// The credit of one visit, in hundredths of a unit: 1 to `scheduling_shares_max`.
    shares: u16,

    fn empty(shares: u16) Lane {
        return .{ .head = null, .tail = null, .count = 0, .startable = 0, .deficit = 0, .shares = shares };
    }
};

/// The static entry of the end mark. The run never calls it: a pop compares the next head with
/// the mark before any call.
fn end_mark_function(_: *Task) void {
    unreachable;
}

const end_mark_call: Task.Call = .{ .name = "rotor.scheduling.end_mark", .function = end_mark_function };

/// The groups of one loop. Size 536 B, alignment 8.
pub const Groups = struct {
    lanes: [constants.scheduling_groups_max]Lane,
    /// Where the queue of each group other than `.default` ends. It is never queued and never run.
    end_mark: Task,
    /// The highest id reserved: n named groups after init, plus each `reserve`.
    reserved: u8,
    /// The group of the visit that is open, or the next group to visit.
    cursor: u8,
    /// True while the visit at `cursor` holds the credit it took. A visit that the tick's bound cut
    /// resumes in the next run and takes no second credit.
    visit_open: bool,
    /// n, the named groups of the program, which hold ids 1 to n on every loop.
    named: u8,

    /// The groups of a loop that has just started: `.default` at the default shares, then the
    /// named groups of `table` at their declared shares.
    pub fn init(groups: *Groups, table: *const NamedTable) void {
        groups.* = .{
            .lanes = @splat(Lane.empty(constants.scheduling_shares_default)),
            .end_mark = .{ .call = &end_mark_call },
            .reserved = 0,
            .cursor = 0,
            .visit_open = false,
            .named = 0,
        };
        groups.reserve_named(table);
    }

    /// Gives ids 1 to n of `table` their declared shares, in order, and stores n. Once, before any
    /// `reserve`.
    pub fn reserve_named(groups: *Groups, table: *const NamedTable) void {
        assert(groups.reserved == 0);
        // A table of more than `scheduling_groups_max - 1` names runs out of ids here.
        for (table.shares[0..table.count]) |shares| {
            _ = groups.reserve(shares) catch unreachable;
        }
        groups.named = table.count;
        assert(groups.reserved == table.count);
    }

    /// Reserves the lowest free id with `shares`, which must be in 1 to `scheduling_shares_max`
    /// (decision 8, class B). The id belongs to this loop until `deinit`.
    pub fn reserve(groups: *Groups, shares: u16) ReserveSchedulingGroupError!SchedulingGroup {
        assert_shares(shares);
        if (groups.reserved == constants.scheduling_groups_max - 1) return error.SchedulingGroupsFull;
        groups.reserved += 1;
        groups.lanes[groups.reserved] = .empty(shares);
        return @enumFromInt(groups.reserved);
    }

    /// Sets the shares of `.default` or of a reserved group. The visit that is open keeps the
    /// credit it took, so the change counts from the group's next visit.
    pub fn set_shares(groups: *Groups, group: SchedulingGroup, shares: u16) void {
        assert_shares(shares);
        groups.assert_reserved(group);
        groups.lanes[@intFromEnum(group)].shares = shares;
    }

    /// Halts on an id that this loop did not reserve: a forged `@enumFromInt` (decision 8, class
    /// A, one compare).
    pub fn assert_reserved(groups: *const Groups, group: SchedulingGroup) void {
        assert_class_a(@intFromEnum(group) <= groups.reserved);
    }

    /// Appends `task` to group `group`, which is not `.default`. Returns `TasksFull` when the group
    /// holds `queued_max` tasks, and then changes nothing. The caller checked that the task is not
    /// queued.
    pub fn push(groups: *Groups, group: SchedulingGroup, task: *Task, queued_max: u32) ScheduleError!void {
        assert(group != .default);
        assert(queued_max <= constants.tasks_queued_max);
        const lane = &groups.lanes[@intFromEnum(group)];
        if (lane.count >= queued_max) return error.TasksFull;
        task.next = &groups.end_mark;
        if (lane.tail) |tail| tail.next = task else lane.head = task;
        lane.tail = task;
        lane.count += 1;
    }

    /// Takes the head of group `index`, which is not `.default` and holds a task, off its queue,
    /// and clears its link.
    pub fn pop(groups: *Groups, index: u8) *Task {
        assert(index != 0);
        const lane = &groups.lanes[index];
        assert_class_a(lane.count >= 1);
        const task = lane.head.?;
        // The end mark is never popped as a task (decision 8, class A).
        assert_class_a(task != &groups.end_mark);
        const next = task.next.?;
        if (next == &groups.end_mark) {
            lane.head = null;
            lane.tail = null;
        } else {
            lane.head = next;
        }
        task.next = null;
        lane.count -= 1;
        return task;
    }

    /// The tasks queued in the groups other than `.default`.
    pub fn queued(groups: *const Groups) u32 {
        var sum: u32 = 0;
        for (groups.lanes[1 .. @as(usize, groups.reserved) + 1]) |*lane| sum += lane.count;
        return sum;
    }

    /// Unlinks every task of the groups other than `.default` without a call, and returns the count.
    /// It resets every deficit, the cursor and the open visit, `.default`'s included. The caller
    /// discards `.default`'s queue.
    pub fn discard(groups: *Groups) u32 {
        var discarded: u32 = 0;
        for (groups.lanes[1 .. @as(usize, groups.reserved) + 1]) |*lane| {
            const count = lane.count;
            var unlinked: u32 = 0;
            var at = lane.head;
            while (unlinked < constants.tasks_queued_max) : (unlinked += 1) {
                const task = at orelse break;
                const next = task.next.?;
                at = if (next == &groups.end_mark) null else next;
                task.next = null;
            }
            assert(at == null);
            assert(unlinked == count);
            discarded += count;
            lane.* = .empty(lane.shares);
        }
        groups.lanes[0].deficit = 0;
        groups.lanes[0].startable = 0;
        groups.cursor = 0;
        groups.visit_open = false;
        return discarded;
    }

    /// Decision 8, class B, once in each run of the groups: the shape of each ready lane. A ready
    /// lane holds a task, its head and its tail are not null, and the queued tasks are at most
    /// `outstanding`, the callbacks owed. `assert_lanes` checks every lane in the tests.
    pub fn assert_ready_shape(groups: *const Groups, tasks: *const Tasks, ready: u16, outstanding: u32) void {
        tasks.assert_shape();
        assert(ready & 1 == 0);
        var sum: u64 = tasks.count;
        var mask = ready;
        for (0..constants.scheduling_groups_max) |_| {
            if (mask == 0) break;
            const index = @ctz(mask);
            mask &= mask - 1;
            const lane = &groups.lanes[index];
            assert(lane.count >= 1);
            assert(lane.head != null and lane.tail != null);
            sum += lane.count;
        }
        assert(sum <= outstanding);
    }

    /// Decision 8, class D, O(n): each lane's queue is `count` long, ends at its tail and then at
    /// the end mark, within `tasks_queued_max` steps, and its ready bit is set exactly when it
    /// holds a task. The tests call it after every step.
    pub fn assert_lanes(groups: *const Groups, ready: u16) void {
        assert(ready & 1 == 0);
        for (groups.lanes[1..], 1..) |*lane, index| {
            assert((lane.count == 0) == (lane.head == null));
            assert((lane.head == null) == (lane.tail == null));
            assert((ready >> @intCast(index)) & 1 == @intFromBool(lane.count != 0));
            assert(index <= groups.reserved or lane.count == 0);
            assert(lane.startable <= lane.count);
            var walked: u32 = 0;
            var last: ?*Task = null;
            var at = lane.head;
            while (at) |task| {
                assert(walked < constants.tasks_queued_max);
                assert(task != &groups.end_mark);
                walked += 1;
                last = task;
                const next = task.next.?;
                at = if (next == &groups.end_mark) null else next;
            }
            assert(walked == lane.count);
            assert(last == lane.tail);
        }
    }
};

/// Halts on shares outside 1 to `scheduling_shares_max` (decision 8, class B).
pub fn assert_shares(shares: u16) void {
    assert(shares >= 1);
    assert(shares <= constants.scheduling_shares_max);
}

comptime {
    assert(@sizeOf(Lane) == 32);
    assert(@alignOf(Lane) == 8);
    assert(@sizeOf(Groups) == 536);
    assert(@alignOf(Groups) == 8);
}
