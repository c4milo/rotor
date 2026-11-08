//! The calls of the public `Loop` that the cross-core call of decision 32 makes. Only `Service` and
//! `CallRecord` call them, through `SharedLoop`. Each call makes the call of the same name on the
//! backend this process runs. Split from `rotor_loop.zig` for the 500-line limit.
const core = @import("core");
const loop_module = @import("rotor_loop.zig");

const Loop = loop_module.Loop;
const CallLink = core.call.CallLink;
const CallStation = core.call.CallStation;
const loops_max = core.constants.loops_max;

/// Sends the call of `link`, which `Service.send` wrote. `CallsFull` when that target has
/// `calls_per_pair_max` calls that have not yet run their `finish`, `MailboxFull` when the ring to
/// it holds `mailbox_posts_max` messages, and `LoopNotFound` for an id that runs no loop.
pub fn call(loop: *Loop, link: *CallLink) core.call.CallError!void {
    return switch (loop.inner) {
        inline else => |*inner| inner.call(link),
    };
}

/// Answers the call of `link`, which this loop holds. It is never refused.
pub fn answer(loop: *Loop, link: *CallLink) void {
    switch (loop.inner) {
        inline else => |*inner| inner.answer(link),
    }
}

/// This loop serves the service of `stations`. Returns its station.
pub fn serve(loop: *Loop, stations: *[loops_max]CallStation) *CallStation {
    return switch (loop.inner) {
        inline else => |*inner| inner.serve(stations),
    };
}

/// This loop stops the service of `stations`.
pub fn stop_serving(loop: *Loop, stations: *[loops_max]CallStation) void {
    switch (loop.inner) {
        inline else => |*inner| inner.stop_serving(stations),
    }
}
