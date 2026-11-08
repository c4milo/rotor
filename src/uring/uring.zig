//! The `uring` module: the Linux backend (decision 1), over io_uring. It imports `core` and
//! nothing else. Its pure parts, which turn a slot into a submission entry and a completion entry
//! into an event, compile and are tested on every host, with completion entries a test builds
//! itself (decision 10). Everything that enters the kernel is tested under Linux alone, by
//! `tools/linux_test.sh`.
//!
//! `Loop` holds the state; the paths are one file each: `uring_submit.zig`, `uring_reap.zig`,
//! `uring_cancel.zig`, `uring_tick.zig`. A loop belongs to the thread that initialised it, holds
//! no lock and starts no thread (decision 4).
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = core.assertion_class.assert_class_a;
const core = @import("core");

pub const constants = @import("constants.zig");
pub const address = @import("linux_shared").address;
pub const datagram_module = @import("uring_datagram.zig");
pub const buffers = @import("uring_buffers.zig");
pub const cancel_module = @import("uring_cancel.zig");
pub const descriptors = @import("uring_descriptors.zig");
pub const errno = @import("uring_errno.zig");
pub const reap_module = @import("uring_reap.zig");
pub const remote_module = @import("uring_remote.zig");
pub const ring_module = @import("uring_ring.zig");
pub const submit_module = @import("uring_submit.zig");
pub const sync = @import("uring_sync.zig");
pub const testing = @import("linux_shared").testing;
pub const tick_module = @import("uring_tick.zig");
pub const wake_module = @import("uring_wake.zig");

