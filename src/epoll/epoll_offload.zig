//! Handing a blocking file operation to the caller's threads, and taking its result back
//! (decision 18). This is the epoll half, and it is `src/kqueue/kqueue_offload.zig` with two
//! differences: the system calls are Linux's, and the wake is a write to the loop's eventfd rather
//! than an `EVFILT_USER` trigger.
//!
//! Three operations block on this backend: `read`, `write` and `fdatasync`. epoll never reports a
//! regular file as anything but ready, so waiting for readiness saves nothing and the call is made
//! inline or on a worker. A tick holding a batch of them performs each in turn and serves no socket
//! until the last returns. Decision 18 measured 2.8 ms for 32 reads on kqueue. Under the `offload`
//! policy the loop hands each one out and the tick goes on.
//!
//! What crosses the thread boundary: the loop fills a `core.offload.Work` with everything the
//! system call needs and hands it out. A worker calls `Work.run`, which makes the call on the
//! worker's thread and pushes one `core.Message` — the slot index and the result — into that
//! worker's ring. The loop pops the ring on its own thread and calls `finish_local`. So only the
//! loop thread writes a slot, and non-negotiable 4 holds: no lock, and the loop starts no thread.
//!
//! Each worker has its own ring, so each ring has one producer, which is what `core/mailbox.zig`'s
//! ordering argument depends on. `core.constants.offload_workers_max` bounds the rings.
//!
//! Waking a sleeping loop repeats the race decision 12's point 6 settles. The loop sets
//! `offload_asleep` before it blocks, then reads every ring again: a worker that pushed before it
//! could see the flag did not wake the loop, so the loop must not sleep on that message. Both sides
//! use `seq_cst`, so at least one of two things holds — the worker sees the flag set, or the loop
//! sees the ring non-empty.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const queue_module = @import("epoll_queue.zig");
const file_call = @import("epoll_file_call.zig");
const submit_module = @import("epoll_submit.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Slot = core.Slot;
const Work = core.offload.Work;

/// The rings are `core`'s: every readiness backend carves the same ones out of the caller's memory
/// (`core/offload.zig`). The loop's `init` and the tests reach them through `offload_module`.
pub const memory_bytes = core.offload.Offload.memory_bytes;
pub const init_rings = core.offload.init_rings;

/// True when the caller's offload holds `slot`. Under the `offload` policy a file operation reaches
/// `submitted` only by being handed out, so the policy and the operation's tag decide this.
///
/// The cancel path uses it to avoid treating such a slot as one waiting for readiness. A file is
/// registered with no epoll interest, so `perform.filter_of` has no answer for one.
pub fn on_a_worker(loop: *const Loop, slot: *const Slot) bool {
    if (loop.file_policy != .offload) return false;
    return core.offload.work_tag_of(slot.tag) != null;
}

/// Hands one queued operation to the caller's offload. The slot becomes `submitted` and stays the
/// loop's until the worker's message comes back and `finish_local` ends it.
///
/// With `core.constants.offload_in_flight_max` operations out, the operation stays `queued` on the
/// held list instead, with its deadline armed, and the flush of a later tick hands it out once a
/// result has come back. So no worker's ring can fill (decision 18, amendment of 2026-11-06).
///
/// Every parameter is copied out of the slot here, on the loop thread, so the worker reads no slot.
pub fn hand_out(loop: *Loop, index: u32, slot: *Slot) void {
    loop.tables.assert_owner();
    const in_flight = &loop.inbox.offload_in_flight;
    if (!in_flight.has_room()) return in_flight.hold(&loop.tables, index);
    const offload = loop.offload.?;
    assert(index < loop.works.len);
    const tag = core.offload.work_tag_of(slot.tag).?;
    const bytes = if (core.file_call.is_sync(tag)) &[_]u8{} else slot.bytes();

    loop.tables.hand_over(index, slot);
    in_flight.note_handed_out(index, slot.descriptor);
    const work = &loop.works[index];
    work.* = .{
        .function = run,
        .owner = loop,
        .index = index,
        .tag = tag,
        .descriptor = slot.descriptor,
        .buffer = @intFromPtr(bytes.ptr),
        .length = @intCast(bytes.len),
        .offset = slot.offset,
    };
    offload.submit(offload.context, work);
}

/// Runs on one of the caller's worker threads, once per handed-out operation. It makes the system
/// call, pushes the result to that worker's ring, and wakes the loop if the loop said it would
/// sleep.
///
/// It touches the work, the caller's buffer, one ring and one atomic flag. It reads no slot and no
/// table, so it can run while the loop ticks. It does read the loop after its push has made the
/// result visible, so the loop must outlive every call: a caller stops its offload before `deinit`
/// (decision 18).
fn run(work: *Work, worker: u16) void {
    const loop: *Loop = @ptrCast(@alignCast(work.owner));
    // The ring is looked up before the system call, and the order matters. A worker index the loop
    // holds no ring for then halts on this index's bounds check before the call runs, so a worker
    // that names a ring it was never given writes nothing. rotor builds only in Debug and
    // ReleaseSafe, where the bounds check is on. An `assert` of the index stood here until
    // 2026-09-22; no halt scenario could prove it, because this bounds check halts as well.
    const ring = &loop.inbox.completions[worker];
    // The call the inline attempt of `epoll_perform.zig` makes too, so the policy changes which
    // thread makes it and nothing else.
    const result = file_call.result(core.file_call.request_of_work(work));

    // The ring holds `mailbox_messages` per worker, and the loop has at most
    // `offload_in_flight_max`, which is no more, out at a time. Each result in the ring belongs to
    // an operation that is out, so the ring has room for this one (decision 18, amendment of
    // 2026-11-06). A dropped message would owe an operation a final event it never gets
    // (decision 5, rule 1), so a failed push halts.
    const pushed = ring.push(.{ .tag = core.offload.tag_of(result), .payload = work.index });
    assert(pushed);

    // Ordering: the push stored the ring's tail with `seq_cst` before this load, and the loop
    // stores the flag with `seq_cst` before it re-reads the rings. So either this sees the flag or
    // the loop sees the message. The wake names the eventfd and not the epoll instance: an epoll
    // descriptor is not writable, so the loop owns a descriptor whose only job is to be written.
    if (loop.inbox.offload_asleep.load(.seq_cst)) queue_module.Queue.wake(loop.queue.wake_descriptor);
}

/// Moves every result the workers pushed into the loop's finished list, gives back the room each
/// one held, and closes a descriptor whose close waited for those results: `core.offload.drain`.
///
/// It does not check the owner. `tick` checks it first, before its flush and expiry touch the
/// tables, and in the loop only `tick` calls this. A second check here halted the same tick, so no
/// halt scenario could show that `tick`'s own check halts, as decision 4 requires (2026-09-22).
pub fn drain(loop: *Loop) u32 {
    const inbox = &loop.inbox;
    const in_flight = &inbox.offload_in_flight;
    const taken = core.offload.drain(inbox.completions, in_flight, &loop.tables, loop.works.len);
    // A result can end the wait of a kept close (decision 18, ruling (d) of 2026-11-06). A loop
    // with no offload takes no result, so it pays this one compare.
    if (taken != 0) settle_closes(loop);
    return taken;
}

/// Hands each kept close to `epoll_submit.close` again, after a drain that took a result.
fn settle_closes(loop: *Loop) void {
    const in_flight = &loop.inbox.offload_in_flight;
    if (in_flight.closing.count == 0) return;
    in_flight.settle_closes(&loop.tables, loop, submit_module.close);
}

/// True when any worker has pushed a result the loop has not taken: `core.offload.pending`.
pub fn pending(loop: *const Loop) bool {
    return core.offload.pending(loop.inbox.completions);
}

const testing = std.testing;

test "no slot is on a worker unless the policy is offload and the tag is one that blocks" {
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);

    var slot: Slot = std.mem.zeroes(Slot);
    slot.tag = .read;
    // The policy `init_tables` was given is `refuse`, so nothing is on a worker whatever its tag.
    try testing.expect(!on_a_worker(&loop, &slot));
    slot.tag = .receive;
    try testing.expect(!on_a_worker(&loop, &slot));
}
