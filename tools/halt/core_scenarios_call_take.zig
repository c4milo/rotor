//! Halt scenarios for the target's side of the cross-core call of decision 32, and for the drain
//! of the reserved tags: `core.call.take`. Each reaches its check through the function's own
//! parameters: a message and a link that the scenario writes by hand. With the check deleted, each
//! scenario returns, and says how.
const core = @import("core");
const scenario = @import("scenario.zig");
const fixture = @import("core_scenarios_call.zig");

const call = core.call;
const take = call.take;
const Message = core.Message;
const constants = core.constants;

/// What the drain of loop `receiver` hands the cold path for the ring from `sender`.
fn taker_of(sender: core.LoopId, receiver: core.LoopId) take.Taker {
    return .{
        .registry = &fixture.registry,
        .dispatch = &fixture.dispatch,
        .groups = &fixture.groups,
        .receiver = receiver,
        .sender = sender,
        .woke = false,
    };
}

/// The message of the call of `fixture.link`, as loop 0 pushed it.
fn call_message() Message {
    return .{ .payload = @intFromPtr(&fixture.link), .tag = constants.message_tag_call, .reserved = fixture.link.generation };
}

/// A call from loop 0 to loop 1 that loop 0 sent: the link is out.
fn sent() void {
    fixture.prepared(.default);
    fixture.link.origin = 0;
}

/// Takes `message` on loop 1, from the ring of loop 0, after the scenario's marker.
fn take_on_loop_one(message: Message) void {
    var taker = taker_of(0, 1);
    scenario.reached_violation();
    take.take_reserved(&taker, message);
}

/// With the check deleted, loop 1 holds a call that is idle and queues its task.
fn take_a_call_whose_link_is_not_out() void {
    sent();
    fixture.link.state = .idle;
    take_on_loop_one(call_message());
}

/// A link that names loop 1 as its origin, on the ring from loop 0. With the check deleted, the
/// call is held and its task queued.
fn take_a_call_with_a_wrong_origin() void {
    sent();
    fixture.link.origin = 1;
    take_on_loop_one(call_message());
}

/// A link that names loop 0 as its target, drained on loop 1. With the check deleted, the call
/// is held and its task queued.
fn take_a_call_with_a_wrong_target() void {
    sent();
    fixture.link.target = 0;
    take_on_loop_one(call_message());
}

/// A message whose generation is not the link's. With the check deleted, the call is held.
fn take_a_call_with_a_wrong_generation() void {
    sent();
    var message = call_message();
    message.reserved +%= 1;
    take_on_loop_one(message);
}

/// A group id above the target's named groups. The target reserved one group of its own, so the
/// task's push takes it. With the check deleted, the call is held in that group.
fn take_a_call_with_a_forged_group_id() void {
    sent();
    _ = fixture.groups.reserve(constants.scheduling_shares_default) catch return;
    fixture.link.group = @enumFromInt(1);
    take_on_loop_one(call_message());
}

/// A call to a loop whose station never served. With the check deleted, the call is held.
fn take_a_call_on_a_station_that_never_served() void {
    sent();
    fixture.stations[1].state = .unused;
    take_on_loop_one(call_message());
}

/// A call's tag in a registry of a decision 21 group, which a peer of an older build sent as data.
/// With the check deleted, the call is held.
fn take_a_call_in_a_registry_of_a_group() void {
    sent();
    fixture.registry.group = true;
    take_on_loop_one(call_message());
}

/// The return of the call of `fixture.link`, as loop 1 pushed it to loop 0.
fn return_message() Message {
    return .{ .payload = @intFromPtr(&fixture.link), .tag = constants.message_tag_return, .reserved = fixture.link.generation };
}

/// A call that loop 1 answered: the link is answered, and its count is 1.
fn answered() void {
    sent();
    fixture.link.state = .answered;
    fixture.count = 1;
    fixture.link.calls_out = &fixture.count;
}

/// Takes `message` on loop 0, from the ring of loop 1, after the scenario's marker.
fn take_on_loop_zero(message: Message) void {
    var taker = taker_of(1, 0);
    // The call out is counted, as `call` counted it.
    fixture.dispatch.callbacks_outstanding = 1;
    scenario.reached_violation();
    take.take_reserved(&taker, message);
}

/// With the check deleted, the caller's task is queued for a link that is still held.
fn take_a_return_whose_link_is_not_answered() void {
    answered();
    fixture.link.state = .held;
    take_on_loop_zero(return_message());
}

/// With the check deleted, the caller's task is queued on a loop that did not send the call.
fn take_a_return_with_a_wrong_origin() void {
    answered();
    fixture.link.origin = 1;
    take_on_loop_zero(return_message());
}

/// With the check deleted, the caller's task is queued for a return from a loop the call did not
/// reach.
fn take_a_return_with_a_wrong_target() void {
    answered();
    fixture.link.target = 0;
    take_on_loop_zero(return_message());
}

