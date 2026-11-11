//! Halt scenarios for the reserved tags of the mailbox rings (decisions 29, 32 and 33): the core's
//! push of a call or a return, the drain's slow path and its hook, the registry's mark of a loop
//! that takes calls, and the count that a loop ends with. Each reaches its check through the
//! function's own parameters, or through a state that the scenario sets by hand, and enters no
//! kernel. With the check deleted, each scenario returns, and says how. Moved from the call's
//! scenarios at step 3 of decision 33, when these checks stayed in the core.
const core = @import("core");
const scenario = @import("scenario.zig");

const constants = core.constants;
const Registry = core.mailbox.Registry;
const reserved = core.reserved;

const loops = 2;
var registry_memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
var registry: Registry align(@alignOf(Registry)) = undefined;

/// Two loops on a registry, which both take calls.
fn start() void {
    registry.init(&registry_memory, loops);
    registry.set(0, 100);
    registry.set(1, 101);
    registry.mark_calls(0);
    registry.mark_calls(1);
}

/// A call or a return of a made-up link, as the reactor pushes it (decision 33).
fn reserved_message(tag: u32) core.Message {
    return .{ .payload = 0x1000, .tag = tag, .reserved = 1 };
}

/// A push to the loop that makes it, which no ring serves. With the check deleted, the call goes
/// into the ring from loop 0 to itself, and `push` returns.
fn push_to_the_loop_itself() void {
    start();
    scenario.reached_violation();
    _ = reserved.push(&registry, 0, 0, reserved_message(constants.message_tag_call)) catch return;
}

/// A push of a caller's tag. With the check deleted, `push` pushes it as a return, and returns.
fn push_a_tag_that_is_not_a_call_or_a_return() void {
    start();
    scenario.reached_violation();
    _ = reserved.push(&registry, 0, 1, reserved_message(0)) catch return;
}

/// With the check deleted, the call goes into a ring of shared memory, and `push` returns.
fn push_in_a_registry_of_a_group() void {
    start();
    registry.group = true;
    scenario.reached_violation();
    _ = reserved.push(&registry, 0, 1, reserved_message(constants.message_tag_call)) catch return;
}

/// A return into a ring that every slot fills, which no correct count of calls allows. With the
/// check deleted, the return is dropped, and `push` returns.
fn push_a_return_into_a_full_ring() void {
    start();
    const ring = registry.mailbox(0, 1);
    for (0..constants.mailbox_messages) |_| _ = ring.push(.{ .payload = 0, .tag = 0 });
    scenario.reached_violation();
    _ = reserved.push(&registry, 0, 1, reserved_message(constants.message_tag_return)) catch return;
}

/// A post of the tag of a call: only rotor posts it. With the check deleted, the call's tag is in
/// the ring and `post_now` returns.
fn post_the_tag_of_a_call() void {
    start();
    scenario.reached_violation();
    _ = core.remote.post_now(&registry, 0, 1, .{ .payload = 0, .tag = constants.message_tag_call }) catch return;
}

/// A ring takes back a visit that read nothing, which the drain skips. With the check deleted, the
/// store of `head` changes nothing and returns.
fn release_an_empty_visit() void {
    start();
    const ring = registry.mailbox(0, 1);
    scenario.reached_violation();
    ring.release(.{ .head = 0, .count = 0 });
}

/// A read of a slot past what the visit read. With the check deleted, the read returns a slot that
/// no message filled since `init`.
fn read_a_slot_past_the_visit() void {
    start();
    const ring = registry.mailbox(0, 1);
    scenario.reached_violation();
    _ = ring.message_at(.{ .head = 0, .count = 1 }, 1);
}

/// A slow path that names the receiver as the ring's sender, with a message in the ring from loop 1
/// to itself, which no loop pushes. With the check deleted, the drain skips that ring, finds the
/// other ring empty, and returns.
fn take_the_reserved_tags_of_the_receiver() void {
    start();
    _ = registry.mailbox(1, 1).push(.{ .payload = 0, .tag = 1 });
    var inbox = core.inbox.Inbox.init(&registry, &.{}, null);
    var events: [4]core.Event = undefined;
    scenario.reached_violation();
    _ = core.inbox.take_reserved(&inbox, 1, &events, 1, 0, &reserved.Hook.none);
}

/// A slow path that names a ring that holds nothing. With the check deleted, the drain finds the
/// ring empty and returns.
fn take_the_reserved_tags_of_an_empty_ring() void {
    start();
    var inbox = core.inbox.Inbox.init(&registry, &.{}, null);
    var events: [4]core.Event = undefined;
    scenario.reached_violation();
    _ = core.inbox.take_reserved(&inbox, 1, &events, 0, 0, &reserved.Hook.none);
}

