//! The calls of `Reactor(Loop)` at step 2 of decision 33. Each one makes the call of the same name
//! on the loop that the reactor holds, and adds no work. The loop still holds the reactor's state
//! until step 3, which moves that state here and gives some of these calls a part of their own.
//! Split from `reactor.zig`, whose `Reactor` declares one alias for each function here.
//!
//! A call makes no check of its own. The loop's call makes each check, as the public `rotor.Loop`
//! leaves each check to its backend.
const core = @import("core");

const BufferGroup = core.BufferGroup;
const CallLink = core.call.CallLink;
const CallStation = core.call.CallStation;
const Descriptor = core.Descriptor;
const Event = core.Event;
const Handle = core.Handle;
const LoopId = core.LoopId;
const Message = core.Message;
const Operation = core.Operation;
const Poller = core.Poller;
const SchedulingGroup = core.SchedulingGroup;
const Task = core.Task;
const group_alignment = core.buffer_group.group_alignment;
const loops_max = core.constants.loops_max;
const memory_alignment = core.layout.memory_alignment;

/// The type that `function` returns. A twin of decision 10 picks its own error sets, so each call
/// returns what the loop's call of the same name returns.
fn Result(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

/// The calls of `Reactor`, which holds a `Loop` in its field `loop`.
pub fn Calls(comptime Reactor: type, comptime Loop: type) type {
    return struct {
        /// The bytes of memory that `init` needs: the loop's.
        pub fn memory_bytes(options: *const Reactor.Options) usize {
            return Loop.memory_bytes(&options.loop);
        }

        /// Starts the reactor in place, on the thread that will own it.
        pub fn init(
            reactor: *Reactor,
            memory: []align(memory_alignment) u8,
            options: *const Reactor.Options,
        ) Result(Loop.init) {
            return reactor.loop.init(memory, &options.loop);
        }

        pub fn deinit(reactor: *Reactor) void {
            reactor.loop.deinit();
        }

        pub fn dropped_wakes(reactor: *const Reactor) u64 {
            return reactor.loop.dropped_wakes();
        }

        pub fn submit(reactor: *Reactor, operations: []const Operation, handles: []Handle) u32 {
            return reactor.loop.submit(operations, handles);
        }

        pub fn cancel(reactor: *Reactor, handle: Handle) void {
            reactor.loop.cancel(handle);
        }

        pub fn post(reactor: *Reactor, target: LoopId, message: Message) Result(Loop.post) {
            return reactor.loop.post(target, message);
        }

        pub fn tick(reactor: *Reactor, events: []Event, wait_ns: u64) Result(Loop.tick) {
            return reactor.loop.tick(events, wait_ns);
        }

        pub fn add_poller(reactor: *Reactor, poller: *Poller) Result(Loop.add_poller) {
            return reactor.loop.add_poller(poller);
        }

        pub fn remove_poller(reactor: *Reactor, poller: *Poller) void {
            reactor.loop.remove_poller(poller);
        }

        pub fn schedule(reactor: *Reactor, task: *Task) Result(Loop.schedule) {
            return reactor.loop.schedule(task);
        }

        pub fn is_scheduled(reactor: *const Reactor, task: *const Task) bool {
            return reactor.loop.is_scheduled(task);
        }

        pub fn tasks_queued(reactor: *const Reactor) u32 {
            return reactor.loop.tasks_queued();
        }

        pub fn task_budget_left(reactor: *const Reactor) u32 {
            return reactor.loop.task_budget_left();
        }

        pub fn discard_tasks(reactor: *Reactor) u32 {
            return reactor.loop.discard_tasks();
        }

        pub fn schedule_in(reactor: *Reactor, group: SchedulingGroup, task: *Task) Result(Loop.schedule_in) {
            return reactor.loop.schedule_in(group, task);
        }

        pub fn charge_task(reactor: *Reactor, units: u16) void {
            reactor.loop.charge_task(units);
        }

        pub fn reserve_scheduling_group(reactor: *Reactor, shares: u16) Result(Loop.reserve_scheduling_group) {
            return reactor.loop.reserve_scheduling_group(shares);
        }

        pub fn set_scheduling_group_shares(reactor: *Reactor, group: SchedulingGroup, shares: u16) void {
            reactor.loop.set_scheduling_group_shares(group, shares);
        }

        /// The view that the program hands to each library (decision 28). Its address is the
        /// reactor's, so a library's calls reach the reactor. The loop's own `shared` makes the
        /// owner check, and the reactor drops the loop's view.
        pub fn shared(reactor: *Reactor) *Reactor.SharedLoop {
            _ = reactor.loop.shared();
            return @ptrCast(reactor);
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

        pub fn drain(reactor: *Reactor, scratch: []Event) Result(Loop.drain) {
            return reactor.loop.drain(scratch);
        }

        pub fn assert_empty(reactor: *const Reactor) void {
            reactor.loop.assert_empty();
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

        pub fn wait_limit(reactor: *Reactor) core.WaitLimit {
            return reactor.loop.wait_limit();
        }

        pub fn call(reactor: *Reactor, link: *CallLink) Result(Loop.call) {
            return reactor.loop.call(link);
        }

        pub fn answer(reactor: *Reactor, link: *CallLink) void {
            reactor.loop.answer(link);
        }

        pub fn serve(reactor: *Reactor, stations: *[loops_max]CallStation) *CallStation {
            return reactor.loop.serve(stations);
        }

        pub fn stop_serving(reactor: *Reactor, stations: *[loops_max]CallStation) void {
            reactor.loop.stop_serving(stations);
        }
    };
}
