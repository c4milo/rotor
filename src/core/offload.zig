//! What a caller hands a loop so the loop can perform a blocking file operation without stalling
//! (decision 18). `core` owns the types because both backends take the same options, and only the
//! kqueue backend acts on them: io_uring performs these operations without a thread, so it takes
//! the policy and ignores it.
//!
//! **rotor names no thread and no pool here.** It names a context, one function it calls to hand
//! work out, and one function a worker calls to run it. Whether the caller's side is a pool, one
//! thread, or a queue it drains itself is the caller's, which is non-negotiable 4: a loop starts
//! no thread, and a caller may hand it threads the loop never started.
//!
//! **The worker touches its `Work` and its own mailbox, and nothing else of the loop.** Every
//! parameter the system call needs is copied into the `Work` before it is handed out, so a worker
//! never reads the slot table. That keeps shared-nothing true across the hand-off: the loop thread
//! remains the only thread that touches a `Slot`.
//!
//! The caller's buffer is the exception, and it is not one: decision 5, rule 3 already says a
//! buffer belongs to the loop until the operation's final event, and an offloaded transfer is
//! inside that window.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const operation = @import("operation.zig");

const Descriptor = operation.Descriptor;

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
    /// the device takes, which is the whole reason this exists.
    pub const Code = enum { read, write, fdatasync };
};

/// The caller's side of the hand-off.
pub const Offload = struct {
    /// Passed back to `submit` untouched. rotor never reads through it.
    context: ?*anyopaque,
    /// rotor calls this on the loop thread to hand one operation out. The caller arranges for some
    /// thread of its own to call `work.run(work, worker)`, once, with that thread's index.
    ///
    /// It returns nothing: a caller that cannot take the work right now queues it, because the
    /// operation has a slot already and decision 5 owes it exactly one final event. A caller that
    /// wants to refuse work chooses the `refuse` policy instead.
    submit: *const fn (context: ?*anyopaque, work: *Work) void,
    /// How many threads will call `run`, which is how many mailboxes the loop holds. A worker
    /// index is below this number, and two threads never share one.
    workers: u16,

    /// True when the offload can be used: at least one worker, and no more than the loop can hold.
    pub fn valid(offload: Offload) bool {
        return offload.workers >= 1 and offload.workers <= constants.offload_workers_max;
    }
};

const testing = std.testing;

test "a policy is one of three, and refuse is the one a caller gets without asking" {
    // The default is the record's own choice, so a caller that says nothing is told and not slowed.
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
    // A socket operation is never offloaded: kqueue reports its readiness, so it never blocks the
    // loop. Adding one here would hand the loop's own work to a thread for nothing.
    try testing.expectEqual(@as(usize, 3), @typeInfo(Work.Code).@"enum".fields.len);
    try testing.expectEqual(@as(u2, 0), @intFromEnum(Work.Code.read));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(Work.Code.write));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(Work.Code.fdatasync));
}
