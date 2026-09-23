//! What a caller hands a loop so the loop can perform a blocking file operation without stalling
//! (decision 18). `core` owns the types because every backend takes the same options, and only the
//! readiness backends act on them: io_uring performs these operations without a thread, so it checks
//! the options as the others do and then ignores them (`assert_options`).
//!
//! rotor names no thread type and no pool. It names a context, one function it calls to hand work
//! out, and one function a worker calls to run it. The caller decides whether its side is a pool,
//! a single thread, or a queue it drains itself. Non-negotiable 4 holds: a loop starts no thread,
//! and a caller may hand it threads the loop never started.
//!
//! A worker reads its `Work` and writes its own mailbox. It reads no slot table, because every
//! parameter the system call needs is copied into the `Work` before it is handed out. So the loop
//! thread stays the only thread that touches a `Slot`.
//!
//! The worker also writes the caller's buffer. Decision 5, rule 3 already covers that: a buffer
//! belongs to the loop until the operation's final event, and an offloaded transfer is inside that
//! window.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const layout = @import("layout.zig");
const mailbox_module = @import("mailbox.zig");
const operation = @import("operation.zig");
const tables_module = @import("tables.zig");

const Descriptor = operation.Descriptor;
const Mailbox = mailbox_module.Mailbox;
const Tables = tables_module.Tables;

/// What a loop does with `read`, `write` and `fdatasync` on a backend that cannot perform them
/// without blocking (decision 18). The default refuses, because the complaint that record answers
/// is that the stall is invisible: a caller that wants the stall asks for it in one word.
pub const FilePolicy = enum {
    /// The operation ends with `unsupported`. Nobody is quietly slowed.
    refuse,
    /// Perform it inline on the loop thread, which stalls the tick for its duration.
    blocking,
    /// Hand it to the caller's offload, which answers on one of the caller's threads.
    offload,
};

/// One operation handed out. The loop fills it, one worker runs it, and neither writes it again.
pub const Work = struct {
    /// The caller's worker calls this exactly once, on its own thread, passing its own index. It
    /// performs the system call and hands the result back to the loop that owns this work.
    ///
    /// A backend fills it with its own function, which casts `owner` back to its own `Loop`.
    run: *const fn (work: *Work, worker: u16) void,
    /// The loop that handed this out, opaque so that `core` names no backend type.
    owner: *anyopaque,
    /// The slot this work finishes. The loop reads it back off the mailbox and finishes it there.
    index: u32,
    code: Code,
    descriptor: Descriptor,
    /// The bytes to transfer, as an address and a length, which is how a `Slot` carries them.
    /// Both are 0 for `fdatasync`.
    buffer: usize,
    length: u32,
    offset: u64,

    /// The operations an offload is ever handed. `fdatasync` is here because it blocks as long as
    /// the device takes, and that is why it is here.
    pub const Code = enum { read, write, fdatasync };
};

/// The caller's side of the hand-off.
pub const Offload = struct {
    /// Passed back to `submit` untouched. rotor never reads through it.
    context: ?*anyopaque,
    /// rotor calls this on the loop thread to hand one operation out. The caller arranges for some
    /// thread of its own to call `work.run(work, worker)`, once, with that thread's index.
    ///
    /// It returns nothing. A caller that cannot take the work now must queue it: the operation
    /// already has a slot, and decision 5 owes it exactly one final event. A caller that wants to
    /// refuse file operations chooses the `refuse` policy instead.
    submit: *const fn (context: ?*anyopaque, work: *Work) void,
    /// How many threads will call `run`, which is how many mailboxes the loop holds. A worker
    /// index is below this number, and two threads never share one.
    workers: u16,

    /// True when the offload can be used: at least one worker, and no more than the loop can hold.
    pub fn valid(offload: Offload) bool {
        return offload.workers >= 1 and offload.workers <= constants.offload_workers_max;
    }
};

/// Halts on file options a loop cannot use. Every backend's `init` calls it, io_uring's included,
/// which uses none of them: under the public module one binary runs io_uring or epoll by what the
/// kernel allows, so the same options must halt on both or on neither. Until 2026-09-23 io_uring
/// checked nothing, and kqueue and epoll checked only what their ring carving happened to.
///
/// A mistake here is a programmer error and not an operational one: it is made at init, and nothing
/// can recover from it later (CLAUDE.md, Conventions).
pub fn assert_options(
    policy: FilePolicy,
    offload: ?Offload,
    memory: []align(layout.memory_alignment) const u8,
) void {
    if (policy != .offload) {
        // An offload named under another policy would never be handed work. The options say an
        // offload is refused then, and this is where that is enforced.
        assert(offload == null);
        return;
    }
    // A missing offload fails the same check as one with no worker: either way no thread would run
    // the work, and every file operation would wait for a final event that cannot come
    // (decision 5, rule 1). One check for both is also what lets a halt scenario prove it: a
    // separate null check would be followed by the unwrap below, which halts on its own.
    const usable = if (offload) |given| given.valid() else false;
    assert(usable);
    assert(memory.len >= memory_bytes(offload.?.workers));
}