/// Where loops find each other's mailbox rings: `core.mailbox`'s, the one kqueue and epoll use.
/// Since 2026-09-25 a post on io_uring goes through these rings too, and `IORING_OP_MSG_RING`
/// only wakes a target that sleeps (decision 4, Camilo's ruling of that day).
pub const Registry = core.mailbox.Registry;
pub const group_module = @import("linux_shared").group;
pub const Remote = remote_module.Remote;
/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Options.file_policy` and an offload mean anything here. io_uring completes a file operation
/// without a thread, so there is nothing to hand out, and `Options.file_policy` is checked and then
/// ignored (decision 18).
pub const files_block = false;

/// Whether a `post` can be refused for lack of room at the target, which decides what a caller
/// may assume of `mailbox_full` and what the conformance suite asserts (decision 4). A post goes
/// through the mailbox ring the sender has to the target, of which it sees
/// `core.constants.mailbox_posts_max` slots (decision 32), so a full ring refuses it, as on kqueue
/// and epoll. Until
/// 2026-09-25 the message rode an `IORING_OP_MSG_RING` and was bounded by kernel memory alone.
pub const post_bounded = true;

/// True on a host whose kernel this backend can run on. The conformance suite skips elsewhere.
pub const supported = @import("builtin").os.tag == .linux;

pub const InitError = ring_module.InitError;
pub const TickError = tick_module.TickError;
pub const DrainError = TickError || error{ StillInFlight, TasksStillQueued };

/// True when this kernel refuses the ring this backend needs: `uring_ring.zig` says how it asks.
pub const refused = ring_module.refused;

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const Tables = core.Tables;
const TimerHeap = core.timer_heap.TimerHeap;
const Layout = core.layout.Layout;
const HandleQueue = cancel_module.HandleQueue;

pub const Loop = struct {
    ring: ring_module.Ring,
    /// What a loop holds whatever its kernel: the slot table, the timer heap, the pending and
    /// finished lists, the clock, the owner.
    tables: Tables,
    /// Handles `cancel` named whose operations the kernel holds, waiting for an entry.
    cancels: HandleQueue,
    /// The kernel's form of the address of each `connect` of the flush in progress. The kernel
    /// reads them while `enter` runs, and `tick` reuses the storage after it.
    addresses: []address.Storage,
    addresses_used: u32,
    /// One per submission entry, for a `receive_from` or a `send_to`: the kernel reads the
    /// `msghdr` while `io_uring_enter` runs, so it lives exactly as long as `addresses` does
    /// and is reused the same way (decision 15).
    messages: []datagram_module.Message,
    messages_used: u32,
    /// The reserve every datagram group of this loop uses, fixed by the first
    /// `provide_datagram_buffers`. One loop serves one shape, so the prefix a reap subtracts is a
    /// constant it already holds rather than a lookup per completion (decision 15).
    datagram_shape: core.datagram.Shape,
    /// `core.datagram.prefix_bytes(datagram_shape.options)`, held here because the reap subtracts
    /// it from every datagram completion and must not recompute it per event.
    datagram_prefix: i32,
    /// When the wait timer fires, on the tick's clock, or 0 when it is not armed. A tick that
    /// blocks leaves an armed timer in place when it fires no later than the tick's own deadline,
    /// so the timer is armed about once per wait bound and not once per tick (decision 6, amended
    /// 2026-09-27). The reap sets it to 0 when the timer's completion comes back.
    wait_timer_deadline_ns: u64,
    /// The kernel error of a tick that had already produced events, which the next tick returns
    /// before it drains anything (decision 5, amendment of 2026-11-06).
    kept_error: core.tick_error.Kept(TickError),
    /// The absolute time the wait timer's entries carry. The kernel reads it when it takes an
    /// entry, which can be a later tick's enter when the completion ring was full, so it lives in
    /// the loop and always holds the deadline the loop wants.
    wait_timer_timespec: std.os.linux.kernel_timespec,
    /// The mailbox rings other loops post to this one through, and the sleep flag they read to
    /// know whether to wake it (decision 12, point 6).
    inbox: core.inbox.Inbox,
    /// The loops this loop's posts must wake whose wake found no room in the submission ring yet.
    /// A tick does not block while one is left, so no wake is lost (`uring_submit.zig`).
    wakes: core.remote.Wakes,
    /// The wakes this loop dropped since `init`, which `dropped_wakes` reads. Only a refusal
    /// writes it: a refused answer, a refused group write, or a wake `deinit` could not send.
    dropped_wake_count: u64,
    /// In a group, the eventfd its creator made for this loop, and -1 outside one (decision 21,
    /// point 3). The loop keeps a poll of it in the ring.
    group_wake: core.Descriptor,
    /// True while the poll of it is in the ring. A tick does not block while it is not.
    group_wake_armed: bool,
    /// In a registry of one process, the eventfd `deinit` points the registry's descriptor for
    /// this loop at, and -1 otherwise (`uring_wake.zig`).
    wake_stand_in: core.Descriptor,
    /// The provided-buffer groups `provide_buffers` named, by group id.
    groups: [core.constants.buffer_groups_max]buffers.Group,
    /// The group ids a caller reserved (decision 29). A provide halts on an id that is not here.
    buffer_groups: core.buffer_group.Reservations,
    /// What is left of a coalesced datagram the reap is splitting (decision 15, amendment of
    /// 2026-11-05): the next reap hands it over before any new completion.
    split: core.datagram_split.Split,

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, core.constants.operations_max].
        operations: u32,
        /// Submission ring entries, a power of two in [1, constants.entries_max], or 0 for the
        /// default: `operations` rounded up to a power of two and capped at `entries_max`. One
        /// tick submits at most this many operations; the rest wait for the next.
        entries: u16 = 0,
        /// How often the loop measures an operation (decision 9, rule 2).
        sampling: core.statistics.Options = .{},
        /// How long a tick polls without waiting before it blocks, in nanoseconds, at most
        /// `core.constants.spin_budget_ns_max` (decision 13). 0, the default, never polls. A loop
        /// with a budget answers a message that comes inside it without being woken, and spends
        /// the budget in CPU on every wait that outlasts it.
        spin_budget_ns: u64 = 0,
        /// A turn of the loop at or above this, in nanoseconds, counts as a stall in
        /// `statistics()`, and null counts none (decision 28). A host that sleeps in its own wait
        /// sets null, because its sleep reads as one long turn (decision 23).
        stall_turn_ns: ?u64 = core.constants.stall_turn_ns_default,
        /// The program's named scheduling groups, which `init` reserves as ids 1 to n at their
        /// declared shares (decision 30). Empty by default. The public module sets it from the
        /// program's root file, so every loop of a program holds the same names.
        named_groups: core.scheduling.NamedTable = .empty,
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        /// Where loops find each other's mailbox rings. Null for a loop that posts to none and
        /// that none posts to.
        registry: ?*Registry = null,
        /// **Checked and ignored** (decision 18). The kernel performs `read`, `write` and
        /// `fdatasync` and `fsync` without a thread here, which is the whole point of this backend, so there is
        /// nothing to hand out and no policy to apply. It is in the options so that a caller's
        /// options are the same on every backend, as `entries` is on the others. `init` checks it
        /// with `offload` and `offload_memory` as kqueue and epoll do
        /// (`core.offload.assert_options`), so options that halt there halt here.
        file_policy: core.offload.FilePolicy = .refuse,
        /// Checked and ignored, for the same reason as `file_policy`: required when `file_policy`
        /// is `offload`, and refused otherwise.
        offload: ?core.offload.Offload = null,
        /// Checked and ignored, for the same reason as `file_policy`. This backend holds no ring for
        /// an offload and asks for no memory for one, but under the `offload` policy it requires
        /// `core.offload.Offload.memory_bytes(offload.?.workers)` bytes, as epoll does.
        offload_memory: []align(core.layout.memory_alignment) u8 = &.{},
    };

    /// The submission ring entries `options` asks for: its own, or the default derived from
    /// `operations` when it names none.
    pub fn entries_of(options: *const Options) u16 {
        if (options.entries != 0) return options.entries;
        const wanted: u32 = @min(options.operations, constants.entries_max);
        return @intCast(std.math.ceilPowerOfTwoAssert(u32, wanted));
    }

    /// The bytes of memory `init` needs for `options`, aligned to `core.layout.memory_alignment`.
    pub fn memory_bytes(options: *const Options) usize {
        var layout: Layout = .{};
        _ = layout.add(Slot, options.operations);
        _ = layout.add(TimerHeap.Entry, options.operations);
        _ = layout.add(u64, options.operations);
        // The heartbeat's line, which a watch on another thread reads (decision 28).
        _ = layout.add(core.Heartbeat, 1);
        // The scheduling groups, which a tick reads only while a group other than `.default`
        // holds a task (decision 30).
        _ = layout.add(core.scheduling.Groups, 1);
        _ = layout.add(Handle, HandleQueue.capacity_for(options.operations));
        _ = layout.add(address.Storage, entries_of(options));
        _ = layout.add(datagram_module.Message, entries_of(options));
        return layout.bytes;
    }

    /// Must run on the thread that will own the loop, after that thread is pinned: the ring
    /// binds to it, and the pages of `memory` it touches first land on its node (decision 4).
    pub fn init(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: *const Options,
    ) InitError!void {
        loop.init_tables(memory, options);
        loop.ring = try ring_module.Ring.init(entries_of(options));
        errdefer loop.ring.deinit();
        const registry = loop.inbox.registry orelse return;
        const id = loop.tables.id;
        if (!registry.group) {
            // Senders wake the loop through a descriptor the registry keeps, which refers to this
            // ring until `deinit` (decision 4, amendment of 2026-11-06).
            const claimed = try wake_module.claim(registry, id, loop.ring.descriptor());
            loop.wake_stand_in = claimed.stand_in;
            return registry.set(id, claimed.send);
        }
        // In a group the loop is woken through the eventfd its group's creator made for it, and
        // every sender writes there (decision 21, point 3). The first flush queues its poll.
        const wake = registry.wake(id).?;
        loop.group_wake = wake.watch;
        registry.set(id, wake.send);
    }

    /// Everything but the ring: what the paths that enter no kernel run on, so their tests
    /// build a loop on any host.
    pub fn init_tables(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: *const Options,
    ) void {
        assert(options.operations >= 1);
        assert(options.operations <= core.constants.operations_max);
        assert(memory.len >= memory_bytes(options));
        core.offload.assert_options(options.file_policy, options.offload, options.offload_memory);
        var layout: Layout = .{};
        const slots = layout.take(memory, Slot, options.operations);
        const entries = layout.take(memory, TimerHeap.Entry, options.operations);
        const starts = layout.take(memory, u64, options.operations);
        const heartbeat_line = &layout.take(memory, core.Heartbeat, 1)[0];
        const groups_table = &layout.take(memory, core.scheduling.Groups, 1)[0];
        const handles = layout.take(memory, Handle, HandleQueue.capacity_for(options.operations));
        loop.addresses = layout.take(memory, address.Storage, entries_of(options));
        loop.messages = layout.take(memory, datagram_module.Message, entries_of(options));
        assert(layout.bytes == memory_bytes(options));
        loop.tables.init(slots, entries, starts, heartbeat_line, groups_table, .{
            .id = options.id,
            .sampling = options.sampling,
            .spin_budget_ns = options.spin_budget_ns,
            .stall_turn_ns = options.stall_turn_ns,
            .named_groups = options.named_groups,
        });
        loop.cancels.init(handles);
        loop.addresses_used = 0;
        loop.messages_used = 0;
        loop.datagram_shape = .{};
        loop.datagram_prefix = @intCast(core.datagram.prefix_bytes(.{}));
        loop.split = .idle;
        loop.wait_timer_deadline_ns = 0;
        loop.kept_error = .none;
        loop.wait_timer_timespec = .{ .sec = 0, .nsec = 0 };
        loop.inbox = core.inbox.Inbox.init(options.registry, &.{}, null);
        loop.wakes = .{};
        loop.dropped_wake_count = 0;
        loop.group_wake = -1;
        loop.group_wake_armed = false;
        loop.wake_stand_in = -1;
        loop.groups = @splat(buffers.Group.none);
        loop.buffer_groups = .empty;
    }

    /// Every operation must have had its final event (decision 5, rule 7), no tick may run, and no
    /// watch may read the heartbeat (decision 28). Sends the wakes that
    /// the posts noted and no tick sent, before it frees the ring (decision 4, amended
    /// 2026-11-06). `dropped_wakes` says how many of them the kernel did not take.
    pub fn deinit(loop: *Loop) void {
        loop.deinit_through(submit_module.KernelEnter{});
    }

    /// `deinit`, with each enter that sends a noted wake made through `enters.enter(&loop.ring)`.
    /// A test hands it an answer the kernel gives only under load (`uring_submit.zig`).
    pub fn deinit_through(loop: *Loop, enters: anytype) void {
        loop.tables.assert_owner();
        loop.tables.assert_ended(loop.kept_error.failure != null);
        loop.dropped_wake_count += submit_module.send_noted_wakes(loop, enters);
        if (loop.inbox.registry) |registry| {
            if (!registry.group) wake_module.release(registry, loop.tables.id, loop.wake_stand_in);
            registry.clear(loop.tables.id);
        }
        loop.ring.deinit();
    }

    /// The wakes the loop dropped since `init`, read until the next `init` (decision 4, fourth
    /// amendment of 2026-11-06). The kernel answered a wake below 0, refused a group's write, or
    /// took no entry for a wake in `deinit`. A target that stopped refuses its wake, so a normal
    /// shutdown can leave it above 0. Each message is in its target's ring, and the target reads
    /// it when its wait ends, at most `core.constants.wait_ns_max` later.
    pub fn dropped_wakes(loop: *const Loop) u64 {
        return loop.dropped_wake_count;
    }

    /// Halts when an operation has not had its final event. `deinit` calls it before it touches
    /// the ring.
    pub fn assert_empty(loop: *const Loop) void {
        loop.tables.assert_empty();
    }

    /// Halts when another thread calls into the loop (decision 4).
    pub fn assert_owner(loop: *const Loop) void {
        loop.tables.assert_owner();
    }

    /// Operations submitted whose final event the caller has not been handed.
    pub fn in_flight(loop: *const Loop) u32 {
        return loop.tables.in_flight();
    }

    /// The monotonic clock in nanoseconds, as the last `tick` read it: at its start, or after its
    /// wait when it waited. Timers expire against this reading. A timer submitted now
    /// runs its `after_ns` from this reading, so it is due at this reading plus its `after_ns`, and
    /// fires no earlier (decision 14, rule 6). 0 until the first tick. Reading it makes no system
    /// call.
    pub fn now_ns(loop: *const Loop) u64 {
        return loop.tables.now_ns;
    }

    /// Null: an io_uring loop has nothing a host that owns the wait can sleep on (decision 23). The
    /// ring is set up with `DEFER_TASKRUN`, so the kernel posts a completion only when the loop's
    /// thread enters the ring. While that thread sleeps in another wait, with the ring's descriptor
    /// among what it waits on, no completion wakes it. A process whose host must sleep elsewhere
    /// requires the epoll backend before it makes a loop.
    pub fn wait_descriptor(loop: *const Loop) ?core.Descriptor {
        _ = loop;
        return null;
    }

    /// Claims a slot per operation until the table is full, and returns how many it took. Makes
    /// no system call: the next `tick` submits.
    pub fn submit(loop: *Loop, operations: []const Operation, handles: []Handle) u32 {
        loop.tables.assert_owner();
        return loop.tables.submit(operations, handles);
    }

    pub fn cancel(loop: *Loop, handle: Handle) void {
        loop.tables.assert_owner();
        cancel_module.cancel(loop, handle);
    }

    /// Sends `message` to loop `target` now, with no operation, so no slot and no event (decision
    /// 4, amended 2026-09-29). It fails as a post operation's event does: `LoopNotFound` for an id
    /// that runs no loop, `MailboxFull` when the ring to it has no room. The message is in the
    /// target's ring when this returns. A target that sleeps is woken by this loop's next tick,
    /// whose flush sends the wakes its posts noted with the tick's own submit, one per target. A
    /// loop that posts and then calls `deinit` with no tick between has its wakes sent by `deinit`.
    pub fn post(loop: *Loop, target: core.LoopId, message: core.Message) core.remote.SendError!void {
        loop.tables.assert_owner();
        const wake = try core.remote.post_now(loop.inbox.registry, loop.tables.id, target, message);
        if (wake != null) loop.wakes.note(target);
    }

    pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
        // With no poller and no record in flight, no callback can run in this tick, so the tick
        // skips the dispatch (decision 26).
        if (loop.tables.dispatch.idle()) return loop.tick_backend(events, wait_ns);
        return loop.tick_dispatched(events, wait_ns);
    }

    /// A tick that calls the pollers first and the records of the events last. It is marked cold
    /// so that the compiler keeps it out of `tick`: inline, it cost a program with no record 12
    /// instructions in each tick, in saved registers, on the work gate's post. Decision 7 allows the
    /// hint in this file, and `docs/hot-path-ledger.md`, row H2, holds the numbers.
    fn tick_dispatched(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
        @branchHint(.cold);
        const dispatch = &loop.tables.dispatch;
        // An error an earlier tick kept counts as an outstanding callback, so it brings the tick
        // here, and comes before any poller and any event (decision 5, amendment of 2026-11-06).
        try loop.kept_error.take(dispatch);
        const heartbeat_line = loop.tables.heartbeat;
        const wait = dispatch.begin(heartbeat_line, wait_ns);
        errdefer dispatch.abandon();
        const produced = try loop.tick_backend(events, wait);
        return dispatch.end(heartbeat_line, loop.tables.groups, events[0..produced]);
    }

    fn tick_backend(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
        const produced = if (core.spin.applies(loop.tables.spin.budget_ns, wait_ns))
            try tick_module.spin_then_wait(loop, events, wait_ns)
        else
            try tick_module.tick(loop, events, wait_ns);
        loop.tables.spin.note_handed_over(produced, loop.tables.now_ns);
        return produced;
    }

    // The pollers of decision 26 and the tasks of decision 27: `core.dispatch.Calls`.
    const dispatch_calls = core.dispatch.Calls(Loop);
    pub const add_poller = dispatch_calls.add_poller;
    pub const remove_poller = dispatch_calls.remove_poller;
    pub const schedule = dispatch_calls.schedule;
    pub const is_scheduled = dispatch_calls.is_scheduled;
    pub const tasks_queued = dispatch_calls.tasks_queued;
    pub const task_budget_left = dispatch_calls.task_budget_left;
    pub const discard_tasks = dispatch_calls.discard_tasks;
    // The scheduling groups of decision 30.
    pub const schedule_in = dispatch_calls.schedule_in;
    pub const charge_task = dispatch_calls.charge_task;
    pub const reserve_scheduling_group = dispatch_calls.reserve_scheduling_group;
    pub const set_scheduling_group_shares = dispatch_calls.set_scheduling_group_shares;
    // The view a library holds and the heartbeat of decision 28.
    pub const shared = dispatch_calls.shared;
    pub const heartbeat = dispatch_calls.heartbeat;
    // The host's wait limit of decision 29.
    pub const wait_limit = dispatch_calls.wait_limit;
    // The cross-core calls of decision 32.
    const call_calls = core.call.loop.Calls(Loop);
    pub const call = call_calls.call;
    pub const answer = call_calls.answer;
    pub const serve = call_calls.serve;
    pub const stop_serving = call_calls.stop_serving;
    pub const callbacks_outstanding = call_calls.callbacks_outstanding;
    /// Notes loop `target` after a call or an answer, as `post` does: the next tick's submit carries
    /// the wake.
    pub fn wake_target(loop: *Loop, target: core.LoopId, descriptor: core.Descriptor) void {
        _ = descriptor;
        loop.wakes.note(target);
    }

    /// Asks for the cancel of every operation in flight (decision 5, rule 7). Each still ends
    /// with its own final event, which `drain` or the caller's ticks hand over.
    pub fn cancel_all(loop: *Loop) void {
        loop.tables.cancel_all(loop, cancel_module.request);
    }

    /// Ticks until no operation is in flight, discarding the events into `scratch`: what a
    /// caller that is shutting down, and has no use for them, calls after `cancel_all`. Fails
    /// when the loop is still not empty after `core.constants.drain_rounds_max` ticks.
    pub fn drain(loop: *Loop, scratch: []Event) DrainError!void {
        const rounds_max = core.constants.drain_rounds_max;
        return core.shutdown.drain(loop, scratch, rounds_max, core.constants.drain_wait_ns);
    }

    /// What the loop has counted about itself, sampled (decision 9). Read by the caller alone.
    pub fn statistics(loop: *const Loop) *const core.statistics.Statistics {
        return &loop.tables.statistics;
    }

    pub const register_buffers = buffers.register;
    pub const register_descriptors = descriptors.register;
    pub const provide_buffers = buffers.provide;
    pub const give_back_buffer = buffers.give_back;
    pub const release_buffers = buffers.release;

    // The datagram groups of decision 15, and the reader of a provided buffer: `uring_buffers.zig`.
    pub const provide_datagram_buffers = buffers.provide_datagram_buffers;
    pub const datagram = buffers.datagram;
    pub const provided_buffer = buffers.provided_buffer;
    pub const reserve_buffer_group = buffers.reserve;

    /// Moves the messages other loops posted into `events`: `core.inbox`'s.
    pub fn drain_mailboxes(loop: *Loop, events: []Event) u32 {
        const tables = &loop.tables;
        return loop.inbox.drain_mailboxes(tables.id, events, &tables.dispatch, tables.groups, reap_module.take_reserved);
    }

    /// Tells the registry this loop is about to sleep, and looks at its mailboxes once more:
    /// `core.inbox`'s.
    pub fn settle_to_sleep(loop: *Loop, wait: ?u64) ?u64 {
        return loop.inbox.settle_to_sleep(loop.tables.id, wait);
    }

    /// Tells the registry the loop is awake again.
    pub fn wake_up(loop: *Loop) void {
        loop.inbox.wake_up(loop.tables.id);
    }
};

comptime {
    core.surface.check(Loop);
    core.surface.check_remote(Remote);
}

test {
    _ = constants;
    _ = address;
    _ = buffers;
    _ = cancel_module;
    _ = descriptors;
    _ = errno;
    _ = reap_module;
    _ = remote_module;
    _ = ring_module;
    _ = submit_module;
    _ = sync;
    _ = tick_module;
    _ = wake_module;
    _ = @import("uring_group.zig");
    _ = @import("uring_reap_test.zig");
    _ = @import("uring_submit_test.zig");
    _ = @import("uring_loop_test.zig");
    _ = @import("uring_loop_test_wakes.zig");
}