/// With the check deleted, the caller's task is queued.
fn take_a_return_with_a_wrong_generation() void {
    answered();
    var message = return_message();
    message.reserved +%= 1;
    take_on_loop_zero(message);
}

/// With the check deleted, the caller's task is queued.
fn take_a_return_in_a_registry_of_a_group() void {
    answered();
    fixture.registry.group = true;
    take_on_loop_zero(return_message());
}

/// A tag above `message_tag_wake`, which no post accepts. With the check deleted, the drain drops
/// it and returns.
fn take_a_tag_above_the_wake() void {
    sent();
    var message = call_message();
    message.tag = constants.message_tag_wake + 1;
    take_on_loop_one(message);
}

/// A call that loop 1 holds, as its drain left it, with its task unlinked, as the run does before
/// the handler.
fn held() void {
    sent();
    var taker = taker_of(0, 1);
    take.take_reserved(&taker, call_message());
    _ = fixture.dispatch.tasks.pop();
}

/// A second answer, on a station that counts a call held again. With the check deleted, a second
/// return is pushed and `answer` returns.
fn answer_a_call_twice() void {
    held();
    _ = take.answer(&fixture.registry, 1, &fixture.dispatch, &fixture.groups, &fixture.link);
    fixture.stations[1].held = 1;
    scenario.reached_violation();
    _ = take.answer(&fixture.registry, 1, &fixture.dispatch, &fixture.groups, &fixture.link);
}

/// An answer through loop 0, which does not hold the call, on a station that counts one. With the
/// check deleted, the answer takes the path of a call to self and returns.
fn answer_on_a_loop_that_does_not_hold_the_call() void {
    held();
    fixture.stations[0].held = 1;
    fixture.dispatch.callbacks_outstanding = 2;
    scenario.reached_violation();
    _ = take.answer(&fixture.registry, 0, &fixture.dispatch, &fixture.groups, &fixture.link);
}

/// A held call whose station counts none. With the check deleted, the count wraps and the return
/// is pushed.
fn answer_with_no_call_held_on_the_station() void {
    held();
    fixture.stations[1].held = 0;
    scenario.reached_violation();
    _ = take.answer(&fixture.registry, 1, &fixture.dispatch, &fixture.groups, &fixture.link);
}

/// A ring from loop 1 to loop 0 that every slot fills, which the posts' share and the bound of the
/// calls prevent. With the check deleted, the return is lost and `answer` returns.
fn answer_into_a_full_ring() void {
    held();
    const ring = fixture.registry.mailbox(1, 0);
    for (0..constants.mailbox_messages) |payload| {
        if (!ring.push(.{ .payload = payload, .tag = 1 })) return;
    }
    scenario.reached_violation();
    _ = take.answer(&fixture.registry, 1, &fixture.dispatch, &fixture.groups, &fixture.link);
}

/// The record's task on the target with a link that is not held. With the check deleted, the
/// verdict lets the handler run.
fn run_the_handler_of_a_call_that_is_not_held() void {
    sent();
    scenario.reached_violation();
    _ = take.verdict(&fixture.link, 0);
}

/// The record's task on a station that never served. With the check deleted, the verdict lets the
/// handler run.
fn run_the_handler_on_a_station_that_never_served() void {
    held();
    fixture.stations[1].state = .unused;
    scenario.reached_violation();
    _ = take.verdict(&fixture.link, 0);
}

/// A view that a record's `request_of` never calls.
const NoView = opaque {};

/// The request of a record that the target does not hold. With the check deleted, `request_of`
/// returns it.
fn read_the_request_of_a_record_that_is_not_held() void {
    const Record = call.CallRecord(NoView, u64, u64);
    var record: Record = .{ .link = .idle(&fixture.finish_call), .request = 1, .reply = 0 };
    scenario.reached_violation();
    _ = record.request_of();
}

/// A call's task pushed again while it is queued in a group other than `.default`. With the check
/// deleted, the lane links the task to itself, and the push returns.
fn queue_the_task_of_a_call_twice() void {
    sent();
    fixture.groups.init(&core.scheduling.Named(.{ .low = 100 }).table);
    fixture.link.group = @enumFromInt(1);
    take.schedule_link(&fixture.dispatch, &fixture.groups, &fixture.link);
    scenario.reached_violation();
    take.schedule_link(&fixture.dispatch, &fixture.groups, &fixture.link);
}

/// A tick with the task of a call queued, which the tick did not count. With the check deleted, the
/// loop ends with a call out.
fn end_a_loop_with_a_call_out() void {
    sent();
    fixture.dispatch.callbacks_outstanding = 1;
    scenario.reached_violation();
    core.Tables.assert_calls_ended(&fixture.dispatch, &fixture.groups, false);
}

