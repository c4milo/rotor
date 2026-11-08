//! The loop as the program hands it to a library (decision 28). A library takes a `*SharedLoop`
//! at init and keeps it. It declares only the calls a library may make, so a library that ticks,
//! drains, ends or cancels everything on a loop it shares fails to compile, with a message that
//! states the rule (decision 27, ruling 1).
//!
//! It is an opaque type. Its address is the loop's, and each call casts the address back and makes
//! the `Loop` call of the same name, so it costs what that call costs. A struct with a field that
//! holds the loop would let `shared.loop.tick()` compile with no cast. An opaque view needs a
//! deliberate `@ptrCast`, which the loop cannot see.
//!
//! It is written once for any `Loop` with these calls: each backend's, and the public module's.
//! A twin of the surface brings its own with the same declarations (decision 10).
const std = @import("std");
const buffer_group = @import("buffer_group.zig");
const datagram_module = @import("datagram.zig");
const dispatch = @import("dispatch/dispatch.zig");
const event_module = @import("event.zig");
const handle_module = @import("handle.zig");
const operation_module = @import("operation.zig");
const tasks_module = @import("tasks.zig");
const call_module = @import("call/call.zig");
const constants = @import("constants.zig");

const Delivery = datagram_module.Delivery;
const Event = event_module.Event;
const GroupOptions = datagram_module.GroupOptions;
const Handle = handle_module.Handle;
const LoopId = operation_module.LoopId;
const Message = operation_module.Message;
const Operation = operation_module.Operation;
const Poller = dispatch.Poller;
const Task = tasks_module.Task;
const SchedulingGroup = @import("scheduling/scheduling.zig").SchedulingGroup;
const BufferGroup = buffer_group.BufferGroup;
const group_alignment = buffer_group.group_alignment;

/// The calls a library may make on the view: each is the `Loop` call of the same name.
pub const library_calls = [_][]const u8{
    "submit",          "cancel",               "post",
    "now_ns",          "schedule_in",          "charge_task",
    "is_scheduled",    "task_budget_left",     "add_poller",
    "remove_poller",   "provide_buffers",      "provide_datagram_buffers",
    "datagram",        "provided_buffer",      "give_back_buffer",
    "release_buffers", "reserve_buffer_group", "call",
    "answer",          "serve",                "stop_serving",
};

/// The calls that only the program makes. The view declares each one as a compile error that states
/// the rule. The test that names every public function skips these names, and
/// `zig build test-compile-fail` proves that each one refuses to compile.
pub const refused_calls = [_][]const u8{
    "tick",
    "drain",
    "deinit",
    "cancel_all",
    "discard_tasks",
    "schedule",
    "reserve_scheduling_group",
    "set_scheduling_group_shares",
};

/// True for a call the view refuses.
pub fn is_refused(comptime name: []const u8) bool {
    for (refused_calls) |refused_name| {
        if (std.mem.eql(u8, name, refused_name)) return true;
    }
    return false;
}

/// Holds `View` to the declarations of a view: each call of a library, each refused call, the list
/// of the refused calls, and nothing else. A twin's own view passes it too (decision 10).
pub fn check(comptime View: type) void {
    const declarations = @typeInfo(View).@"opaque".decls;
    comptime std.debug.assert(declarations.len == library_calls.len + refused_calls.len + 1);
    inline for (library_calls ++ refused_calls ++ .{"refused"}) |name| {
        if (!@hasDecl(View, name)) @compileError("SharedLoop lacks '" ++ name ++ "'");
    }
}

