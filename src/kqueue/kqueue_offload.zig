//! Handing a blocking file operation to the caller's threads, and taking its result back
//! (decision 18). This is the kqueue half: io_uring performs these operations without a thread, so
//! it checks the policy and does nothing with it.
//!
//! Three operations block on this backend: `read`, `write` and `fdatasync`. A tick holding a batch
//! of them performs each in turn and serves no socket until the last returns. Decision 18 measured
//! 2.8 ms for 32 reads. Under the `offload` policy the loop hands each one out and the tick goes on.
//!
//! What crosses the thread boundary: the loop fills a `core.offload.Work` with everything the
//! system call needs and hands it out. A worker calls `Work.run`, which makes the call on the
//! worker's thread and pushes one `core.Message` — the slot index and the result — into that
//! worker's ring. The loop pops the ring on its own thread and calls `finish_local`. So only the
//! loop thread writes a slot, and non-negotiable 4 holds: no lock, and the loop starts no thread.
//!
//! Each worker has its own ring, so each ring has one producer. `core/mailbox.zig`'s `Mailbox` is
//! single-producer and single-consumer, and its memory-ordering argument depends on that. One ring
//! per worker keeps that true and needs no multi-producer structure. libxev shares one Vyukov MPSC
//! queue between its pool threads instead, and its source carries a TODO saying the atomics are
//! unaudited. `core.constants.offload_workers_max` bounds the rings.
//!
//! Waking a sleeping loop repeats the race decision 12's point 6 settles. The loop sets
//! `offload_asleep` before it blocks, then reads every ring again: a worker that pushed before it
//! could see the flag did not wake the loop, so the loop must not sleep on that message. Both sides
//! use `seq_cst`, so at least one of two things holds — the worker sees the flag set, or the loop
//! sees the ring non-empty.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const queue_module = @import("kqueue_queue.zig");
const file_call = @import("kqueue_file_call.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Slot = core.Slot;
const Work = core.offload.Work;

/// The rings are `core`'s: every readiness backend carves the same ones out of the caller's memory
/// (`core/offload.zig`). The loop's `init` and the tests reach them through `offload_module`.
pub const memory_bytes = core.offload.memory_bytes;
pub const init_rings = core.offload.init_rings;

/// True when the caller's offload holds `slot`. Under the `offload` policy a file operation reaches
/// `submitted` only by being handed out, so the policy and the operation's code decide this.
///
/// The cancel path uses it to avoid treating such a slot as one waiting on a kqueue filter. A file
/// registers no filter, so `perform.filter_of` has no answer for one.
pub fn on_a_worker(loop: *const Loop, slot: *const Slot) bool {
    if (loop.file_policy != .offload) return false;
    return core.offload.code_of(slot.code) != null;
}

/// Hands one queued operation to the caller's offload. The slot becomes `submitted` and stays the
/// loop's until the worker's message comes back and `finish_local` ends it.
///
/// Every parameter is copied out of the slot here, on the loop thread, so the worker reads no slot.
pub fn hand_out(loop: *Loop, index: u32, slot: *Slot) void {
    loop.tables.assert_owner();
    const offload = loop.offload.?;
    assert(index < loop.works.len);
    const code = core.offload.code_of(slot.code).?;
    const bytes = if (code == .fdatasync) &[_]u8{} else slot.bytes();

    slot.state = .submitted;
    const work = &loop.works[index];
    work.* = .{
        .run = run,
        .owner = loop,
        .index = index,
        .code = code,
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
    const ring = &loop.completions[worker];
    // The call the inline attempt of `kqueue_perform.zig` makes too, so the policy changes which
    // thread makes it and nothing else.
    const result = file_call.result(core.file_call.request_of_work(work));

    // The ring holds `mailbox_messages` per worker. A caller that hands one worker more operations
    // than that without letting the loop run has overrun it, and dropping the message would owe an
    // operation a final event it never gets (decision 5, rule 1). So the push must succeed.
    const pushed = ring.push(.{ .tag = core.offload.tag_of(result), .payload = work.index });
    assert(pushed);

    // Ordering: the push stored the ring's tail with `seq_cst` before this load, and the loop
    // stores the flag with `seq_cst` before it re-reads the rings. So either this sees the flag or
    // the loop sees the message.
    if (loop.offload_asleep.load(.seq_cst)) queue_module.Queue.wake(loop.queue.descriptor);
}

/// Moves every result the workers pushed into the loop's finished list: `core.offload.drain`.
///
/// It does not check the owner. `tick` checks it first, before its flush and expiry touch the
/// tables, and in the loop only `tick` calls this. A second check here halted the same tick, so no
/// halt scenario could show that `tick`'s own check halts, as decision 4 requires (2026-09-22).
pub fn drain(loop: *Loop) u32 {
    return core.offload.drain(loop.completions, &loop.tables, loop.works.len);
}

/// True when any worker has pushed a result the loop has not taken: `core.offload.pending`.
pub fn pending(loop: *const Loop) bool {
    return core.offload.pending(loop.completions);
}
