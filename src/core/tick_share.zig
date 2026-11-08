//! How one tick shares its events between its sources (W3, ruled 2026-11-07): the fired and
//! finished lists, the mailboxes, and the kernel. Before W3 the lists took every place first, and a
//! long finished list kept the messages and the kernel's answer out of the tick (decision 11,
//! point 4, and decision 12, point 6, as amended).
//!
//! The rule reads counts and flags only, which the tick has before its first drain. It reads no
//! clock and no list, so a tick with the same inputs gets the same share (non-negotiable 2).
//!
//! For `N` events, with `N` at or above `fair_events_min`:
//!
//! - The kernel keeps `K = min(max(1, N / kernel_share_divisor) + kernel_own, kernel_room_max)`
//!   while it can answer, and 0 otherwise.
//! - The mailboxes keep `M = max(1, N / mailbox_share_divisor)` while the loop has a registry, and
//!   0 otherwise.
//! - The two lists take at most `N - K - M` before the kernel's turn.
//!
//! A place that a source does not use goes back to the others in the same tick, so a tick hands
//! over as many events as before whenever its sources hold that many.
//!
//! `drain_first` is the tick's first drain of the lists. When the lists hold few entries, it
//! drains them all and computes only `K`, because the share cannot cut them (its doc comment has
//! the arithmetic).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const event_module = @import("event.zig");
const tables_module = @import("tables/tables.zig");

const Event = event_module.Event;
const Tables = tables_module.Tables;

/// The lists that share what the reserves leave: `fired` and `finished`. Each keeps one place at
/// `fair_events_min` events.
const lists_count = 2;

/// The places of one tick, as `split` gives them.
pub const Share = struct {
    /// The most events the fired and finished lists together may take before the kernel's turn.
    lists_max: u32,
    /// The events kept for the kernel's turn, its own entries included. The mailboxes stop short
    /// of them.
    kernel_min: u32,
};

/// The share of a tick of `events_len` events. `kernel_answers` is true when the tick's kernel call
/// can report an operation. `mailboxes` is true when the loop has a registry. `kernel_own` is the
/// backend's `own_entries_max`, and `kernel_room_max` is the most places its kernel call takes.
pub fn split(
    events_len: u32,
    kernel_answers: bool,
    mailboxes: bool,
    kernel_own: u32,
    kernel_room_max: u32,
) Share {
    assert(events_len >= 1 and events_len <= constants.batch_max);
    if (events_len < constants.fair_events_min) return .{ .lists_max = events_len, .kernel_min = 0 };
    const kernel_min = kernel_reserve(events_len, kernel_answers, kernel_own, kernel_room_max);
    const mailbox_min = if (mailboxes) @max(1, events_len / constants.mailbox_share_divisor) else 0;
    const reserved = kernel_min + mailbox_min;
    // The lists keep one place each (`fair_events_min`).
    assert(reserved + lists_count <= events_len);
    return .{ .lists_max = events_len - reserved, .kernel_min = kernel_min };
}

/// `K`, the events kept for the kernel's turn, own entries included: 0 when the kernel cannot
/// answer or the tick has fewer than `fair_events_min` events.
pub fn kernel_reserve(
    events_len: u32,
    kernel_answers: bool,
    kernel_own: u32,
    kernel_room_max: u32,
) u32 {
    assert(kernel_own <= constants.kernel_own_max);
    assert(!kernel_answers or kernel_room_max >= 1);
    if (!kernel_answers or events_len < constants.fair_events_min) return 0;
    return @min(@max(1, events_len / constants.kernel_share_divisor) + kernel_own, kernel_room_max);
}

/// What the first drain of a tick wrote, and what the rest of the tick needs of the share.
pub const First = struct {
    /// The events the first drain wrote, from the start of the tick's events.
    produced: u32,
    /// True when the lists filled their share and may hold more, so the tick drains them again
    /// into the places the other sources did not use.
    capped: bool,
    /// `K`: the mailboxes stop this many events short of the end, for the kernel's turn.
    kernel_min: u32,
};

