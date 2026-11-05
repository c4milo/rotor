//! Halt scenarios for the std.Io adapter (decision 22): one per assertion a caller's mistake can
//! reach. Each name says what the scenario does wrong, and each comment says how the scenario
//! returns when its assertion is deleted.
const std = @import("std");
const Io = std.Io;
const rotor = @import("rotor");
const scenario = @import("scenario.zig");

const adapter_module = rotor.adapter;
const Adapter = adapter_module.Adapter;
const adapter_constants = adapter_module.adapter_constants;

const loop_options: rotor.Loop.Options = .{ .operations = 4 };

const fiber_count = 2;

const good_options: adapter_module.Options = .{
    .fibers = fiber_count,
    .stack_bytes = adapter_constants.stack_bytes_min,
    .rest = undefined,
};

var loop_memory: [rotor.Loop.memory_bytes(loop_options)]u8 align(rotor.memory_alignment) = undefined;
var loop: rotor.Loop align(@alignOf(rotor.Loop)) = undefined;
var memory: [adapter_module.memory_bytes(good_options)]u8 align(adapter_module.memory_alignment) = undefined;
var second_memory: [adapter_module.memory_bytes(good_options)]u8 align(adapter_module.memory_alignment) = undefined;
var adapter: Adapter align(@alignOf(Adapter)) = undefined;
var second_adapter: Adapter align(@alignOf(Adapter)) = undefined;
var threaded: Io.Threaded align(@alignOf(Io.Threaded)) = .init_single_threaded;

/// A descriptor no process has open.
const closed_descriptor = 4096;

const group_buffers = 4;
const group_buffer_bytes = 512;
var group_memory: [rotor.buffers.group_bytes(group_buffers, group_buffer_bytes)]u8 align(rotor.buffers.group_alignment) = undefined;

/// An adapter that receives datagrams: group 0, one socket, a queue as long as the group.
fn datagram_options() adapter_module.Options {
    var result = options();
    result.datagram_group = 0;
    result.datagram_sockets = 1;
    result.datagram_queue = group_buffers;
    return result;
}

const datagram_sizing: adapter_module.Options = .{
    .fibers = fiber_count,
    .stack_bytes = adapter_constants.stack_bytes_min,
    .rest = undefined,
    .datagram_group = 0,
    .datagram_sockets = 1,
    .datagram_queue = group_buffers,
};
var datagram_memory: [adapter_module.memory_bytes(datagram_sizing)]u8 align(adapter_module.memory_alignment) = undefined;

fn options() adapter_module.Options {
    var result = good_options;
    result.rest = threaded.io();
    return result;
}

/// An adapter over a loop that runs. The scenarios that never reach the loop skip it.
fn start(with_loop: bool) void {
    if (with_loop) loop.init(&loop_memory, loop_options) catch return;
    adapter.init(&loop, &memory, options());
}

/// With the check deleted, the call reads the main context's cancel state and returns.
fn call_from_another_thread() void {
    start(false);
    const thread = std.Thread.spawn(.{}, check_cancel_on_this_thread, .{}) catch return;
    thread.join();
}

fn check_cancel_on_this_thread() void {
    const io = adapter.io();
    scenario.reached_violation();
    io.checkCancel() catch {};
}

/// With the check deleted, the stacks still fit: `memory_bytes` counts a whole granule for the
/// alignment, and moving the stacks up takes less than that.
fn give_memory_one_byte_short() void {
    scenario.reached_violation();
    adapter.init(&loop, memory[0 .. memory.len - 1], options());
}

