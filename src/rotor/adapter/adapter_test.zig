//! The adapter's tasks, groups, futexes and time, run on this host's loop (decision 22, check 3).
//! `adapter_test_cancel.zig` holds cancellation.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const rotor = @import("../rotor.zig");
const adapter_module = @import("adapter.zig");
const Adapter = adapter_module.Adapter;

pub const loop_options: rotor.Loop.Options = .{ .operations = 16 };

/// Four fibers, so a test can take every one of them.
pub const fiber_count = 4;

pub const millisecond_ns = 1_000_000;

var loop_memory: [rotor.Loop.memory_bytes(loop_options)]u8 align(rotor.memory_alignment) = undefined;
var adapter_memory: [
    adapter_module.memory_bytes(.{
        .fibers = fiber_count,
        .stack_bytes = adapter_module.adapter_constants.stack_bytes_min,
        .rest = undefined,
    })
]u8 align(adapter_module.memory_alignment) = undefined;

/// A loop, a `std.Io.Threaded` for `rest`, and the adapter over both.
pub const Fixture = struct {
    loop: rotor.Loop,
    threaded: Io.Threaded,
    adapter: Adapter,

    pub fn init(fixture: *Fixture, handler: ?adapter_module.Handler) !void {
        try fixture.loop.init(&loop_memory, loop_options);
        fixture.threaded = .init_single_threaded;
        fixture.adapter.init(&fixture.loop, &adapter_memory, .{
            .fibers = fiber_count,
            .stack_bytes = adapter_module.adapter_constants.stack_bytes_min,
            .rest = fixture.threaded.io(),
            .handler = handler,
        });
    }

    pub fn deinit(fixture: *Fixture) void {
        fixture.adapter.deinit();
        fixture.loop.assert_empty();
        fixture.loop.deinit();
    }

    pub fn io(fixture: *Fixture) Io {
        return fixture.adapter.io();
    }
};

fn add(io: Io, a: u32, b: u32) struct { sum: u32, fiber: adapter_module.Index } {
    const adapter: *Adapter = @ptrCast(@alignCast(io.userdata.?));
    return .{ .sum = a + b, .fiber = adapter.current };
}

test "a task runs on a fiber, and await returns its result and frees the fiber" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(add, .{ io, 2, 3 });
    try testing.expect(future.any_future != null);
    const result = future.await(io);
    try testing.expectEqual(5, result.sum);
    try testing.expectEqual(1, result.fiber);
    // The fiber is free again, so the next task takes it too.
    var again = io.async(add, .{ io, 4, 5 });
    try testing.expectEqual(1, again.await(io).fiber);
}

fn nap(io: Io, log: *Log, mark: u8, delay_ns: u64) void {
    log.append(mark);
    io.sleep(.fromNanoseconds(@intCast(delay_ns)), .awake) catch unreachable;
    log.append(mark);
}

const Log = struct {
    marks: [16]u8 = undefined,
    len: usize = 0,

    fn append(log: *Log, mark: u8) void {
        log.marks[log.len] = mark;
        log.len += 1;
    }

    fn text(log: *const Log) []const u8 {
        return log.marks[0..log.len];
    }
};

test "a sleep hands the thread to the next task, and the shorter sleep ends first" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var log: Log = .{};
    var long = io.async(nap, .{ io, &log, 'a', 4 * millisecond_ns });
    var short = io.async(nap, .{ io, &log, 'b', millisecond_ns });
    long.await(io);
    short.await(io);
    try testing.expectEqualStrings("abba", log.text());
}

test "sleep waits on the loop's timer, and the awake clock is the loop's" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const before = Io.Clock.awake.now(io);
    try testing.expectEqual(@as(i96, fixture.loop.now_ns()), before.nanoseconds);
    try io.sleep(.fromMilliseconds(2), .awake);
    const after = Io.Clock.awake.now(io);
    try testing.expect(after.nanoseconds - before.nanoseconds >= 2 * millisecond_ns);
    try testing.expectEqual(@as(i96, fixture.loop.now_ns()), after.nanoseconds);
}

test "the first sleep after init waits in full, by the real clock" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    // The real clock goes to rest, and reading it ticks nothing, so the loop has read no clock yet.
    const before = Io.Clock.real.now(io);
    try testing.expectEqual(0, fixture.loop.now_ns());
    try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expect(Io.Clock.real.now(io).nanoseconds - before.nanoseconds >= 5 * millisecond_ns);
}

fn hold(io: Io, gate: *u32) void {
    io.vtable.futexWaitUncancelable(io.userdata, gate, 0);
}

test "async runs a task inline when no fiber is free, and concurrent refuses it" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var gate: u32 = 0;
    var held: [fiber_count]Io.Future(void) = undefined;
    for (&held) |*future| future.* = try io.concurrent(hold, .{ io, &gate });
    try testing.expectError(error.ConcurrencyUnavailable, io.concurrent(add, .{ io, 1, 1 }));
    var inline_future = io.async(add, .{ io, 1, 1 });
    try testing.expect(inline_future.any_future == null);
    try testing.expectEqual(adapter_module.index_main, inline_future.await(io).fiber);
    gate = 1;
    io.vtable.futexWake(io.userdata, &gate, std.math.maxInt(u32));
    for (&held) |*future| future.await(io);
}