/// The tick's first drain of the fired and finished lists, into the start of `events`. The
/// arguments after `events` are those of `split`.
///
/// When the lists hold `c` entries and `c + kernel_own <= N / 2`, the share cannot cut them, so
/// the drain takes them all and computes only `K`. The arithmetic, for `N >= fair_events_min`,
/// with both divisors at least 4 and so `N / 4 >= 2`:
///
/// - `K <= N / 4 + kernel_own` and `M <= N / 4`, so `K + M <= 2 * (N / 4) + kernel_own`, which is
///   at most `N / 2 + kernel_own`.
/// - So `lists_max = N - K - M >= N - N / 2 - kernel_own >= N / 2 - kernel_own >= c`.
/// - With `c <= lists_max`, `drain_lists` takes every entry, in the same order: `fired` gets
///   `F - min(finished.count, F / 2)`, which is at least `fired.count` whether `finished.count`
///   is above `F / 2` or not. So both paths write the same events.
/// - The mailboxes then get `N - K - c >= M`, and the kernel keeps `K`. So every bound of W3's
///   section 3.6 holds as on the shared path.
///
/// Below `fair_events_min`, `lists_max` is `N`, so the lists are never cut there either. The
/// first drain empties the lists on this path, so `capped` is false: an entry that a later step
/// of the tick pushes waits for the expiry's drain or for the next tick, as on the shared path
/// when the lists did not fill their share.
pub fn drain_first(
    tables: *Tables,
    events: []Event,
    kernel_answers: bool,
    mailboxes: bool,
    kernel_own: u32,
    kernel_room_max: u32,
) First {
    const events_len: u32 = @intCast(events.len);
    const listed = tables.fired.count + tables.finished.count;
    if (listed + kernel_own > events_len / lists_count) {
        return drain_shared(tables, events, kernel_answers, mailboxes, kernel_own, kernel_room_max);
    }
    // Most ticks find both lists empty, and skip the drain's call.
    return .{
        .produced = if (listed == 0) 0 else tables.drain_finished(events),
        .capped = false,
        .kernel_min = kernel_reserve(events_len, kernel_answers, kernel_own, kernel_room_max),
    };
}

/// `drain_first` for lists that the share can cut: `split`, then `drain_lists` into `lists_max`.
fn drain_shared(
    tables: *Tables,
    events: []Event,
    kernel_answers: bool,
    mailboxes: bool,
    kernel_own: u32,
    kernel_room_max: u32,
) First {
    const events_len: u32 = @intCast(events.len);
    const share = split(events_len, kernel_answers, mailboxes, kernel_own, kernel_room_max);
    const produced = tables.drain_lists(events, share.lists_max);
    return .{
        .produced = produced,
        .capped = produced == share.lists_max,
        .kernel_min = share.kernel_min,
    };
}

const testing = std.testing;

/// The own entries and the kernel's room of one backend (W3, section 3.1).
const Backend = struct {
    own: u32,
    room_max: u32,
};

/// The own entries of each backend, and the readiness room of kqueue and epoll (W3, section 3.1).
const kqueue_own = 3;
const epoll_own = 2;
const readiness_room = 256;

const kqueue_backend: Backend = .{ .own = kqueue_own, .room_max = readiness_room };
const epoll_backend: Backend = .{ .own = epoll_own, .room_max = readiness_room };
const uring_backend: Backend = .{ .own = 0, .room_max = constants.batch_max };

/// One cell of the table of W3, section 3.3: `K`, `M` and `lists_max`.
const Cell = struct {
    events: u32,
    kernel: u32,
    mailbox: u32,
    lists: u32,
};

/// Checks `split` against `cells` for `backend`, with both flags set, and then with each one clear.
fn expect_cells(backend: Backend, cells: []const Cell) !void {
    for (cells) |cell| {
        const both = split(cell.events, true, true, backend.own, backend.room_max);
        try testing.expectEqual(cell.kernel, both.kernel_min);
        try testing.expectEqual(cell.lists, both.lists_max);
        try testing.expectEqual(cell.mailbox, cell.events - both.lists_max - both.kernel_min);
        // A false flag gives its places to the lists.
        const quiet = split(cell.events, false, true, backend.own, backend.room_max);
        try testing.expectEqual(@as(u32, 0), quiet.kernel_min);
        try testing.expectEqual(cell.lists + cell.kernel, quiet.lists_max);
        const alone = split(cell.events, true, false, backend.own, backend.room_max);
        try testing.expectEqual(cell.kernel, alone.kernel_min);
        try testing.expectEqual(cell.lists + cell.mailbox, alone.lists_max);
    }
}

