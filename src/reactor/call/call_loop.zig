//! The calls of decision 32 on a reactor's state and its loop: `call`, `answer`, `serve` and
//! `stop_serving`, which only `Service` and `CallRecord` make, and the hook that the core's drain
//! hands each wake, call and return (decision 33, "The reserved hook"). `Dispatch` declares each
//! one. The reactor sends a call or a return through the port's `push_reserved`, which pushes it
//! into a ring's kept slots and wakes the target when it sleeps.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("../constants.zig");
const call_module = @import("call.zig");
const call_take = @import("call_take.zig");
const reactor_module = @import("../reactor.zig");

const CallError = call_module.CallError;
const CallLink = reactor_module.CallLink;
const CallStation = reactor_module.CallStation;
const Dispatch = reactor_module.Dispatch;
const LoopId = core.LoopId;
const Message = core.Message;

/// Sends the call of `link`, which `CallLink.prepare` wrote (decision 32, "The flow", step 2). On an
/// error the link is `idle` again, and no count changed. `LoopNotFound` also covers a target whose
/// loop takes no calls: a plain loop, which the push finds unmarked in its registry (decision 33,
/// open question 12). Halts on a group id above the caller's named groups, and in a registry of a
/// decision 21 group (class B): a pointer does not cross a process.
pub fn call(dispatch: *Dispatch, loop: anytype, link: *CallLink) CallError!void {
    loop.assert_owner();
    assert(link.state == .out);
    assert(@intFromEnum(link.group) <= dispatch.groups.named);
    assert(!dispatch.in_group);
    link.origin = dispatch.id;
    if (link.target == dispatch.id) return call_self(dispatch, loop, link);
    errdefer call_module.refuse(link);
    const message: Message = .{
        .payload = @intFromPtr(link),
        .tag = constants.message_tag_call,
        .reserved = link.generation,
    };
    const calls_out = try loop.push_reserved(link.target, message);
    // The target owns the link from the push, and never reads `calls_out`, which only this
    // reactor's `finish` reads. Only this reactor's counts change after the push.
    link.calls_out = calls_out;
    calls_out.* += 1;
    loop.outstanding().* += 1;
}

/// A call to the caller's own reactor, through no ring. The station's `self_out` bounds it, and the
/// reactor counts it twice: out, and held. A station that stopped answers `target_stopped` at once,
/// and the call's task runs `finish` (decision 32, "What was built", item 15).
fn call_self(dispatch: *Dispatch, loop: anytype, link: *CallLink) CallError!void {
    const station = &link.stations[link.origin];
    // A call to a reactor that never served halts on the target (class B), here the caller itself.
    assert(station.state != .unused);
    if (station.self_out >= constants.calls_per_pair_max) {
        call_module.refuse(link);
        return error.CallsFull;
    }
    call_module.attach(dispatch.groups, station);
    link.calls_out = &station.self_out;
    station.self_out += 1;
    loop.outstanding().* += call_module.self_call_callbacks;
    link.state = .held;
    station.held += 1;
    if (station.state == .stopped) {
        link.outcome = .target_stopped;
        return call_take.answer_held(dispatch, loop, link);
    }
    call_take.schedule_link(dispatch, loop, link);
}

/// Answers the call of `link`, which this reactor holds, with the outcome the link holds. It is
/// never refused.
pub fn answer(dispatch: *Dispatch, loop: anytype, link: *CallLink) void {
    loop.assert_owner();
    call_take.answer_held(dispatch, loop, link);
}

/// This reactor serves the service of `stations`. Returns its station, whose `context` and `loop`
/// the caller writes. Halts on a station that serves (class C), and in a registry of a decision 21
/// group (class B).
pub fn serve(dispatch: *Dispatch, loop: anytype, stations: *[constants.loops_max]CallStation) *CallStation {
    loop.assert_owner();
    assert(!dispatch.in_group);
    const station = &stations[dispatch.id];
    assert(station.state != .serving);
    call_module.attach(dispatch.groups, station);
    station.state = .serving;
    dispatch.groups.serving += 1;
    return station;
}

/// This reactor stops the service of `stations`. A call that reaches it later gets
/// `target_stopped`.
pub fn stop_serving(dispatch: *Dispatch, loop: anytype, stations: *[constants.loops_max]CallStation) void {
    loop.assert_owner();
    const station = &stations[dispatch.id];
    const groups = dispatch.groups;
    assert(station.state == .serving);
    assert(groups.serving >= 1);
    station.state = .stopped;
    // Wrapping, so the assertion above is the one check of the count.
    groups.serving -%= 1;
    call_module.detach(station);
}

/// The hook: what the core's drain hands each reserved message, in the order of its ring. A wake
/// makes the next tick not block before the pollers run, so it stores `.now` while a poller is
/// added: only then does the next tick run `begin`, which writes the limit again (decision 29). A
/// call queues the task of its handler, and a return the task of `finish`. Halts on a state that
/// `start` did not write (class C), and on any other tag (class B).
pub fn take_reserved(dispatch: *Dispatch, loop: anytype, sender: LoopId, message: Message) void {
    dispatch.assert_started();
    switch (message.tag) {
        constants.message_tag_wake => {
            if (dispatch.poller_count != 0) loop.stored_limit().* = .now;
        },
        constants.message_tag_call => call_take.take_call(dispatch, loop, sender, message),
        constants.message_tag_return => call_take.take_return(dispatch, loop, sender, message),
        else => unreachable,
    }
}
