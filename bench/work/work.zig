//! work: rotor's own work per operation, for the instruction gate (`work_gate.zig`,
//! `bench/baseline/work.txt`).
//!
//! Run:  work WORKLOAD ITERATIONS
//!
//! Each workload repeats one exchange on two loops of one thread, and neither loop ever sleeps:
//! every message is in its ring and every timer is due before the tick that takes it. So no tick
//! waits for another thread or for the clock, and the instructions one iteration runs are the same
//! on every run and on every machine of one architecture, whatever else the machine is doing. That
//! is what lets the gate hold them to a baseline with a few percent of room, where a time needs a
//! factor of ten (`src/conformance/conformance_cost.zig`).
//!
//! - `post`: loop 0 posts to loop 1 with `Loop.post`, loop 1 ticks and takes it, then the same
//!   back. One iteration is that round trip.
//! - `post-operation`: the same round trip with post operations, so each side also ticks once to
//!   hand over its post's own event.
//! - `timer`: one timer of no delay, submitted and handed over by one tick.
//! - `batch`: 32 timers of no delay in one submit, handed over by one tick. One iteration is the
//!   batch.
//! - `wait`: the loop wakes itself and ticks with a wait, which the wake ends at once: the whole
//!   path of a tick that blocks. kqueue and epoll only; on io_uring a loop has no call that wakes
//!   itself, and the program exits with `unsupported_status`.
//!
//! The program prints nothing. Something outside it counts: `work_gate` runs it twice, with two
//! iteration counts, and takes the difference, so what the process does to start and stop cancels.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;

pub const Workload = enum { post, post_operation, timer, batch, wait };

/// The exit status of a workload this backend cannot run.
pub const unsupported_status: u8 = 2;

/// Slots per loop: a batch and room for the answer.
const operations = 64;

/// Timers one `batch` iteration submits at once.
const batch_operations = 32;

/// Events one tick may hand over: a whole batch.
const events_max = batch_operations;

/// What a tick of `wait` is given. Its own wake ends it at once; a wake that failed would end it
/// after a millisecond, and the count would show the timer's work.
const wait_ns = core.constants.ns_per_ms;

/// The ids of the two loops.
const first_id: core.LoopId = 0;
const second_id: core.LoopId = 1;

const ping: core.Message = .{ .payload = 1, .tag = 1 };
const pong: core.Message = .{ .payload = 2, .tag = 2 };

const loop_options: Loop.Options = .{ .operations = operations, .id = first_id };
const memory_bytes = Loop.memory_bytes(loop_options);

const Side = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment) = undefined,
    loop: Loop = undefined,
    events: [events_max]Event = undefined,

    /// Ticks once, with no wait, and fails unless that tick handed over exactly `count` events.
    fn expect(side: *Side, count: u32) !void {
        if (try side.loop.tick(&side.events, 0) != count) return error.EventsMissing;
    }
};

var registry: backend.Registry align(@alignOf(backend.Registry)) = undefined;
var registry_memory: [backend.Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
var first: Side align(@alignOf(Side)) = .{};
var second: Side align(@alignOf(Side)) = .{};
var batch: [batch_operations]Operation align(@alignOf(Operation)) = undefined;

/// True when this backend's loop can wake itself, which `wait` needs: kqueue and epoll, whose loop
/// holds the descriptor a post's wake would reach.
const can_wake_itself = @hasField(Loop, "queue");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 3) return error.Usage;
    const workload = workload_of(arguments[1]) orelse return error.UnknownWorkload;
    const iterations = try std.fmt.parseInt(u64, arguments[2], 10);
    if (workload == .wait and !can_wake_itself) std.process.exit(unsupported_status);

    registry.init(&registry_memory, 2);
    var options = loop_options;
    options.registry = &registry;
    try first.loop.init(&first.memory, options);
    defer first.loop.deinit();
    options.id = second_id;
    try second.loop.init(&second.memory, options);
    defer second.loop.deinit();
    for (&batch, 0..) |*operation, index| operation.* = Operation.timer(index, 0, 0);

    for (0..iterations) |_| try run(workload);
}

fn run(workload: Workload) !void {
    switch (workload) {
        .post => {
            try first.loop.post(second_id, ping);
            try second.expect(1);
            try second.loop.post(first_id, pong);
            try first.expect(1);
        },
        .post_operation => {
            try submit(&first, &.{Operation.post(1, second_id, ping)});
            try first.expect(1);
            try second.expect(1);
            try submit(&second, &.{Operation.post(2, first_id, pong)});
            try second.expect(1);
            try first.expect(1);
        },
        .timer => {
            try submit(&first, &.{Operation.timer(3, 0, 0)});
            try first.expect(1);
        },
        .batch => {
            try submit(&first, &batch);
            try first.expect(batch_operations);
        },
        .wait => try wait_once(),
    }
}

fn submit(side: *Side, operations_to_submit: []const Operation) !void {
    const taken = side.loop.submit(operations_to_submit, &.{});
    if (taken != operations_to_submit.len) return error.TableFull;
}

/// The loop wakes itself, then ticks with a wait that the wake ends at once and that hands over
/// nothing.
fn wait_once() !void {
    if (comptime !can_wake_itself) unreachable;
    const queue = &first.loop.queue;
    const target = if (@hasField(@TypeOf(queue.*), "wake_descriptor")) queue.wake_descriptor else queue.descriptor;
    backend.queue_module.Queue.wake(target);
    if (try first.loop.tick(&first.events, wait_ns) != 0) return error.UnexpectedEvent;
}

/// The workload named on the command line, spelled with dashes there.
pub fn workload_of(name: []const u8) ?Workload {
    if (std.mem.eql(u8, name, "post")) return .post;
    if (std.mem.eql(u8, name, "post-operation")) return .post_operation;
    if (std.mem.eql(u8, name, "timer")) return .timer;
    if (std.mem.eql(u8, name, "batch")) return .batch;
    if (std.mem.eql(u8, name, "wait")) return .wait;
    return null;
}
