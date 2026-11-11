//! The reactor as the program hands it to a library (decision 28). A library takes a `*SharedLoop`
//! at init and keeps it. It declares only the calls a library may make, so a library that ticks,
//! drains, ends or cancels everything on a reactor it shares fails to compile, with a message that
//! states the rule (decision 27, ruling 1).
//!
//! Each reactor type declares its view as `SharedLoop`, an opaque type inside its own struct, so
//! the compiler prints `reactor.Reactor(kqueue.Loop).SharedLoop` (decision 33, "`SharedLoop` and
//! the conformance suite"). The view's address is the reactor's, and each call casts the address
//! back and makes the reactor's call of the same name, so it costs what that call costs. A struct
//! with a field that held the reactor would let `shared.reactor.tick()` compile with no cast. An
//! opaque view needs a deliberate `@ptrCast`, which the reactor cannot see.
//!
//! This file holds the view's calls, generic over the reactor type, and the refused calls. Moved
//! from the core's `shared_loop.zig` at step 3 of decision 33.
const std = @import("std");
const core = @import("core");
const reactor_module = @import("reactor.zig");

const BufferGroup = core.BufferGroup;
const CallLink = reactor_module.CallLink;
const CallStation = reactor_module.CallStation;
const Delivery = core.Delivery;
const Event = core.Event;
const GroupOptions = core.datagram.GroupOptions;
const Handle = core.Handle;
const LoopId = core.LoopId;
const Message = core.Message;
const Operation = core.Operation;
const Poller = reactor_module.Poller;
const SchedulingGroup = core.SchedulingGroup;
const Task = reactor_module.Task;
const group_alignment = core.buffer_group.group_alignment;
const loops_max = core.constants.loops_max;

/// The calls a library may make on the view: each is the reactor call of the same name.
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
/// `zig build test-compile-fail` proves that each one refuses to compile. Decision 33 adds
/// `wait_until`: a library bounds the wait with a poller.
pub const refused_calls = [_][]const u8{
    "tick",
    "drain",
    "deinit",
    "cancel_all",
    "discard_tasks",
    "schedule",
    "reserve_scheduling_group",
    "set_scheduling_group_shares",
    "wait_until",
};

/// True for a call the view refuses.
pub fn is_refused(comptime name: []const u8) bool {
    for (refused_calls) |refused_name| {
        if (std.mem.eql(u8, name, refused_name)) return true;
    }
    return false;
}

/// Holds `View` to the declarations of a view: each call of a library, each refused call, the list
/// of the refused calls, and nothing else.
pub fn check(comptime View: type) void {
    const declarations = @typeInfo(View).@"opaque".decls;
    comptime std.debug.assert(declarations.len == library_calls.len + refused_calls.len + 1);
    inline for (library_calls ++ refused_calls ++ .{"refused"}) |name| {
        if (!@hasDecl(View, name)) @compileError("SharedLoop lacks '" ++ name ++ "'");
    }
}

/// The refused calls of each view, and of a reactor's `wait_until`. Each fails to compile where a
/// program names it, with a message that states the rule.
pub const refusals = struct {
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
    pub const wait_until = @compileError("a library bounds the wait with a poller that returns " ++
        "its limit (decision 33)");
    pub const reactor_wait_until = @compileError("a reactor bounds its wait with a poller that " ++
        "returns its limit; wait_until is a plain loop's (decision 33)");
};

