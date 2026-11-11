//! Tests of `Reactor(Loop)` over a twin of decision 10 that notes each call it takes (decision 33).
//! A forwarder must reach the loop's call of the same name, with its arguments, and return what
//! that call returns. A call of the reactor's own must run on the reactor's state, and reach the
//! loop only through the core's surface and the port. Split from `reactor.zig` for the 500-line
//! limit.
const std = @import("std");
const core = @import("core");
const reactor_module = @import("reactor.zig");
const check_module = @import("reactor_check.zig");

const testing = std.testing;

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Poller = reactor_module.Poller;
const Task = reactor_module.Task;
const group_alignment = core.buffer_group.group_alignment;

/// A line that keeps the name of the first poller, and counts the calls it takes.
const Line = struct {
    poller_name: ?*const [:0]const u8 = null,
    entered: u32 = 0,

    pub fn enter(line: *Line, _: *const [:0]const u8) void {
        line.entered += 1;
    }
    pub fn leave(_: *Line, _: u64) void {}
    pub fn leave_polling(_: *Line, _: u32) void {}
    pub fn leave_tasks(_: *Line, _: u64) void {}
    pub fn leave_group_tasks(_: *Line, _: u64, _: u8) void {}
    pub fn name_poller(line: *Line, name: ?*const [:0]const u8) void {
        line.poller_name = name;
    }
};

