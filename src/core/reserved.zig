//! The reserved tags of the mailbox rings: a wake (decision 29), a call and a return (decision 32).
//! The core carries them, and the reactor sends and takes calls through the port of decision 33.
//! This file holds the hook that the drain hands each reserved message, and the push of a call or
//! a return into a ring's kept slots. The drain's switch on the tag is in `inbox.zig`.
//!
//! A plain loop has no hook. It drops a wake, and halts on a call or a return (class B): no `call`
//! sends one to a loop that its registry does not mark (decision 33, open question 12).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const mailbox = @import("mailbox.zig");
const operation = @import("operation.zig");

const Descriptor = operation.Descriptor;
const LoopId = operation.LoopId;
const Message = operation.Message;
const Registry = mailbox.Registry;

/// What the drain calls for each reserved message, with the context that `attach_reserved` stored:
/// the reactor's address (decision 33, "The reserved hook").
pub const Take = fn (context: *anyopaque, sender: LoopId, message: Message) void;

/// The function and the context that the drain hands each wake, call and return. `Tables` holds
/// one. Size 16 B, alignment 8. Neither field is optional, so the drain calls the function with no
/// check of its own.
pub const Hook = struct {
    take: *const Take,
    context: *anyopaque,

    /// The hook of a plain loop: `take_none`, whose context it never reads.
    pub const none: Hook = .{ .take = take_none, .context = @constCast(@as(*const anyopaque, &none_context)) };
};

/// The context of `Hook.none`. Nothing reads or writes it.
const none_context: u8 = 0;

/// What a plain loop's drain does with a reserved message: it drops a wake, and halts on a call or
/// a return (class B). Its registry does not mark it, so no `call` sends one (decision 33, open
/// question 12). Any other tag halts too: no post accepts one.
fn take_none(_: *anyopaque, _: LoopId, message: Message) void {
    assert(message.tag == constants.message_tag_wake);
}

comptime {
    assert(@sizeOf(Hook) == 16);
    assert(@alignOf(Hook) == 8);
}

/// Why a push sent nothing. The reactor's `CallError` is this set.
pub const PushError = error{
    /// `calls_per_pair_max` calls to that target have not yet run their `finish`.
    CallsFull,
    /// The ring to that target holds `mailbox_posts_max` messages.
    MailboxFull,
    /// The target runs no loop, its loop left, or its loop takes no calls.
    LoopNotFound,
};

/// What each backend's `wake_target` checks: a call or an answer wakes another loop, never the
/// loop that makes it, through a descriptor that names a loop (class B).
pub fn assert_wake(id: LoopId, target: LoopId, descriptor: Descriptor) void {
    assert(target != id);
    assert(descriptor >= 0);
}

/// What `push` did: the count of calls out of the ring that it wrote, and the descriptor that wakes
/// the target, or `no_wake` when the target is awake. A plain descriptor, and not an optional, is
/// returned in a register.
pub const Pushed = struct {
    calls_out: *u32,
    wake: Descriptor,
};

/// The `Pushed.wake` of a target that is awake. A registry holds no negative descriptor for a loop
/// that runs.
pub const no_wake: Descriptor = -1;

/// Pushes `message`, a call or a return of decision 32, from loop `id` into its ring to loop
/// `target`. It changes no count: the reactor raises the count of a call after the push, and a
/// return changes no count (decision 33, amendment of 2026-11-10). Halts on a target that is the
/// loop itself, because a call to self takes no ring, on a tag that is neither, and in a registry
/// of a decision 21 group (class B).
pub fn push(registry: ?*Registry, id: LoopId, target: LoopId, message: Message) PushError!Pushed {
    const tag = message.tag;
    assert(target != id);
    assert(tag == constants.message_tag_call or tag == constants.message_tag_return);
    if (registry) |known| assert(!known.group);
    if (tag == constants.message_tag_call) return push_call(registry, id, target, message);
    return push_return(registry.?, id, target, message);
}

/// A call sees the slots that a post sees. It fails with `LoopNotFound` for a target that runs no
/// loop or takes no calls (decision 33, open question 12), `CallsFull` for a pair with
/// `calls_per_pair_max` calls out, and `MailboxFull` for a ring that holds `mailbox_posts_max`
/// messages.
fn push_call(registry: ?*Registry, id: LoopId, target: LoopId, message: Message) PushError!Pushed {
    const known = registry orelse return error.LoopNotFound;
    if (target >= known.loop_count()) return error.LoopNotFound;
    // The entry, read once, in the orders of `get`, `takes_calls` and `must_wake`.
    const entry = known.target(target);
    // Negative covers a loop that is not running and a remote.
    const wake = entry.queue.load(.acquire);
    if (wake < 0) return error.LoopNotFound;
    // A plain loop, with no hook, takes no calls.
    if (!entry.calls.load(.acquire)) return error.LoopNotFound;
    const ring = known.mailbox(id, target);
    if (ring.calls_out >= constants.calls_per_pair_max) return error.CallsFull;
    if (!ring.push_post(message)) return error.MailboxFull;
    return .{ .calls_out = &ring.calls_out, .wake = if (entry.sleeping.load(.seq_cst)) wake else no_wake };
}

/// A return sees every slot. The posts leave `calls_per_pair_max` slots, and the calls of one pair
/// are at most that many, so a push that fails halts (class B).
fn push_return(registry: *Registry, id: LoopId, target: LoopId, message: Message) Pushed {
    const ring = registry.mailbox(id, target);
    const pushed = ring.push(message);
    assert(pushed);
    const entry = registry.target(target);
    const wake = entry.queue.load(.acquire);
    const sleeps = wake >= 0 and entry.sleeping.load(.seq_cst);
    return .{ .calls_out = &ring.calls_out, .wake = if (sleeps) wake else no_wake };
}

test {
    _ = @import("reserved_test.zig");
}
