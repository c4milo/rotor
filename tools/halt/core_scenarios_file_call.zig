//! Halt scenarios for `core.file_call.result`, which both readiness backends and the offload's
//! workers call with the system call as a parameter, so a scenario hands it a made-up answer or a
//! request of the wrong shape. Split from `core_scenarios.zig` for the 500-line limit.
//!
//! With its assertion deleted, each call returns the count the made-up call answered.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const FileAnswer = core.file_call.Answer(std.posix.E);

/// A call that answers one more byte than it was given, which no kernel does.
const OverCount = struct {
    pub fn answer(_: OverCount, request: core.file_call.Request) FileAnswer {
        return .{ .count = request.bytes.len + 1 };
    }
};

/// A call that transfers nothing and succeeds, so only the request's own shape can halt.
const NoCount = struct {
    pub fn answer(_: NoCount, request: core.file_call.Request) FileAnswer {
        _ = request;
        return .{ .count = 0 };
    }
};

/// The bound handed to `file_call.result`. Each call here answers the first time.
const file_retries_max = 1;

var file_bytes: [1]u8 = undefined;

fn answer_a_read_with_more_bytes_than_it_was_given() void {
    const request: core.file_call.Request = .{
        .code = .read,
        .descriptor = 0,
        .bytes = &file_bytes,
        .offset = 0,
    };
    scenario.reached_violation();
    _ = core.file_call.result(OverCount{}, request, file_retries_max);
}

fn hand_an_fsync_bytes_to_transfer() void {
    const request: core.file_call.Request = .{
        .code = .fsync,
        .descriptor = 0,
        .bytes = &file_bytes,
        .offset = 0,
    };
    scenario.reached_violation();
    _ = core.file_call.result(NoCount{}, request, file_retries_max);
}

fn hand_a_sync_bytes_to_transfer() void {
    const request: core.file_call.Request = .{
        .code = .fdatasync,
        .descriptor = 0,
        .bytes = &file_bytes,
        .offset = 0,
    };
    scenario.reached_violation();
    _ = core.file_call.result(NoCount{}, request, file_retries_max);
}

pub const scenarios = [_]scenario.Scenario{
    .{
        .name = "file_call: answer a read with more bytes than it was given",
        .run = answer_a_read_with_more_bytes_than_it_was_given,
    },
    .{
        .name = "file_call: hand a sync bytes to transfer",
        .run = hand_a_sync_bytes_to_transfer,
    },
    .{
        .name = "file_call: hand an fsync bytes to transfer",
        .run = hand_an_fsync_bytes_to_transfer,
    },
};
