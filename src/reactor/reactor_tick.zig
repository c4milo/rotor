//! The tick of a reactor (decisions 26 and 33): the loop's tick, with the pollers before it and the
//! records and the tasks after it. With no poller added and nothing in `outstanding`, no callback
//! can run in the tick, so the reactor runs the backend's tick alone. That is two compares, as at
//! v0.10.0. `Dispatch` declares `tick`. Split from `reactor.zig`, and on decision 7's list for the
//! cold hint of `tick_dispatched` (ledger row H9).
const std = @import("std");
const core = @import("core");
const dispatch_module = @import("dispatch/dispatch.zig");

const Dispatch = dispatch_module.Dispatch;
const Event = core.Event;
const TickError = dispatch_module.TickError;

/// One tick of the reactor of `dispatch` over `loop`: the backend's tick alone while no callback
/// can run, and `tick_dispatched` otherwise.
pub fn tick(dispatch: *Dispatch, loop: anytype, events: []Event, wait_ns: u64) TickError(@TypeOf(loop))!u32 {
    if (dispatch.poller_count == 0 and loop.outstanding().* == 0) return loop.tick_backend(events, wait_ns);
    return tick_dispatched(dispatch, loop, events, wait_ns);
}

/// A tick that takes a kept error first, calls the pollers, runs the backend's tick, and calls the
/// records of the events and the tasks last. It is marked cold so that the compiler keeps it out of
/// `tick`: inline in each backend's tick at v0.10.0, it cost a program with no record 12
/// instructions in each tick, in saved registers, on the work gate's post (decision 7, row H1). Row
/// H9 holds the counts here, with the hint and without it.
fn tick_dispatched(dispatch: *Dispatch, loop: anytype, events: []Event, wait_ns: u64) TickError(@TypeOf(loop))!u32 {
    @branchHint(.cold);
    // An error an earlier tick kept counts in `outstanding`, so it brings the tick here, and comes
    // before any poller and any event (decision 5, amendment of 2026-11-06).
    try loop.take_kept_error();
    const wait = dispatch.begin(loop, wait_ns);
    errdefer dispatch.abandon();
    const produced = try loop.tick_backend(events, wait);
    return dispatch.end(loop, events[0..produced]);
}
