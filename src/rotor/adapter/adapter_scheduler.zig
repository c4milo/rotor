//! Which of the adapter's contexts runs, and when the loop ticks (decision 22, "How a blocking
//! call runs").
//!
//! There is no scheduler context. A context that blocks hands the thread straight to the first
//! ready context. When none is ready, the blocking context ticks the loop itself, on its own stack,
//! and each event of the adapter makes the context that waits for it ready. So a blocking call
//! costs one switch out and one switch back, and a tick costs no switch.
//!
//! A tick only marks contexts ready. It starts no task and runs none, so a fiber that is done can
//! tick on its own stack after it went back on the free list: nothing takes that stack until the
//! fiber has switched away for good.
const std = @import("std");
const assert = std.debug.assert;
const rotor = @import("../rotor.zig");
const constants = @import("constants.zig");
const adapter_module = @import("adapter.zig");
const switching = @import("adapter_switch.zig");
const Adapter = adapter_module.Adapter;
const Fiber = adapter_module.Fiber;
const Index = adapter_module.Index;
const Wait = adapter_module.Wait;
const index_none = adapter_module.index_none;

const index_mask: u64 = (@as(u64, 1) << constants.user_data_tag_shift) - 1;
const tag_mask: u64 = ~index_mask;

/// The result a wait ends with when a cancel ended it.
pub const canceled_result: i32 = -@as(i32, @intFromEnum(rotor.Code.canceled));

pub fn current(adapter: *Adapter) *Fiber {
    return &adapter.fibers[adapter.current];
}

pub fn push_free(adapter: *Adapter, index: Index) void {
    const fiber = &adapter.fibers[index];
    assert(index != adapter_module.index_main);
    fiber.* = .empty;
    fiber.next = adapter.free_head;
    adapter.free_head = index;
}

/// A free fiber's index, taken off the free list, or null when every fiber holds a task.
pub fn take_free(adapter: *Adapter) ?Index {
    const index = adapter.free_head;
    if (index == index_none) return null;
    const fiber = &adapter.fibers[index];
    assert(fiber.state == .free);
    adapter.free_head = fiber.next;
    fiber.next = index_none;
    return index;
}

/// Puts context `index` at the end of the ready list.
pub fn make_ready(adapter: *Adapter, index: Index) void {
    const fiber = &adapter.fibers[index];
    assert(fiber.state == .blocked or fiber.state == .free);
    assert(fiber.next == index_none);
    fiber.state = .ready;
    if (adapter.ready_tail == index_none) {
        adapter.ready_head = index;
    } else {
        adapter.fibers[adapter.ready_tail].next = index;
    }
    adapter.ready_tail = index;
}

fn pop_ready(adapter: *Adapter) Index {
    const index = adapter.ready_head;
    assert(index != index_none);
    const fiber = &adapter.fibers[index];
    assert(fiber.state == .ready);
    adapter.ready_head = fiber.next;
    if (adapter.ready_head == index_none) adapter.ready_tail = index_none;
    fiber.next = index_none;
    return index;
}

/// Blocks the running context until a wake, an event or a cancel makes it ready. `cancelable`
/// says whether a cancel may end the wait: it does only when the context's protection allows it
/// and no cancel point has already returned `error.Canceled`.
pub fn block(adapter: *Adapter, wait: Wait, cancelable: bool) void {
    const me = adapter.current;
    const fiber = &adapter.fibers[me];
    assert(fiber.state == .running);
    assert(wait != .none);
    fiber.state = .blocked;
    fiber.wait = wait;
    fiber.cancelable = cancelable and fiber.protection == .unblocked and !fiber.acknowledged;
    fiber.interrupted = false;
    while (adapter.ready_head == index_none) tick(adapter);
    const next = pop_ready(adapter);
    if (next == me) {
        fiber.state = .running;
    } else {
        switch_to(adapter, next);
    }
    assert(adapter.current == me);
    assert(fiber.state == .running);
    fiber.wait = .none;
    fiber.cancelable = false;
}

/// The result of the wait that just ended: `error.Canceled` when a cancel ended it.
pub fn end_wait(fiber: *Fiber) error{Canceled}!i32 {
    assert(fiber.state == .running);
    if (fiber.interrupted and fiber.result == canceled_result) {
        assert(!fiber.acknowledged);
        fiber.acknowledged = true;
        return error.Canceled;
    }
    return fiber.result;
}

/// Hands the thread to the next ready context for good: the running fiber is done.
pub fn leave(adapter: *Adapter) noreturn {
    assert(adapter.current != adapter_module.index_main);
    while (adapter.ready_head == index_none) tick(adapter);
    switch_to(adapter, pop_ready(adapter));
    unreachable;
}

fn switch_to(adapter: *Adapter, next: Index) void {
    const from = adapter.current;
    assert(next != from);
    adapter.fibers[next].state = .running;
    adapter.current = next;
    const message: switching.Switch = .{
        .old = &adapter.fibers[from].context,
        .new = &adapter.fibers[next].context,
    };
    switching.switch_context(&message);
}

