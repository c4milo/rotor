//! The fair tick order on the readiness backends (W3, ruled 2026-11-07, finding F4): receives that
//! the flush completes inline keep the finished list long, and a readiness the kernel holds still
//! reaches the caller. Before W3 the finished list took every place of such a tick, the `kevent` or
//! `epoll_pwait2` call got no room, and an accept that waited for its connection never ended.
//!
//! It runs on kqueue and epoll only: on io_uring the kernel performs a receive, and no flush ends
//! one inline.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const constants = @import("constants.zig");
const fair_module = @import("conformance_fair.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const FairLoop = fair_module.FairLoop;

/// The events of each tick of the scenario: the case of finding F4.
const readiness_events = 256;

/// The ticks within which the accept's event comes: the connection is queued before the first.
const accept_ticks_max = 2;

const receive_user_data = 1;
const accept_user_data = 2;

/// Ticks the loop once, posts again each receive that ended, and returns the result of the
/// accept's event when the tick handed it over. Every tick hands over all its events.
fn tick(fair: *FairLoop, socket: core.Descriptor, bytes: []u8) !?i32 {
    var events: [readiness_events]Event = undefined;
    const count = try fair.loop.tick(&events, 0);
    try testing.expectEqual(@as(u32, readiness_events), count);
    var accepted: ?i32 = null;
    var receives: u32 = 0;
    for (events[0..count]) |event| switch (event.user_data) {
        receive_user_data => receives += 1,
        accept_user_data => accepted = event.result,
        else => return error.UnexpectedEvent,
    };
    try fair.submit_copies(Operation.receive(receive_user_data, socket, bytes), receives);
    return accepted;
}

test "receives that end at the flush keep no accept out of a tick" {
    if (conformance.unsupported() or !backend.files_block) return error.SkipZigTest;
    var side: Harness = undefined;
    try side.init(0, null);
    defer side.deinit();
    const listener = try tcp.Listener.open();
    defer backend.sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&side, &listener);
    defer for (pair) |descriptor| backend.sync.close_now(descriptor);

    // The backlog the receives take one byte at a time.
    var backlog: [constants.fair_backlog_bytes]u8 = @splat(7);
    try side.submit(&.{Operation.send(1, pair[0], &backlog)}, &.{});
    var sent: [1]Event = undefined;
    try side.collect(&sent);
    try testing.expectEqual(@as(u32, backlog.len), try sent[0].outcome());
    try fair_module.wait_readable(pair[1]);

    var fair: FairLoop = undefined;
    try fair.init(null);
    defer fair.loop.deinit();
    // Each receive takes one byte, and the test reads none of them, so they share one place.
    var bytes: [1]u8 = undefined;
    const receive = Operation.receive(receive_user_data, pair[1], &bytes);
    try fair.submit_copies(receive, constants.fair_inline_receives);
    try fair.submit_copies(Operation.accept(accept_user_data, listener.descriptor, false), 1);
    try testing.expectEqual(@as(?i32, null), try tick(&fair, pair[1], &bytes));

    // One connection arrives while the finished list holds hundreds of receives.
    const client = try backend.sync.open_socket(listener.address.family);
    defer backend.sync.close_now(client);
    try side.submit(&.{Operation.connect(2, client, &listener.address)}, &.{});
    try side.collect(&sent);
    try testing.expectEqual(@as(u32, 0), try sent[0].outcome());
    try fair_module.wait_readable(listener.descriptor);
    var accepted: ?i32 = null;
    var ticks: u32 = 0;
    while (accepted == null and ticks < accept_ticks_max) : (ticks += 1) {
        accepted = try tick(&fair, pair[1], &bytes);
    }
    const descriptor = accepted orelse return error.AcceptMissing;
    try testing.expect(descriptor >= 0);
    backend.sync.close_now(descriptor);
    try fair.end();
}
