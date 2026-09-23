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

const Descriptor = operation.Descriptor;
const Mailbox = mailbox_module.Mailbox;

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
/// the same memory; each one re-exports it so a caller reaches it as `offload_memory_bytes`.
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
