//! `operate` and the batch calls (decision 22, step 3).
//!
//! A `net_receive` runs on the loop, through the socket's standing receive (`adapter_datagram.zig`).
//! The other operations, the streaming file reads and writes and `device_io_control`, go to `rest`,
//! as decision 22 says: rotor's `read` and `write` take an offset, and these take the file's own
//! position. `rest` runs them on the calling thread, so one that blocks holds the loop's thread too.
//!
//! An operation of a batch stays on the batch's `submitted` list until it completes, and then moves
//! to `completed`. Nothing of the batch is ever in flight on the loop: a socket's standing receive
//! belongs to the socket. So the adapter uses no `pending` list and sets no `userdata`, and
//! `Batch.cancel`, which drops what is submitted, leaves `batchCancel` nothing to do.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Batch = Io.Batch;
const Operation = Io.Operation;
const adapter_module = @import("adapter.zig");
const datagram = @import("adapter_datagram.zig");
const wait = @import("adapter_wait.zig");
const Adapter = adapter_module.Adapter;

pub fn operate(userdata: ?*anyopaque, operation: Operation) Io.Cancelable!Operation.Result {
    const adapter = adapter_module.from(userdata);
    return switch (operation) {
        .net_receive => |receive| .{ .net_receive = try datagram.receive(adapter, receive) },
        else => adapter.rest.vtable.operate(adapter.rest.userdata, operation),
    };
}

pub fn batch_await_async(userdata: ?*anyopaque, batch: *Batch) Io.Cancelable!void {
    const adapter = adapter_module.from(userdata);
    return await_batch(adapter, batch, .none) catch |failure| switch (failure) {
        error.Canceled => error.Canceled,
        // A batch with no timeout never times out.
        error.Timeout => unreachable,
    };
}

pub fn batch_await_concurrent(userdata: ?*anyopaque, batch: *Batch, timeout: Io.Timeout) Batch.AwaitConcurrentError!void {
    const adapter = adapter_module.from(userdata);
    return await_batch(adapter, batch, timeout);
}

/// Every operation is still on `submitted` when `Batch.cancel` calls this, and it dropped them
/// all, so nothing is left.
pub fn batch_cancel(userdata: ?*anyopaque, batch: *Batch) void {
    _ = adapter_module.from(userdata);
    assert(batch.pending.head == .none);
    assert(batch.userdata == null);
}

/// Completes what can complete, and waits for a datagram until at least one has, a cancel point.
fn await_batch(adapter: *Adapter, batch: *Batch, timeout: Io.Timeout) (Io.Cancelable || Io.Timeout.Error)!void {
    const deadline: ?Io.Timeout = if (wait.timeout_ns(adapter, timeout)) |ns| .{ .deadline = .{
        .raw = .{ .nanoseconds = @as(i96, adapter.loop.now_ns()) + ns },
        .clock = .awake,
    } } else null;
    while (batch.completed.head == .none) {
        const seen = adapter.datagram_epoch;
        try complete_ready(adapter, batch);
        if (batch.completed.head != .none or batch.submitted.head == .none) return;
        if (deadline) |until| {
            if (wait.timeout_ns(adapter, until) == 0) return error.Timeout;
        }
        try wait.futex_wait(adapter, &adapter.datagram_epoch, seen, deadline orelse .none);
    }
}

/// Moves every submitted operation that completes now to `completed`, in the order submitted.
fn complete_ready(adapter: *Adapter, batch: *Batch) Io.Cancelable!void {
    var previous: Operation.OptionalIndex = .none;
    var index = batch.submitted.head;
    while (index != .none) {
        const storage = &batch.storage[index.toIndex()];
        const next = storage.submission.node.next;
        if (try complete_now(adapter, storage.submission.operation)) |result| {
            unlink(batch, previous, index, next);
            append_completed(batch, index, result);
        } else {
            previous = index;
        }
        index = next;
    }
}

fn complete_now(adapter: *Adapter, operation: Operation) Io.Cancelable!?Operation.Result {
    return switch (operation) {
        .net_receive => |receive| if (datagram.try_receive(adapter, receive)) |result|
            .{ .net_receive = result }
        else
            null,
        else => try adapter.rest.vtable.operate(adapter.rest.userdata, operation),
    };
}

fn unlink(batch: *Batch, previous: Operation.OptionalIndex, index: Operation.OptionalIndex, next: Operation.OptionalIndex) void {
    if (previous == .none) {
        batch.submitted.head = next;
    } else {
        batch.storage[previous.toIndex()].submission.node.next = next;
    }
    if (batch.submitted.tail == index) batch.submitted.tail = previous;
}

fn append_completed(batch: *Batch, index: Operation.OptionalIndex, result: Operation.Result) void {
    batch.storage[index.toIndex()] = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
    if (batch.completed.tail == .none) {
        batch.completed.head = index;
    } else {
        batch.storage[batch.completed.tail.toIndex()].completion.node.next = index;
    }
    batch.completed.tail = index;
}