/// The type that `function` returns.
fn Result(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

/// The view of `Loop` that a library holds. Only the loop's own thread calls it (class B, as for
/// the loop itself).
pub fn SharedLoop(comptime Loop: type) type {
    return opaque {
        const Shared = @This();

        fn loop(shared: *Shared) *Loop {
            return @ptrCast(@alignCast(shared));
        }

        fn loop_const(shared: *const Shared) *const Loop {
            return @ptrCast(@alignCast(shared));
        }

        /// `Loop.submit`.
        pub fn submit(shared: *Shared, operations: []const Operation, handles: []Handle) u32 {
            return loop(shared).submit(operations, handles);
        }

        /// `Loop.cancel`.
        pub fn cancel(shared: *Shared, handle: Handle) void {
            loop(shared).cancel(handle);
        }

        /// `Loop.post`.
        pub fn post(shared: *Shared, target: LoopId, message: Message) Result(Loop.post) {
            return loop(shared).post(target, message);
        }

        /// `Loop.now_ns`.
        pub fn now_ns(shared: *const Shared) u64 {
            return loop_const(shared).now_ns();
        }

        /// `Loop.schedule_in`: a library names its group in each call (decision 30). The program
        /// hands each library its group at init.
        pub fn schedule_in(shared: *Shared, group: SchedulingGroup, task: *Task) tasks_module.ScheduleError!void {
            return loop(shared).schedule_in(group, task);
        }

        /// `Loop.charge_task`, inside a task's run only.
        pub fn charge_task(shared: *Shared, units: u16) void {
            loop(shared).charge_task(units);
        }

        /// `Loop.is_scheduled`.
        pub fn is_scheduled(shared: *const Shared, task: *const Task) bool {
            return loop_const(shared).is_scheduled(task);
        }

        /// `Loop.task_budget_left`.
        pub fn task_budget_left(shared: *const Shared) u32 {
            return loop_const(shared).task_budget_left();
        }

        /// `Loop.add_poller`.
        pub fn add_poller(shared: *Shared, poller: *Poller) dispatch.AddPollerError!void {
            return loop(shared).add_poller(poller);
        }

        /// `Loop.remove_poller`.
        pub fn remove_poller(shared: *Shared, poller: *Poller) void {
            loop(shared).remove_poller(poller);
        }

        /// `Loop.reserve_buffer_group`: a library calls it once, at init, and keeps the id until
        /// the loop's `deinit` (decision 29).
        pub fn reserve_buffer_group(shared: *Shared) Result(Loop.reserve_buffer_group) {
            return loop(shared).reserve_buffer_group();
        }

        /// `Loop.provide_buffers`.
        pub fn provide_buffers(
            shared: *Shared,
            group: BufferGroup,
            memory: []align(group_alignment) u8,
            count: u16,
            buffer_bytes: u32,
        ) Result(Loop.provide_buffers) {
            return loop(shared).provide_buffers(group, memory, count, buffer_bytes);
        }

        /// `Loop.provide_datagram_buffers`.
        pub fn provide_datagram_buffers(
            shared: *Shared,
            group: BufferGroup,
            memory: []align(group_alignment) u8,
            count: u16,
            buffer_bytes: u32,
            options: GroupOptions,
        ) Result(Loop.provide_datagram_buffers) {
            const view = loop(shared);
            return view.provide_datagram_buffers(group, memory, count, buffer_bytes, options);
        }

        /// `Loop.datagram`.
        pub fn datagram(shared: *const Shared, group: BufferGroup, event: Event) Delivery {
            return loop_const(shared).datagram(group, event);
        }

        /// `Loop.provided_buffer`.
        pub fn provided_buffer(shared: *const Shared, group: BufferGroup, buffer_id: u16) []u8 {
            return loop_const(shared).provided_buffer(group, buffer_id);
        }

        /// `Loop.give_back_buffer`.
        pub fn give_back_buffer(shared: *Shared, group: BufferGroup, buffer_id: u16) void {
            loop(shared).give_back_buffer(group, buffer_id);
        }

        /// `Loop.release_buffers`.
        pub fn release_buffers(shared: *Shared, group: BufferGroup) void {
            loop(shared).release_buffers(group);
        }

        /// `Loop.call`: only `Service.send` calls it (decision 32).
        pub fn call(shared: *Shared, link: *call_module.CallLink) call_module.CallError!void {
            return loop(shared).call(link);
        }

        /// `Loop.answer`: only `Service` and `CallRecord.answer` call it (decision 32).
        pub fn answer(shared: *Shared, link: *call_module.CallLink) void {
            loop(shared).answer(link);
        }

        /// `Loop.serve`: only `Service.serve` calls it (decision 32).
        pub fn serve(
            shared: *Shared,
            stations: *[constants.loops_max]call_module.CallStation,
        ) *call_module.CallStation {
            return loop(shared).serve(stations);
        }

        /// `Loop.stop_serving`: only `Service.stop_serving` calls it (decision 32).
        pub fn stop_serving(shared: *Shared, stations: *[constants.loops_max]call_module.CallStation) void {
            loop(shared).stop_serving(stations);
        }

        /// The calls that only the program makes, which fail to compile here.
        pub const refused = refused_calls;
        pub const tick = @compileError("a library never ticks a shared loop: finish the work " ++
            "in a record, a poller or a task (decision 27, ruling 1)");
        pub const drain = @compileError("only the program drains a shared loop");
        pub const deinit = @compileError("only the program ends a shared loop");
        pub const cancel_all = @compileError("cancel_all cancels every library's operations");
        pub const discard_tasks = @compileError("only the program discards the task queue");
        pub const schedule = @compileError("a library names its group: schedule_in(group, task) " ++
            "(decision 30)");
        pub const reserve_scheduling_group = @compileError("only the program sets the groups and " ++
            "their shares (decision 30)");
        pub const set_scheduling_group_shares = @compileError("only the program sets the groups " ++
            "and their shares (decision 30)");
    };
}

const testing = std.testing;

/// The loop id whose mailbox `Counting.post` finds full.
const full_target: LoopId = 9;

/// A loop with every call of the view, which counts the calls it took.
const Counting = struct {
    calls: u32 = 0,
    seen_now_ns: u64 = 0,

    pub fn submit(counting: *Counting, operations: []const Operation, handles: []Handle) u32 {
        _ = handles;
        counting.calls += 1;
        return @intCast(operations.len);
    }
    pub fn cancel(counting: *Counting, handle: Handle) void {
        _ = handle;
        counting.calls += 1;
    }
    pub fn post(counting: *Counting, target: LoopId, message: Message) error{MailboxFull}!void {
        _ = message;
        counting.calls += 1;
        if (target == full_target) return error.MailboxFull;
    }
    pub fn now_ns(counting: *const Counting) u64 {
        return counting.seen_now_ns;
    }
    pub fn schedule_in(counting: *Counting, group: SchedulingGroup, task: *Task) tasks_module.ScheduleError!void {
        _ = task;
        counting.calls += 1 + @as(u32, @intFromEnum(group));
    }
    pub fn charge_task(counting: *Counting, units: u16) void {
        counting.calls += units;
    }
    pub fn is_scheduled(counting: *const Counting, task: *const Task) bool {
        _ = task;
        return counting.calls != 0;
    }
    pub fn task_budget_left(counting: *const Counting) u32 {
        return counting.calls;
    }
    pub fn add_poller(counting: *Counting, poller: *Poller) dispatch.AddPollerError!void {
        _ = poller;
        counting.calls += 1;
    }
    pub fn remove_poller(counting: *Counting, poller: *Poller) void {
        _ = poller;
        counting.calls += 1;
    }
};

test "each call of the view reaches the loop it was made from" {
    var counting: Counting = .{ .seen_now_ns = 42 };
    const View = SharedLoop(Counting);
    const shared: *View = @ptrCast(&counting);
    try testing.expectEqual(@as(u32, 1), shared.submit(&.{Operation.timer(0, 1, 0)}, &.{}));
    shared.cancel(.none);
    try shared.post(1, .{ .tag = 0, .payload = 0 });
    const message: Message = .{ .tag = 0, .payload = 0 };
    try testing.expectError(error.MailboxFull, shared.post(full_target, message));
    try testing.expectEqual(@as(u64, 42), shared.now_ns());
    try testing.expectEqual(@as(u32, 4), counting.calls);
    var task: Task = .{ .call = undefined };
    try testing.expect(shared.is_scheduled(&task));
    try testing.expectEqual(@as(u32, 4), shared.task_budget_left());
    // The group reaches the loop: the counting loop adds its id.
    try shared.schedule_in(@enumFromInt(2), &task);
    try testing.expectEqual(@as(u32, 7), counting.calls);
    shared.charge_task(5);
    try testing.expectEqual(@as(u32, 12), counting.calls);
}

test "the view declares each refused call, so the compiler states the rule" {
    const View = SharedLoop(Counting);
    comptime check(View);
    inline for (View.refused) |name| try testing.expect(@hasDecl(View, name));
    // A library's calls are there too, and the program's other calls are not.
    try testing.expect(@hasDecl(View, "submit"));
    try testing.expect(!@hasDecl(View, "in_flight"));
    try testing.expect(!@hasDecl(View, "wait_descriptor"));
    // Only the program sleeps, so the view does not declare the host's call (decision 29).
    try testing.expect(!@hasDecl(View, "wait_limit"));
}
