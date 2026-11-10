//! The calls of decision 32 that every backend's `Loop` exports, written once: `call`, `answer`,
//! `serve` and `stop_serving`. Only `Service` and `CallRecord` call them. `Loop` has a
//! `tables: Tables` field and an `inbox: Inbox` field, and a `wake_target` function that makes
//! the backend's own wake of a loop that sleeps, as its `post` does. Also `push_reserved`, a name
//! of the port of decision 33.
const std = @import("std");
const constants = @import("../constants.zig");
const assert = std.debug.assert;
const call_module = @import("call.zig");
const call_take = @import("call_take.zig");
const event = @import("../event.zig");
const inbox_module = @import("../inbox.zig");
const mailbox = @import("../mailbox.zig");
const operation = @import("../operation.zig");

const CallError = call_module.CallError;
const CallLink = call_module.CallLink;
const CallStation = call_module.CallStation;
const Descriptor = operation.Descriptor;
const Event = event.Event;
const Inbox = inbox_module.Inbox;
const LoopId = operation.LoopId;
const Message = operation.Message;
const Registry = mailbox.Registry;

/// What each backend's `wake_target` checks: a call or an answer wakes another loop, never the
/// loop that makes it, through a descriptor that names a loop (class B).
pub fn assert_wake(id: LoopId, target: LoopId, descriptor: Descriptor) void {
    assert(target != id);
    assert(descriptor >= 0);
}

/// What `push` did: the count of calls out of the ring that it wrote, and the descriptor that wakes
/// the target, or null when the target is awake.
pub const Pushed = struct {
    calls_out: *u32,
    wake: ?Descriptor,
};

/// Pushes `message`, a call or a return of decision 32, from loop `id` into its ring to loop
/// `target`, as `call.call` and `call_take.answer` push today. It changes no count: the caller
/// raises the count of a call after the push, and a return changes no count (decision 33,
/// amendment of 2026-11-10). Halts on a target that is the loop itself, because a call to self
/// takes no ring, on a tag that is neither, and in a registry of a decision 21 group (class B).
pub fn push(registry: ?*Registry, id: LoopId, target: LoopId, message: Message) CallError!Pushed {
    const tag = message.tag;
    assert(target != id);
    assert(tag == constants.message_tag_call or tag == constants.message_tag_return);
    if (registry) |known| assert(!known.group);
    if (tag == constants.message_tag_call) return push_call(registry, id, target, message);
    return push_return(registry.?, id, target, message);
}

/// A call sees the slots that a post sees, and fails as `call.call` fails: `LoopNotFound` for a
/// target that runs no loop, `CallsFull` for a pair with `calls_per_pair_max` calls out, and
/// `MailboxFull` for a ring that holds `mailbox_posts_max` messages.
fn push_call(registry: ?*Registry, id: LoopId, target: LoopId, message: Message) CallError!Pushed {
    const known = registry orelse return error.LoopNotFound;
    if (target >= known.loop_count()) return error.LoopNotFound;
    // Negative covers a loop that is not running and a remote.
    const wake = known.get(target);
    if (wake < 0) return error.LoopNotFound;
    const ring = known.mailbox(id, target);
    if (ring.calls_out >= constants.calls_per_pair_max) return error.CallsFull;
    if (!ring.push_post(message)) return error.MailboxFull;
    return .{ .calls_out = &ring.calls_out, .wake = if (known.must_wake(target)) wake else null };
}

/// A return sees every slot, as `call_take.answer` does. The posts leave `calls_per_pair_max`
/// slots, and the calls of one pair are at most that many, so a push that fails halts (class B).
fn push_return(registry: *Registry, id: LoopId, target: LoopId, message: Message) Pushed {
    const ring = registry.mailbox(id, target);
    const pushed = ring.push(message);
    assert(pushed);
    const wake = registry.get(target);
    const sleeps = wake >= 0 and registry.must_wake(target);
    return .{ .calls_out = &ring.calls_out, .wake = if (sleeps) wake else null };
}

pub fn Calls(comptime Loop: type) type {
    return struct {
        /// Sends the call of `link`, which `CallLink.prepare` wrote (decision 32). Each call checks
        /// that the loop's own thread makes it (decision 8, class B).
        pub fn call(loop: *Loop, link: *CallLink) CallError!void {
            loop.tables.assert_owner();
            const tables = &loop.tables;
            const wake = try call_module.call(loop.inbox.registry, tables.id, &tables.dispatch, tables.groups, link);
            const descriptor = wake orelse return;
            loop.wake_target(link.target, descriptor);
        }

        /// Answers the call of `link`, which this loop holds, with the outcome the link holds.
        pub fn answer(loop: *Loop, link: *CallLink) void {
            loop.tables.assert_owner();
            const tables = &loop.tables;
            // The answer pushes the return, so the origin is read first.
            const origin = link.origin;
            const wake = call_take.answer(loop.inbox.registry, tables.id, &tables.dispatch, tables.groups, link);
            const descriptor = wake orelse return;
            loop.wake_target(origin, descriptor);
        }

        /// This loop serves the service of `stations`, and returns its station.
        pub fn serve(loop: *Loop, stations: *[constants.loops_max]CallStation) *CallStation {
            loop.tables.assert_owner();
            return call_module.serve(loop.inbox.registry, loop.tables.id, loop.tables.groups, stations);
        }

        /// This loop stops the service of `stations`.
        pub fn stop_serving(loop: *Loop, stations: *[constants.loops_max]CallStation) void {
            loop.tables.assert_owner();
            call_module.stop_serving(loop.tables.id, loop.tables.groups, stations);
        }

        /// The slow path of the loop's drain (`Inbox.TakeReserved`): `Inbox.take_reserved` with the
        /// loop's dispatch, groups and wake. A backend calls it from its own `take_reserved`, which
        /// keeps it out of the tick (decision 7).
        pub fn take_reserved(inbox: *Inbox, receiver: LoopId, events: []Event, first: LoopId, written: u32) u32 {
            const loop: *Loop = @alignCast(@fieldParentPtr("inbox", inbox));
            const tables = &loop.tables;
            const waker: call_take.Waker = .{ .context = loop, .wake = wake_erased };
            return inbox_module.take_reserved(inbox, receiver, events, first, written, &tables.dispatch, tables.groups, waker);
        }

        /// `wake_target`, through a `Waker`'s context.
        fn wake_erased(context: *anyopaque, target: LoopId, descriptor: Descriptor) void {
            const loop: *Loop = @ptrCast(@alignCast(context));
            loop.wake_target(target, descriptor);
        }

        /// The callbacks that the loop still owes: operations with a record, tasks queued, calls out
        /// and calls held. `drain` ticks until it is 0 (decision 32).
        pub fn callbacks_outstanding(loop: *const Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.callbacks_outstanding;
        }

        /// Pushes `message`, a call or a return, into the ring from this loop to `target`, then
        /// wakes `target` when it sleeps (`push`). Returns the count of calls out of that ring,
        /// which the reactor raises after the push of a call. A name of the port of decision 33:
        /// it makes no owner check, because the reactor calls it inside its own calls and drain.
        pub fn push_reserved(loop: *Loop, target: LoopId, message: Message) CallError!*u32 {
            const pushed = try push(loop.inbox.registry, loop.tables.id, target, message);
            if (pushed.wake) |descriptor| loop.wake_target(target, descriptor);
            return pushed.calls_out;
        }
    };
}