/// A call message, which no `call` sends, that reaches a plain loop with no hook (decision 33,
/// "The reserved hook"). With the check deleted, the drain drops the call and returns.
fn take_a_call_on_a_loop_with_no_hook() void {
    start();
    _ = registry.mailbox(0, 1).push(reserved_message(constants.message_tag_call));
    var inbox = core.inbox.Inbox.init(&registry, &.{}, null);
    var events: [4]core.Event = undefined;
    scenario.reached_violation();
    _ = core.inbox.take_reserved(&inbox, 1, &events, 0, 0, &reserved.Hook.none);
}

/// A wake of the loop that makes it. With the check deleted, the check returns.
fn wake_the_loop_that_makes_the_call() void {
    scenario.reached_violation();
    reserved.assert_wake(3, 3, 7);
}

/// A wake through a descriptor that names no loop. With the check deleted, the check returns.
fn wake_through_no_descriptor() void {
    scenario.reached_violation();
    reserved.assert_wake(3, 4, -1);
}

/// A mark of a loop in a registry of a group, where no call goes. With the check deleted, the mark
/// is stored in shared memory and the call returns.
fn mark_a_loop_of_a_group() void {
    start();
    registry.group = true;
    scenario.reached_violation();
    registry.mark_calls(1);
}

/// A mark of an id that runs no loop. With the check deleted, the mark is stored and the call
/// returns.
fn mark_an_id_that_runs_no_loop() void {
    start();
    registry.clear(1);
    scenario.reached_violation();
    registry.mark_calls(1);
}

/// The entry of an id past the table, which a push reads once for its wake, its mark and its sleep
/// flag. With the check deleted, the read is past the entries, and the scenario returns.
fn read_the_entry_of_an_id_past_the_table() void {
    start();
    scenario.reached_violation();
    _ = registry.target(loops);
}

/// A loop of no kernel: the fields that `core.loop_calls.Calls` reads.
const Host = struct {
    slots: [2]core.Slot,
    entries: [2]core.timer_heap.TimerHeap.Entry,
    starts: [2]u64,
    heartbeat: core.Heartbeat,
    tables: core.Tables,
    inbox: core.inbox.Inbox,
    kept_error: core.tick_error.Kept(error{Unexpected}),

    fn init(host: *Host) void {
        host.tables.init(&host.slots, &host.entries, &host.starts, &host.heartbeat, .{});
        host.inbox = .init(null, &.{}, null);
        host.kept_error = .none;
    }

    pub fn wake_target(_: *Host, _: core.LoopId, _: core.Descriptor) void {}
};

var plain_loop: Host align(@alignOf(Host)) = undefined;

fn ignore(_: *anyopaque, _: core.LoopId, _: core.Message) void {}

/// A hook attached twice: the second would replace the first reactor's. With the check deleted,
/// the second hook is stored and the call returns.
fn attach_a_hook_twice() void {
    plain_loop.init();
    const calls = core.loop_calls.Calls(Host);
    calls.attach_reserved(&plain_loop, &plain_loop, ignore);
    scenario.reached_violation();
    calls.attach_reserved(&plain_loop, &plain_loop, ignore);
}

/// A loop that ends with a callback still counted in `outstanding`: a call out, a record in flight
/// or a task queued, which a reactor's `deinit` lets through. With the check deleted, the check
/// returns.
fn end_a_loop_with_a_callback_counted() void {
    plain_loop.init();
    plain_loop.tables.outstanding = 1;
    scenario.reached_violation();
    plain_loop.tables.assert_ended(false);
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "reserved: push to the loop itself", .run = push_to_the_loop_itself },
    .{ .name = "reserved: push a tag that is not a call or a return", .run = push_a_tag_that_is_not_a_call_or_a_return },
    .{ .name = "reserved: push in a registry of a group", .run = push_in_a_registry_of_a_group },
    .{ .name = "reserved: push a return into a full ring", .run = push_a_return_into_a_full_ring },
    .{ .name = "reserved: post the tag of a call", .run = post_the_tag_of_a_call },
    .{ .name = "mailbox: release an empty visit", .run = release_an_empty_visit },
    .{ .name = "mailbox: read a slot past the visit", .run = read_a_slot_past_the_visit },
    .{ .name = "reserved: take the reserved tags of the receiver", .run = take_the_reserved_tags_of_the_receiver },
    .{ .name = "reserved: take the reserved tags of an empty ring", .run = take_the_reserved_tags_of_an_empty_ring },
    .{ .name = "reserved: take a call on a loop with no hook", .run = take_a_call_on_a_loop_with_no_hook },
    .{ .name = "reserved: wake the loop that makes the call", .run = wake_the_loop_that_makes_the_call },
    .{ .name = "reserved: wake through no descriptor", .run = wake_through_no_descriptor },
    .{ .name = "reserved: mark a loop of a group", .run = mark_a_loop_of_a_group },
    .{ .name = "reserved: mark an id that runs no loop", .run = mark_an_id_that_runs_no_loop },
    .{ .name = "reserved: read the entry of an id past the table", .run = read_the_entry_of_an_id_past_the_table },
    .{ .name = "reserved: attach a hook twice", .run = attach_a_hook_twice },
    .{ .name = "reserved: end a loop with a callback counted", .run = end_a_loop_with_a_callback_counted },
};