/// A twin with each name of the core's surface and of the port. A call that may change the loop
/// stores its name in `last` and one of its arguments in `argument`. A call that only reads the
/// loop returns a value made from `argument`, so a test sees that the call ran.
pub const Twin = struct {
    last: []const u8 = "",
    argument: u64 = 0,
    line: Line = .{},
    word: u32 = 0,
    limit: core.WaitLimit = .none,
    bytes: [8]u8 = @splat(0),
    /// The hook that `attach_reserved` stored.
    hook: core.reserved.Hook = .none,
    /// The ticks of the backend that ran, and the kept errors taken.
    backend_ticks: u32 = 0,
    kept_taken: u32 = 0,

    pub const Options = struct { operations: u32, id: core.LoopId = 0 };

    /// The error sets of the twin's own, which the reactor returns as they are.
    pub const InitError = error{InitRefused};
    pub const TickError = error{TickRefused};

    fn note(twin: *Twin, name: []const u8, argument: u64) void {
        twin.last = name;
        twin.argument = argument;
    }

    pub fn memory_bytes(options: *const Options) usize {
        return options.operations * 8;
    }
    pub fn init(twin: *Twin, memory: []align(core.layout.memory_alignment) u8, options: *const Options) InitError!void {
        twin.* = .{};
        if (options.operations == 0) return error.InitRefused;
        twin.note("init", memory.len + options.operations);
    }
    pub fn deinit(twin: *Twin) void {
        twin.note("deinit", 0);
    }
    pub fn dropped_wakes(twin: *const Twin) u64 {
        return twin.argument + 1;
    }
    pub fn submit(twin: *Twin, operations: []const Operation, handles: []Handle) u32 {
        twin.note("submit", handles.len);
        return @intCast(operations.len);
    }
    pub fn cancel(twin: *Twin, handle: Handle) void {
        twin.note("cancel", handle.generation);
    }
    pub fn post(twin: *Twin, target: core.LoopId, message: core.Message) error{MailboxFull}!void {
        twin.note("post", target + message.payload);
        if (target == 0) return error.MailboxFull;
    }
    pub fn tick(twin: *Twin, events: []Event, wait_ns: u64) TickError!u32 {
        return core.tick_error.tick(twin, events, wait_ns);
    }
    pub fn heartbeat(twin: *Twin) *Line {
        twin.note("heartbeat", 0);
        return &twin.line;
    }
    pub fn in_flight(twin: *const Twin) u32 {
        return @intCast(twin.argument + 5);
    }
    pub fn now_ns(twin: *const Twin) u64 {
        return twin.argument + 6;
    }
    pub fn wait_descriptor(twin: *const Twin) ?core.Descriptor {
        return @intCast(twin.argument + 7);
    }
    pub fn statistics(twin: *const Twin) *const u64 {
        return &twin.argument;
    }
    pub fn cancel_all(twin: *Twin) void {
        twin.note("cancel_all", 0);
    }
    pub fn drain(twin: *Twin, scratch: []Event) error{StillInFlight}!void {
        twin.note("drain", scratch.len);
    }
    pub fn assert_empty(twin: *const Twin) void {
        std.debug.assert(twin.argument != 9);
    }
    pub fn register_buffers(twin: *Twin, blocks: []const []u8) error{RegisterRefused}!void {
        twin.note("register_buffers", blocks.len);
    }
    pub fn register_descriptors(twin: *Twin, descriptors: []const core.Descriptor) error{RegisterRefused}!void {
        twin.note("register_descriptors", descriptors.len);
    }
    pub fn reserve_buffer_group(twin: *Twin) error{BufferGroupsFull}!core.BufferGroup {
        twin.note("reserve_buffer_group", 0);
        return @enumFromInt(3);
    }
    pub fn provide_buffers(twin: *Twin, group: core.BufferGroup, memory: []align(group_alignment) u8, count: u16, buffer_bytes: u32) error{ProvideRefused}!void {
        twin.note("provide_buffers", @intFromEnum(group) + memory.len + count + buffer_bytes);
    }
    pub fn provide_datagram_buffers(twin: *Twin, group: core.BufferGroup, memory: []align(group_alignment) u8, count: u16, buffer_bytes: u32, options: core.datagram.GroupOptions) error{ProvideRefused}!void {
        twin.note("provide_datagram_buffers", @intFromEnum(group) + memory.len + count + buffer_bytes + options.name_reserve);
    }
    pub fn datagram(twin: *const Twin, group: core.BufferGroup, event: Event) core.Delivery {
        _ = event;
        return .{ .from = std.mem.zeroes(core.datagram.Received), .bytes = @constCast(twin.bytes[0..@intFromEnum(group)]) };
    }
    pub fn give_back_buffer(twin: *Twin, group: core.BufferGroup, buffer_id: u16) void {
        twin.note("give_back_buffer", @as(u64, @intFromEnum(group)) * 1000 + buffer_id);
    }
    pub fn release_buffers(twin: *Twin, group: core.BufferGroup) void {
        twin.note("release_buffers", @intFromEnum(group));
    }
    pub fn provided_buffer(twin: *const Twin, group: core.BufferGroup, buffer_id: u16) []u8 {
        return @constCast(twin.bytes[@intFromEnum(group)..buffer_id]);
    }
    pub fn wait_limit(twin: *Twin) core.WaitLimit {
        twin.note("wait_limit", 0);
        return twin.limit;
    }
    pub fn wait_until(twin: *Twin, limit: core.WaitLimit) void {
        twin.limit = limit;
    }

    // The port of decision 33.
    pub fn tick_backend(twin: *Twin, _: []Event, wait_ns: u64) TickError!u32 {
        twin.note("tick", wait_ns);
        twin.backend_ticks += 1;
        if (wait_ns == 1) return error.TickRefused;
        return 0;
    }
    pub fn take_kept_error(twin: *Twin) TickError!void {
        twin.kept_taken += 1;
    }
    pub fn outstanding(twin: *Twin) *u32 {
        return &twin.word;
    }
    pub fn stored_limit(twin: *Twin) *core.WaitLimit {
        return &twin.limit;
    }
    pub fn heartbeat_line(twin: *Twin) *Line {
        return &twin.line;
    }
    pub fn attach_reserved(twin: *Twin, context: *anyopaque, take: *const core.reserved.Take) void {
        std.debug.assert(twin.hook.take == core.reserved.Hook.none.take);
        twin.hook = .{ .take = take, .context = context };
    }
    pub fn push_reserved(_: *Twin, _: core.LoopId, _: core.Message) core.reserved.PushError!*u32 {
        return error.LoopNotFound;
    }
    pub fn assert_owner(_: *const Twin) void {}
};

const Reactor = reactor_module.Reactor(Twin);

/// The memory of a reactor over a twin of 2 operations: the twin's 16 B, then the groups.
const test_options: Reactor.Options = .{ .loop = .{ .operations = 2 } };
const test_bytes = Reactor.memory_bytes(&test_options);

/// A reactor over memory of its own, which `init` started.
const Fixture = struct {
    memory: [test_bytes]u8 align(core.layout.memory_alignment) = undefined,
    reactor: Reactor = undefined,

    fn init(fixture: *Fixture) !void {
        try fixture.reactor.init(&fixture.memory, &test_options);
    }
};

/// Fails unless the twin's last call that may change it was `name`, with `argument`.
fn expect_last(reactor: *const Reactor, name: []const u8, argument: u64) !void {
    try testing.expectEqualStrings(name, reactor.loop.last);
    try testing.expectEqual(argument, reactor.loop.argument);
}

test "a twin with each name passes the check" {
    try testing.expectEqual(null, comptime check_module.message(Twin));
}

