//! The `epoll` module: the second Linux backend (decision 20), for a host that refuses io_uring. It
//! imports `core` and nothing else.
//!
//! epoll reports readiness, so this backend is `kqueue`'s shape and not `uring`'s: it performs each
//! operation itself when the descriptor is ready, and emulates multishot and provided buffer groups
//! in user space because epoll has neither. The conformance suite runs against it unchanged, and in
//! Docker under the default seccomp profile, which is the environment that justifies it.
//!
//! `Loop` holds the state; the paths are one file each, as on kqueue. What is the same on every
//! kernel is `core.Tables`. A loop belongs to the thread that initialised it, holds no lock and
//! starts no thread (decision 4).
//!
//! Two things differ from `kqueue`'s `Loop`. There is no changelist, because `epoll_ctl` takes one
//! descriptor per call and has no batched form, so a registration is made as it is needed and
//! nothing accumulates. And `readiness` holds `linux.epoll_event` rather than `Kevent`.
//!
//! **No speed claim is made for this backend.** epoll has none of decision 3's speed sources: no
//! registered descriptors, no provided buffer rings, no multishot, no batched submission. It exists
//! so that rotor runs where io_uring does not, and the comparison gains no row for it.
//!
//! Every organ is `kqueue`'s file by file, with Linux's calls. The waiters table, the mailboxes,
//! the errno map and the offload's rings are `core`'s and shared with `kqueue`; the address
//! conversion, the clock and the test support are `linux_shared`'s, shared with `uring`, because
//! both Linux backends convert to the same Linux structures.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = core.assertion_class.assert_class_a;
const core = @import("core");

pub const constants = @import("constants.zig");
pub const address = @import("linux_shared").address;
pub const buffers = @import("epoll_buffers.zig");
const datagram_module = @import("epoll_datagram.zig");
pub const cancel_module = @import("epoll_cancel.zig");
pub const descriptors_module = @import("epoll_descriptors.zig");
pub const errno = core.errno;
pub const mailbox = core.mailbox;
pub const offload_module = @import("epoll_offload.zig");
pub const perform = @import("epoll_perform.zig");
pub const queue_module = @import("epoll_queue.zig");
pub const reap_module = @import("epoll_reap.zig");
pub const remote_module = @import("epoll_remote.zig");
pub const submit_module = @import("epoll_submit.zig");
pub const sync = @import("epoll_sync.zig");
pub const testing = @import("linux_shared").testing;
pub const tick_module = @import("epoll_tick.zig");
pub const wake_module = @import("epoll_wake.zig");

