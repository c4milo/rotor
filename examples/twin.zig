//! A twin of `rotor.Loop`: a loop of the program's own, with no kernel, for a test that must replay
//! exactly (decision 10). It declares the 28 names of the core's surface, the 8 names of the port of
//! decision 33, and a line with the 6 calls that the reactor makes on it. `rotor.Reactor(Twin)` then
//! gives the twin the records, the pollers, the tasks and the view, from the same code as the host's
//! reactor.
//!
//! The twin's clock moves only in a tick. A tick moves it to the end of its wait, which the nearest
//! operation and the stored limit bound, so each run is the same. A timer with no repeat ends at its
//! deadline. Each other operation ends at the next tick with `unsupported`, because the twin has no
//! kernel. The twin ignores `timeout_ns`.
//!
//! The program runs one record and one task on `rotor.Reactor(Twin)`: a library's timer names a
//! record, and the record schedules a task. It exits 0 only when both ran, in that order, at the
//! timer's deadline on the twin's clock. `docs/using.md`, "A twin of the loop", quotes this file.
//! `zig build test` runs it, and the Linux gate runs it on io_uring and on epoll, which it does not
//! use.
//!
//! Run:  zig build examples && ./zig-out/bin/twin
const std = @import("std");
const rotor = @import("rotor");
const assert = std.debug.assert;

/// The operations that a twin holds in flight at most.
const operations_max = 8;

/// The result of an operation that a cancel ended, and of one that the twin cannot do.
const canceled = -@as(i32, @intFromEnum(rotor.Code.canceled));
const unsupported = -@as(i32, @intFromEnum(rotor.Code.unsupported));

/// The message of a call that names a buffer group. The twin reserves none, so each such call is a
/// mistake of the program, and it halts, as on a loop.
const no_group = "twin: the twin reserves no buffer group";

/// What the drain hands each wake, call and return: the type of the hook of `attach_reserved`.
const Take = fn (context: *anyopaque, sender: rotor.LoopId, message: rotor.Message) void;

/// Why `push_reserved` sent nothing.
const PushError = error{ LoopNotFound, CallsFull, MailboxFull };

/// The twin's heartbeat line. It keeps the name of each callback that the reactor names on it, in
/// order, so the program can check what ran. A twin for replay may store nothing.
const Line = struct {
    names: [names_max][]const u8 = undefined,
    count: u32 = 0,
    poller_name: ?*const [:0]const u8 = null,

    const names_max = 8;

    pub fn enter(line: *Line, name: *const [:0]const u8) void {
        if (line.count == names_max) return;
        line.names[line.count] = name.*;
        line.count += 1;
    }
    pub fn leave(_: *Line, _: u64) void {}
    pub fn leave_polling(_: *Line, _: u32) void {}
    pub fn leave_tasks(_: *Line, _: u64) void {}
    pub fn leave_group_tasks(_: *Line, _: u64, _: u8) void {}
    pub fn name_poller(line: *Line, name: ?*const [:0]const u8) void {
        line.poller_name = name;
    }
};

/// One operation in flight: what its event carries, and when the twin ends it.
const Entry = struct {
    user_data: u64 = 0,
    /// On the twin's clock.
    due_ns: u64 = 0,
    result: i32 = 0,
    dispatched: bool = false,
    taken: bool = false,
    /// Plus 1 at each claim, so a handle of an earlier operation names none.
    generation: u32 = 0,
};

