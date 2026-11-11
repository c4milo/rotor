//! The functions of the host's reactor, `rotor.Reactor(rotor.Loop)` (decision 33), which
//! `rotor.zig` declares. This form holds a `rotor.Loop` by value, so `Reactor(T)` holds a `T`, as
//! Camilo ruled on open question 16 on 2026-11-08. Each call makes the call of the same name on that
//! loop, which switches once on its backend.
//!
//! At step 2 the reactor holds no state of its own: the backend's loop still holds it. Step 3 puts
//! the reactor's state beside the loop. That state names no backend type, so one copy serves every
//! backend (decision 33, open question 16).
const core = @import("core");
const loop_module = @import("rotor_loop.zig");

const Loop = loop_module.Loop;
const BufferGroup = core.buffer_group.BufferGroup;
const CallLink = core.call.CallLink;
const CallStation = core.call.CallStation;
const Event = core.Event;
const Handle = core.Handle;
const group_alignment = loop_module.group_alignment;
const loops_max = core.constants.loops_max;

/// The host's reactor, which holds a `Loop` in its field `loop`.
const Host = @import("rotor.zig").Reactor(Loop);

/// The bytes of memory `init` needs: the loop's.
pub fn memory_bytes(options: *const Host.Options) usize {
    return Loop.memory_bytes(&options.loop);
}

/// Must run on the thread that will own the reactor (decision 4). Runs the backend this
/// process chose, which `rotor.backend()` reports.
pub fn init(
    reactor: *Host,
    memory: []align(core.layout.memory_alignment) u8,
    options: *const Host.Options,
) Loop.InitError!void {
    return reactor.loop.init(memory, &options.loop);
}

pub fn deinit(reactor: *Host) void {
    reactor.loop.deinit();
}

pub fn dropped_wakes(reactor: *const Host) u64 {
    return reactor.loop.dropped_wakes();
}

pub fn submit(reactor: *Host, operations: []const core.Operation, handles: []Handle) u32 {
    return reactor.loop.submit(operations, handles);
}

pub fn cancel(reactor: *Host, handle: Handle) void {
    reactor.loop.cancel(handle);
}

pub fn post(reactor: *Host, target: core.LoopId, message: core.Message) Loop.PostError!void {
    return reactor.loop.post(target, message);
}

pub fn tick(reactor: *Host, events: []Event, wait_ns: u64) Loop.TickError!u32 {
    return reactor.loop.tick(events, wait_ns);
}

pub fn add_poller(reactor: *Host, poller: *core.Poller) Loop.AddPollerError!void {
    return reactor.loop.add_poller(poller);
}

pub fn remove_poller(reactor: *Host, poller: *core.Poller) void {
    reactor.loop.remove_poller(poller);
}

pub fn schedule(reactor: *Host, task: *core.Task) Loop.ScheduleError!void {
    return reactor.loop.schedule(task);
}

pub fn is_scheduled(reactor: *const Host, task: *const core.Task) bool {
    return reactor.loop.is_scheduled(task);
}

pub fn tasks_queued(reactor: *const Host) u32 {
    return reactor.loop.tasks_queued();
}

pub fn task_budget_left(reactor: *const Host) u32 {
    return reactor.loop.task_budget_left();
}

pub fn discard_tasks(reactor: *Host) u32 {
    return reactor.loop.discard_tasks();
}

pub fn schedule_in(reactor: *Host, group: core.SchedulingGroup, task: *core.Task) Loop.ScheduleError!void {
    return reactor.loop.schedule_in(group, task);
}

pub fn charge_task(reactor: *Host, units: u16) void {
    reactor.loop.charge_task(units);
}

pub fn reserve_scheduling_group(
    reactor: *Host,
    shares: u16,
) Loop.ReserveSchedulingGroupError!core.SchedulingGroup {
    return reactor.loop.reserve_scheduling_group(shares);
}

pub fn set_scheduling_group_shares(reactor: *Host, group: core.SchedulingGroup, shares: u16) void {
    reactor.loop.set_scheduling_group_shares(group, shares);
}

/// The view that the program hands to each library (decision 28). Its address is the
/// reactor's, so a library's calls reach the reactor. The loop's own `shared` makes the
/// owner check, and the reactor drops the loop's view.
pub fn shared(reactor: *Host) *Host.SharedLoop {
    _ = reactor.loop.shared();
    return @ptrCast(reactor);
}

pub fn heartbeat(reactor: *Host) *core.HeartbeatView {
    return reactor.loop.heartbeat();
}

pub fn in_flight(reactor: *const Host) u32 {
    return reactor.loop.in_flight();
}

pub fn now_ns(reactor: *const Host) u64 {
    return reactor.loop.now_ns();
}

pub fn wait_descriptor(reactor: *const Host) ?core.Descriptor {
    return reactor.loop.wait_descriptor();
}

pub fn statistics(reactor: *const Host) *const core.statistics.Statistics {
    return reactor.loop.statistics();
}

pub fn cancel_all(reactor: *Host) void {
    reactor.loop.cancel_all();
}

pub fn drain(reactor: *Host, scratch: []Event) Loop.DrainError!void {
    return reactor.loop.drain(scratch);
}

pub fn assert_empty(reactor: *const Host) void {
    reactor.loop.assert_empty();
}

pub fn register_buffers(reactor: *Host, blocks: []const []u8) Loop.RegisterError!void {
    return reactor.loop.register_buffers(blocks);
}

pub fn register_descriptors(reactor: *Host, descriptors: []const core.Descriptor) Loop.RegisterError!void {
    return reactor.loop.register_descriptors(descriptors);
}

pub fn provide_buffers(
    reactor: *Host,
    group: BufferGroup,
    memory: []align(group_alignment) u8,
    count: u16,
    buffer_bytes: u32,
) Loop.ProvideError!void {
    return reactor.loop.provide_buffers(group, memory, count, buffer_bytes);
}

pub fn provide_datagram_buffers(
    reactor: *Host,
    group: BufferGroup,
    memory: []align(group_alignment) u8,
    count: u16,
    buffer_bytes: u32,
    options: core.datagram.GroupOptions,
) Loop.ProvideError!void {
    return reactor.loop.provide_datagram_buffers(group, memory, count, buffer_bytes, options);
}

pub fn datagram(reactor: *const Host, group: BufferGroup, event: Event) core.Delivery {
    return reactor.loop.datagram(group, event);
}

pub fn give_back_buffer(reactor: *Host, group: BufferGroup, buffer_id: u16) void {
    reactor.loop.give_back_buffer(group, buffer_id);
}

pub fn release_buffers(reactor: *Host, group: BufferGroup) void {
    reactor.loop.release_buffers(group);
}

pub fn provided_buffer(reactor: *const Host, group: BufferGroup, buffer_id: u16) []u8 {
    return reactor.loop.provided_buffer(group, buffer_id);
}

pub fn reserve_buffer_group(reactor: *Host) error{BufferGroupsFull}!BufferGroup {
    return reactor.loop.reserve_buffer_group();
}

pub fn wait_limit(reactor: *Host) core.WaitLimit {
    return reactor.loop.wait_limit();
}

pub fn call(reactor: *Host, link: *CallLink) Loop.CallError!void {
    return reactor.loop.call(link);
}

pub fn answer(reactor: *Host, link: *CallLink) void {
    reactor.loop.answer(link);
}

pub fn serve(reactor: *Host, stations: *[loops_max]CallStation) *CallStation {
    return reactor.loop.serve(stations);
}

pub fn stop_serving(reactor: *Host, stations: *[loops_max]CallStation) void {
    reactor.loop.stop_serving(stations);
}
