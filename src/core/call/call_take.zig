//! The target's side of a cross-core call (decision 32), and the drain of the reserved tags: a
//! call, a return and a wake. Split from `call.zig`, which holds the types and the caller's side.
//!
//! The drain sends each message whose tag is above `message_tag_max` here, with one compare. A
//! loop that makes no calls never reaches this file.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const mailbox = @import("../mailbox.zig");
const operation = @import("../operation.zig");
const call_module = @import("call.zig");

const Dispatch = @import("../dispatch/dispatch.zig").Dispatch;
const Groups = @import("../scheduling/scheduling_groups.zig").Groups;
const CallLink = call_module.CallLink;
const Descriptor = operation.Descriptor;
const LoopId = operation.LoopId;
const Message = operation.Message;
const Outcome = call_module.Outcome;
const Registry = mailbox.Registry;

/// How the drain wakes the caller of a call that it answers at once: the backend's own wake of a
/// loop that sleeps, as its `post` makes it (decision 32).
pub const Waker = struct {
    context: *anyopaque,
    wake: *const fn (context: *anyopaque, target: LoopId, descriptor: Descriptor) void,
};

/// What one drain hands the cold path of its reserved tags. The drain writes `sender` before each
/// ring it visits.
pub const Taker = struct {
    registry: *Registry,
    dispatch: *Dispatch,
    groups: *Groups,
    /// Null for a test's loop, which wakes no other loop.
    waker: ?Waker,
    receiver: LoopId,
    sender: LoopId,
    /// True when the drain took a `Message.wake` (decision 29).
    woke: bool,
};

/// Takes one message with a tag above `message_tag_max`: a wake, a call or a return. It writes no
/// event. Any other tag halts: no post accepts one.
pub fn take_reserved(taker: *Taker, message: Message) void {
    switch (message.tag) {
        constants.message_tag_wake => taker.woke = true,
        constants.message_tag_call => take_call(taker, message),
        constants.message_tag_return => take_return(taker, message),
        else => unreachable,
    }
}

/// The drain on the target (decision 32, "The flow", step 3): the target holds the call, and its
/// task waits in the call's group to run the handler. Halts on a link that the message does not
/// match, on a group id above the target's named groups, on a station that never served, and in a
/// registry of a decision 21 group (class B).
pub fn take_call(taker: *Taker, message: Message) void {
    assert(!taker.registry.group);
    const link: *CallLink = @ptrFromInt(message.payload);
    assert(link.state == .out);
    assert(link.origin == taker.sender);
    assert(link.target == taker.receiver);
    assert(link.generation == message.reserved);
    assert(@intFromEnum(link.group) <= taker.groups.named);
    const station = &link.stations[taker.receiver];
    assert(station.state != .unused);
    link.state = .held;
    station.held += 1;
    taker.dispatch.callbacks_outstanding += 1;
    schedule_link(taker.dispatch, taker.groups, link);
}

/// The drain on the caller (step 6): the caller's loop owns the record again, and its task waits in
/// the call's group to run `finish`. The call out leaves the count, and the queued task counts in
/// its place. Halts on a link that the message does not match (class B).
pub fn take_return(taker: *Taker, message: Message) void {
    assert(!taker.registry.group);
    const link: *CallLink = @ptrFromInt(message.payload);
    assert(link.state == .answered);
    assert(link.origin == taker.receiver);
    assert(link.target == taker.sender);
    assert(link.generation == message.reserved);
    taker.dispatch.callbacks_outstanding -= 1;
    give_back(taker.dispatch, taker.groups, link);
}

/// The answer on the target (step 5), with the link's `outcome` written. It pushes the return
/// through `push`, which sees every slot, and halts when the push fails (class B): the posts leave
/// `calls_per_pair_max` slots, and the calls of one pair are at most that many. Returns the
/// descriptor that wakes the caller when it sleeps. Halts on a link that is not `held`, and on a
/// link of another loop (class B).
pub fn answer(
    registry: ?*Registry,
    id: LoopId,
    dispatch: *Dispatch,
    groups: *Groups,
    link: *CallLink,
) ?Descriptor {
    assert(link.state == .held);
    assert(link.target == id);
    const station = &link.stations[id];
    assert(station.held >= 1);
    // Wrapping, so the assertion above is the one check of the count.
    station.held -%= 1;
    const origin = link.origin;
    if (origin == id) {
        // A call to self: the call held and the call out leave the count at once.
        dispatch.callbacks_outstanding -= call_module.self_call_callbacks;
        give_back(dispatch, groups, link);
        return null;
    }
    const known = registry.?;
    const message: Message = .{
        .payload = @intFromPtr(link),
        .tag = constants.message_tag_return,
        .reserved = link.generation,
    };
    link.state = .answered;
    // The push is the last read or write of the link on this loop.
    const pushed = known.mailbox(id, origin).push(message);
    assert(pushed);
    dispatch.callbacks_outstanding -= 1;
    const wake = known.get(origin);
    return if (wake >= 0 and known.must_wake(origin)) wake else null;
}

/// The caller's loop owns the record again: its task runs `finish`, in the call's group.
fn give_back(dispatch: *Dispatch, groups: *Groups, link: *CallLink) void {
    link.state = .back;
    link.task.call = link.finish;
    schedule_link(dispatch, groups, link);
}

/// Queues the record's task in the call's group, with the limit of a call's task (decision 32,
/// ruling item 11). A group that the program filled takes it. The calls bound their tasks at
/// `call_tasks_max`, so the push cannot fail, and a failure halts (class B).
pub fn schedule_link(dispatch: *Dispatch, groups: *Groups, link: *CallLink) void {
    dispatch.schedule_call(groups, link.group.scheduling_group(), &link.task);
}

/// Halts on a handler run that the record does not allow, and answers what the record's task on
/// the target does instead of the handler: `target_stopped` for a station that stopped, `expired`
/// for a deadline at or before `now_ns`, and null when the handler runs.
pub fn verdict(link: *const CallLink, now_ns: u64) ?Outcome {
    assert(link.state == .held);
    const station = &link.stations[link.target];
    assert(station.state != .unused);
    if (station.state == .stopped) return .target_stopped;
    if (link.deadline_ns != 0 and link.deadline_ns <= now_ns) return .expired;
    return null;
}
