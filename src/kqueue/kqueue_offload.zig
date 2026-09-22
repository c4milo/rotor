//! Handing a blocking file operation to the caller's threads, and taking its result back
//! (decision 18). This is the kqueue half: io_uring performs these operations without a thread, so
//! it takes the policy and does nothing with it.
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
//! Each worker has its own ring, so each ring has one producer. `kqueue_mailbox.zig`'s `Mailbox` is
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
const posix = std.posix;
const core = @import("core");
const errno_module = @import("kqueue_errno.zig");
const mailbox_module = @import("kqueue_mailbox.zig");
const queue_module = @import("kqueue_queue.zig");
const constants = @import("constants.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Slot = core.Slot;
const Mailbox = mailbox_module.Mailbox;
const Work = core.offload.Work;

/// Messages one drain moves out of one worker's ring at a time. The same bound
/// `drain_mailboxes` uses, for the same reason: a ring that still holds messages is drained by the
/// next tick, which does not wait while one does.
const messages_per_drain = 32;

/// Rounds one drain pops one ring in. A ring holds `constants.mailbox_messages` and each round
/// takes `messages_per_drain`, so this many empties a ring that was full when the drain began.
///
/// A worker may push while the drain runs, so a drain is not promised to leave the ring empty. It
/// does not have to: what it leaves the next tick takes, and a tick with anything to hand over does
/// not wait (`kqueue_tick.zig`). `drain_mailboxes` makes the same trade for the same reason.
const drain_rounds_max = constants.mailbox_messages / messages_per_drain;

/// A `Mailbox` is aligned to 128 and `core.layout.Layout` carves to 64, which is why the registry
/// carries the same constant: the caller's memory is aligned to 64 like every other memory rotor
/// takes, and `init_rings` skips forward to the first address a ring can sit at.
const alignment_slack_bytes: usize = @alignOf(Mailbox) - core.layout.memory_alignment;

/// The bytes the offload's rings need for `workers`, to be passed as `Options.offload_memory`.
///
/// The rings are the one part of a loop the caller's threads write, so the caller owns their
/// memory, as the application owns the registry's (decision 12, point 6). A loop with no offload
/// asks for none of it.
pub fn memory_bytes(workers: u16) usize {
    if (workers == 0) return 0;
    assert(workers <= core.constants.offload_workers_max);
    return alignment_slack_bytes + @as(usize, workers) * @sizeOf(Mailbox);
}

/// Carves `workers` empty rings out of `memory` and returns them.
pub fn init_rings(
    memory: []align(core.layout.memory_alignment) u8,
    workers: u16,
) []Mailbox {
    if (workers == 0) return &.{};
    assert(memory.len >= memory_bytes(workers));
    const base = @intFromPtr(memory.ptr);
    const skipped = std.mem.alignForward(usize, base, @alignOf(Mailbox)) - base;
    assert(skipped <= alignment_slack_bytes);
    const rings: [*]Mailbox = @ptrCast(@alignCast(memory.ptr + skipped));
    assert(@intFromPtr(rings) % @alignOf(Mailbox) == 0);
    const taken = rings[0..workers];
    for (taken) |*ring| ring.init();
    return taken;
}

/// The `Work.Code` an operation maps to, or null when it is not one an offload is handed.
pub fn code_of(code: core.Operation.Code) ?Work.Code {
    return switch (code) {
        .read => .read,
        .write => .write,
        .fdatasync => .fdatasync,
        else => null,
    };
}

/// True when the caller's offload holds `slot`. Under the `offload` policy a file operation reaches
/// `submitted` only by being handed out, so the policy and the operation's code decide this.
///
/// The cancel path uses it to avoid treating such a slot as one waiting on a kqueue filter. A file
/// registers no filter, so `perform.filter_of` has no answer for one.
pub fn on_a_worker(loop: *const Loop, slot: *const Slot) bool {
    if (loop.file_policy != .offload) return false;
    return code_of(slot.code) != null;
}

/// Hands one queued operation to the caller's offload. The slot becomes `submitted` and stays the
/// loop's until the worker's message comes back and `finish_local` ends it.
///
/// Every parameter is copied out of the slot here, on the loop thread, so the worker reads no slot.
pub fn hand_out(loop: *Loop, index: u32, slot: *Slot) void {
    loop.tables.assert_owner();
    const offload = loop.offload.?;
    assert(index < loop.works.len);
    const code = code_of(slot.code).?;
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
/// table, so it can run while the loop ticks.
fn run(work: *Work, worker: u16) void {
    const loop: *Loop = @ptrCast(@alignCast(work.owner));
    assert(worker < loop.completions.len);
    const result = perform(work);

    const ring = &loop.completions[worker];
    // The ring holds `mailbox_messages` per worker. A caller that hands one worker more operations
    // than that without letting the loop run has overrun it, and dropping the message would owe an
    // operation a final event it never gets (decision 5, rule 1). So the push must succeed.
    const pushed = ring.push(.{ .tag = tag_of(result), .payload = work.index });
    assert(pushed);

    // Ordering: the push stored the ring's tail with `seq_cst` before this load, and the loop
    // stores the flag with `seq_cst` before it re-reads the rings. So either this sees the flag or
    // the loop sees the message.
    if (loop.offload_asleep.load(.seq_cst)) queue_module.Queue.wake(loop.queue.descriptor);
}

/// The result of one offloaded call, as a `Message` tag. A `Message` tag is unsigned, and a failed
/// operation's result is the negation of a `core.Code`, so the tag carries the bits and
/// `result_of_tag` reads them back. Nothing is lost: a transfer count fits in 31 bits
/// (`transfer_bytes_max`) and a code is small.
fn tag_of(result: i32) u32 {
    return @bitCast(result);
}

fn result_of_tag(tag: u32) i32 {
    return @bitCast(tag);
}

/// The system call, on the worker's thread. These are the same calls `kqueue_perform.zig` makes
/// inline, so the policy changes which thread runs them and nothing else.
fn perform(work: *const Work) i32 {
    return switch (work.code) {
        .read, .write => transfer(work),
        .fdatasync => sync(work.descriptor),
    };
}

fn transfer(work: *const Work) i32 {
    const buffer: [*]u8 = @ptrFromInt(work.buffer);
    const offset: i64 = @intCast(work.offset);
    var retry: u32 = 0;
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
        const rc = switch (work.code) {
            .read => std.c.pread(work.descriptor, buffer, work.length, offset),
            .write => std.c.pwrite(work.descriptor, buffer, work.length, offset),
            .fdatasync => unreachable,
        };
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => |code| return core.event.result_of(errno_module.code_of(code)),
        }
    }
    return core.event.result_of(.would_block);
}

