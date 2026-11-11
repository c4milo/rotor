//! The calls of `Reactor(Loop)` (decision 33). Each takes the reactor first, so `reactor.zig`
//! declares one alias for each. A call of the reactor's own, or one of the seven that wrap the
//! loop's, makes the `Dispatch` call of the same name with the reactor's state and its loop. Each
//! other call forwards to the loop. Split from `reactor.zig`, whose `Reactor` declares one alias
//! for each function here.
//!
//! A forwarder makes no check of its own: the loop's call makes each check, as the public
//! `rotor.Loop` leaves each check to its backend.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const reactor_module = @import("reactor.zig");

const BufferGroup = core.BufferGroup;
const CallLink = reactor_module.CallLink;
const CallStation = reactor_module.CallStation;
const Descriptor = core.Descriptor;
const Dispatch = reactor_module.Dispatch;
const Event = core.Event;
const Groups = reactor_module.Groups;
const Handle = core.Handle;
const LoopId = core.LoopId;
const Message = core.Message;
const Operation = core.Operation;
const Poller = reactor_module.Poller;
const SchedulingGroup = core.SchedulingGroup;
const Task = reactor_module.Task;
const group_alignment = core.buffer_group.group_alignment;
const loops_max = core.constants.loops_max;
const memory_alignment = core.layout.memory_alignment;

/// The bytes of a reactor's memory, for a loop that takes `loop_bytes`: the loop's bytes, then the
/// reactor's groups at their alignment, 536 B more (decision 33, "The public module").
pub fn memory_bytes(loop_bytes: usize) usize {
    return groups_offset(loop_bytes) + @sizeOf(Groups);
}

/// Where the reactor's groups start in its memory: after the loop's bytes.
fn groups_offset(loop_bytes: usize) usize {
    return std.mem.alignForward(usize, loop_bytes, @alignOf(Groups));
}

/// The reactor's groups, carved from the end of `memory`, after the loop's `loop_bytes`.
pub fn groups_in(memory: []align(memory_alignment) u8, loop_bytes: usize) *Groups {
    assert(memory.len >= memory_bytes(loop_bytes));
    const offset = groups_offset(loop_bytes);
    return @ptrCast(@alignCast(memory[offset..][0..@sizeOf(Groups)]));
}

