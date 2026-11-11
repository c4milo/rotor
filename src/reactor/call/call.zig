//! The cross-core call of decision 32: a request that one reactor sends to another, which runs a
//! handler and answers. A call is a record that the caller owns, and the ring carries its address.
//! The record holds a task, which the target's hook schedules to run the handler, and the caller's
//! hook schedules again to run `finish`. Each reactor schedules the task only on its own queue, and
//! only while it owns the record.
//!
//! The root of `reactor` declares the types of a call that a program can see: `CallLink`,
//! `CallStation`, `CallOptions`, `Answer` and `CallResult` (decision 33, "Where each type is
//! declared"). This file holds the link's functions and the stations' count. `call_loop.zig` holds
//! the calls of a reactor and its hook, `call_take.zig` the target's side, and `call_service.zig`
//! the typed `Service` and `CallRecord` over a view. Nothing here reads a clock. The reactor sends
//! a record's address and follows it, and never decides anything from its value (non-negotiable 2).
//!
//! Each change of owner is a ring push and a pop. `core/mailbox.zig` argues the orderings of a
//! slot's bytes. They also make the request visible to the target and the reply to the caller, so
//! the record needs no atomic. The core carries the ring, the reserved tags and the kept slots, and
//! hands each call and return to the reactor's hook (decision 33, "The line").
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("../constants.zig");
const reactor_module = @import("../reactor.zig");

const CallLink = reactor_module.CallLink;
const CallOptions = reactor_module.CallOptions;
const CallStation = reactor_module.CallStation;
const Groups = reactor_module.Groups;
const LoopId = core.LoopId;
const Task = reactor_module.Task;

pub const take = @import("call_take.zig");
pub const service = @import("call_service.zig");
/// The calls of a reactor and its hook: `call_loop.zig`.
pub const loop = @import("call_loop.zig");

/// The callbacks that a call to self counts at once: the call out, and the call held.
pub const self_call_callbacks: u32 = 2;

/// Why `send` sent nothing. `finish` does not run for such a send. It is the core's set for a push
/// into a ring's kept slots: `LoopNotFound` also covers a target that takes no calls (decision 33,
/// open question 12).
pub const CallError = core.reserved.PushError;

/// Who owns a call's record (decision 32, "Ownership").
pub const State = enum(u8) {
    /// The caller, and no call is out.
    idle,
    /// The target, from the push of the call.
    out,
    /// The target, from its hook, or from `call` for a call to self.
    held,
    /// The caller's reactor, from the push of the return.
    answered,
    /// The caller's reactor, from its hook, or from `answer` for a call to self.
    back,
};

/// How a call ended, which `finish` receives.
pub const Outcome = enum(u8) { replied, expired, target_stopped };

comptime {
    assert(@sizeOf(CallLink) == 64);
    assert(@alignOf(CallLink) == 8);
    assert(@sizeOf(CallStation) == 128);
    assert(@alignOf(CallStation) == constants.mailbox_index_alignment);
}

/// A link that no call has used, whose task runs `finish` on the caller. `CallLink.idle`.
pub fn link_idle(finish: *const Task.Call) CallLink {
    return .{
        .task = .{ .call = finish },
        .stations = undefined,
        .finish = finish,
        .calls_out = undefined,
        .deadline_ns = 0,
        .generation = 0,
        .origin = 0,
        .target = 0,
        .state = .idle,
        .outcome = .replied,
        .group = .default,
        .sent = false,
    };
}

/// The caller owns the link again: `call` refused the call, and nothing was sent.
pub fn refuse(link: *CallLink) void {
    link.state = .idle;
    link.sent = false;
}

/// The caller's part of `send`, before the reactor's `call`: the link names the target, the group
/// and the deadline, and the task runs `entry` on the target. Halts when a call is out with the
/// link already (class B). `CallLink.prepare`.
pub fn link_prepare(
    link: *CallLink,
    stations: *[constants.loops_max]CallStation,
    entry: *const Task.Call,
    target: LoopId,
    options: CallOptions,
) void {
    assert(!link.sent);
    assert(link.task.next == null);
    link.stations = stations;
    link.task.call = entry;
    link.target = target;
    link.group = options.group;
    link.deadline_ns = options.deadline_ns;
    link.generation +%= 1;
    link.state = .out;
    link.sent = true;
}

/// Counts `station` in `groups.stations` when its `serve` or its first call to self reaches it.
/// Halts above `services_max` (class B, cold), and on a station that another reactor's groups count
/// (class B): a reactor that ends counts no station.
pub fn attach(groups: *Groups, station: *CallStation) void {
    if (station.attached) |counted| {
        assert(counted == groups);
        return;
    }
    station.attached = groups;
    groups.stations += 1;
    assert(groups.stations <= constants.services_max);
}

/// Takes `station` out of the count of its reactor's groups once it neither serves nor holds a
/// call to self. Halts on a count of 0 (class B).
pub fn detach(station: *CallStation) void {
    if (station.state == .serving or station.self_out != 0) return;
    const groups = station.attached.?;
    assert(groups.stations >= 1);
    // Wrapping, so the assertion above is the one check of the count.
    groups.stations -%= 1;
    station.attached = null;
}

/// The caller's part of the record's last task, before `finish` (decision 32, "The flow", step 7):
/// the link is `idle` again, and the count of the pair falls. So `finish` may send the record
/// again. Halts on a link that is not `back`, and on a count of 0 (class B).
pub fn end_call(link: *CallLink) Outcome {
    assert(link.state == .back);
    const count = link.calls_out;
    assert(count.* >= 1);
    // Wrapping, so the assertion above is the one check of the count.
    count.* -%= 1;
    link.state = .idle;
    link.sent = false;
    if (link.origin == link.target) detach(&link.stations[link.origin]);
    return link.outcome;
}

test {
    _ = take;
    _ = service;
    _ = loop;
    _ = @import("call_test.zig");
    _ = @import("call_test_claim.zig");
    _ = @import("call_test_model.zig");
}
