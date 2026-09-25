//! What every backend's `Remote` shares: the errors `init` and `post` return, and the rules a
//! `Remote` keeps (decision 4, "What another thread may do"). A `Remote` is what a thread that
//! owns no loop holds so it can post a message to a loop.
//!
//! Each backend has its own `Remote`, because the wake belongs to its kernel: every remote is the
//! producer end of its mailbox rings, and wakes a sleeping loop with that loop's own wake, which on
//! io_uring means a small ring of its own to submit `MSG_RING` on. The shared part is here, so one
//! conformance suite drives every backend (decision 10).
//!
//! A `Remote` returns errors where a loop's `post` produces events. A loop that posts gets a
//! final event with a code such as `mailbox_full` (decision 5, rule 1). A `Remote` owns no loop,
//! so it has no event stream: the return value is the completion. Where the condition is one a
//! loop's `post` also reports, the error has the name `event.error_of` gives that code.
//!
//! A `Remote` sends and never receives. It holds a `LoopId`, so a message can name its sender,
//! and it counts against `constants.loops_max` as decision 4 says, but it publishes no queue. A
//! loop that posts to a remote's id is answered `loop_not_found`, as for any id that runs no loop.
//!
//! A `Remote` belongs to one thread, as a loop does. Every backend records the thread at `init`
//! and halt a `post` or `deinit` from another thread, with the compare `core/tables.zig` makes
//! for a loop.
//!
//! `send` is the post of the readiness backends, kqueue and epoll, where a loop's post and a
//! `Remote`'s post write the same mailbox ring, on io_uring too since 2026-09-25 (decision 4).
const std = @import("std");
const constants = @import("constants.zig");
const event = @import("event.zig");
const layout = @import("layout.zig");
const mailbox = @import("mailbox.zig");
const operation = @import("operation.zig");
const slot_module = @import("slot.zig");

const assert = std.debug.assert;
const Slot = slot_module.Slot;
const Descriptor = operation.Descriptor;
const LoopId = operation.LoopId;
const Message = operation.Message;

/// What `Remote.post` answers.
pub const PostError = error{
    /// The target's queue had no room. Nothing was sent, and the caller may try again. The queue
    /// is the mailbox ring of `mailbox_messages` the remote has to the target, on every backend
    /// since 2026-09-25 (decision 4).
    MailboxFull,
    /// The target names no running loop: an id at or above the count the registry was sized for,
    /// a loop that has not started or has stopped, or another `Remote`.
    LoopNotFound,
    /// No backend answers it since 2026-09-25, when io_uring's posts moved to the mailbox rings
    /// (decision 4). Until then io_uring answered it when the kernel had no memory for the request
    /// that carried the message. It stays in the set by the owner's ruling of that day, so the
    /// surface did not change.
    SystemResources,
    /// No backend answers it since 2026-09-25, for the same reason. Until then io_uring answered it
    /// when the kernel had not answered the `IORING_OP_MSG_RING` that carried the message within
    /// the post's wait.
    Unanswered,
    /// No backend answers it since 2026-09-25, for the same reason. Until then io_uring answered it
    /// for an errno rotor had no meaning for, or an `io_uring_enter` the kernel refused.
    Unexpected,
};

/// What `Remote.init` answers. On io_uring it creates a ring, which the kernel can refuse, and
/// the four errors are the ones `Loop.init` reports for the same call. On kqueue it creates
/// nothing and cannot fail; it takes the same set so the two surfaces match.
pub const InitError = error{
    /// The host has no io_uring, or its io_uring lacks a flag or an opcode rotor needs.
    Unsupported,
    PermissionDenied,
    /// A descriptor or memory limit refused the ring. The caller may try again later.
    SystemResources,
    Unexpected,
};

/// Why `send` delivered nothing. Both are also `PostError`s, so a `Remote` returns them as they are.
pub const SendError = error{ LoopNotFound, MailboxFull };

/// Pushes `message` into the ring `sender` has to `target`. Answers the descriptor that wakes the
/// target when the target said it would sleep, and null when it is awake: the caller makes its own
/// backend's wake call with it (decision 12, point 6). The target's `settle_to_sleep` reads the
/// rings again after it sets the flag, so a message pushed before it saw the flag is found anyway.
pub fn send(
    registry: *mailbox.Registry,
    sender: LoopId,
    target: LoopId,
    message: Message,
) SendError!?Descriptor {
    if (target >= registry.loops()) return error.LoopNotFound;
    // Negative covers a loop that is not running and another remote, which publishes a sentinel
    // below zero for exactly this reason.
    const wake = registry.get(target);
    if (wake < 0) return error.LoopNotFound;
    if (!registry.mailbox(sender, target).push(message)) return error.MailboxFull;
    return if (registry.must_wake(target)) wake else null;
}