const testing = std.testing;

test "a policy is one of three, and refuse is the one a caller gets without asking" {
    // Decision 18 chose this default so a caller who sets nothing is told, rather than slowed.
    const policy: FilePolicy = .refuse;
    try testing.expectEqual(FilePolicy.refuse, policy);
    try testing.expectEqual(@as(usize, 3), @typeInfo(FilePolicy).@"enum".fields.len);
}

test "an offload is valid with workers the loop can hold, and not otherwise" {
    const nothing: *const fn (?*anyopaque, *Work) void = undefined;
    try testing.expect(!(Offload{ .context = null, .submit = nothing, .workers = 0 }).valid());
    try testing.expect((Offload{ .context = null, .submit = nothing, .workers = 1 }).valid());
    try testing.expect((Offload{
        .context = null,
        .submit = nothing,
        .workers = constants.offload_workers_max,
    }).valid());
    try testing.expect(!(Offload{
        .context = null,
        .submit = nothing,
        .workers = constants.offload_workers_max + 1,
    }).valid());
}

test "the offloadable operations are the three that block, and no others" {
    // Socket operations are never offloaded. kqueue reports their readiness, so they do not block
    // the loop, and handing one to a thread would cost a hop and save nothing.
    try testing.expectEqual(@as(usize, 3), @typeInfo(Work.Code).@"enum".fields.len);
    try testing.expectEqual(@as(u2, 0), @intFromEnum(Work.Code.read));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(Work.Code.write));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(Work.Code.fdatasync));
}

/// A `Mailbox` is aligned to 128 and `layout.Layout` carves to 64, which is why the registry
/// carries the same constant: the caller's memory is aligned to 64 like every other memory rotor
/// takes, and `init_rings` skips forward to the first address a ring can sit at.
const alignment_slack_bytes: usize = @alignOf(Mailbox) - layout.memory_alignment;

/// The bytes the offload's rings need for `workers`, to be passed as `Loop.Options.offload_memory`.
///
/// The rings are the one part of a loop the caller's threads write, so the caller owns their
/// memory, as the application owns the registry's (decision 12, point 6). A loop with no offload
/// asks for none of it.
///
/// It is here rather than in a backend because every readiness backend carves the same rings out of
/// the same memory. The public module hands it to a caller as `offload_memory_bytes`.
pub fn memory_bytes(workers: u16) usize {
    if (workers == 0) return 0;
    assert(workers <= constants.offload_workers_max);
    return alignment_slack_bytes + @as(usize, workers) * @sizeOf(Mailbox);
}

