//! The cross-core call of decision 32: a request that one loop sends to another loop, which runs a
//! handler and answers. A call is a record that the caller owns, and the ring carries its address.
//! The record holds a task, which the target's drain schedules to run the handler, and the
//! caller's drain schedules again to run `finish`. Each loop schedules the task only on its own
//! queue, and only while it owns the record.
//!
//! This file holds the record's link, the station of one service on one loop, and the caller's
//! side: `call`, `serve`, `stop_serving` and `end_call`. `call_take.zig` holds the target's side
//! and the drain, and `call_service.zig` holds the typed `Service` and `CallRecord` over a view.
//! Nothing here reads a clock. The loop sends a record's address and follows it, and never decides
//! anything from its value (non-negotiable 2).
//!
//! Each change of owner is a ring push and a pop. `mailbox.zig` argues the orderings of a slot's
//! bytes. They also make the request visible to the target and the reply to the caller, so the
//! record needs no atomic.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const mailbox = @import("../mailbox.zig");
const operation = @import("../operation.zig");
const scheduling = @import("../scheduling/scheduling.zig");
const tasks_module = @import("../tasks.zig");

const Dispatch = @import("../dispatch/dispatch.zig").Dispatch;
const Groups = @import("../scheduling/scheduling_groups.zig").Groups;
const Descriptor = operation.Descriptor;
const LoopId = operation.LoopId;
const Message = operation.Message;
const NamedSchedulingGroup = scheduling.NamedSchedulingGroup;
const Registry = mailbox.Registry;
const Task = tasks_module.Task;

pub const take = @import("call_take.zig");
pub const service = @import("call_service.zig");
/// The calls every backend's `Loop` exports: `call_loop.zig`.
pub const loop = @import("call_loop.zig");
pub const Service = service.Service;
pub const CallRecord = service.CallRecord;

/// The callbacks that a call to self counts at once: the call out, and the call held.
pub const self_call_callbacks: u32 = 2;

/// Why `send` sent nothing. `finish` does not run for such a send.
pub const CallError = error{
    /// `calls_per_pair_max` calls to that target have not yet run their `finish`.
    CallsFull,
    /// The ring to that target holds `mailbox_posts_max` messages.
    MailboxFull,
    /// The target has no loop, or the loop left.
    LoopNotFound,
};

/// What a handler returns. The compiler requires a choice, and a reply with `.now`.
pub fn Answer(comptime Reply: type) type {
    return union(enum) { now: Reply, later };
}

/// What `finish` receives. The caller switches on it.
pub fn CallResult(comptime Reply: type) type {
    return union(enum) { replied: *const Reply, expired, target_stopped };
}

/// The options of one `send`.
pub const CallOptions = struct {
    /// The group that the handler runs in on the target, and that `finish` runs in on the caller
    /// (decision 32, "Scheduling groups"). It has no default: a call that wants no group of its own
    /// writes `.default`.
    group: NamedSchedulingGroup,
    /// On the loop clock (`now_ns`), or 0 for none. The target compares it before the handler runs.
    deadline_ns: u64 = 0,
};

/// Who owns a call's record (decision 32, "Ownership").
pub const State = enum(u8) {
    /// The caller, and no call is out.
    idle,
    /// The target, from the push of the call.
    out,
    /// The target, from its drain, or from `call` for a call to self.
    held,
    /// The caller's loop, from the push of the return.
    answered,
    /// The caller's loop, from its drain, or from `answer` for a call to self.
    back,
};

/// How a call ended, which `finish` receives.
pub const Outcome = enum(u8) { replied, expired, target_stopped };