/// The type that `function` returns.
fn Result(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

/// The calls of `View`, the view of `Reactor`. Only the reactor's own thread calls them (class B,
/// as for the reactor itself).
pub fn Library(comptime Reactor: type, comptime View: type) type {
    return struct {
        fn reactor_of(shared: *View) *Reactor {
            return @ptrCast(@alignCast(shared));
        }

        fn reactor_const(shared: *const View) *const Reactor {
            return @ptrCast(@alignCast(shared));
        }

        /// `Reactor.submit`.
        pub fn submit(shared: *View, operations: []const Operation, handles: []Handle) u32 {
            return reactor_of(shared).submit(operations, handles);
        }

        /// `Reactor.cancel`.
        pub fn cancel(shared: *View, handle: Handle) void {
            reactor_of(shared).cancel(handle);
        }

        /// `Reactor.post`.
        pub fn post(shared: *View, target: LoopId, message: Message) Result(Reactor.post) {
            return reactor_of(shared).post(target, message);
        }

        /// `Reactor.now_ns`.
        pub fn now_ns(shared: *const View) u64 {
            return reactor_const(shared).now_ns();
        }

        /// `Reactor.schedule_in`: a library names its group in each call (decision 30). The program
        /// hands each library its group at init.
        pub fn schedule_in(shared: *View, group: SchedulingGroup, task: *Task) Reactor.ScheduleError!void {
            return reactor_of(shared).schedule_in(group, task);
        }

        /// `Reactor.charge_task`, inside a task's run only.
        pub fn charge_task(shared: *View, units: u16) void {
            reactor_of(shared).charge_task(units);
        }

        /// `Reactor.is_scheduled`.
        pub fn is_scheduled(shared: *const View, task: *const Task) bool {
            return reactor_const(shared).is_scheduled(task);
        }

        /// `Reactor.task_budget_left`.
        pub fn task_budget_left(shared: *const View) u32 {
            return reactor_const(shared).task_budget_left();
        }

        /// `Reactor.add_poller`.
        pub fn add_poller(shared: *View, poller: *Poller) Reactor.AddPollerError!void {
            return reactor_of(shared).add_poller(poller);
        }

        /// `Reactor.remove_poller`.
        pub fn remove_poller(shared: *View, poller: *Poller) void {
            reactor_of(shared).remove_poller(poller);
        }

        /// `Reactor.reserve_buffer_group`: a library calls it once, at init, and keeps the id until
        /// the reactor's `deinit` (decision 29).
        pub fn reserve_buffer_group(shared: *View) Result(Reactor.reserve_buffer_group) {
            return reactor_of(shared).reserve_buffer_group();
        }

        /// `Reactor.provide_buffers`.
        pub fn provide_buffers(
            shared: *View,
            group: BufferGroup,
            memory: []align(group_alignment) u8,
            count: u16,
            buffer_bytes: u32,
        ) Result(Reactor.provide_buffers) {
            return reactor_of(shared).provide_buffers(group, memory, count, buffer_bytes);
        }

        /// `Reactor.provide_datagram_buffers`.
        pub fn provide_datagram_buffers(
            shared: *View,
            group: BufferGroup,
            memory: []align(group_alignment) u8,
            count: u16,
            buffer_bytes: u32,
            options: GroupOptions,
        ) Result(Reactor.provide_datagram_buffers) {
            const reactor = reactor_of(shared);
            return reactor.provide_datagram_buffers(group, memory, count, buffer_bytes, options);
        }

        /// `Reactor.datagram`.
        pub fn datagram(shared: *const View, group: BufferGroup, event: Event) Delivery {
            return reactor_const(shared).datagram(group, event);
        }

        /// `Reactor.provided_buffer`.
        pub fn provided_buffer(shared: *const View, group: BufferGroup, buffer_id: u16) []u8 {
            return reactor_const(shared).provided_buffer(group, buffer_id);
        }

        /// `Reactor.give_back_buffer`.
        pub fn give_back_buffer(shared: *View, group: BufferGroup, buffer_id: u16) void {
            reactor_of(shared).give_back_buffer(group, buffer_id);
        }

        /// `Reactor.release_buffers`.
        pub fn release_buffers(shared: *View, group: BufferGroup) void {
            reactor_of(shared).release_buffers(group);
        }

        /// `Reactor.call`: only `Service.send` calls it (decision 32).
        pub fn call(shared: *View, link: *CallLink) Reactor.CallError!void {
            return reactor_of(shared).call(link);
        }

        /// `Reactor.answer`: only `Service` and `CallRecord.answer` call it (decision 32).
        pub fn answer(shared: *View, link: *CallLink) void {
            reactor_of(shared).answer(link);
        }

        /// `Reactor.serve`: only `Service.serve` calls it (decision 32).
        pub fn serve(shared: *View, stations: *[loops_max]CallStation) *CallStation {
            return reactor_of(shared).serve(stations);
        }

        /// `Reactor.stop_serving`: only `Service.stop_serving` calls it (decision 32).
        pub fn stop_serving(shared: *View, stations: *[loops_max]CallStation) void {
            reactor_of(shared).stop_serving(stations);
        }
    };
}