/// The loops one flush posted to that asked to be woken. A flush notes each as `send` answers, and
/// wakes each once when the flush is done, however many messages it sent it: decision 12, point 6
/// says a burst costs one wake. The wake comes later than the push it follows, which the handshake
/// allows: what it needs is that every push comes before its `must_wake` read, and `send` does
/// both.
pub const Wakes = struct {
    targets: std.StaticBitSet(constants.loops_max) = .initEmpty(),

    pub fn note(wakes: *Wakes, target: LoopId) void {
        wakes.targets.set(target);
    }

    /// Wakes every loop noted once, through `wake`, the backend's own call. A loop that stopped
    /// since has no descriptor in the registry, and nothing wakes it.
    pub fn send(
        wakes: *const Wakes,
        registry: *mailbox.Registry,
        comptime wake: fn (Descriptor) void,
    ) void {
        var noted = wakes.targets.iterator(.{});
        while (noted.next()) |target| {
            const descriptor = registry.get(@intCast(target));
            if (descriptor >= 0) wake(descriptor);
        }
    }
};

/// A loop's `post`, the same on every backend: writes the slot's message into the ring `sender`
/// has to the slot's target, and notes the target in `wakes` when it said it sleeps, so the flush
/// wakes it once (decision 12, point 6). The result is the post's own final event. Until
/// 2026-09-25 kqueue and epoll each carried a copy, and io_uring posted through the kernel.
pub fn post(registry: ?*mailbox.Registry, sender: LoopId, slot: *const Slot, wakes: *Wakes) i32 {
    assert(slot.code == .post);
    const known = registry orelse return event.result_of(.loop_not_found);
    const target = slot.post_target();
    const wake = send(known, sender, target, slot.message()) catch |err| {
        return event.result_of(code_of(err));
    };
    if (wake != null) wakes.note(target);
    return 0;
}

/// The code a loop's post ends with when `send` refused it.
pub fn code_of(err: SendError) event.Code {
    return switch (err) {
        error.LoopNotFound => .loop_not_found,
        error.MailboxFull => .mailbox_full,
    };
}

const testing = std.testing;

test "the errors a post shares with a loop's post carry the names of the matching codes" {
    // A caller that moves work off the loop thread meets the names it knows from a loop's own
    // post: `event.error_of` gives them. The set adds `Unanswered`, which a loop cannot report
    // because a loop never waits for a post's answer.
    try testing.expectEqual(PostError.MailboxFull, event.error_of(.mailbox_full));
    try testing.expectEqual(PostError.LoopNotFound, event.error_of(.loop_not_found));
    try testing.expectEqual(PostError.SystemResources, event.error_of(.system_resources));
    try testing.expectEqual(PostError.Unexpected, event.error_of(.unexpected));
    const fields = @typeInfo(PostError).error_set.?;
    try testing.expectEqual(@as(usize, 5), fields.len);
}

test "a flush wakes each loop it noted once, however often, and none that stopped since" {
    const loop_count = 3;
    // Records each descriptor it is given. A loop woken twice would need a second entry, so the
    // log has room for one per loop and a wake past that halts on the bound.
    const WakeLog = struct {
        var woken: [loop_count]Descriptor align(@alignOf(Descriptor)) = undefined;
        var count: usize = 0;

        fn wake(descriptor: Descriptor) void {
            woken[count] = descriptor;
            count += 1;
        }
    };
    var memory: [mailbox.Registry.memory_bytes(loop_count)]u8 align(layout.memory_alignment) =
        undefined;
    var registry: mailbox.Registry = undefined;
    registry.init(&memory, loop_count);
    registry.set(1, 41);
    registry.set(2, 42);
    var wakes: Wakes = .{};
    wakes.note(1);
    wakes.note(1);
    wakes.note(2);
    registry.clear(2);
    WakeLog.count = 0;
    wakes.send(&registry, WakeLog.wake);
    try testing.expectEqual(@as(usize, 1), WakeLog.count);
    try testing.expectEqual(@as(Descriptor, 41), WakeLog.woken[0]);
}
