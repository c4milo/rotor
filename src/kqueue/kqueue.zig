//! The `kqueue` module: the macOS backend (decisions 1 and 12), over kqueue. It imports `core`
//! and nothing else. kqueue reports readiness, so this backend performs each operation itself
//! when its descriptor is ready, and presents the caller the behaviour `uring` presents: the
//! conformance suite runs against both.
//!
//! `Loop` holds the state; the paths are one file each: `kqueue_submit.zig`, `kqueue_reap.zig`,
//! `kqueue_cancel.zig`, `kqueue_tick.zig`. What is the same on every kernel is `core.Tables`. A
//! loop belongs to the thread that initialised it, holds no lock and starts no thread
//! (decision 4).
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

pub const constants = @import("constants.zig");
pub const address = @import("kqueue_address.zig");
pub const buffers = @import("kqueue_buffers.zig");
const datagram_module = @import("kqueue_datagram.zig");
pub const cancel_module = @import("kqueue_cancel.zig");
pub const descriptors_module = @import("kqueue_descriptors.zig");
pub const errno = core.errno;
pub const group_module = @import("kqueue_group.zig");
pub const mailbox = core.mailbox;
pub const offload_module = @import("kqueue_offload.zig");
pub const perform = @import("kqueue_perform.zig");
pub const remote_module = @import("kqueue_remote.zig");
pub const queue_module = @import("kqueue_queue.zig");
pub const reap_module = @import("kqueue_reap.zig");
pub const submit_module = @import("kqueue_submit.zig");
pub const sync = @import("kqueue_sync.zig");
pub const testing = @import("kqueue_testing.zig");
pub const tick_module = @import("kqueue_tick.zig");
pub const wake_module = @import("kqueue_wake.zig");
/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Options.file_policy` and an offload mean anything here. kqueue reports readiness and never
/// completes a file operation, so this backend makes the `pread`, `pwrite` and `fsync` calls
/// itself and they block the loop thread (decision 18).
pub const files_block = true;

/// Whether a `post` can be refused for lack of room at the target, which decides what a caller
/// may assume of `mailbox_full` and what the conformance suite asserts (decision 4). A post sees
/// `core.constants.mailbox_posts_max` slots of a mailbox (decision 32), and a post to a ring that
/// holds that many is refused with `mailbox_full`, from a loop or from a `Remote`.
pub const post_bounded = true;

/// True on a host whose kernel this backend can run on. The conformance suite skips elsewhere.
pub const supported = @import("builtin").os.tag.isDarwin();

pub const Registry = mailbox.Registry;
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
const Kevent = queue_module.Kevent;

/// `Loop.group_watch` of a loop that is not in a group: no descriptor has this number.
pub const group_watch_none: usize = std.math.maxInt(usize);

pub const Loop = struct {
    queue: queue_module.Queue,
    /// What a loop holds whatever its kernel: the slot table, the timer heap, the pending and
    /// finished lists, the clock, the owner.
    tables: Tables,
    /// From a descriptor to the operations that wait for it to become ready.
    waiters: Waiters,
    /// The registrations the next `kevent` call carries in.
    changes: [constants.changes_max]Kevent,
    changes_used: u32,
    /// True from when a poll arms the loop's wake trigger until a call hands the wake event back.
    /// A poll whose readiness filled its room leaves the trigger set, and a tick that skipped its
    /// call (`kqueue_tick.zig`) would leave it for the next wait, which would then end at once.
    trigger_armed: bool,
    /// When the loop's wait timer fires, on the tick's clock, or 0 when it is not armed. A tick
    /// that blocks leaves an armed timer in place when it fires no later than the tick's own
    /// deadline, so the timer is armed about once per wait bound and not once per tick (decision
    /// 12, point 7). The reap sets it to 0 when the timer's event comes back.
    wait_timer_deadline_ns: u64,
    /// The kernel error of a tick that had already produced events, which the next tick returns
    /// before it drains anything (decision 5, amendment of 2026-11-06).
    kept_error: core.tick_error.Kept(TickError),
    /// The read end of this loop's wake pipe in a group, as the `ident` of the readiness that
    /// reports it, or `group_watch_none` (decision 21, point 3).
    group_watch: usize,
    /// The wakes this loop's posts asked for that the kernel refused since `init`, which
    /// `dropped_wakes` reads (decision 4, fourth amendment of 2026-11-06).
    dropped_wake_count: u64,
    /// In a registry of one process, the kqueue `deinit` points the registry's descriptor for this
    /// loop at, and -1 otherwise (`kqueue_wake.zig`).
    wake_stand_in: core.Descriptor,
    /// Where the `kevent` call writes the descriptors that became ready.
    readiness: [constants.readiness_max]Kevent,
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
    /// The provided-buffer groups `provide_buffers` named, by group id.
    groups: [core.constants.buffer_groups_max]buffers.Group,
    /// The group ids a caller reserved (decision 29). A provide halts on an id that is not here.
    buffer_groups: core.buffer_group.Reservations,
    /// The descriptors `register_descriptors` named, by index. `tables.descriptors_registered`
    /// says how many hold one.
    descriptors: [core.constants.registered_descriptors_max]core.Descriptor,

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, core.constants.operations_max].
        operations: u32,
        /// What the uring backend sizes its submission ring by, or 0 for its default. This
        /// backend sizes nothing by it, and takes it so that a caller's options are the same on
        /// both.
        entries: u16 = 0,
        /// How often the loop measures an operation (decision 9, rule 2).
        sampling: core.statistics.Options = .{},
        /// How long a tick polls without waiting before it blocks, in nanoseconds, at most
        /// `core.constants.spin_budget_ns_max` (decision 13). 0, the default, never polls. A loop
        /// with a budget answers a message that comes inside it without being woken, and spends
        /// the budget in CPU on every wait that outlasts it. A message that comes after the budget
        /// also arrives about 11 µs later than with no budget: 12.5 to 14.5 µs against 1.0 to 3.5,
        /// measured on macOS 26.6.2 on 2026-09-25 (decision 13, "kqueue").
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
    fn workers_of(options: *const Options) u16 {
        if (options.file_policy != .offload) return 0;
        return (options.offload orelse return 0).workers;
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
        _ = layout.add(core.waiters.Entry, Waiters.capacity_for(options.operations));
        // Nothing for an offload the options did not ask for, so a caller that wants none pays no
        // byte for one (decision 12, point 6 makes the same argument for the registry).
        // The rings are not here: the caller's threads write them, so the caller owns their
        // memory. `offload_module.memory_bytes` sizes those.
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
        options: *const Options,
    ) InitError!void {
        loop.init_tables(memory, options);
        loop.queue = try queue_module.Queue.init();
        errdefer loop.queue.deinit();
        const registry = loop.inbox.registry orelse return;
        const id = loop.tables.id;
        if (!registry.group) {
            // Senders wake the loop through a descriptor the registry keeps, which refers to this
            // kqueue until `deinit` (decision 4, amendment of 2026-11-06).
            const claimed = try wake_module.claim(registry, id, loop.queue.descriptor);
            loop.wake_stand_in = claimed.stand_in;
            return registry.set(id, claimed.send);
        }
        const wake = registry.wake(id).?;
        // In a group the loop is woken through the pipe its group's creator made for it, and every
        // sender writes there (decision 21, point 3).
        const watch = [1]Kevent{group_module.watch_event(wake.watch)};
        _ = loop.queue.exchange(&watch, &.{}, 0) catch return error.Unexpected;
        loop.group_watch = @intCast(wake.watch);
        registry.set(id, wake.send);
    }

    /// Everything but the kqueue: what the paths that enter no kernel run on.
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
        loop.offload = options.offload;
        loop.tables.init(slots, entries, starts, heartbeat_line, groups_table, .{
            .id = options.id,
            .sampling = options.sampling,
            .spin_budget_ns = options.spin_budget_ns,
            .stall_turn_ns = options.stall_turn_ns,
            .named_groups = options.named_groups,
        });
        loop.changes_used = 0;
        loop.trigger_armed = false;
        loop.wait_timer_deadline_ns = 0;
        loop.kept_error = .none;
        loop.group_watch = group_watch_none;
        loop.dropped_wake_count = 0;
        loop.wake_stand_in = -1;
        loop.groups = @splat(buffers.Group.none);
        loop.buffer_groups = .empty;
        loop.datagram_shape = .{};
    }

    /// Every operation must have had its final event (decision 5, rule 7), no tick may run, and no
    /// watch may read the heartbeat (decision 28).
    pub fn deinit(loop: *Loop) void {
        loop.tables.assert_owner();
        loop.tables.assert_ended(loop.kept_error.failure != null);
        if (loop.inbox.registry) |registry| {
            if (!registry.group) wake_module.release(registry, loop.tables.id, loop.wake_stand_in);
            registry.clear(loop.tables.id);
        }
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
    /// target's mailbox, and the target reads it when its wait ends (decision 4, fourth amendment).
    pub fn dropped_wakes(loop: *const Loop) u64 {
        return loop.dropped_wake_count;
    }

    /// The loop's kqueue: what a host that owns the wait sleeps on, in a wait of its own (decision
    /// 23). It turns readable when a descriptor an operation waits on is ready. The public
    /// `Loop.wait_descriptor` says what such a host does and what the descriptor does not report.
    /// Never null on this backend.
    pub fn wait_descriptor(loop: *const Loop) ?core.Descriptor {
        // A loop that has ended holds no kqueue, and a host that waited on -1 would never wake.
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
    /// woken before this returns, one `kevent` call per post, where post operations wake each
    /// target once per flush.
    pub fn post(loop: *Loop, target: core.LoopId, message: core.Message) core.remote.SendError!void {
        loop.tables.assert_owner();
        const registry = loop.inbox.registry;
        const wake = try core.remote.post_now(registry, loop.tables.id, target, message);
        const descriptor = wake orelse return;
        submit_module.wake_one(loop, registry.?.group, descriptor);
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
    /// hint in this file, and `docs/hot-path-ledger.md`, row H1, holds the numbers.
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
    /// Wakes loop `target` through `descriptor` after a call or an answer, as `post` does.
    pub fn wake_target(loop: *Loop, target: core.LoopId, descriptor: core.Descriptor) void {
        _ = target;
        submit_module.wake_one(loop, loop.inbox.registry.?.group, descriptor);
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
        const tables = &loop.tables;
        return loop.inbox.drain_mailboxes(tables.id, events, reap_module.take_reserved);
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
    _ = constants;
    _ = address;
    _ = buffers;
    _ = cancel_module;
    _ = descriptors_module;
    _ = errno;
    _ = group_module;
    _ = mailbox;
    _ = perform;
    _ = remote_module;
    _ = queue_module;
    _ = reap_module;
    _ = submit_module;
    _ = sync;
    _ = testing;
    _ = tick_module;
    _ = offload_module;
    _ = wake_module;
    _ = @import("kqueue_file_call.zig");
    _ = @import("kqueue_mailbox_test.zig");
    _ = @import("kqueue_offload_test.zig");
    _ = @import("kqueue_offload_held_test.zig");
    _ = @import("kqueue_perform_test.zig");
    _ = @import("kqueue_sync_socket_test.zig");
    _ = @import("kqueue_tick_test.zig");
    _ = @import("kqueue_tick_recover.zig");
    _ = @import("kqueue_loop_test_wakes.zig");
}
