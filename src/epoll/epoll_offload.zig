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
const linux = std.os.linux;
const core = @import("core");
const queue_module = @import("epoll_queue.zig");
const constants = @import("constants.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Slot = core.Slot;
const Mailbox = core.mailbox.Mailbox;
const Work = core.offload.Work;

/// Messages one drain moves out of one worker's ring at a time. The same bound `drain_mailboxes`
/// uses, for the same reason: a ring that still holds messages is drained by the next tick, which
/// does not wait while one does.
const messages_per_drain = 32;

/// Rounds one drain pops one ring in. A ring holds `core.constants.mailbox_messages` and each round
/// takes `messages_per_drain`, so this many empties a ring that was full when the drain began.
///
/// A worker may push while the drain runs, so a drain is not promised to leave the ring empty. It
/// does not have to: what it leaves the next tick takes, and a tick with anything to hand over does
/// not wait. `drain_mailboxes` makes the same trade for the same reason.
const drain_rounds_max = core.constants.mailbox_messages / messages_per_drain;

/// The rings are `core`'s: every readiness backend carves the same ones out of the caller's memory
/// (`core/offload.zig`). They are re-exported here because `src/rotor.zig` reaches them through the
/// backend's `offload_module`.
pub const memory_bytes = core.offload.memory_bytes;
pub const init_rings = core.offload.init_rings;

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
/// The cancel path uses it to avoid treating such a slot as one waiting for readiness. A file is
/// registered with no epoll interest, so `perform.interest_of` has no answer for one.
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
/// table, so it can run while the loop ticks. It does read the loop after its push has made the
/// result visible, so the loop must outlive every call: a caller stops its offload before `deinit`
/// (decision 18).
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
    // the loop sees the message. The wake names the eventfd and not the epoll instance: an epoll
    // descriptor is not writable, so the loop owns a descriptor whose only job is to be written.
    if (loop.offload_asleep.load(.seq_cst)) queue_module.Queue.wake(loop.queue.wake_descriptor);
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

/// The system call, on the worker's thread. These are the same calls `epoll_perform.zig` makes
/// inline, so the policy changes which thread runs them and nothing else.
fn perform(work: *const Work) i32 {
    return switch (work.code) {
        .read, .write => transfer(work),
        .fdatasync => sync(work.descriptor),
    };
}

fn transfer(work: *const Work) i32 {
    const buffer: [*]u8 = @ptrFromInt(work.buffer);
    var retry: u32 = 0;
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
        const rc = switch (work.code) {
            .read => linux.pread(work.descriptor, buffer, work.length, @intCast(work.offset)),
            .write => linux.pwrite(work.descriptor, buffer, work.length, @intCast(work.offset)),
            .fdatasync => unreachable,
        };
        const errno = linux.errno(rc);
        if (errno == .SUCCESS) return @intCast(rc);
        if (errno != .INTR) return core.event.result_of(core.errno.code_of(errno));
    }
    return core.event.result_of(.would_block);
}

/// Linux has `fdatasync` itself, so there is no `F_FULLFSYNC` dance as on macOS: the operation's
/// name and the system call's name are the same thing here.
fn sync(descriptor: core.Descriptor) i32 {
    var retry: u32 = 0;
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
        const rc = linux.fdatasync(descriptor);
        const errno = linux.errno(rc);
        if (errno == .SUCCESS) return 0;
        if (errno != .INTR) return core.event.result_of(core.errno.code_of(errno));
    }
    return core.event.result_of(.would_block);
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

    var block: [4 * @sizeOf(Mailbox)]u8 align(core.layout.memory_alignment) = undefined;
    const workers: u16 = 2;
    const rings = init_rings(block[0..memory_bytes(workers)], workers);
    try testing.expectEqual(@as(usize, workers), rings.len);
    for (rings) |*ring| {
        try testing.expectEqual(@as(usize, 0), @intFromPtr(ring) % @alignOf(Mailbox));
        try testing.expect(ring.is_empty());
    }
}

test "only the three blocking operations map to offload work" {
    try testing.expectEqual(Work.Code.read, code_of(.read).?);
    try testing.expectEqual(Work.Code.write, code_of(.write).?);
    try testing.expectEqual(Work.Code.fdatasync, code_of(.fdatasync).?);
    try testing.expectEqual(@as(?Work.Code, null), code_of(.receive));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.send));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.accept));
    try testing.expectEqual(@as(?Work.Code, null), code_of(.timer));
}

test "a result crosses a ring as its bits, so a failed operation's code survives the trip" {
    // A `Message` tag is unsigned and a failed result is negative, so the trip is only lossless if
    // the bits are carried rather than the value. A count and a code both make the round trip.
    const results = [_]i32{ 0, 1, 4096, core.event.result_of(.connection_reset) };
    for (results) |result| try testing.expectEqual(result, result_of_tag(tag_of(result)));
    try testing.expect(core.event.result_of(.connection_reset) < 0);
}

test "no slot is on a worker unless the policy is offload and the code is one that blocks" {
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);

    var slot: Slot = std.mem.zeroes(Slot);
    slot.code = .read;
    // The policy `init_tables` was given is `refuse`, so nothing is on a worker whatever its code.
    try testing.expect(!on_a_worker(&loop, &slot));
    slot.code = .receive;
    try testing.expect(!on_a_worker(&loop, &slot));
}
