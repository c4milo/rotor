//! Halt scenarios for how a tick shares its events (W3, ruled 2026-11-07): `core.tick_share.split`,
//! the sender cursor of `core.inbox.Inbox`, and `Tables.drain_lists`. Each scenario reaches its
//! assertion through the function's own parameters, or through a field the loop alone writes.
//! With the assertion deleted, each call returns. Split from `core_scenarios.zig` for the
//! 500-line limit.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const Event = core.Event;
const Registry = core.mailbox.Registry;
const Slot = core.Slot;
const TimerHeap = core.timer_heap.TimerHeap;

/// The events of the share scenarios' tick: at or above `fair_events_min`, so the reserves apply.
const share_events = 64;

/// The kernel's room of a readiness backend.
const readiness_room = 256;

/// A kernel that answers and has no room for an answer. With the check deleted, the kernel keeps
/// no place and `split` returns.
fn split_for_a_kernel_with_no_room() void {
    scenario.reached_violation();
    _ = core.tick_share.split(share_events, true, true, 0, 0);
}

/// A backend with more entries of its own than any backend has. With the check deleted, the
/// kernel keeps one place more and `split` returns.
fn split_for_more_own_entries_than_the_most() void {
    const own = core.constants.kernel_own_max + 1;
    scenario.reached_violation();
    _ = core.tick_share.split(share_events, true, true, own, readiness_room);
}

const loops = 3;
var registry_memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
var registry: Registry align(@alignOf(Registry)) = undefined;
var events: [4]Event align(@alignOf(Event)) = undefined;

/// A cursor at the count of loops, one past the last sender. A cursor above 0 takes the drain's one
/// wrapping loop. With the check deleted, that loop wraps to sender 0 before its first visit, visits
/// every ring, all empty, and the drain returns 0. A larger cursor would index past the registry and
/// halt on the bounds check, which would prove nothing.
fn drain_from_a_cursor_past_the_last_loop() void {
    registry.init(&registry_memory, loops);
    var inbox = core.inbox.Inbox.init(&registry, &.{}, null);
    inbox.sender_cursor = loops;
    scenario.reached_violation();
    _ = inbox.drain_mailboxes(0, &events);
}

const slots_count = 4;
var slots: [slots_count]Slot align(@alignOf(Slot)) = undefined;
var entries: [slots_count]TimerHeap.Entry align(@alignOf(TimerHeap.Entry)) = undefined;
var starts: [slots_count]u64 = undefined;
var heartbeat: core.Heartbeat align(@alignOf(core.Heartbeat)) = undefined;
var tables: core.Tables align(@alignOf(core.Tables)) = undefined;

/// A share of the lists larger than the events. With the check deleted, both lists are empty and
/// the drain returns 0.
fn drain_the_lists_into_more_places_than_events() void {
    tables.init(&slots, &entries, &starts, &heartbeat, .{});
    scenario.reached_violation();
    _ = tables.drain_lists(&events, events.len + 1);
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "share: split for a kernel with no room", .run = split_for_a_kernel_with_no_room },
    .{
        .name = "share: split for more own entries than the most",
        .run = split_for_more_own_entries_than_the_most,
    },
    .{
        .name = "share: drain from a cursor past the last loop",
        .run = drain_from_a_cursor_past_the_last_loop,
    },
    .{
        .name = "share: drain the lists into more places than events",
        .run = drain_the_lists_into_more_places_than_events,
    },
};