const Twin = struct {
    clock_ns: u64,
    entries: [operations_max]Entry,
    /// The port's `outstanding`: above 0, it takes the reactor's tick off its fast path.
    outstanding_word: u32,
    /// The stored limit: the port's `stored_limit`, which `wait_until` writes on a plain twin.
    limit: rotor.WaitLimit,
    line: Line,
    hook: ?struct { context: *anyopaque, take: *const Take },
    counts: Statistics,
    owner: std.Thread.Id,

    // The core's surface: the 28 names of `rotor.Loop`.

    pub const Options = struct {};
    pub const InitError = error{};
    pub const TickError = error{};
    pub const DrainError = TickError || error{StillInFlight};
    pub const PostError = error{ MailboxFull, LoopNotFound };
    /// What `statistics` returns: the twin's own counts.
    pub const Statistics = struct { ticks: u64 = 0, events: u64 = 0 };

    /// The twin keeps its state in its own struct, so it takes no memory of the caller.
    pub fn memory_bytes(_: *const Options) usize {
        return 0;
    }

    /// Starts the twin in place, on the thread that will own it.
    pub fn init(twin: *Twin, memory: []align(rotor.memory_alignment) u8, options: *const Options) InitError!void {
        assert(memory.len >= memory_bytes(options));
        twin.* = .{
            .clock_ns = 0,
            .entries = @splat(.{}),
            .outstanding_word = 0,
            .limit = .none,
            .line = .{},
            .hook = null,
            .counts = .{},
            .owner = std.Thread.getCurrentId(),
        };
    }

    /// Halts while an operation, a record or a task is still counted, as a loop does.
    pub fn deinit(twin: *Twin) void {
        twin.assert_owner();
        assert(twin.in_flight() == 0);
        assert(twin.outstanding_word == 0);
        twin.* = undefined;
    }

    /// Takes each operation while a slot is free, and returns how many it took.
    pub fn submit(twin: *Twin, operations: []const rotor.Operation, handles: []rotor.Handle) u32 {
        twin.assert_owner();
        assert(handles.len == 0 or handles.len == operations.len);
        for (operations, 0..) |*operation, taken| {
            const index = twin.free_index() orelse return @intCast(taken);
            const handle = twin.claim(index, operation);
            if (handles.len != 0) handles[taken] = handle;
        }
        return @intCast(operations.len);
    }

    /// Ends the operation at the next tick with `canceled`, when it is still in flight.
    pub fn cancel(twin: *Twin, handle: rotor.Handle) void {
        twin.assert_owner();
        assert(handle.index < operations_max);
        const entry = &twin.entries[handle.index];
        if (!entry.taken or entry.generation != handle.generation) return;
        twin.end_now(entry, canceled);
    }

    pub fn cancel_all(twin: *Twin) void {
        twin.assert_owner();
        for (&twin.entries) |*entry| {
            if (entry.taken) twin.end_now(entry, canceled);
        }
    }

    pub fn tick(twin: *Twin, events: []rotor.Event, wait_ns: u64) TickError!u32 {
        if (twin.outstanding_word != 0) try twin.take_kept_error();
        return twin.tick_backend(events, wait_ns);
    }

    /// Ticks until nothing is in flight, at most `drain_rounds_max` ticks.
    pub fn drain(twin: *Twin, scratch: []rotor.Event) DrainError!void {
        for (0..rotor.constants.drain_rounds_max) |_| {
            if (twin.in_flight() == 0) return;
            _ = try twin.tick(scratch, rotor.constants.drain_wait_ns);
        }
        if (twin.in_flight() != 0) return error.StillInFlight;
    }

    pub fn assert_empty(twin: *const Twin) void {
        assert(twin.in_flight() == 0);
    }

    pub fn in_flight(twin: *const Twin) u32 {
        var count: u32 = 0;
        for (twin.entries) |entry| count += @intFromBool(entry.taken);
        return count;
    }

    pub fn now_ns(twin: *const Twin) u64 {
        return twin.clock_ns;
    }

    /// `.now` while an operation is due, and otherwise the nearest end or the stored limit.
    pub fn wait_limit(twin: *Twin) rotor.WaitLimit {
        twin.assert_owner();
        const until_ns = @min(twin.nearest_ns(), @intFromEnum(twin.limit));
        if (until_ns <= twin.clock_ns) return .now;
        return .at(until_ns);
    }

    pub fn wait_until(twin: *Twin, limit: rotor.WaitLimit) void {
        twin.assert_owner();
        twin.limit = limit;
    }

    /// The twin's heartbeat is its line. It has no thread to watch it.
    pub fn heartbeat(twin: *Twin) *Line {
        twin.assert_owner();
        return &twin.line;
    }

    pub fn statistics(twin: *const Twin) *const Statistics {
        return &twin.counts;
    }

    /// The twin has no registry, so no loop takes its messages.
    pub fn post(twin: *Twin, target: rotor.LoopId, message: rotor.Message) PostError!void {
        twin.assert_owner();
        _ = .{ target, message };
        return error.LoopNotFound;
    }

    pub fn dropped_wakes(_: *const Twin) u64 {
        return 0;
    }

    /// The twin has no descriptor that a host can wait on.
    pub fn wait_descriptor(_: *const Twin) ?rotor.Descriptor {
        return null;
    }

    // The twin has no kernel, so it registers nothing and reserves no buffer group.

    pub fn register_buffers(_: *Twin, _: []const []u8) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn register_descriptors(_: *Twin, _: []const rotor.Descriptor) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn reserve_buffer_group(_: *Twin) error{BufferGroupsFull}!rotor.BufferGroup {
        return error.BufferGroupsFull;
    }
    pub fn provide_buffers(_: *Twin, _: rotor.BufferGroup, _: []align(rotor.buffers.group_alignment) u8, _: u16, _: u32) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn provide_datagram_buffers(_: *Twin, _: rotor.BufferGroup, _: []align(rotor.buffers.group_alignment) u8, _: u16, _: u32, _: rotor.datagram.GroupOptions) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn datagram(_: *const Twin, _: rotor.BufferGroup, _: rotor.Event) rotor.Delivery {
        @panic(no_group);
    }
    pub fn give_back_buffer(_: *Twin, _: rotor.BufferGroup, _: u16) void {
        @panic(no_group);
    }
    pub fn release_buffers(_: *Twin, _: rotor.BufferGroup) void {
        @panic(no_group);
    }
    pub fn provided_buffer(_: *const Twin, _: rotor.BufferGroup, _: u16) []u8 {
        @panic(no_group);
    }

    // The port of decision 33: what the reactor needs, and a plain caller must not call.

    pub fn tick_backend(twin: *Twin, events: []rotor.Event, wait_ns: u64) TickError!u32 {
        twin.assert_owner();
        assert(events.len != 0);
        twin.clock_ns += twin.wait_bound(wait_ns);
        const written = twin.end_due(events);
        twin.counts.ticks += 1;
        twin.counts.events += written;
        return written;
    }
    pub fn take_kept_error(twin: *Twin) TickError!void {
        twin.assert_owner();
    }
    pub fn outstanding(twin: *Twin) *u32 {
        return &twin.outstanding_word;
    }
    pub fn stored_limit(twin: *Twin) *rotor.WaitLimit {
        return &twin.limit;
    }
    pub fn heartbeat_line(twin: *Twin) *Line {
        return &twin.line;
    }
    pub fn attach_reserved(twin: *Twin, context: *anyopaque, take: *const Take) void {
        twin.assert_owner();
        assert(twin.hook == null);
        twin.hook = .{ .context = context, .take = take };
    }
    pub fn push_reserved(twin: *Twin, target: rotor.LoopId, message: rotor.Message) PushError!*u32 {
        _ = .{ twin, target, message };
        return error.LoopNotFound;
    }
    pub fn assert_owner(twin: *const Twin) void {
        assert(twin.owner == std.Thread.getCurrentId());
    }

    // The twin's own functions.

    /// How long a tick that is given `wait_ns` waits: until the nearest operation ends or the
    /// stored limit comes, when either is first. A loop bounds its wait in the same way.
    fn wait_bound(twin: *const Twin, wait_ns: u64) u64 {
        const limit_ns = @min(twin.nearest_ns(), @intFromEnum(twin.limit));
        const until_ns = @min(limit_ns, twin.clock_ns +| wait_ns);
        return until_ns -| twin.clock_ns;
    }

    /// The end of the operation in flight that ends first, or `maxInt(u64)` when none is in flight.
    fn nearest_ns(twin: *const Twin) u64 {
        var nearest: u64 = std.math.maxInt(u64);
        for (twin.entries) |entry| {
            if (entry.taken) nearest = @min(nearest, entry.due_ns);
        }
        return nearest;
    }

    /// Ends each operation that is due on the twin's clock, in the order of the table, and writes
    /// its event. Returns how many it wrote.
    fn end_due(twin: *Twin, events: []rotor.Event) u32 {
        var written: u32 = 0;
        for (&twin.entries) |*entry| {
            if (written == events.len) break;
            if (!entry.taken or entry.due_ns > twin.clock_ns) continue;
            events[written] = .{
                .user_data = entry.user_data,
                .result = entry.result,
                .flags = .{ .dispatched = entry.dispatched },
            };
            entry.taken = false;
            written += 1;
        }
        return written;
    }

    fn free_index(twin: *const Twin) ?u32 {
        for (twin.entries, 0..) |entry, index| {
            if (!entry.taken) return @intCast(index);
        }
        return null;
    }

    /// Claims the entry at `index` for `operation`, and returns its handle. The `dispatched` bit
    /// goes into the event, so the reactor calls the record that the operation names.
    fn claim(twin: *Twin, index: u32, operation: *const rotor.Operation) rotor.Handle {
        const entry = &twin.entries[index];
        entry.* = .{
            .user_data = operation.user_data,
            .due_ns = twin.clock_ns,
            .result = unsupported,
            .dispatched = operation.dispatched,
            .taken = true,
            .generation = entry.generation + 1,
        };
        switch (operation.kind) {
            .timer => |timer| if (timer.repeat_ns == 0) {
                entry.due_ns = twin.clock_ns + timer.after_ns;
                entry.result = 0;
            },
            else => {},
        }
        return .{ .index = index, .generation = entry.generation };
    }

    fn end_now(twin: *Twin, entry: *Entry, result: i32) void {
        entry.due_ns = twin.clock_ns;
        entry.result = result;
    }
};

