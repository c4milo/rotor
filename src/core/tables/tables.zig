//! `Tables`: what a loop holds and does whatever kernel it runs on. Every backend embeds one, so
//! a slot is claimed, a deadline fires, a cancel is asked for and a final event is handed over
//! by the same code on io_uring, kqueue and epoll (decisions 5 and 11). What differs between them
//! is what happens to an operation the kernel holds, and that stays in the backend.
//!
//! A loop belongs to the thread that initialised it (decision 4). `assert_owner` compares the
//! address of a thread-local byte against the one `init` recorded: one thread-local address and
//! one compare (C21), with no system call.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("../assertion_class.zig").assert_class_a;
const constants = @import("../constants.zig");
const event_module = @import("../event.zig");
const handle_module = @import("../handle.zig");
const operation_module = @import("../operation.zig");
const slot_module = @import("../slot.zig");
const slot_list_module = @import("../slot_list.zig");
const slot_table_module = @import("../slot_table.zig");
const statistics_module = @import("../statistics.zig");
const spin_module = @import("../spin.zig");
const timer_heap_module = @import("../timer_heap.zig");
const waiters_module = @import("../waiters.zig");
const deadline = @import("tables_deadline.zig");
const finish_module = @import("tables_finish.zig");
const Dispatch = @import("../dispatch/dispatch.zig").Dispatch;
const Heartbeat = @import("../stall.zig").Heartbeat;
const Shuffle = @import("../shuffle.zig").Shuffle;

const Code = event_module.Code;
const Descriptor = operation_module.Descriptor;
const Event = event_module.Event;
const Handle = handle_module.Handle;
const LoopId = operation_module.LoopId;
const Operation = operation_module.Operation;
const Slot = slot_module.Slot;
const SlotList = slot_list_module.SlotList;
const SlotTable = slot_table_module.SlotTable;
const Statistics = statistics_module.Statistics;
const TimerHeap = timer_heap_module.TimerHeap;

/// One per thread, and its address is that thread's identity.
threadlocal var thread_marker: u8 = 0;

/// The calling thread's identity: the address of its `thread_marker`. A loop records it at init
/// and compares it at every entry point; a `Remote` does the same (decision 4).
pub fn thread_identity() usize {
    return @intFromPtr(&thread_marker);
}

/// What the backend must do about a cancel that `request_cancel` accepted.
pub const CancelAction = enum {
    /// Nothing: the operation was already marked, was still queued, or was a timer, which the
    /// tables ended themselves.
    none,
    /// The kernel holds the operation, and only the backend can reach it there.
    backend,
};