/// The part of a call that the loops schedule and post (decision 32). It sits in the caller's
/// record. Size 64 B, alignment 8.
pub const CallLink = struct {
    /// Its `call` is the service's entry on the target, and the `finish` entry on the caller.
    task: Task,
    /// The service's stations. `send` writes it.
    stations: *[constants.loops_max]CallStation,
    /// A static entry named after the caller's field. `CallRecord.init` writes it.
    finish: *const Task.Call,
    /// The count of the ring from the origin to the target, or the station's `self_out`. `call`
    /// writes it, and the record's task on the caller lowers it before `finish`.
    calls_out: *u32,
    /// On the loop clock, or 0 for none.
    deadline_ns: u64,
    /// Plus 1 for each `send`. The message's `reserved` carries it.
    generation: u32,
    origin: LoopId,
    target: LoopId,
    state: State,
    /// An `Outcome`, which `answer` reads.
    outcome: Outcome,
    /// The caller's choice. `send` writes it.
    group: NamedSchedulingGroup,
    /// True from `prepare` until `end_call`, or until `call` refuses the call. Only the caller's
    /// thread reads or writes it, so `is_out` reads no byte that the target writes. It sits in the
    /// padding.
    sent: bool,

    /// A link that no call has used, whose task runs `finish` on the caller.
    pub fn idle(finish: *const Task.Call) CallLink {
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
    fn refuse(link: *CallLink) void {
        link.state = .idle;
        link.sent = false;
    }

    /// The caller's part of `send`, before the loop's `call`: the link names the target, the
    /// group and the deadline, and the task runs `entry` on the target. Halts when a call is out
    /// with the link already (class B).
    pub fn prepare(
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
};

/// One service on one loop. Only that loop's thread writes it. Size 128 B, alignment 128, so two
/// loops' stations never share a line on Apple silicon (decision 32, open question 6).
pub const CallStation = struct {
    /// What the handler receives. `serve` writes it.
    context: ?*anyopaque align(constants.mailbox_index_alignment),
    /// The loop's view. `serve` writes it, and a call's task reads `now_ns` and answers through it.
    loop: ?*anyopaque,
    /// The calls this station holds: taken, and not yet answered.
    held: u32,
    /// The calls to self that have not yet run their `finish`.
    self_out: u32,
    /// The groups of the loop that counts this station in `Groups.stations`, from its `serve` or
    /// its first call to self, until it stops serving and its last call to self ends. Null while
    /// no loop counts it. So a loop that ends counts none, and a later loop of the id starts from
    /// none (decision 32).
    attached: ?*Groups,
    state: StationState,

    pub const StationState = enum(u8) { unused, serving, stopped };

    pub const unused: CallStation = .{
        .context = null,
        .loop = null,
        .held = 0,
        .self_out = 0,
        .attached = null,
        .state = .unused,
    };
};

comptime {
    assert(@sizeOf(CallLink) == 64);
    assert(@alignOf(CallLink) == 8);
    assert(@sizeOf(CallStation) == 128);
    assert(@alignOf(CallStation) == constants.mailbox_index_alignment);
}

/// Sends the call of `link`, which `prepare` wrote, from loop `id` (decision 32, "The flow", step
/// 2). Returns the descriptor that wakes the target when it sleeps, and null when it is awake or
/// the call is to self. On an error the link is `idle` again, and no count changed.
///
/// It halts on a group id above the caller's named groups, and in a registry of a decision 21
/// group (class B): a pointer does not cross a process.
pub fn call(
    registry: ?*Registry,
    id: LoopId,
    dispatch: *Dispatch,
    groups: *Groups,
    link: *CallLink,
) CallError!?Descriptor {
    assert(link.state == .out);
    assert(@intFromEnum(link.group) <= groups.named);
    if (registry) |known| assert(!known.group);
    link.origin = id;
    if (link.target == id) return call_self(dispatch, groups, link);
    errdefer link.refuse();
    const known = registry orelse return error.LoopNotFound;
    if (link.target >= known.loop_count()) return error.LoopNotFound;
    // Negative covers a loop that is not running and a remote.
    const wake = known.get(link.target);
    if (wake < 0) return error.LoopNotFound;
    const ring = known.mailbox(id, link.target);
    if (ring.calls_out >= constants.calls_per_pair_max) return error.CallsFull;
    link.calls_out = &ring.calls_out;
    const message: Message = .{
        .payload = @intFromPtr(link),
        .tag = constants.message_tag_call,
        .reserved = link.generation,
    };
    if (!ring.push_post(message)) return error.MailboxFull;
    // The target owns the link from the push. Only this loop's counts change after it.
    ring.calls_out += 1;
    dispatch.callbacks_outstanding += 1;
    return if (known.must_wake(link.target)) wake else null;
}

/// A call to the caller's own loop, through no ring. The station's `self_out` bounds it, and the
/// loop counts it twice: out, and held. A station that stopped answers `target_stopped` at once,
/// and the call's task runs `finish` (decision 32, "What was built", item 15).
fn call_self(dispatch: *Dispatch, groups: *Groups, link: *CallLink) CallError!?Descriptor {
    const station = &link.stations[link.origin];
    // A call to a loop that never served halts on the target (class B), here the caller itself.
    assert(station.state != .unused);
    if (station.self_out >= constants.calls_per_pair_max) {
        link.refuse();
        return error.CallsFull;
    }
    attach(groups, station);
    link.calls_out = &station.self_out;
    station.self_out += 1;
    dispatch.callbacks_outstanding += self_call_callbacks;
    link.state = .held;
    station.held += 1;
    if (station.state == .stopped) {
        link.outcome = .target_stopped;
        const wake = take.answer(null, link.origin, dispatch, groups, link);
        assert(wake == null);
        return null;
    }
    take.schedule_link(dispatch, groups, link);
    return null;
}

/// Counts `station` in `groups.stations` when its `serve` or its first call to self reaches it.
/// Halts above `services_max` (class B, cold), and on a station that another loop's groups count
/// (class B): a loop that ends counts no station.
pub fn attach(groups: *Groups, station: *CallStation) void {
    if (station.attached) |counted| {
        assert(counted == groups);
        return;
    }
    station.attached = groups;
    groups.stations += 1;
    assert(groups.stations <= constants.services_max);
}

/// Takes `station` out of the count of its loop's groups once it neither serves nor holds a call
/// to self. Halts on a count of 0 (class B).
pub fn detach(station: *CallStation) void {
    if (station.state == .serving or station.self_out != 0) return;
    const groups = station.attached.?;
    assert(groups.stations >= 1);
    // Wrapping, so the assertion above is the one check of the count.
    groups.stations -%= 1;
    station.attached = null;
}

/// Loop `id` serves the service of `stations`. Returns its station, whose `context` and `loop`
/// the caller writes. Halts on a station that serves (class C), and in a registry of a decision 21
/// group (class B).
pub fn serve(
    registry: ?*Registry,
    id: LoopId,
    groups: *Groups,
    stations: *[constants.loops_max]CallStation,
) *CallStation {
    if (registry) |known| assert(!known.group);
    const station = &stations[id];
    assert(station.state != .serving);
    attach(groups, station);
    station.state = .serving;
    groups.serving += 1;
    return station;
}

/// Loop `id` stops the service of `stations`. A call that reaches it later gets `target_stopped`.
pub fn stop_serving(id: LoopId, groups: *Groups, stations: *[constants.loops_max]CallStation) void {
    const station = &stations[id];
    assert(station.state == .serving);
    assert(groups.serving >= 1);
    station.state = .stopped;
    // Wrapping, so the assertion above is the one check of the count.
    groups.serving -%= 1;
    detach(station);
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
    _ = @import("call_test.zig");
    _ = @import("call_test_claim.zig");
    _ = @import("call_test_model.zig");
    _ = @import("call_test_push.zig");
}