/// The type that `function` returns. A twin of decision 10 picks its own error sets, so each call
/// returns what the loop's call of the same name returns.
fn Result(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

/// What a reactor copies from a loop's options at `init`: the loop's id, and whether its registry
/// is a decision 21 group's. A twin whose options name neither is loop 0, in no group.
fn identity(comptime Options: type, options: *const Options) struct { id: LoopId, in_group: bool } {
    const id: LoopId = if (@hasField(Options, "id")) options.id else 0;
    if (!@hasField(Options, "registry") or @FieldType(Options, "registry") != ?*core.mailbox.Registry) {
        return .{ .id = id, .in_group = false };
    }
    const registry = options.registry orelse return .{ .id = id, .in_group = false };
    return .{ .id = id, .in_group = registry.group };
}

/// The calls of `Reactor`, which holds a `Loop` in its field `loop` and its state in `dispatch`.
pub fn Calls(comptime Reactor: type, comptime Loop: type) type {
    return struct {
        /// The loop's error set for a tick.
        pub const TickError = @typeInfo(Result(Loop.tick_backend)).error_union.error_set;

        /// The bytes of memory that `init` needs: the loop's, then the reactor's groups.
        pub fn memory_bytes(options: *const Reactor.Options) usize {
            return reactor_module.memory_bytes(Loop.memory_bytes(&options.loop));
        }

        /// Starts the reactor in place, on the thread that will own it. It carves the groups from
        /// the end of `memory`, starts the loop on the rest, and attaches the hook with the
        /// reactor's address as its context. The reactor then stays at that address until
        /// `deinit`, as a loop does.
        pub fn init(
            reactor: *Reactor,
            memory: []align(memory_alignment) u8,
            options: *const Reactor.Options,
        ) Result(Loop.init) {
            const loop_bytes = Loop.memory_bytes(&options.loop);
            const groups = reactor_module.groups_in(memory, loop_bytes);
            try reactor.loop.init(memory[0..loop_bytes], &options.loop);
            const copied = identity(Loop.Options, &options.loop);
            reactor.dispatch.start(groups, .{
                .id = copied.id,
                .in_group = copied.in_group,
                .named_groups = &options.named_groups,
            });
            reactor.loop.attach_reserved(reactor, take_reserved);
        }

        /// The hook: the reactor's `Dispatch.take_reserved`, through the context that `init`
        /// stored.
        fn take_reserved(context: *anyopaque, sender: LoopId, message: Message) void {
            const reactor: *Reactor = @ptrCast(@alignCast(context));
            reactor.dispatch.take_reserved(&reactor.loop, sender, message);
        }

        /// Halts while a poller is added, a task is queued or a station serves (class C), then ends
        /// the loop, which halts while an operation, a record or a call is still counted.
        pub fn deinit(reactor: *Reactor) void {
            reactor.loop.assert_owner();
            reactor.dispatch.assert_empty();
            reactor.dispatch.assert_calls_ended();
            reactor.loop.deinit();
        }

        pub fn tick(reactor: *Reactor, events: []Event, wait_ns: u64) TickError!u32 {
            return reactor.dispatch.tick(&reactor.loop, events, wait_ns);
        }

        pub fn drain(reactor: *Reactor, scratch: []Event) Reactor.DrainError!void {
            return reactor.dispatch.drain(&reactor.loop, scratch);
        }

        /// Halts while an operation is in flight, inside a tick, or while a poller is added or a
        /// task is queued.
        pub fn assert_empty(reactor: *const Reactor) void {
            reactor.dispatch.assert_empty();
            reactor.loop.assert_empty();
        }

        pub fn wait_limit(reactor: *Reactor) core.WaitLimit {
            return reactor.dispatch.wait_limit(&reactor.loop);
        }

        pub fn submit(reactor: *Reactor, operations: []const Operation, handles: []Handle) u32 {
            return reactor.dispatch.submit(&reactor.loop, operations, handles);
        }

        pub fn add_poller(reactor: *Reactor, poller: *Poller) Reactor.AddPollerError!void {
            return reactor.dispatch.add_poller(&reactor.loop, poller);
        }

        pub fn remove_poller(reactor: *Reactor, poller: *Poller) void {
            reactor.dispatch.remove_poller(&reactor.loop, poller);
        }

        pub fn schedule(reactor: *Reactor, task: *Task) Reactor.ScheduleError!void {
            return reactor.dispatch.schedule(&reactor.loop, task);
        }

        pub fn is_scheduled(reactor: *const Reactor, task: *const Task) bool {
            return reactor.dispatch.is_scheduled(&reactor.loop, task);
        }

        pub fn tasks_queued(reactor: *const Reactor) u32 {
            return reactor.dispatch.tasks_queued(&reactor.loop);
        }

        pub fn task_budget_left(reactor: *const Reactor) u32 {
            return reactor.dispatch.task_budget_left(&reactor.loop);
        }

        pub fn discard_tasks(reactor: *Reactor) u32 {
            return reactor.dispatch.discard_tasks(&reactor.loop);
        }

        pub fn schedule_in(reactor: *Reactor, group: SchedulingGroup, task: *Task) Reactor.ScheduleError!void {
            return reactor.dispatch.schedule_in(&reactor.loop, group, task);
        }

        pub fn charge_task(reactor: *Reactor, units: u16) void {
            reactor.dispatch.charge_task(&reactor.loop, units);
        }

        pub fn reserve_scheduling_group(
            reactor: *Reactor,
            shares: u16,
        ) Reactor.ReserveSchedulingGroupError!SchedulingGroup {
            return reactor.dispatch.reserve_scheduling_group(&reactor.loop, shares);
        }

        pub fn set_scheduling_group_shares(reactor: *Reactor, group: SchedulingGroup, shares: u16) void {
            reactor.dispatch.set_scheduling_group_shares(&reactor.loop, group, shares);
        }

        /// The view that the program hands to each library (decision 28). Its address is the
        /// reactor's, so a library's calls reach the reactor. Program only.
        pub fn shared(reactor: *Reactor) *Reactor.SharedLoop {
            reactor.loop.assert_owner();
            return @ptrCast(reactor);
        }

        pub fn call(reactor: *Reactor, link: *CallLink) Reactor.CallError!void {
            return reactor.dispatch.call(&reactor.loop, link);
        }

        pub fn answer(reactor: *Reactor, link: *CallLink) void {
            reactor.dispatch.answer(&reactor.loop, link);
        }

        pub fn serve(reactor: *Reactor, stations: *[loops_max]CallStation) *CallStation {
            return reactor.dispatch.serve(&reactor.loop, stations);
        }

        pub fn stop_serving(reactor: *Reactor, stations: *[loops_max]CallStation) void {
            reactor.dispatch.stop_serving(&reactor.loop, stations);
        }

        // The forwarders: each the loop's call of the same name.

        pub fn dropped_wakes(reactor: *const Reactor) u64 {
            return reactor.loop.dropped_wakes();
        }

        pub fn cancel(reactor: *Reactor, handle: Handle) void {
            reactor.loop.cancel(handle);
        }

        pub fn post(reactor: *Reactor, target: LoopId, message: Message) Result(Loop.post) {
            return reactor.loop.post(target, message);
        }

        pub fn heartbeat(reactor: *Reactor) Result(Loop.heartbeat) {
            return reactor.loop.heartbeat();
        }

        pub fn in_flight(reactor: *const Reactor) u32 {
            return reactor.loop.in_flight();
        }

        pub fn now_ns(reactor: *const Reactor) u64 {
            return reactor.loop.now_ns();
        }

        pub fn wait_descriptor(reactor: *const Reactor) ?Descriptor {
            return reactor.loop.wait_descriptor();
        }

        pub fn statistics(reactor: *const Reactor) Result(Loop.statistics) {
            return reactor.loop.statistics();
        }

        pub fn cancel_all(reactor: *Reactor) void {
            reactor.loop.cancel_all();
        }

        pub fn register_buffers(reactor: *Reactor, blocks: []const []u8) Result(Loop.register_buffers) {
            return reactor.loop.register_buffers(blocks);
        }

        pub fn register_descriptors(
            reactor: *Reactor,
            descriptors: []const Descriptor,
        ) Result(Loop.register_descriptors) {
            return reactor.loop.register_descriptors(descriptors);
        }

        pub fn reserve_buffer_group(reactor: *Reactor) Result(Loop.reserve_buffer_group) {
            return reactor.loop.reserve_buffer_group();
        }

        pub fn provide_buffers(
            reactor: *Reactor,
            group: BufferGroup,
            memory: []align(group_alignment) u8,
            count: u16,
            buffer_bytes: u32,
        ) Result(Loop.provide_buffers) {
            return reactor.loop.provide_buffers(group, memory, count, buffer_bytes);
        }

        pub fn provide_datagram_buffers(
            reactor: *Reactor,
            group: BufferGroup,
            memory: []align(group_alignment) u8,
            count: u16,
            buffer_bytes: u32,
            options: core.datagram.GroupOptions,
        ) Result(Loop.provide_datagram_buffers) {
            return reactor.loop.provide_datagram_buffers(group, memory, count, buffer_bytes, options);
        }

        pub fn datagram(reactor: *const Reactor, group: BufferGroup, event: Event) core.Delivery {
            return reactor.loop.datagram(group, event);
        }

        pub fn give_back_buffer(reactor: *Reactor, group: BufferGroup, buffer_id: u16) void {
            reactor.loop.give_back_buffer(group, buffer_id);
        }

        pub fn release_buffers(reactor: *Reactor, group: BufferGroup) void {
            reactor.loop.release_buffers(group);
        }

        pub fn provided_buffer(reactor: *const Reactor, group: BufferGroup, buffer_id: u16) []u8 {
            return reactor.loop.provided_buffer(group, buffer_id);
        }
    };
}