test "the shares of each backend are the table of W3" {
    try expect_cells(kqueue_backend, &.{
        .{ .events = 10, .kernel = 5, .mailbox = 2, .lists = 3 },
        .{ .events = 16, .kernel = 7, .mailbox = 4, .lists = 5 },
        .{ .events = 32, .kernel = 11, .mailbox = 8, .lists = 13 },
        .{ .events = 64, .kernel = 19, .mailbox = 16, .lists = 29 },
        .{ .events = 256, .kernel = 67, .mailbox = 64, .lists = 125 },
        .{ .events = 4096, .kernel = 256, .mailbox = 1024, .lists = 2816 },
    });
    try expect_cells(epoll_backend, &.{
        .{ .events = 10, .kernel = 4, .mailbox = 2, .lists = 4 },
        .{ .events = 16, .kernel = 6, .mailbox = 4, .lists = 6 },
        .{ .events = 32, .kernel = 10, .mailbox = 8, .lists = 14 },
        .{ .events = 64, .kernel = 18, .mailbox = 16, .lists = 30 },
        .{ .events = 256, .kernel = 66, .mailbox = 64, .lists = 126 },
        .{ .events = 4096, .kernel = 256, .mailbox = 1024, .lists = 2816 },
    });
    try expect_cells(uring_backend, &.{
        .{ .events = 10, .kernel = 2, .mailbox = 2, .lists = 6 },
        .{ .events = 16, .kernel = 4, .mailbox = 4, .lists = 8 },
        .{ .events = 32, .kernel = 8, .mailbox = 8, .lists = 16 },
        .{ .events = 64, .kernel = 16, .mailbox = 16, .lists = 32 },
        .{ .events = 256, .kernel = 64, .mailbox = 64, .lists = 128 },
        .{ .events = 4096, .kernel = 1024, .mailbox = 1024, .lists = 2048 },
    });
}

/// Checks one share of `events_len` events with `own` own entries and both flags set.
fn expect_bounds(events_len: u32, own: u32, room_max: u32) !void {
    const share = split(events_len, true, true, own, room_max);
    if (events_len < constants.fair_events_min) {
        // Below the floor a tick keeps the order of decision 12.
        try testing.expectEqual(events_len, share.lists_max);
        try testing.expectEqual(@as(u32, 0), share.kernel_min);
        return;
    }
    const mailbox = events_len - share.lists_max - share.kernel_min;
    try testing.expectEqual(@max(1, events_len / constants.mailbox_share_divisor), mailbox);
    const kernel_wanted = @max(1, events_len / constants.kernel_share_divisor) + own;
    try testing.expectEqual(@min(kernel_wanted, room_max), share.kernel_min);
    try testing.expect(share.lists_max >= lists_count);
    try testing.expect(share.lists_max + own >= events_len / lists_count);
}

test "every count of events leaves the lists at least two places and half less the own entries" {
    var events_len: u32 = 1;
    while (events_len <= constants.batch_max) : (events_len += 1) {
        var own: u32 = 0;
        while (own <= constants.kernel_own_max) : (own += 1) {
            try expect_bounds(events_len, own, readiness_room);
            try expect_bounds(events_len, own, constants.batch_max);
        }
    }
}

const Heartbeat = @import("stall.zig").Heartbeat;
const Operation = @import("operation.zig").Operation;
const Slot = @import("slot.zig").Slot;
const TimerHeap = @import("timer_heap.zig").TimerHeap;

/// Slots of the tests of `drain_first`: room for the longest list they build.
const test_slots = 48;

/// The tick of the tests of `drain_first` at the boundary: at or above `fair_events_min`, and a
/// multiple of 4, so that `lists_max` is `N / 2 - own` on every backend.
const boundary_events = 32;

/// The most events of the test that compares the two paths, and how many entries past half of them
/// it builds, so that each count of events meets the boundary from both sides.
const compared_events_max = 64;
const listed_past_half = 2;

/// The socket the receives of the tests name. No kernel sees it.
const test_socket = 3;