comptime {
    // Each declaration of the twin compiles, also each one that this program never calls.
    for (@typeInfo(Twin).@"struct".decls) |declaration| _ = &@field(Twin, declaration.name);
}

/// The reactor over the twin: the same code as the host's reactor.
const Reactor = rotor.Reactor(Twin);

/// A library on the reactor's view: a timer whose record schedules a task.
const Library = struct {
    shared: *Reactor.SharedLoop,
    timer: rotor.Completion = .init(Library, "timer", on_timer),
    done: rotor.Task = .init(Library, "done", on_done),
    fired_ns: ?u64 = null,
    done_ns: ?u64 = null,

    fn start(library: *Library, after_ns: u64) !void {
        const timer = rotor.Completion.mark(&library.timer, rotor.Operation.timer(0, after_ns, 0));
        if (library.shared.submit(&.{timer}, &.{}) != 1) return error.NotTaken;
    }

    fn on_timer(library: *Library, event: rotor.Event) void {
        _ = event.outcome() catch return;
        library.fired_ns = library.shared.now_ns();
        // The queue holds no other task, so it has room.
        library.shared.schedule_in(.default, &library.done) catch unreachable;
    }

    fn on_done(library: *Library) void {
        library.done_ns = library.shared.now_ns();
    }
};

/// The timer's deadline on the twin's clock, which starts at 0.
const deadline_ns = 5 * rotor.constants.ns_per_ms;