/// Carves `workers` empty rings out of `memory` and returns them.
pub fn init_rings(memory: []align(layout.memory_alignment) u8, workers: u16) []Mailbox {
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

/// The `Work.Code` an operation maps to, or null when it is not one an offload is handed. Every
/// other operation waits for readiness, so handing it to a worker would spend a thread on nothing.
pub fn code_of(code: operation.Operation.Code) ?Work.Code {
    return switch (code) {
        .read => .read,
        .write => .write,
        .fdatasync => .fdatasync,
        else => null,
    };
}

/// The result of one offloaded call, as a `Message` tag. A `Message` tag is unsigned, and a failed
/// operation's result is the negation of a `Code`, so the tag carries the bits and `result_of_tag`
/// reads them back. Nothing is lost: a transfer count fits in 31 bits (`transfer_bytes_max`) and a
/// code is small.
pub fn tag_of(result: i32) u32 {
    return @bitCast(result);
}

fn result_of_tag(tag: u32) i32 {
    return @bitCast(tag);
}

/// Messages one drain moves out of one worker's ring at a time. The same bound a readiness loop's
/// `drain_mailboxes` uses, for the same reason: a ring that still holds messages is drained by the
/// next tick, which does not wait while one does.
const messages_per_drain = 32;

/// Rounds one drain pops one ring in. A ring holds `constants.mailbox_messages` and each round
/// takes `messages_per_drain`, so this many empties a ring that was full when the drain began.
///
/// A worker may push while the drain runs, so a drain is not promised to leave the ring empty. It
/// does not have to: what it leaves the next tick takes, and a tick with anything to hand over does
/// not wait. `drain_mailboxes` makes the same trade for the same reason.
const drain_rounds_max = constants.mailbox_messages / messages_per_drain;

/// Moves every result the workers pushed into `tables`' finished list, on the loop thread. The
/// next `drain_finished` hands their events over, as decision 5, rule 2 requires: not the call that
/// produced the result. `works_len` is how many works the loop holds, one per slot.
///
/// Returns how many operations it finished, which a tick uses to decide it has work to hand over.
pub fn drain(completions: []Mailbox, tables: *Tables, works_len: usize) u32 {
    var finished: u32 = 0;
    var messages: [messages_per_drain]operation.Message = undefined;
    for (completions) |*ring| {
        var round: u32 = 0;
        while (round < drain_rounds_max) : (round += 1) {
            const moved = ring.pop_into(&messages);
            if (moved == 0) break;
            for (messages[0..moved]) |message| {
                // The payload is the slot index this loop wrote into the work before handing it
                // out, so it names a slot of this loop's own table and nothing else.
                assert(message.payload < works_len);
                const index: u32 = @intCast(message.payload);
                // A result can only come back for an operation that was handed out, and a hand-out
                // marks such an operation `submitted`. A slot in any other state means the ring
                // carried something this loop never sent.
                assert(tables.table.at(index).state == .submitted);
                tables.finish_local(index, result_of_tag(message.tag));
                finished += 1;
            }
        }
    }
    return finished;
}

/// True when any worker has pushed a result the loop has not taken. The check a loop makes after
/// it has said it will sleep, so it never sleeps on a message already in a ring.
pub fn pending(completions: []const Mailbox) bool {
    for (completions) |*ring| {
        if (!ring.is_empty()) return true;
    }
    return false;
}

test "only the three blocking operations map to offload work" {
    try testing.expectEqual(Work.Code.read, code_of(.read).?);
    try testing.expectEqual(Work.Code.write, code_of(.write).?);
    try testing.expectEqual(Work.Code.fdatasync, code_of(.fdatasync).?);
    const others = [_]operation.Operation.Code{
        .accept, .receive, .send, .connect, .timer, .post, .close,
    };
    for (others) |code| try testing.expectEqual(@as(?Work.Code, null), code_of(code));
}

test "a result survives the trip through a message tag, failures included" {
    // A `Message` tag is unsigned and a failed result is negative, so the tag carries the bits.
    // A round trip that lost the sign would turn every error into an enormous transfer count.
    const event = @import("event.zig");
    const results = [_]i32{
        0,
        1,
        4096,
        @intCast(constants.transfer_bytes_max),
        event.result_of(.would_block),
        event.result_of(.connection_reset),
        event.result_of(.unexpected),
        -1,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    };
    for (results) |result| try testing.expectEqual(result, result_of_tag(tag_of(result)));
}

/// Workers of the alignment test: two rings are enough to prove where the second one lands.
const test_workers = 2;

test "init_rings skips forward to a ring's own alignment, from memory that is only 64 aligned" {
    // The caller's memory is aligned to 64, like every memory rotor takes, and a `Mailbox` needs
    // 128. Memory that is already 128 aligned hides the skip, so this test hands it a base that is
    // 64 aligned and not 128 aligned, which is the case `alignment_slack_bytes` exists for.
    const workers = test_workers;
    var backing: [memory_bytes(workers) + layout.memory_alignment]u8 align(@alignOf(Mailbox)) =
        undefined;
    const offset = layout.memory_alignment;
    const memory: []align(layout.memory_alignment) u8 = @alignCast(backing[offset..]);
    try testing.expect(@intFromPtr(memory.ptr) % @alignOf(Mailbox) != 0);
    try testing.expect(memory.len >= memory_bytes(workers));

    const rings = init_rings(memory, workers);
    try testing.expectEqual(@as(usize, workers), rings.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(rings.ptr) % @alignOf(Mailbox));
    // Every ring sits inside the memory the caller handed in, so the skip did not run past its end.
    const first = @intFromPtr(rings.ptr);
    const last_end = first + workers * @sizeOf(Mailbox);
    try testing.expect(first >= @intFromPtr(memory.ptr));
    try testing.expect(last_end <= @intFromPtr(memory.ptr) + memory.len);
    for (rings) |*ring| try testing.expect(ring.is_empty());
}

test "memory_bytes counts the slack a 64 aligned base can cost, and none for no workers" {
    try testing.expectEqual(@as(usize, 0), memory_bytes(0));
    try testing.expectEqual(@as(usize, 0), init_rings(&.{}, 0).len);
    // The slack is what a base 64 short of 128 costs, so the rings fit wherever the base sits.
    const slack = @alignOf(Mailbox) - layout.memory_alignment;
    try testing.expectEqual(slack + @sizeOf(Mailbox), memory_bytes(1));
    try testing.expectEqual(slack + test_workers * @sizeOf(Mailbox), memory_bytes(test_workers));
}