/// Tables over memory the test owns, with receives on `finished`.
const TestTables = struct {
    slots: [test_slots]Slot,
    entries: [test_slots]TimerHeap.Entry,
    starts: [test_slots]u64,
    heartbeat: Heartbeat,
    groups: @import("scheduling/scheduling.zig").Groups,
    tables: Tables,
    bytes: [1]u8,

    /// Empty tables, then `count` receives, each handed to the kernel and ended by the loop:
    /// onto `finished`, in order.
    fn init(fixture: *TestTables, count: u32) !void {
        const tables = &fixture.tables;
        tables.init(&fixture.slots, &fixture.entries, &fixture.starts, &fixture.heartbeat, &fixture.groups, .{});
        for (0..count) |user_data| {
            const receive = Operation.receive(user_data, test_socket, &fixture.bytes);
            try testing.expectEqual(@as(u32, 1), tables.submit(&.{receive}, &.{}));
            const index = tables.next_pending().?;
            tables.take_pending(index);
            tables.hand_over(index, tables.table.at(index));
            tables.finish_local(index, 0);
        }
    }
};

/// Builds `listed` finished entries, runs `drain_first` for `backend` on `boundary_events` events
/// with both flags set, and checks that it returns `expected` and keeps the list's order.
fn expect_first(backend: Backend, listed: u32, expected: First) !void {
    var fixture: TestTables = undefined;
    try fixture.init(listed);
    var events: [boundary_events]Event = undefined;
    const first = drain_first(&fixture.tables, &events, true, true, backend.own, backend.room_max);
    try testing.expectEqual(expected, first);
    for (events[0..first.produced], 0..) |event, user_data| {
        try testing.expectEqual(@as(u64, user_data), event.user_data);
    }
}

test "lists that fit in half the events less the own entries drain whole, and are not capped" {
    // io_uring at 32 events: K = 8, M = 8, lists_max = 16 = N / 2. At 16 entries both paths write
    // the same events. Only the fast path knows that the lists are now empty, so it is not capped.
    try expect_first(uring_backend, 16, .{ .produced = 16, .capped = false, .kernel_min = 8 });
    // One entry more takes the shared path, which stops at lists_max and asks for the give-back.
    try expect_first(uring_backend, 17, .{ .produced = 16, .capped = true, .kernel_min = 8 });
    // kqueue at 32 events: K = 11, M = 8, lists_max = 13 = N / 2 - 3. The own entries count.
    try expect_first(kqueue_backend, 13, .{ .produced = 13, .capped = false, .kernel_min = 11 });
    try expect_first(kqueue_backend, 14, .{ .produced = 13, .capped = true, .kernel_min = 11 });
    // Empty lists write nothing and still keep the kernel's reserve.
    try expect_first(epoll_backend, 0, .{ .produced = 0, .capped = false, .kernel_min = 10 });
}

test "the fast path keeps no kernel reserve below the floor or for a kernel that cannot answer" {
    var fixture: TestTables = undefined;
    try fixture.init(2);
    var small: [constants.fair_events_min - 1]Event = undefined;
    const below = drain_first(&fixture.tables, &small, true, true, 0, constants.batch_max);
    try testing.expectEqual(@as(u32, 2), below.produced);
    try testing.expectEqual(@as(u32, 0), below.kernel_min);
    try fixture.init(2);
    var events: [boundary_events]Event = undefined;
    const quiet = drain_first(&fixture.tables, &events, false, true, kqueue_own, readiness_room);
    try testing.expectEqual(@as(u32, 2), quiet.produced);
    try testing.expectEqual(@as(u32, 0), quiet.kernel_min);
}

/// Checks `drain_first` against `split` and `drain_lists` for `listed` finished entries on
/// `events_len` events: the same count of events, the same reserve, and a cap only at the share.
fn expect_first_as_split(events_len: u32, own: u32, listed: u32) !void {
    var fixture: TestTables = undefined;
    try fixture.init(listed);
    var events: [compared_events_max]Event = undefined;
    const share = split(events_len, true, true, own, readiness_room);
    const tick_events = events[0..events_len];
    const first = drain_first(&fixture.tables, tick_events, true, true, own, readiness_room);
    try testing.expectEqual(@min(listed, share.lists_max), first.produced);
    try testing.expectEqual(share.kernel_min, first.kernel_min);
    if (first.capped) try testing.expectEqual(share.lists_max, first.produced);
}

test "the fast path writes what the shared path writes, for every count of events and entries" {
    var events_len: u32 = 1;
    while (events_len <= compared_events_max) : (events_len += 1) {
        var own: u32 = 0;
        while (own <= constants.kernel_own_max) : (own += 1) {
            var listed: u32 = 0;
            while (listed <= events_len / lists_count + listed_past_half) : (listed += 1) {
                try expect_first_as_split(events_len, own, listed);
            }
        }
    }
}
