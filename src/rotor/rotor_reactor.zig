//! The functions of the host's reactor, `rotor.Reactor(rotor.Loop)` (decision 33), which
//! `rotor.zig` declares. It holds a `rotor.Loop` by value, so `Reactor(T)` holds a `T`, as Camilo
//! ruled on open question 16 on 2026-11-08, and the reactor's state beside it. A call of the
//! reactor's own switches once on the loop's backend, and makes the `Dispatch` call of the same
//! name with the state and that backend's loop (form H, ruled on 2026-11-11). Each other call is
//! the loop's call of the same name, which makes that switch itself.
const core = @import("core");
const reactor_module = @import("reactor");
const loop_module = @import("rotor_loop.zig");

const Loop = loop_module.Loop;
const BufferGroup = core.buffer_group.BufferGroup;
const CallLink = reactor_module.CallLink;
const CallStation = reactor_module.CallStation;
const Event = core.Event;
const Handle = core.Handle;
const LoopId = core.LoopId;
const Message = core.Message;
const Poller = reactor_module.Poller;
const SchedulingGroup = core.SchedulingGroup;
const Task = reactor_module.Task;
const group_alignment = loop_module.group_alignment;
const loops_max = core.constants.loops_max;

/// The host's reactor, which holds a `Loop` in its field `loop` and its state in `dispatch`.
const Host = @import("rotor.zig").Reactor(Loop);

/// The bytes of memory `init` needs: the loop's, then the reactor's groups.
pub fn memory_bytes(options: *const Host.Options) usize {
    return reactor_module.memory_bytes(Loop.memory_bytes(&options.loop));
}

/// Must run on the thread that will own the reactor (decision 4). Runs the backend this process
/// chose, which `rotor.backend()` reports. It carves the groups from the end of `memory`, starts
/// the loop on the rest, and attaches the hook with the reactor's address as its context. The
/// reactor then stays at that address until `deinit`, as a loop does.
pub fn init(
    reactor: *Host,
    memory: []align(core.layout.memory_alignment) u8,
    options: *const Host.Options,
) Loop.InitError!void {
    const loop_bytes = Loop.memory_bytes(&options.loop);
    const groups = reactor_module.groups_in(memory, loop_bytes);
    try reactor.loop.init(memory[0..loop_bytes], &options.loop);
    reactor.dispatch.start(groups, .{
        .id = options.loop.id,
        .in_group = in_group(options.loop.registry),
        .named_groups = &options.named_groups,
    });
    switch (reactor.loop.inner) {
        inline else => |*inner, tag| inner.attach_reserved(reactor, Hook(tag).take),
    }
}

/// True when `registry` is a decision 21 group's, where no call goes.
fn in_group(registry: ?*loop_module.Registry) bool {
    const known = registry orelse return false;
    return switch (known.inner) {
        inline else => |*inner| inner.group,
    };
}

/// The hook of the backend `tag` names: the reactor's `Dispatch.take_reserved`, with that
/// backend's loop, through the context that `init` stored.
fn Hook(comptime tag: loop_module.Tag) type {
    return struct {
        fn take(context: *anyopaque, sender: LoopId, message: Message) void {
            const reactor: *Host = @ptrCast(@alignCast(context));
            const inner = &@field(reactor.loop.inner, @tagName(tag));
            reactor.dispatch.take_reserved(inner, sender, message);
        }
    };
}

/// Halts while a poller is added, a task is queued or a station serves (class C), then ends the
/// loop, which halts while an operation, a record or a call is still counted.
pub fn deinit(reactor: *Host) void {
    switch (reactor.loop.inner) {
        inline else => |*inner| inner.assert_owner(),
    }
    reactor.dispatch.assert_empty();
    reactor.dispatch.assert_calls_ended();
    reactor.loop.deinit();
}

pub fn tick(reactor: *Host, events: []Event, wait_ns: u64) Loop.TickError!u32 {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.tick(inner, events, wait_ns),
    };
}

pub fn drain(reactor: *Host, scratch: []Event) Host.DrainError!void {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.drain(inner, scratch),
    };
}

/// Halts while an operation is in flight, inside a tick, or while a poller is added or a task is
/// queued.
pub fn assert_empty(reactor: *const Host) void {
    reactor.dispatch.assert_empty();
    reactor.loop.assert_empty();
}

/// `.now` while a task is queued, and the loop's `wait_limit` otherwise (decision 29).
pub fn wait_limit(reactor: *Host) core.WaitLimit {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.wait_limit(inner),
    };
}

/// The loop's `submit`, then the count of the operations it took that name a record.
pub fn submit(reactor: *Host, operations: []const core.Operation, handles: []Handle) u32 {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.submit(inner, operations, handles),
    };
}

pub fn add_poller(reactor: *Host, poller: *Poller) Host.AddPollerError!void {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.add_poller(inner, poller),
    };
}

pub fn remove_poller(reactor: *Host, poller: *Poller) void {
    switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.remove_poller(inner, poller),
    }
}

pub fn schedule(reactor: *Host, task: *Task) Host.ScheduleError!void {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.schedule(inner, task),
    };
}

pub fn is_scheduled(reactor: *const Host, task: *const Task) bool {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.is_scheduled(inner, task),
    };
}

pub fn tasks_queued(reactor: *const Host) u32 {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.tasks_queued(inner),
    };
}

pub fn task_budget_left(reactor: *const Host) u32 {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.task_budget_left(inner),
    };
}

pub fn discard_tasks(reactor: *Host) u32 {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.discard_tasks(inner),
    };
}

pub fn schedule_in(reactor: *Host, group: SchedulingGroup, task: *Task) Host.ScheduleError!void {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.schedule_in(inner, group, task),
    };
}

pub fn charge_task(reactor: *Host, units: u16) void {
    switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.charge_task(inner, units),
    }
}

pub fn reserve_scheduling_group(reactor: *Host, shares: u16) Host.ReserveSchedulingGroupError!SchedulingGroup {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.reserve_scheduling_group(inner, shares),
    };
}

pub fn set_scheduling_group_shares(reactor: *Host, group: SchedulingGroup, shares: u16) void {
    switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.set_scheduling_group_shares(inner, group, shares),
    }
}

/// The view that the program hands to each library (decision 28). Its address is the reactor's,
/// so a library's calls reach the reactor. Only the program calls this, on the reactor's thread.
pub fn shared(reactor: *Host) *Host.SharedLoop {
    switch (reactor.loop.inner) {
        inline else => |*inner| inner.assert_owner(),
    }
    return @ptrCast(reactor);
}

pub fn call(reactor: *Host, link: *CallLink) Host.CallError!void {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.call(inner, link),
    };
}

pub fn answer(reactor: *Host, link: *CallLink) void {
    switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.answer(inner, link),
    }
}

pub fn serve(reactor: *Host, stations: *[loops_max]CallStation) *CallStation {
    return switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.serve(inner, stations),
    };
}

pub fn stop_serving(reactor: *Host, stations: *[loops_max]CallStation) void {
    switch (reactor.loop.inner) {
        inline else => |*inner| reactor.dispatch.stop_serving(inner, stations),
    }
}

// The forwarders: each the loop's call of the same name.

pub fn dropped_wakes(reactor: *const Host) u64 {
    return reactor.loop.dropped_wakes();
}

pub fn cancel(reactor: *Host, handle: Handle) void {
    reactor.loop.cancel(handle);
}

pub fn post(reactor: *Host, target: LoopId, message: Message) Loop.PostError!void {
    return reactor.loop.post(target, message);
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