/// With the check deleted, the loop ends with a station that serves.
fn end_a_loop_with_a_station_that_serves() void {
    sent();
    fixture.groups.serving = 1;
    scenario.reached_violation();
    core.Tables.assert_calls_ended(&fixture.dispatch, &fixture.groups, false);
}

/// A post of the tag of a call: only rotor posts it. With the check deleted, the call's tag is in
/// the ring and `post_now` returns.
fn post_the_tag_of_a_call() void {
    fixture.start();
    scenario.reached_violation();
    _ = core.remote.post_now(&fixture.registry, 0, 1, .{ .payload = 0, .tag = constants.message_tag_call }) catch return;
}

/// The push of a call's task into `.default` with the queue at the limit of a call's task, which
/// the bound of the calls prevents. With the check deleted, the push is dropped and returns.
fn queue_a_call_in_a_full_default_queue() void {
    sent();
    fixture.dispatch.tasks.count = constants.task_queue_length_max;
    scenario.reached_violation();
    fixture.dispatch.schedule_call(&fixture.groups, .default, &fixture.link.task);
}

/// The same, in a group other than `.default`.
fn queue_a_call_in_a_full_group() void {
    sent();
    fixture.groups.init(&core.scheduling.Named(.{ .low = 100 }).table);
    fixture.groups.lanes[1].count = constants.task_queue_length_max;
    scenario.reached_violation();
    fixture.dispatch.schedule_call(&fixture.groups, @enumFromInt(1), &fixture.link.task);
}

/// A ring takes back a visit that read nothing, which the drain skips. With the check deleted, the
/// store of `head` changes nothing and returns.
fn release_an_empty_visit() void {
    fixture.start();
    const ring = fixture.registry.mailbox(0, 1);
    scenario.reached_violation();
    ring.release(.{ .head = 0, .count = 0 });
}

/// A read of a slot past what the visit read. With the check deleted, the read returns a slot that
/// no message filled since `init`.
fn read_a_slot_past_the_visit() void {
    fixture.start();
    const ring = fixture.registry.mailbox(0, 1);
    scenario.reached_violation();
    _ = ring.message_at(.{ .head = 0, .count = 1 }, 1);
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "call: queue a call in a full default queue", .run = queue_a_call_in_a_full_default_queue },
    .{ .name = "call: queue a call in a full group", .run = queue_a_call_in_a_full_group },
    .{ .name = "mailbox: release an empty visit", .run = release_an_empty_visit },
    .{ .name = "mailbox: read a slot past the visit", .run = read_a_slot_past_the_visit },
    .{ .name = "call: take a call whose link is not out", .run = take_a_call_whose_link_is_not_out },
    .{ .name = "call: take a call with a wrong origin", .run = take_a_call_with_a_wrong_origin },
    .{ .name = "call: take a call with a wrong target", .run = take_a_call_with_a_wrong_target },
    .{ .name = "call: take a call with a wrong generation", .run = take_a_call_with_a_wrong_generation },
    .{ .name = "call: take a call with a forged group id", .run = take_a_call_with_a_forged_group_id },
    .{ .name = "call: take a call on a station that never served", .run = take_a_call_on_a_station_that_never_served },
    .{ .name = "call: take a call in a registry of a group", .run = take_a_call_in_a_registry_of_a_group },
    .{ .name = "call: take a return whose link is not answered", .run = take_a_return_whose_link_is_not_answered },
    .{ .name = "call: take a return with a wrong origin", .run = take_a_return_with_a_wrong_origin },
    .{ .name = "call: take a return with a wrong target", .run = take_a_return_with_a_wrong_target },
    .{ .name = "call: take a return with a wrong generation", .run = take_a_return_with_a_wrong_generation },
    .{ .name = "call: take a return in a registry of a group", .run = take_a_return_in_a_registry_of_a_group },
    .{ .name = "call: take a tag above the wake", .run = take_a_tag_above_the_wake },
    .{ .name = "call: answer a call twice", .run = answer_a_call_twice },
    .{ .name = "call: answer on a loop that does not hold the call", .run = answer_on_a_loop_that_does_not_hold_the_call },
    .{ .name = "call: answer with no call held on the station", .run = answer_with_no_call_held_on_the_station },
    .{ .name = "call: answer into a full ring", .run = answer_into_a_full_ring },
    .{ .name = "call: run the handler of a call that is not held", .run = run_the_handler_of_a_call_that_is_not_held },
    .{ .name = "call: run the handler on a station that never served", .run = run_the_handler_on_a_station_that_never_served },
    .{ .name = "call: read the request of a record that is not held", .run = read_the_request_of_a_record_that_is_not_held },
    .{ .name = "call: queue the task of a call twice", .run = queue_the_task_of_a_call_twice },
    .{ .name = "call: end a loop with a call out", .run = end_a_loop_with_a_call_out },
    .{ .name = "call: end a loop with a station that serves", .run = end_a_loop_with_a_station_that_serves },
    .{ .name = "call: post the tag of a call", .run = post_the_tag_of_a_call },
};
