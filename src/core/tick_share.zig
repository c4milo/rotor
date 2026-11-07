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
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

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
    assert(kernel_own <= constants.kernel_own_max);
    assert(!kernel_answers or kernel_room_max >= 1);
    if (events_len < constants.fair_events_min) return .{ .lists_max = events_len, .kernel_min = 0 };
    const kernel_wanted = @max(1, events_len / constants.kernel_share_divisor) + kernel_own;
    const kernel_min = if (kernel_answers) @min(kernel_wanted, kernel_room_max) else 0;
    const mailbox_min = if (mailboxes) @max(1, events_len / constants.mailbox_share_divisor) else 0;
    const reserved = kernel_min + mailbox_min;
    // The lists keep one place each (`fair_events_min`).
    assert(reserved + lists_count <= events_len);
    return .{ .lists_max = events_len - reserved, .kernel_min = kernel_min };
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