test "init carves the groups after the loop's memory, starts the loop, and attaches the hook" {
    try testing.expectEqual(16 + @sizeOf(reactor_module.Groups), test_bytes);
    var fixture: Fixture = .{};
    try fixture.init();
    const reactor = &fixture.reactor;
    try expect_last(reactor, "init", 16 + 2);
    try testing.expectEqual(@intFromPtr(&fixture.memory) + 16, @intFromPtr(reactor.dispatch.groups));
    try testing.expectEqual(@as(*anyopaque, reactor), reactor.loop.hook.context);
    try testing.expect(reactor.loop.hook.take != core.reserved.Hook.none.take);
    reactor.deinit();
    try expect_last(reactor, "deinit", 0);
    var refused: Fixture = .{};
    try testing.expectError(error.InitRefused, refused.reactor.init(&refused.memory, &.{ .loop = .{ .operations = 0 } }));
}

test "each forwarder of the core's surface reaches the loop, with its arguments" {
    var fixture: Fixture = .{};
    try fixture.init();
    const reactor = &fixture.reactor;
    reactor.cancel(.{ .index = 1, .generation = 4 });
    try expect_last(reactor, "cancel", 4);
    try reactor.post(2, .{ .payload = 40, .tag = 0 });
    try expect_last(reactor, "post", 42);
    try testing.expectError(error.MailboxFull, reactor.post(0, .{ .payload = 0, .tag = 0 }));
    reactor.cancel_all();
    try expect_last(reactor, "cancel_all", 0);
    try testing.expectEqual(core.WaitLimit.none, reactor.wait_limit());
    try expect_last(reactor, "wait_limit", 0);
    reactor.loop.argument = 100;
    try testing.expectEqual(101, reactor.dropped_wakes());
    try testing.expectEqual(105, reactor.in_flight());
    try testing.expectEqual(106, reactor.now_ns());
    try testing.expectEqual(107, reactor.wait_descriptor());
    try testing.expectEqual(&reactor.loop.argument, reactor.statistics());
    reactor.loop.argument = 0;
    try testing.expectEqual(&reactor.loop.line, reactor.heartbeat());
    try expect_last(reactor, "heartbeat", 0);
    var block: [4]u8 = @splat(0);
    try reactor.register_buffers(&.{&block});
    try expect_last(reactor, "register_buffers", 1);
    try reactor.register_descriptors(&.{ 1, 2 });
    try expect_last(reactor, "register_descriptors", 2);
    const group = try reactor.reserve_buffer_group();
    var memory: [64]u8 align(group_alignment) = @splat(0);
    try reactor.provide_buffers(group, &memory, 2, 32);
    try expect_last(reactor, "provide_buffers", 3 + 64 + 2 + 32);
    try reactor.provide_datagram_buffers(group, &memory, 2, 32, .{ .name_reserve = 100 });
    try expect_last(reactor, "provide_datagram_buffers", 3 + 64 + 2 + 32 + 100);
    try testing.expectEqual(3, reactor.datagram(group, undefined).bytes.len);
    try testing.expectEqual(2, reactor.provided_buffer(group, 5).len);
    reactor.give_back_buffer(group, 6);
    try expect_last(reactor, "give_back_buffer", 3006);
    reactor.release_buffers(group);
    try expect_last(reactor, "release_buffers", 3);
    reactor.deinit();
}

/// A library's records: a record, a poller and a task.
const Library = struct {
    completion: reactor_module.Completion = .init(Library, "completion", completed),
    poller: Poller = .init(Library, "poller", polled),
    task: Task = .init(Library, "task", ran),
    completions: u32 = 0,
    polls: u32 = 0,
    runs: u32 = 0,

    fn completed(library: *Library, _: Event) void {
        library.completions += 1;
    }

    fn polled(library: *Library) core.WaitLimit {
        library.polls += 1;
        return .at(500);
    }

    fn ran(library: *Library) void {
        library.runs += 1;
    }
};

test "submit counts the operations that name a record in the loop's word, and no other" {
    var fixture: Fixture = .{};
    try fixture.init();
    const reactor = &fixture.reactor;
    var library: Library = .{};
    var handles: [3]Handle = @splat(.none);
    const batch = [_]Operation{
        reactor_module.Completion.mark(&library.completion, Operation.timer(0, 1, 0)),
        Operation.timer(0, 1, 0),
        reactor_module.Completion.mark(&library.completion, Operation.timer(0, 1, 0)),
    };
    try testing.expectEqual(3, reactor.submit(&batch, &handles));
    try expect_last(reactor, "submit", 3);
    try testing.expectEqual(2, reactor.loop.word);
    reactor.loop.word = 0;
    reactor.deinit();
}

