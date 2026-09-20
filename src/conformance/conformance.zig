//! The conformance suite (decision 10, point 2): scenarios written against the surface every
//! backend carries, run against the real kernel. The build hands this module one backend as its
//! `backend` import, so the same file tests `uring` under Linux and `kqueue` under macOS, and
//! both passing is what shows that they present the caller one behaviour (decision 5).
//!
//! A scenario uses nothing but the backend's public surface: `Loop`, `Registry`, and the
//! synchronous calls of `sync`. On a host the backend cannot run on, every scenario skips.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");

pub const Loop = backend.Loop;
pub const Event = core.Event;
pub const Handle = core.Handle;
pub const Operation = core.Operation;

pub const operations = 64;
pub const entries = 16;
const memory_bytes = Loop.memory_bytes(.{ .operations = operations, .entries = entries });

/// The most rounds `Harness.collect` ticks before it gives up: with a 10 ms wait each, 2 s.
const collect_rounds_max = 200;
const collect_wait_ns = 10 * core.constants.ns_per_ms;

/// One loop over static memory, and the waiting every scenario needs.
pub const Harness = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment),
    loop: Loop,

    pub fn init(harness: *Harness, id: core.LoopId, registry: ?*backend.Registry) !void {
        try harness.loop.init(&harness.memory, .{
            .operations = operations,
            .entries = entries,
            .id = id,
            .registry = registry,
        });
    }

    pub fn deinit(harness: *Harness) void {
        harness.loop.deinit();
    }

    /// Submits `batch` whole, or fails: no scenario fills the table.
    pub fn submit(harness: *Harness, batch: []const Operation, handles: []Handle) !void {
        const taken = harness.loop.submit(batch, handles);
        if (taken != batch.len) return error.TableFull;
    }

    /// Ticks until `events` is full, and fails when it is not full within the bound.
    pub fn collect(harness: *Harness, events: []Event) !void {
        var filled: usize = 0;
        var round: u32 = 0;
        while (filled < events.len and round < collect_rounds_max) : (round += 1) {
            filled += try harness.loop.tick(events[filled..], collect_wait_ns);
        }
        if (filled < events.len) return error.EventsMissing;
    }

    /// The event among `events` that carries `user_data`.
    pub fn find(events: []const Event, user_data: u64) !Event {
        for (events) |event| {
            if (event.user_data == user_data and !event.flags.message) return event;
        }
        return error.EventNotFound;
    }
};

/// True when the backend cannot run on this host, and the scenario must skip.
pub fn unsupported() bool {
    return !backend.supported;
}

test {
    _ = @import("conformance_loop.zig");
    _ = @import("conformance_tcp.zig");
    _ = @import("conformance_file.zig");
    _ = @import("conformance_post.zig");
}