/// Each of the five option checks, with the other four kept, returns a size when it is deleted.
fn size_no_fiber() void {
    var bad = options();
    bad.fibers = 0;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

fn size_too_many_fibers() void {
    var bad = options();
    bad.fibers = adapter_constants.fibers_max + 1;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

fn size_a_stack_too_small() void {
    var bad = options();
    bad.stack_bytes = 0;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

fn size_a_stack_too_large() void {
    var bad = options();
    bad.stack_bytes = adapter_constants.stack_bytes_max + adapter_constants.stack_granule_bytes;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

fn size_a_stack_off_the_granule() void {
    var bad = options();
    bad.stack_bytes = adapter_constants.stack_bytes_min + adapter_constants.closure_alignment;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

/// With the check deleted, recancel clears a flag that is already clear and returns.
fn recancel_with_no_cancel() void {
    start(false);
    const io = adapter.io();
    scenario.reached_violation();
    io.recancel();
}

fn nothing() void {}

/// The task is ready and never ran. With the check deleted, deinit returns.
fn end_with_a_task_not_awaited() void {
    start(false);
    const io = adapter.io();
    var future = io.async(nothing, .{});
    std.mem.doNotOptimizeAway(&future);
    scenario.reached_violation();
    adapter.deinit();
}

fn nap(io: Io, delay_ns: u64) void {
    io.sleep(.fromNanoseconds(@intCast(delay_ns)), .awake) catch {};
}

fn await_nap(io: Io, future: *Io.Future(void)) void {
    future.await(io);
}

/// Two contexts await one task. With the check deleted, the main context takes the task's awaiter
/// over, the task wakes it after its sleep, and the scenario returns: the first awaiter waits on.
fn await_one_task_twice() void {
    start(true);
    const io = adapter.io();
    var sleeper = io.async(nap, .{ io, 50 * nanoseconds_per_millisecond });
    var copy = sleeper;
    var first = io.async(await_nap, .{ io, &copy });
    // The main context sleeps, so the sleeper blocks in its timer and `first` blocks awaiting it.
    io.sleep(.fromNanoseconds(nanoseconds_per_millisecond), .awake) catch {};
    std.mem.doNotOptimizeAway(&first);
    scenario.reached_violation();
    sleeper.await(io);
}

const nanoseconds_per_millisecond = 1_000_000;

/// A group's members ran on one adapter and the group is awaited on another. With the check
/// deleted, the second adapter finds no member left, closes the group and returns.
fn await_a_group_on_another_adapter() void {
    start(false);
    second_adapter.init(&loop, &second_memory, options());
    const io = adapter.io();
    var group: Io.Group = .init;
    group.concurrent(io, nothing, .{}) catch return;
    // Awaiting a task lets the member run first, so the group has no member left and keeps its
    // token.
    var task = io.async(nothing, .{});
    task.await(io);
    scenario.reached_violation();
    group.await(second_adapter.io()) catch {};
}

/// As above, with a cancel. With the check deleted, the second adapter cancels no member of its
/// own, finds none left, closes the group and returns.
fn cancel_a_group_on_another_adapter() void {
    start(false);
    second_adapter.init(&loop, &second_memory, options());
    const io = adapter.io();
    var group: Io.Group = .init;
    group.concurrent(io, nothing, .{}) catch return;
    var task = io.async(nothing, .{});
    task.await(io);
    scenario.reached_violation();
    group.cancel(second_adapter.io());
}

/// With the check deleted, deinit finds every fiber free and returns.
fn end_from_another_thread() void {
    start(false);
    const thread = std.Thread.spawn(.{}, end_on_this_thread, .{}) catch return;
    thread.join();
}

fn end_on_this_thread() void {
    scenario.reached_violation();
    adapter.deinit();
}

/// Each of the four datagram option checks, with the other three kept, returns a size when it is
/// deleted.
fn size_too_many_datagram_sockets() void {
    var bad = datagram_options();
    bad.datagram_sockets = adapter_constants.datagram_sockets_max + 1;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

fn size_a_datagram_queue_too_long() void {
    var bad = datagram_options();
    bad.datagram_queue = adapter_constants.datagram_queue_max + 1;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

fn size_datagram_sockets_with_no_group() void {
    var bad = datagram_options();
    bad.datagram_group = null;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

fn size_datagram_sockets_with_no_queue() void {
    var bad = datagram_options();
    bad.datagram_queue = 0;
    scenario.reached_violation();
    _ = adapter_module.memory_bytes(bad);
}

/// With the check deleted, the receive finds no entry free in an empty table, and returns
/// `SystemResources`.
fn receive_with_no_datagram_group() void {
    start(false);
    const io = adapter.io();
    var message: [1]Io.net.IncomingMessage = @splat(.init);
    var bytes: [8]u8 = undefined;
    scenario.reached_violation();
    _ = io.operate(.{ .net_receive = .{
        .socket_handle = closed_descriptor,
        .message_buffer = &message,
        .data_buffer = &bytes,
        .flags = .{},
    } }) catch {};
}

/// The socket received a datagram, so its standing receive is in flight. With the check deleted,
/// deinit returns.
fn end_with_a_datagram_socket_open() void {
    loop.init(&loop_memory, loop_options) catch return;
    loop.provide_datagram_buffers(0, &group_memory, group_buffers, group_buffer_bytes, .{}) catch return;
    adapter.init(&loop, &datagram_memory, datagram_options());
    const io = adapter.io();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const socket = address.bind(io, .{ .mode = .dgram }) catch return;
    socket.send(io, &socket.address, "x") catch return;
    var bytes: [8]u8 = undefined;
    _ = socket.receive(io, &bytes) catch return;
    scenario.reached_violation();
    adapter.deinit();
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "adapter: a call from another thread", .run = call_from_another_thread },
    .{ .name = "adapter: memory one byte short", .run = give_memory_one_byte_short },
    .{ .name = "adapter: options with no fiber", .run = size_no_fiber },
    .{ .name = "adapter: options with too many fibers", .run = size_too_many_fibers },
    .{ .name = "adapter: a stack below the smallest", .run = size_a_stack_too_small },
    .{ .name = "adapter: a stack above the largest", .run = size_a_stack_too_large },
    .{ .name = "adapter: a stack off the granule", .run = size_a_stack_off_the_granule },
    .{ .name = "adapter: recancel with no cancel", .run = recancel_with_no_cancel },
    .{ .name = "adapter: deinit with a task not awaited", .run = end_with_a_task_not_awaited },
    .{ .name = "adapter: await one task twice", .run = await_one_task_twice },
    .{ .name = "adapter: await a group on another adapter", .run = await_a_group_on_another_adapter },
    .{ .name = "adapter: cancel a group on another adapter", .run = cancel_a_group_on_another_adapter },
    .{ .name = "adapter: deinit from another thread", .run = end_from_another_thread },
    .{ .name = "adapter: too many datagram sockets", .run = size_too_many_datagram_sockets },
    .{ .name = "adapter: a datagram queue too long", .run = size_a_datagram_queue_too_long },
    .{ .name = "adapter: datagram sockets with no group", .run = size_datagram_sockets_with_no_group },
    .{ .name = "adapter: datagram sockets with no queue", .run = size_datagram_sockets_with_no_queue },
    .{ .name = "adapter: a datagram receive with no group", .run = receive_with_no_datagram_group },
    .{ .name = "adapter: deinit with a datagram socket open", .run = end_with_a_datagram_socket_open },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