fn wait_for(io: Io, word: *u32, log: *Log, mark: u8) void {
    io.vtable.futexWait(io.userdata, word, 0, .none) catch unreachable;
    log.append(mark);
}

test "a futex wake takes the waiters in the order they came, and no more than it asks" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var word: u32 = 0;
    var log: Log = .{};
    var first = io.async(wait_for, .{ io, &word, &log, 'a' });
    var second = io.async(wait_for, .{ io, &word, &log, 'b' });
    var third = io.async(wait_for, .{ io, &word, &log, 'c' });
    // Let the three block, then wake two of them.
    try io.sleep(.fromMilliseconds(1), .awake);
    io.vtable.futexWake(io.userdata, &word, 2);
    first.await(io);
    second.await(io);
    try testing.expectEqualStrings("ab", log.text());
    io.vtable.futexWake(io.userdata, &word, 1);
    third.await(io);
    try testing.expectEqualStrings("abc", log.text());
}

test "a futex wait with a timeout ends with no wake, and a wake ends it before the timer" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var word: u32 = 0;
    const before = Io.Clock.awake.now(io);
    try io.vtable.futexWait(io.userdata, &word, 0, .{ .duration = .{
        .raw = .fromMilliseconds(2),
        .clock = .awake,
    } });
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - before.nanoseconds >= 2 * millisecond_ns);
    // A word that differs from the expected value returns at once, with nothing in flight.
    try io.vtable.futexWait(io.userdata, &word, 1, .none);
    try testing.expectEqual(0, fixture.loop.in_flight());
}

fn wake_later(io: Io, word: *u32) void {
    io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
    io.vtable.futexWake(io.userdata, word, 1);
}

test "a wake ends a futex wait whose timer is long, and the timer ends with it" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var word: u32 = 0;
    var waker = io.async(wake_later, .{ io, &word });
    const before = Io.Clock.awake.now(io);
    try io.vtable.futexWait(io.userdata, &word, 0, .{ .duration = .{
        .raw = .fromSeconds(10),
        .clock = .awake,
    } });
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - before.nanoseconds < 1000 * millisecond_ns);
    try testing.expectEqual(0, fixture.loop.in_flight());
    waker.await(io);
}

fn count_up(io: Io, counter: *u32) void {
    io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
    counter.* += 1;
}

test "a group awaits every member, and each member's fiber is free when it returns" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var counter: u32 = 0;
    var group: Io.Group = .init;
    for (0..fiber_count) |_| try group.concurrent(io, count_up, .{ io, &counter });
    // Every fiber is taken, so one more member runs inline.
    group.async(io, count_up, .{ io, &counter });
    try testing.expectEqual(1, counter);
    try group.await(io);
    try testing.expectEqual(fiber_count + 1, counter);
    try testing.expect(group.token.raw == null);
    // Every fiber is free again.
    for (0..fiber_count) |_| try group.concurrent(io, count_up, .{ io, &counter });
    try group.await(io);
}

const Handled = struct {
    events: u32 = 0,
    last: rotor.Event = undefined,

    fn handle(context: *anyopaque, event: rotor.Event) void {
        const handled: *Handled = @ptrCast(@alignCast(context));
        handled.events += 1;
        handled.last = event;
    }
};

test "an event of the caller's own operation goes to the caller's handler" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var handled: Handled = .{};
    var fixture: Fixture = undefined;
    try fixture.init(.{ .context = &handled, .handle = Handled.handle });
    defer fixture.deinit();
    const io = fixture.io();
    _ = fixture.loop.submit(&.{rotor.Operation.timer(77, millisecond_ns, 0)}, &.{});
    try io.sleep(.fromMilliseconds(3), .awake);
    try testing.expectEqual(1, handled.events);
    try testing.expectEqual(77, handled.last.user_data);
}

var random_calls: u32 = 0;
var random_userdata: ?*anyopaque = null;

fn counting_random(userdata: ?*anyopaque, buffer: []u8) void {
    random_userdata = userdata;
    random_calls += 1;
    @memset(buffer, 0xA5);
}

test "a call the adapter does not run goes to rest, with rest's own userdata" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    var table = fixture.threaded.io().vtable.*;
    table.random = counting_random;
    fixture.adapter.rest = .{ .userdata = &fixture.threaded, .vtable = &table };
    const io = fixture.io();
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    try testing.expectEqual(1, random_calls);
    try testing.expectEqual(@as(?*anyopaque, &fixture.threaded), random_userdata);
    try testing.expectEqualSlices(u8, &.{ 0xA5, 0xA5, 0xA5, 0xA5 }, &bytes);
}

fn large(io: Io) [adapter_module.adapter_constants.result_bytes_max + 1]u8 {
    const adapter: *Adapter = @ptrCast(@alignCast(io.userdata.?));
    var bytes: [adapter_module.adapter_constants.result_bytes_max + 1]u8 = @splat(0);
    bytes[0] = @intCast(adapter.current);
    return bytes;
}

test "a result larger than the top of a stack holds runs inline, and concurrent refuses it" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(large, .{io});
    try testing.expect(future.any_future == null);
    try testing.expectEqual(adapter_module.index_main, future.await(io)[0]);
    try testing.expectError(error.ConcurrencyUnavailable, io.concurrent(large, .{io}));
}