pub fn main() !void {
    const options: Reactor.Options = .{ .loop = .{} };
    var memory: [Reactor.memory_bytes(&options)]u8 align(rotor.memory_alignment) = undefined;
    var reactor: Reactor = undefined;
    try reactor.init(&memory, &options);
    defer reactor.deinit();

    var library: Library = .{ .shared = reactor.shared() };
    try library.start(deadline_ns);
    var events: [4]rotor.Event = undefined;
    // The tick waits until the timer's deadline on the twin's clock. It calls the record, and the
    // record's task runs in the same tick. The reactor hands neither event to the program.
    if (try reactor.tick(&events, rotor.constants.ns_per_s) != 0) return error.EventNotTaken;
    try expect_ran(&reactor, &library);

    // A timer that the program cancels ends with `canceled` at the drain's first tick.
    var handle: [1]rotor.Handle = undefined;
    if (reactor.submit(&.{rotor.Operation.timer(1, rotor.constants.ns_per_s, 0)}, &handle) != 1) return error.NotTaken;
    reactor.cancel(handle[0]);
    try reactor.drain(&events);
    if (reactor.in_flight() != 0 or reactor.now_ns() != deadline_ns) return error.WrongClock;
    std.debug.print("twin: the record and the task ran at {d} ns on the twin's clock\n", .{deadline_ns});
}

/// Fails unless the record and then the task ran, each at the timer's deadline.
fn expect_ran(reactor: *Reactor, library: *const Library) !void {
    const fired_ns = library.fired_ns orelse return error.NotRun;
    const done_ns = library.done_ns orelse return error.NotRun;
    if (fired_ns != deadline_ns or done_ns != deadline_ns) return error.WrongClock;
    if (reactor.tasks_queued() != 0 or reactor.in_flight() != 0) return error.NotEnded;
    const line = reactor.heartbeat();
    if (line.count != 2) return error.WrongNames;
    if (!std.mem.eql(u8, line.names[0], @typeName(Library) ++ ".timer")) return error.WrongNames;
    if (!std.mem.eql(u8, line.names[1], @typeName(Library) ++ ".done")) return error.WrongNames;
}