pub const Tables = struct {
    table: SlotTable,
    timers: TimerHeap,
    /// Slots that are `queued`, oldest first: claimed, and waiting for the backend's flush.
    pending: SlotList,
    /// Slots that are `finishing`, oldest first: each holds in `Slot.result` the result of the
    /// event the next `drain_finished` hands over. That event is final, except for a repeating
    /// timer that was not cancelled, whose event is one fire flagged `more`.
    finished: SlotList,
    /// Due timers, oldest first, in the order they came due: each slot is `finishing` and holds its
    /// fire in `Slot.result`. A list of its own, so a long `finished` list cannot hold a due timer
    /// off, and a stream of due timers cannot hold `finished` off (W3, ruled 2026-11-07).
    fired: SlotList,
    /// The monotonic clock as the backend's tick last read it.
    now_ns: u64,
    /// The loop's heartbeat, on a line of its own in the caller's memory (decision 28). A watch on
    /// another thread reads that line, so the words of `Tables`, which every tick reads, stay on
    /// lines that a watch never moves. Each clock stamp writes it, next to `now_ns`.
    heartbeat: *Heartbeat,
    /// Operations accepted since init: what a sampling decision is a function of (decision 9).
    operation_sequence: u64,
    /// What the loop counts about itself, sampled (decision 9). The loop writes here and never
    /// reads: no branch anywhere depends on a statistic.
    statistics: Statistics,
    /// The address of the owning thread's `thread_marker`.
    owner: usize,
    /// Descriptors the loop registered: 0 until `note_descriptors`.
    descriptors_registered: u32,
    /// Buffers the loop registered: 0 until `note_buffers`.
    buffers_registered: u16,
    id: LoopId,
    /// The spin budget from the options, and when the loop last handed over an event (decision 13).
    spin: spin_module.Window,
    /// The pollers, the count of operations that named a record (decision 26), and the task queue
    /// (decision 27).
    dispatch: Dispatch,
    /// The generator of the seeded shuffle of each reaped batch, which only a test build carries
    /// (decision 10, amendment of 2026-11-06). Off, it has no bytes.
    shuffle: Shuffle,

    pub const Options = struct {
        id: LoopId = 0,
        sampling: statistics_module.Options = .{},
        spin_budget_ns: u64 = 0,
        /// A turn at or above this is a stall, and null counts none (decision 28).
        stall_turn_ns: ?u64 = constants.stall_turn_ns_default,
    };

    /// Must run on the thread that will own the loop. `starts` holds one nanosecond stamp per
    /// slot, for the sampled operations in flight. `heartbeat` is the loop's line for a watch
    /// (decision 28), which a backend carves with `Layout.take`; `init` writes it.
    pub fn init(
        tables: *Tables,
        slots: []Slot,
        entries: []TimerHeap.Entry,
        starts: []u64,
        heartbeat: *Heartbeat,
        options: Options,
    ) void {
        assert(options.id < constants.loops_max);
        assert(options.spin_budget_ns <= constants.spin_budget_ns_max);
        assert(entries.len == slots.len);
        assert(starts.len == slots.len);
        tables.table.init(slots);
        tables.timers.init(entries, slots);
        tables.statistics.init(options.sampling, starts);
        tables.pending = SlotList.empty;
        tables.finished = SlotList.empty;
        tables.fired = SlotList.empty;
        tables.now_ns = 0;
        heartbeat.* = .init(options.stall_turn_ns);
        tables.heartbeat = heartbeat;
        tables.operation_sequence = 0;
        tables.owner = thread_identity();
        tables.descriptors_registered = 0;
        tables.buffers_registered = 0;
        tables.id = options.id;
        tables.spin = .{ .budget_ns = options.spin_budget_ns, .active_ns = 0 };
        tables.dispatch = .empty;
        tables.shuffle = .init(options.id);
    }

    /// Records that the backend registered `count` descriptors: once per loop, before an
    /// operation names one (decision 2).
    pub fn note_descriptors(tables: *Tables, count: usize) void {
        assert(tables.descriptors_registered == 0);
        assert(count >= 1);
        assert(count <= constants.registered_descriptors_max);
        tables.descriptors_registered = @intCast(count);
    }

    /// Records that the backend registered `count` buffers: once per loop, before an operation
    /// names one (decision 3, source 1).
    pub fn note_buffers(tables: *Tables, count: usize) void {
        assert(tables.buffers_registered == 0);
        assert(count >= 1);
        assert(count <= constants.registered_buffers_max);
        tables.buffers_registered = @intCast(count);
    }

    /// Halts when another thread calls into the loop: a call from the wrong thread is a
    /// programmer error, and by the time it is seen the tables may already be torn.
    pub fn assert_owner(tables: *const Tables) void {
        assert(tables.owner == thread_identity());
    }

    /// What every backend's `tick` checks once, on entry (decision 8, class B): the calling thread
    /// owns the loop, `events` has room for one event and for no more than a batch, and the wait is
    /// one the loop allows. Until 2026-09-23 each backend made these checks itself, and kqueue and
    /// epoll checked the wait only inside `wait_bound`, which a tick with events to hand over never
    /// calls, so a wait io_uring refused passed on those backends.
    pub fn begin_tick(tables: *const Tables, events_len: usize, wait_ns: u64) void {
        tables.assert_owner();
        assert(events_len >= 1);
        assert(events_len <= constants.batch_max);
        assert(wait_ns <= constants.wait_ns_max);
    }

    /// A tick's first clock stamp (R1): it becomes `now_ns`, and ends the open turn, which the
    /// heartbeat counts when it is a stall (decision 28).
    pub fn note_clock(tables: *Tables, now_ns: u64) void {
        tables.now_ns = now_ns;
        tables.heartbeat.note_clock(&tables.statistics, &tables.dispatch.pollers, now_ns);
    }

    /// The tick is about to block in a kernel wait, which is in no turn (decision 28).
    pub fn note_asleep(tables: *Tables) void {
        tables.heartbeat.note_asleep();
    }

    /// The clock stamp after a wait that blocked (R2, decision 9, rule 4): it becomes `now_ns`, and
    /// starts a turn, which it does not count (decision 28).
    pub fn note_woken(tables: *Tables, now_ns: u64) void {
        tables.now_ns = now_ns;
        tables.heartbeat.note_woken(now_ns);
    }

    /// What every backend's `deinit` checks: the loop is empty, no tick runs, and no watch reads
    /// its heartbeat (decisions 5, 26, 27 and 28).
    pub fn assert_ended(tables: *const Tables) void {
        tables.assert_empty();
        tables.heartbeat.assert_unwatched();
    }

    /// Halts when an operation has not had its final event (decision 5, rule 7).
    pub fn assert_empty(tables: *const Tables) void {
        assert(tables.in_flight() == 0);
        // A slot on a list is a slot in use, so no caller's mistake reaches this line alone: it
        // holds the lists to the table.
        assert(tables.pending.count == 0 and tables.finished.count == 0 and tables.fired.count == 0);
        tables.dispatch.assert_empty();
    }

    /// Operations submitted whose final event the caller has not been handed.
    pub fn in_flight(tables: *const Tables) u32 {
        return tables.table.in_use();
    }

    /// Claims a slot for each operation, in order, until the table is full, and returns how many
    /// it took. Writes each taken operation's handle to `handles` when the caller passed any.
    /// Enters no kernel: the backend's next tick flushes the pending list.
    pub fn submit(tables: *Tables, operations: []const Operation, handles: []Handle) u32 {
        assert(operations.len <= constants.batch_max);
        assert(handles.len == 0 or handles.len == operations.len);
        var taken: u32 = 0;
        // Summed here and added once after the loop, so the count stays in a register.
        var records: u32 = 0;
        for (operations) |*operation| {
            operation.assert_valid();
            if (operation.descriptor_registered) {
                assert(operation.descriptor().? < tables.descriptors_registered);
            }
            const index = tables.table.claim() orelse break;
            const slot = tables.table.at(index);
            slot.fill(operation);
            // A timer's delay runs from the reading the caller sees now (decision 14, rule 6).
            // `fill` left a timer's buffer at 0, and `arm` reads this from it.
            if (slot.code == .timer) slot.buffer = tables.now_ns;
            // A buffer the loop never registered: kqueue and epoll would ignore the index and
            // io_uring would hand the kernel a bad one, so the mistake halts on every backend.
            if (slot.flags.buffer_registered) assert(slot.buffer_index < tables.buffers_registered);
            const sequence = tables.operation_sequence +% taken;
            tables.statistics.submitted(sequence, index, slot, tables.now_ns);
            records += @intFromBool(operation.dispatched);
            // A loop that posts to itself would wait on an event only its own tick can produce.
            assert_class_a(slot.code != .post or slot.descriptor != tables.id);
            tables.pending.push(tables.table.slots, index);
            if (handles.len != 0) handles[taken] = tables.table.handle_of(index);
            taken += 1;
        }
        tables.operation_sequence +%= taken;
        tables.dispatch.note_submitted(records);
        assert(taken <= operations.len);
        return taken;
    }

    /// The kernel produced the operation's last completion: its deadline is disarmed and its
    /// slot released, as the event is handed to the caller (decision 5, rule 1).
    pub fn finish(tables: *Tables, index: u32, slot: *Slot) void {
        assert_class_a(slot.state == .submitted);
        if (slot.flags.sampled) tables.statistics.finished(index, slot, tables.now_ns);
        if (slot.heap_position != slot_module.heap_position_none) tables.timers.disarm(index);
        tables.table.release(index);
    }

    /// The oldest queued slot a backend must hand to its kernel, still queued, or null when none is
    /// left. On the way it ends every slot at the head of the list whose cancel came while it
    /// waited, and arms every timer there: neither reaches a kernel (decision 5, rule 2). Every
    /// backend's flush calls it, checks its own room, and then calls `take_pending`.
    pub fn next_pending(tables: *Tables) ?u32 {
        const queued = tables.pending.count;
        var visited: u32 = 0;
        while (visited < queued) : (visited += 1) {
            const index = tables.pending.peek() orelse return null;
            const slot = tables.table.at(index);
            assert_class_a(slot.state == .queued);
            if (!slot.flags.cancel_requested and slot.code != .timer) return index;
            tables.take_pending(index);
            if (slot.flags.cancel_requested) {
                tables.finish_canceled(index);
            } else {
                tables.hand_over(index, slot);
            }
        }
        return null;
    }

    /// Takes `index`, the slot `next_pending` answered, off the pending list: the backend hands it
    /// to its kernel now, or ends it itself.
    pub fn take_pending(tables: *Tables, index: u32) void {
        const taken = tables.pending.pop(tables.table.slots);
        assert_class_a(taken == index);
    }

    /// Marks a slot the backend has handed to its kernel, or to an offload, `submitted`, and arms
    /// its deadline, or a timer's delay.
    pub fn hand_over(tables: *Tables, index: u32, slot: *Slot) void {
        assert_class_a(slot.state == .queued);
        slot.state = .submitted;
        tables.arm(index, slot);
    }

    /// Puts a submitted slot back on the pending list for the next flush to hand over again: what
    /// io_uring's reap does with an operation the kernel refused for now. Its deadline stays armed.
    pub fn requeue(tables: *Tables, index: u32) void {
        const slot = tables.table.at(index);
        assert(slot.state == .submitted);
        slot.state = .queued;
        tables.pending.push(tables.table.slots, index);
    }

    /// Ends the operation in `index` with its cancel's code: `canceled`, or `timeout` when the loop
    /// cancelled it because its deadline passed.
    pub fn finish_canceled(tables: *Tables, index: u32) void {
        tables.finish_local(index, event_module.result_of(cancel_code(tables.table.at(index))));
    }

    /// Ends every operation that waits on `descriptor` in `waiting`, oldest first, with
    /// `canceled`: what a readiness backend's `close` does before it closes the descriptor
    /// (decision 5, rule 6). The finished list keeps their order, so the caller sees each of them
    /// before the close.
    pub fn end_waiters(
        tables: *Tables,
        waiting: *waiters_module.Waiters,
        descriptor: Descriptor,
    ) void {
        const limit = tables.table.capacity();
        var ended: u32 = 0;
        while (ended < limit) : (ended += 1) {
            const index = waiting.pop_any(tables.table.slots, descriptor) orelse break;
            tables.table.at(index).flags.cancel_requested = true;
            tables.finish_canceled(index);
        }
    }

    /// Marks `slot` for cancellation, once, and ends it when the tables can: a timer lives in
    /// the heap, so its cancel is synchronous and has no race (decision 5, rule 5). A queued
    /// slot is ended by the backend's flush, which finds the mark before the kernel sees the
    /// operation. The loop calls this itself when a deadline passes, with `timed_out` set.
    ///
    /// A finishing slot reaches here only as a repeating timer whose fire is queued and not yet
    /// handed over. The cancel replaces that fire with `canceled`, so the event already waiting
    /// on `fired` is the timer's final one. That is what a cancel of a timer whose deadline
    /// passed before the loop expired it already hands over, and Camilo chose it on
    /// 2026-09-23 (decision 14, rule 5).
    pub fn request_cancel(tables: *Tables, index: u32, slot: *Slot) CancelAction {
        assert(slot.state != .free);
        assert(slot.state != .finishing or finish_module.repeats(slot));
        if (slot.flags.cancel_requested) return .none;
        slot.flags.cancel_requested = true;
        if (slot.state == .queued) return .none;
        if (slot.state == .finishing) {
            slot.result = event_module.result_of(cancel_code(slot));
            return .none;
        }
        if (slot.code != .timer) return .backend;
        tables.timers.disarm(index);
        tables.finish_canceled(index);
        return .none;
    }

    /// The next slot at or after `from` that a cancel can still reach, or null: what a backend's
    /// `cancel_all` walks the table with.
    pub fn next_cancellable(tables: *Tables, from: u32) ?u32 {
        var index = from;
        while (index < tables.table.capacity()) : (index += 1) {
            if (reachable(tables.table.at(index))) return index;
        }
        return null;
    }

    /// The slot `handle` names when a cancel can still reach it, or null: the handle went stale,
    /// which is legal (decision 5, rule 2), or the final event is already queued.
    pub fn cancellable(tables: *Tables, handle: Handle) ?*Slot {
        const slot = tables.table.lookup(handle) orelse return null;
        return if (reachable(slot)) slot else null;
    }

    /// True when a cancel can still change how `slot` ends. A finishing slot holds its final
    /// event, unless it is a repeating timer whose queued fire says `more`: that timer has no
    /// final event yet, and a cancel that skipped it would leave it repeating.
    fn reachable(slot: *const Slot) bool {
        return switch (slot.state) {
            .free => false,
            .queued, .submitted => true,
            .finishing => finish_module.repeats(slot),
        };
    }

    /// Hands `request` every operation a cancel can still reach, to cancel: what every backend's
    /// `cancel_all` does, with its own cancel as `request` and its loop as `backend`.
    pub fn cancel_all(
        tables: *Tables,
        backend: anytype,
        comptime request: fn (@TypeOf(backend), u32, *Slot) void,
    ) void {
        tables.assert_owner();
        var from: u32 = 0;
        while (tables.next_cancellable(from)) |index| : (from = index + 1) {
            request(backend, index, tables.table.at(index));
        }
    }

    /// The loop produced the operation's final result itself: `tables_finish.zig`.
    pub const finish_local = finish_module.finish_local;
    /// `finish_local` for a receive from a group, whose event names a buffer: `tables_finish.zig`.
    pub const finish_local_buffer = finish_module.finish_local_buffer;
    /// A due timer's fire, onto the fired list: `tables_finish.zig`.
    pub const fire = finish_module.fire;
    /// Hands over the events of both lists, into at most a given count of places: `tables_finish.zig`.
    pub const drain_lists = finish_module.drain_lists;
    /// Hands over the events of both lists, into every place of `events`: `tables_finish.zig`.
    pub const drain_finished = finish_module.drain_finished;
    /// Arms an operation's deadline or a timer's delay: `tables_deadline.zig`.
    pub const arm = deadline.arm;
    /// How long a tick may block: `tables_deadline.zig`.
    pub const wait_bound = deadline.wait_bound;
    /// The nearest timer or poller limit, where a spin stops: `tables_deadline.zig`.
    pub const earliest_deadline_ns = deadline.earliest_deadline_ns;
    /// Core's part of a host's `wait_limit`: `tables_deadline.zig`.
    pub const wait_limit = deadline.wait_limit;
    /// A tick's first expiry, of timers only: `tables_deadline.zig`.
    pub const finish_due_timers = deadline.finish_due_timers;
    /// A tick's last step, after its reap: `tables_deadline.zig`.
    pub const expire_after_reap = deadline.expire_after_reap;
    /// Every due timer finished, and every operation whose deadline passed handed to the
    /// backend's cancel: `tables_deadline.zig`.
    pub const expire = deadline.expire;
    /// The next operation whose deadline passed: `tables_deadline.zig`.
    pub const next_expired = deadline.next_expired;
};

comptime {
    // The heartbeat is a pointer to a line in the caller's memory and not a field, so `Tables`,
    // and each `Loop` that holds it, keep an alignment of 8 (decision 28). Its size depends on
    // the build, because only a test build carries the shuffle.
    assert(@alignOf(Tables) == 8);
    assert(@sizeOf(*Heartbeat) == 8);
}

/// What a cancelled operation's final event says: `timeout` when the loop cancelled it for its
/// deadline, `canceled` when the caller did (decision 5, rule 4).
pub fn cancel_code(slot: *const Slot) Code {
    assert(slot.flags.cancel_requested);
    return if (slot.flags.timed_out) .timeout else .canceled;
}