/// `F_FULLFSYNC` gives `fdatasync` its meaning on macOS, as the inline path does.
fn sync(descriptor: core.Descriptor) i32 {
    if (std.c.fcntl(descriptor, std.c.F.FULLFSYNC, @as(c_int, 0)) == 0) return 0;
    if (std.c.fsync(descriptor) == 0) return 0;
    return core.event.result_of(errno_module.code_of(posix.errno(-1)));
}

/// Moves every result the workers pushed into the loop's finished list, on the loop thread. The
/// next `drain_finished` hands their events over, as decision 5, rule 2 requires: not the call that
/// produced the result.
///
/// Returns how many operations it finished, which a tick uses to decide it has work to hand over.
pub fn drain(loop: *Loop) u32 {
    loop.tables.assert_owner();
    var finished: u32 = 0;
    var messages: [messages_per_drain]core.Message = undefined;
    for (loop.completions) |*ring| {
        var round: u32 = 0;
        while (round < drain_rounds_max) : (round += 1) {
            const moved = ring.pop_into(&messages);
            if (moved == 0) break;
            for (messages[0..moved]) |message| {
                // The payload is the slot index this loop wrote into the work before handing it
                // out, so it names a slot of this loop's own table and nothing else.
                assert(message.payload < loop.works.len);
                const index: u32 = @intCast(message.payload);
                // A result can only come back for an operation that was handed out, and `hand_out`
                // marks such an operation `submitted`. A slot in any other state means the ring
                // carried something this loop never sent.
                assert(loop.tables.table.at(index).state == .submitted);
                loop.tables.finish_local(index, result_of_tag(message.tag));
                finished += 1;
            }
        }
    }
    return finished;
}

/// True when any worker has pushed a result the loop has not taken. The check a loop makes after
/// it has said it will sleep, so it never sleeps on a message already in a ring.
pub fn pending(loop: *const Loop) bool {
    for (loop.completions) |*ring| {
        if (!ring.is_empty()) return true;
    }
    return false;
}

const testing = std.testing;

test "the rings need nothing when there is no offload, and are aligned when there is" {
    try testing.expectEqual(@as(usize, 0), memory_bytes(0));
    try testing.expect(memory_bytes(1) >= @sizeOf(Mailbox));
    try testing.expectEqual(memory_bytes(1) + @sizeOf(Mailbox), memory_bytes(2));

    // Deliberately offset inside a larger block, so the skip forward is exercised and not just
    // the case where the caller's pointer happens to be aligned to 128 already.
    var block: [4 * @sizeOf(Mailbox)]u8 align(core.layout.memory_alignment) = undefined;
    const workers: u16 = 2;
    const rings = init_rings(block[0..memory_bytes(workers)], workers);
    try testing.expectEqual(@as(usize, workers), rings.len);
    for (rings) |*ring| {
        try testing.expectEqual(@as(usize, 0), @intFromPtr(ring) % @alignOf(Mailbox));
        try testing.expect(ring.is_empty());
    }

    try testing.expectEqual(@as(usize, 0), init_rings(block[0..0], 0).len);
}

test "only the three blocking operations map to offload work" {
    try testing.expectEqual(Work.Code.read, code_of(.read).?);
    try testing.expectEqual(Work.Code.write, code_of(.write).?);
    try testing.expectEqual(Work.Code.fdatasync, code_of(.fdatasync).?);

    // A socket operation never blocks this backend's loop: kqueue reports its readiness. Handing
    // one to a worker would spend a thread and a ring on nothing.
    try testing.expectEqual(@as(?Work.Code, null), code_of(.accept));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.receive));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.send));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.connect));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.timer));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.post));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.close));
}

test "a result survives the trip through a message tag, failures included" {
    // A `Message` tag is unsigned and a failed result is negative, so the tag carries the bits.
    // A round trip that lost the sign would turn every error into an enormous transfer count.
    const results = [_]i32{
        0,
        1,
        4096,
        @intCast(core.constants.transfer_bytes_max),
        core.event.result_of(.would_block),
        core.event.result_of(.unsupported),
        core.event.result_of(.unexpected),
        -1,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    };
    for (results) |result| {
        try testing.expectEqual(result, result_of_tag(tag_of(result)));
    }
}