test "a poller names itself on the line, bounds the wait, and its removal clears both" {
    var fixture: Fixture = .{};
    try fixture.init();
    const reactor = &fixture.reactor;
    var library: Library = .{};
    var events: [2]Event = undefined;
    try reactor.add_poller(&library.poller);
    try testing.expectEqual(&library.poller.call.name, reactor.loop.line.poller_name.?);
    // A tick with a poller is dispatched: it calls the poller, which stores its limit.
    try testing.expectEqual(0, try reactor.tick(&events, 9));
    try testing.expectEqual(1, library.polls);
    try testing.expectEqual(core.WaitLimit.at(500), reactor.loop.limit);
    try testing.expectEqual(1, reactor.loop.kept_taken);
    reactor.remove_poller(&library.poller);
    try testing.expectEqual(@as(?*const [:0]const u8, null), reactor.loop.line.poller_name);
    try testing.expectEqual(core.WaitLimit.none, reactor.loop.limit);
    reactor.deinit();
}

test "a tick with no poller and nothing outstanding runs the backend alone" {
    var fixture: Fixture = .{};
    try fixture.init();
    const reactor = &fixture.reactor;
    var events: [2]Event = undefined;
    try testing.expectEqual(0, try reactor.tick(&events, 11));
    try expect_last(reactor, "tick", 11);
    try testing.expectEqual(0, reactor.loop.kept_taken);
    try testing.expectError(error.TickRefused, reactor.tick(&events, 1));
    // A task queued takes the next tick off the fast path, and its `end` runs the task.
    var library: Library = .{};
    try reactor.schedule(&library.task);
    try testing.expectEqual(1, reactor.loop.word);
    try testing.expectEqual(1, reactor.tasks_queued());
    try testing.expectEqual(core.WaitLimit.now, reactor.wait_limit());
    try testing.expectEqual(0, try reactor.tick(&events, 11));
    // A task queued gives the backend no wait.
    try expect_last(reactor, "tick", 0);
    try testing.expectEqual(1, library.runs);
    try testing.expectEqual(0, reactor.loop.word);
    try testing.expectEqual(1, reactor.loop.kept_taken);
    reactor.deinit();
}

test "a wake through the hook stores now only while a poller is added" {
    var fixture: Fixture = .{};
    try fixture.init();
    const reactor = &fixture.reactor;
    const hook = reactor.loop.hook;
    hook.take(hook.context, 1, core.Message.wake);
    try testing.expectEqual(core.WaitLimit.none, reactor.loop.limit);
    var library: Library = .{};
    try reactor.add_poller(&library.poller);
    hook.take(hook.context, 1, core.Message.wake);
    try testing.expectEqual(core.WaitLimit.now, reactor.loop.limit);
    reactor.remove_poller(&library.poller);
    reactor.deinit();
}

test "the view is the reactor's, and declares the calls of a library" {
    var fixture: Fixture = .{};
    try fixture.init();
    const reactor = &fixture.reactor;
    const shared = reactor.shared();
    try testing.expectEqual(@intFromPtr(reactor), @intFromPtr(shared));
    comptime reactor_module.shared.check(Reactor.SharedLoop);
    // A library's call on the view reaches the reactor, and through it the loop.
    try testing.expectEqual(1, shared.submit(&.{Operation.timer(0, 1, 0)}, &.{}));
    try expect_last(reactor, "submit", 0);
    try testing.expect(!@hasDecl(Reactor.SharedLoop, "wait_limit"));
    try testing.expect(@hasDecl(Reactor.SharedLoop, "wait_until"));
    reactor.deinit();
}

test "a call to a loop that takes none is refused, and leaves the link idle" {
    var fixture: Fixture = .{};
    try fixture.init();
    const reactor = &fixture.reactor;
    var stations: [core.constants.loops_max]reactor_module.CallStation = @splat(reactor_module.CallStation.unused);
    const library: Library = .{};
    var link: reactor_module.CallLink = .idle(library.task.call);
    link.prepare(&stations, library.task.call, 1, .{ .group = .default });
    try testing.expectError(error.LoopNotFound, reactor.call(&link));
    try testing.expect(!link.sent);
    try testing.expectEqual(0, reactor.loop.word);
    reactor.deinit();
}

test "the reactor holds its loop and its state, and nothing else" {
    try testing.expectEqual(2, @typeInfo(Reactor).@"struct".fields.len);
    try testing.expectEqual(@sizeOf(Twin) + @sizeOf(reactor_module.Dispatch), @sizeOf(Reactor));
}