/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Options.file_policy` and an offload mean anything here. epoll reports readiness and never
/// reports a regular file as anything but ready, exactly as kqueue does not report one at all, so
/// this backend makes the `pread`, `pwrite` and `fsync` calls itself and they block the loop thread
/// (decisions 18 and 20).
pub const files_block = true;

/// Whether a `post` can be refused for lack of room at the target (decision 4). The mailbox rings
/// are `core`'s and hold `core.constants.mailbox_messages`, as on every backend, so a post to a
/// full one is refused with `mailbox_full`.
pub const post_bounded = true;

/// True on a host whose kernel this backend can run on. The conformance suite skips elsewhere.
pub const supported = @import("builtin").os.tag == .linux;

/// The rings are `core`'s, and so is the table of which loop is where: this backend's `post` is
/// every backend's, `core.remote.post` (decision 20, open question 3; decision 4, amended
/// 2026-09-25).
pub const Registry = core.mailbox.Registry;
pub const group_module = @import("linux_shared").group;
pub const Remote = remote_module.Remote;
pub const InitError = queue_module.InitError;
pub const TickError = tick_module.TickError;
pub const DrainError = TickError || error{ StillInFlight, TasksStillQueued };

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const Tables = core.Tables;
const TimerHeap = core.timer_heap.TimerHeap;
const Layout = core.layout.Layout;
const Waiters = core.waiters.Waiters;

pub const Loop = struct {
    queue: queue_module.Queue,
    /// What a loop holds whatever its kernel: the slot table, the timer heap, the pending and
    /// finished lists, the clock, the owner.
    tables: Tables,
    /// From a descriptor to the operations that wait for it to become ready.
    waiters: Waiters,
    /// Where the `epoll_pwait2` call writes the descriptors that became ready. There is no
    /// changelist beside it: kqueue carries its registrations in the call that waits, and
    /// `epoll_ctl` has no batched form, so each registration is its own call as it is needed
    /// (decision 20, "The shape").
    readiness: [constants.readiness_max]queue_module.Event,
    /// When the wait timer fires, on the tick's clock, or 0 when it is not armed. A tick that
    /// blocks leaves an armed timer in place when it fires no later than the tick's own deadline,
    /// so the timer is armed about once per wait bound and not once per tick (decision 20, "The
    /// wait timer"). The reap sets it to 0 when the timer's readiness comes back.
    wait_timer_deadline_ns: u64,
    /// The kernel error of a tick that had already produced events, which the next tick returns
    /// before it drains anything (decision 5, amendment of 2026-11-06).
    kept_error: core.tick_error.Kept(TickError),
    /// The wakes this loop's posts asked for that the kernel refused since `init`, which
    /// `dropped_wakes` reads. Only a refusal writes it (decision 4, fourth amendment of
    /// 2026-11-06).
    dropped_wake_count: u64,
    /// What other threads send this loop, and the sleep handshake that wakes it for them.
    inbox: core.inbox.Inbox,
    /// What this loop does with a file operation it cannot perform without blocking (decision 18).
    file_policy: core.offload.FilePolicy,
    /// The caller's offload, set when `file_policy` is `offload` and null otherwise.
    offload: ?core.offload.Offload,
    /// One per slot, filled when an operation is handed out. Empty unless the policy is `offload`.
    works: []core.offload.Work,
    /// The reserve every datagram group of this loop uses, fixed by the first
    /// `provide_datagram_buffers` (decision 15). One loop serves one shape, so a receive knows
    /// where a datagram starts without a lookup per completion.
    datagram_shape: core.datagram.Shape,
    /// What is left of a coalesced datagram the reap is splitting (decision 15, amendment of
    /// 2026-11-05): the next reap hands it over before any new readiness.
    split: core.datagram_split.Split,
    /// How many reaps this loop has made, wrapping. A datagram receive the reap before this one also
    /// served asks for a larger batch (`epoll_reap.zig`, `batch_size`).
    reaps: u32,
    /// The provided-buffer groups `provide_buffers` named, by group id.
    groups: [core.constants.buffer_groups_max]buffers.Group,
    /// The group ids a caller reserved (decision 29). A provide halts on an id that is not here.
    buffer_groups: core.buffer_group.Reservations,
    /// The descriptors `register_descriptors` named, by index. `tables.descriptors_registered`
    /// says how many hold one.
    descriptors: [core.constants.registered_descriptors_max]core.Descriptor,
    /// What one `recvmmsg` of a datagram receive needs beside its buffers. Last, because only a
    /// readiness of a datagram socket reads it.
    batch: datagram_module.Batch,

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, core.constants.operations_max].
        operations: u32,
        /// What the uring backend sizes its submission ring by, or 0 for its default. This
        /// backend sizes nothing by it, and takes it so that a caller's options are the same on
        /// every backend.
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
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        registry: ?*Registry = null,
        /// What the loop does with `read`, `write` and `fdatasync`, which this backend cannot
        /// perform without blocking (decision 18). The uring backend checks it and ignores it.
        file_policy: core.offload.FilePolicy = .refuse,
        /// The caller's threads, required when `file_policy` is `offload` and refused otherwise.
        offload: ?core.offload.Offload = null,
        /// Memory for the offload's rings, of at least
        /// `offload_module.memory_bytes(offload.?.workers)`. The caller owns it because its own
        /// threads write it, as the application owns the registry's.
        offload_memory: []align(core.layout.memory_alignment) u8 = &.{},
    };

    /// The workers `options` asks the loop to hold rings for: the offload's, or none.
    fn workers_of(options: Options) u16 {
        if (options.file_policy != .offload) return 0;
        return (options.offload orelse return 0).workers;
    }

    /// The bytes of memory `init` needs for `options`, aligned to `core.layout.memory_alignment`.
    pub fn memory_bytes(options: Options) usize {
        var layout: Layout = .{};
        _ = layout.add(Slot, options.operations);
        _ = layout.add(TimerHeap.Entry, options.operations);
        _ = layout.add(u64, options.operations);
        // The heartbeat's line, which a watch on another thread reads (decision 28).
        _ = layout.add(core.Heartbeat, 1);
        _ = layout.add(core.waiters.Entry, Waiters.capacity_for(options.operations));
        // Nothing for an offload the options did not ask for, so a caller that wants none pays no
        // byte for one. The rings are not here: the caller's threads write them, so the caller
        // owns their memory. `core.offload.Offload.memory_bytes` sizes those.
        // `Layout.add` takes at least one entry, so a loop with no offload adds nothing at all.
        if (workers_of(options) != 0) {
            _ = layout.add(core.offload.Work, options.operations);
            // The operations out, which a close reads to learn whether it must wait (decision 18,
            // ruling (d) of 2026-11-06).
            _ = layout.add(core.offload.Out, core.constants.offload_in_flight_max);
        }
        return layout.bytes;
    }

    /// Must run on the thread that will own the loop (decision 4).
    pub fn init(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: Options,
    ) InitError!void {
        loop.init_tables(memory, options);
        const registry = loop.inbox.registry orelse {
            loop.queue = try queue_module.Queue.init();
            return;
        };
        // The loop waits on the eventfd the registry keeps for its id: in a group, the one the
        // creator made (decision 21, point 3); in one process, the one the first loop of the id
        // made. No loop closes it, so a sender never writes to a number reused by another open
        // (decision 4, amendment of 2026-11-06).
        const wake = try wake_module.claim(registry, loop.tables.id);
        loop.queue = try queue_module.Queue.init_borrowed(wake.watch);
        // The eventfd and not the epoll instance: a post wakes a loop by writing to the descriptor
        // the registry holds, and an epoll descriptor cannot be written to.
        registry.set(loop.tables.id, wake.send);
    }

    /// Everything but the epoll instance: what the paths that enter no kernel run on.
    pub fn init_tables(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: Options,
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
        const waiting = Waiters.capacity_for(options.operations);
        loop.waiters.init(layout.take(memory, core.waiters.Entry, waiting));
        const workers = workers_of(options);
        loop.works = if (workers == 0)
            &.{}
        else
            layout.take(memory, core.offload.Work, options.operations);
        const out_max = core.constants.offload_in_flight_max;
        const out: ?*core.offload.OutArray = if (workers == 0)
            null
        else
            layout.take(memory, core.offload.Out, out_max)[0..out_max];
        assert(layout.bytes == memory_bytes(options));
        const completions = offload_module.init_rings(options.offload_memory, workers);
        loop.inbox = core.inbox.Inbox.init(options.registry, completions, out);
        loop.file_policy = options.file_policy;
        loop.wait_timer_deadline_ns = 0;
        loop.kept_error = .none;
        loop.dropped_wake_count = 0;
        loop.offload = options.offload;
        loop.tables.init(slots, entries, starts, heartbeat_line, .{
            .id = options.id,
            .sampling = options.sampling,
            .spin_budget_ns = options.spin_budget_ns,
            .stall_turn_ns = options.stall_turn_ns,
        });
        loop.groups = @splat(buffers.Group.none);
        loop.buffer_groups = .empty;
        loop.datagram_shape = .{};
        loop.split = .idle;
        loop.reaps = 0;
    }

    /// Every operation must have had its final event (decision 5, rule 7), no tick may run, and no
    /// watch may read the heartbeat (decision 28).
    pub fn deinit(loop: *Loop) void {
        loop.tables.assert_owner();
        loop.tables.assert_ended();
        if (loop.inbox.registry) |registry| registry.clear(loop.tables.id);
        loop.queue.deinit();
    }

    pub fn assert_empty(loop: *const Loop) void {
        loop.tables.assert_empty();
    }

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

    /// The wakes the loop dropped since `init`: each one its `post` or a flush asked for and the
    /// kernel refused. It stays readable after `deinit`, until the next `init`. A target that
    /// stopped refuses its wake, so a normal shutdown can leave it above 0. Each message is in its
    /// target's mailbox, and the target reads it when its wait ends (decision 4, fourth amendment
    /// of 2026-11-06).
    pub fn dropped_wakes(loop: *const Loop) u64 {
        return loop.dropped_wake_count;
    }

    /// The loop's epoll instance: what a host that owns the wait sleeps on, in a wait of its own
    /// (decision 23). It turns readable when a descriptor an operation waits on is ready. It is the
    /// epoll instance and not the eventfd that wakes the loop, which reports a post and nothing
    /// else. The public `Loop.wait_descriptor` says what such a host does and what the descriptor
    /// does not report. Never null on this backend.
    pub fn wait_descriptor(loop: *const Loop) ?core.Descriptor {
        // A loop that has ended holds no epoll instance, and a host that waited on -1 would never
        // wake.
        assert(loop.queue.descriptor >= 0);
        return loop.queue.descriptor;
    }

    /// Claims a slot per operation until the table is full, and returns how many it took. Makes
    /// no system call: the next `tick` tries them.
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
    /// that runs no loop, `MailboxFull` when the ring to it has no room. A target that sleeps is
    /// woken before this returns, one eventfd write per post, where post operations wake each
    /// target once per flush. In a group the descriptor is the group's eventfd, written the same way.
    pub fn post(loop: *Loop, target: core.LoopId, message: core.Message) core.remote.SendError!void {
        loop.tables.assert_owner();
        const wake = try core.remote.post_now(loop.inbox.registry, loop.tables.id, target, message);
        const descriptor = wake orelse return;
        if (!queue_module.Queue.wake_sent(descriptor)) loop.dropped_wake_count += 1;
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
    /// hint in this file, and `docs/hot-path-ledger.md`, row H3, holds the numbers.
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
        return dispatch.end(heartbeat_line, events[0..produced]);
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
    // The view a library holds and the heartbeat of decision 28.
    pub const shared = dispatch_calls.shared;
    pub const heartbeat = dispatch_calls.heartbeat;
    // The host's wait limit of decision 29.
    pub const wait_limit = dispatch_calls.wait_limit;

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
    pub const register_descriptors = descriptors_module.register;
    pub const provide_buffers = buffers.provide;
    pub const give_back_buffer = buffers.give_back;
    pub const release_buffers = buffers.release;

    pub const provide_datagram_buffers = buffers.provide_datagram_buffers;
    pub const datagram = buffers.datagram;
    pub const provided_buffer = buffers.provided_buffer;
    pub const reserve_buffer_group = buffers.reserve;

    /// Moves the messages other loops posted into `events`: `core.inbox`'s.
    pub fn drain_mailboxes(loop: *Loop, events: []Event) u32 {
        return loop.inbox.drain_mailboxes(loop.tables.id, events, &loop.tables.dispatch);
    }

    /// Tells the registry and the offload's workers this loop is about to sleep: `core.inbox`'s.
    pub fn settle_to_sleep(loop: *Loop, wait: ?u64) ?u64 {
        return loop.inbox.settle_to_sleep(loop.tables.id, wait);
    }

    /// Tells the registry, and the offload's workers, that the loop is awake again.
    pub fn wake_up(loop: *Loop) void {
        loop.inbox.wake_up(loop.tables.id);
    }
};

comptime {
    core.surface.check(Loop);
    core.surface.check_remote(Remote);
}

test {
    _ = @import("epoll_file_call.zig");
    _ = @import("epoll_loop_test.zig");
    _ = @import("epoll_loop_test_wakes.zig");
    _ = constants;
    _ = address;
    _ = buffers;
    _ = datagram_module;
    _ = cancel_module;
    _ = descriptors_module;
    _ = offload_module;
    _ = perform;
    _ = queue_module;
    _ = reap_module;
    _ = remote_module;
    _ = submit_module;
    _ = sync;
    _ = testing;
    _ = tick_module;
    _ = wake_module;
}