/// Submits one operation for the running context, which then blocks until its final event. When
/// the loop has no free slot, ticks until an operation ends.
///
/// A timer's delay runs from `Loop.now_ns`, the time of the last tick (decision 14, rule 6), and
/// on io_uring that is 0 before the first tick: a timer submitted then is due at once. So the
/// adapter polls the loop once first, which reads its clock. An operation's deadline runs from it
/// too.
pub fn submit(adapter: *Adapter, kind: rotor.Operation.Kind) void {
    submit_with_deadline(adapter, kind, 0);
}

/// `submit`, with the operation's deadline: `timeout_ns` after the loop's clock, or 0 for none
/// (decision 5, rule 4).
pub fn submit_with_deadline(adapter: *Adapter, kind: rotor.Operation.Kind, timeout_ns: u64) void {
    const me = adapter.current;
    const fiber = &adapter.fibers[me];
    assert(fiber.handle.is_none());
    if (adapter.loop.now_ns() == 0) poll(adapter);
    assert(adapter.loop.now_ns() != 0);
    const operation: rotor.Operation = .{
        .user_data = constants.user_data_tag | me,
        .timeout_ns = timeout_ns,
        .kind = kind,
    };
    var handles = [_]rotor.Handle{.none};
    while (adapter.loop.submit(&.{operation}, &handles) == 0) tick(adapter);
    assert(!handles[0].is_none());
    fiber.handle = handles[0];
}

/// Asks the loop to end the operation context `index` waits for (decision 5, rule 2).
pub fn cancel_operation(adapter: *Adapter, index: Index) void {
    const fiber = &adapter.fibers[index];
    assert(fiber.state == .blocked);
    assert(!fiber.handle.is_none());
    adapter.loop.cancel(fiber.handle);
}

/// Ticks the loop, waiting for an event, and hands each one over. A context waits for every
/// event the adapter's own operations make, so a tick with nothing in flight would wait forever:
/// every context of the adapter waits, and nothing can wake one. That halts.
fn tick(adapter: *Adapter) void {
    if (adapter.loop.in_flight() == 0) @panic("every context of the adapter waits, and nothing is in flight");
    const count = adapter.loop.tick(&adapter.events, rotor.constants.wait_ns_max) catch |err|
        std.debug.panic("the adapter's tick failed: {s}", .{@errorName(err)});
    for (adapter.events[0..count]) |event| hand_over(adapter, event);
}

/// Ticks the loop once without waiting, so that it reads the clock.
pub fn poll(adapter: *Adapter) void {
    const count = adapter.loop.tick(&adapter.events, 0) catch |err|
        std.debug.panic("the adapter's tick failed: {s}", .{@errorName(err)});
    for (adapter.events[0..count]) |event| hand_over(adapter, event);
}

fn hand_over(adapter: *Adapter, event: rotor.Event) void {
    if (event.flags.message or event.user_data & tag_mask != constants.user_data_tag) {
        const handler = adapter.handler orelse @panic("an event of no adapter operation, and no handler");
        handler.handle(handler.context, event);
        return;
    }
    // The adapter submits no multishot operation, so each of its events is a final one.
    assert(event.is_final());
    const index: Index = @intCast(event.user_data & index_mask);
    const fiber = &adapter.fibers[index];
    assert(fiber.state == .blocked);
    assert(!fiber.handle.is_none());
    fiber.handle = .none;
    fiber.result = event.result;
    if (fiber.wait == .futex) unlink_futex(adapter, index);
    make_ready(adapter, index);
}

/// Ends the wait of context `index` for a cancel, when its wait allows one.
pub fn interrupt(adapter: *Adapter, index: Index) void {
    const fiber = &adapter.fibers[index];
    if (fiber.state != .blocked or !fiber.cancelable) return;
    fiber.cancelable = false;
    fiber.interrupted = true;
    switch (fiber.wait) {
        .operation => cancel_operation(adapter, index),
        .futex => {
            unlink_futex(adapter, index);
            end_futex_wait(adapter, index, canceled_result);
        },
        .cancel, .group => {
            fiber.result = canceled_result;
            make_ready(adapter, index);
        },
        .none, .future => unreachable,
    }
}

/// Ends a futex wait the list no longer holds: at once, or at its timer's final event, which the
/// loop is asked to hand over early.
pub fn end_futex_wait(adapter: *Adapter, index: Index, result: i32) void {
    const fiber = &adapter.fibers[index];
    assert(fiber.state == .blocked);
    assert(fiber.wait == .futex);
    fiber.result = result;
    if (fiber.handle.is_none()) {
        make_ready(adapter, index);
    } else {
        fiber.wait = .operation;
        cancel_operation(adapter, index);
    }
}

/// Takes context `index` off the futex list. The list holds at most every fiber and the main
/// context.
pub fn unlink_futex(adapter: *Adapter, index: Index) void {
    var link = &adapter.futex_head;
    var steps: usize = 0;
    while (link.* != index) : (steps += 1) {
        assert(steps <= constants.fibers_max);
        assert(link.* != index_none);
        link = &adapter.fibers[link.*].next;
    }
    link.* = adapter.fibers[index].next;
    adapter.fibers[index].next = index_none;
}
