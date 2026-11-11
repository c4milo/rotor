//! The target's side of a cross-core call (decision 32), and the caller's side of its return: what
//! the reactor's hook does with a call and a return that the core's drain hands it (decision 33,
//! "The reserved hook"). Split from `call.zig`, which holds the link's functions.
//!
//! The drain sends each message whose tag is above `message_tag_max` to the hook, with one compare.
//! A reactor that makes no calls never reaches this file.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("../constants.zig");
const call_module = @import("call.zig");
const reactor_module = @import("../reactor.zig");

const CallLink = reactor_module.CallLink;
const Dispatch = reactor_module.Dispatch;
const LoopId = core.LoopId;
const Message = core.Message;
const Outcome = call_module.Outcome;

/// The hook on the target (decision 32, "The flow", step 3): the target holds the call, and its
/// task waits in the call's group to run the handler. A station that stopped answers
/// `target_stopped` here, and the task does not run on this reactor: a station that an earlier
/// reactor of this id stopped still names that reactor. Halts on a link that the message does not
/// match, on a group id above the target's named groups, on a station that never served, and in a
/// registry of a decision 21 group (class B).
pub fn take_call(dispatch: *Dispatch, loop: anytype, sender: LoopId, message: Message) void {
    assert(!dispatch.in_group);
    const link: *CallLink = @ptrFromInt(message.payload);
    assert(link.state == .out);
    assert(link.origin == sender);
    assert(link.target == dispatch.id);
    assert(link.generation == message.reserved);
    assert(@intFromEnum(link.group) <= dispatch.groups.named);
    const station = &link.stations[dispatch.id];
    assert(station.state != .unused);
    link.state = .held;
    station.held += 1;
    loop.outstanding().* += 1;
    if (station.state == .serving) return schedule_link(dispatch, loop, link);
    link.outcome = .target_stopped;
    answer_held(dispatch, loop, link);
}

/// The hook on the caller (step 6): the caller's reactor owns the record again, and its task waits
/// in the call's group to run `finish`. The call out leaves the count, and the queued task counts in
/// its place. Halts on a link that the message does not match (class B).
pub fn take_return(dispatch: *Dispatch, loop: anytype, sender: LoopId, message: Message) void {
    assert(!dispatch.in_group);
    const link: *CallLink = @ptrFromInt(message.payload);
    assert(link.state == .answered);
    assert(link.origin == dispatch.id);
    assert(link.target == sender);
    assert(link.generation == message.reserved);
    loop.outstanding().* -= 1;
    give_back(dispatch, loop, link);
}

/// The answer on the target (step 5), with the link's `outcome` written. It pushes the return
/// through the port's `push_reserved`, which sees every slot and wakes the caller when it sleeps.
/// A push that fails halts (class B): the posts leave `calls_per_pair_max` slots, and the calls of
/// one pair are at most that many. Halts on a link that is not `held`, and on a link of another
/// reactor (class B).
pub fn answer_held(dispatch: *Dispatch, loop: anytype, link: *CallLink) void {
    assert(link.state == .held);
    assert(link.target == dispatch.id);
    const station = &link.stations[dispatch.id];
    assert(station.held >= 1);
    // Wrapping, so the assertion above is the one check of the count.
    station.held -%= 1;
    const origin = link.origin;
    if (origin == dispatch.id) {
        // A call to self: the call held and the call out leave the count at once.
        loop.outstanding().* -= call_module.self_call_callbacks;
        give_back(dispatch, loop, link);
        return;
    }
    const message: Message = .{
        .payload = @intFromPtr(link),
        .tag = constants.message_tag_return,
        .reserved = link.generation,
    };
    link.state = .answered;
    // The push is the last read or write of the link on this reactor.
    _ = loop.push_reserved(origin, message) catch unreachable;
    loop.outstanding().* -= 1;
}

/// The caller's reactor owns the record again: its task runs `finish`, in the call's group. Halts
/// on a `finish` entry that does not mark a call's task (class B): `discard_tasks` reads the mark.
fn give_back(dispatch: *Dispatch, loop: anytype, link: *CallLink) void {
    assert(link.finish.call_record);
    link.state = .back;
    link.task.call = link.finish;
    schedule_link(dispatch, loop, link);
}

/// Queues the record's task in the call's group, with the limit of a call's task (decision 32,
/// ruling item 11). A group that the program filled takes it. The calls bound their tasks at
/// `call_tasks_max`, so the push cannot fail, and a failure halts (class B). Halts on a link that
/// this reactor does not own: one that is neither `held` nor `back` (class B).
pub fn schedule_link(dispatch: *Dispatch, loop: anytype, link: *CallLink) void {
    assert(link.state == .held or link.state == .back);
    dispatch.schedule_call(loop, link.group.group(), &link.task);
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
