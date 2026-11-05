//! The std.Io adapter (decision 22): a `std.Io` whose state is one rotor loop and a pool of fibers.
//! Code written against `std.Io` runs on the loop's thread, beside code written against the loop's
//! own API.
//!
//! The adapter keeps the loop's rules. It allocates nothing: the caller hands `init` one block for
//! the fibers' records and their stacks. It starts no thread and moves no work between threads:
//! every fiber runs on the thread that owns the loop, and a call from another thread halts. A call
//! the adapter does not run on the loop goes to `rest`, a `std.Io` the caller supplies, which runs
//! it on the calling thread or on threads of its own.
//!
//! The files: `adapter_switch.zig` switches between contexts, `adapter_scheduler.zig` decides which
//! context runs and ticks the loop, `adapter_tasks.zig` holds tasks, groups and cancellation,
//! `adapter_wait.zig` holds futexes and time, `adapter_net.zig` the network calls, and
//! `adapter_rest.zig` forwards the other calls.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const rotor = @import("../rotor.zig");
const constants = @import("constants.zig");
const switching = @import("adapter_switch.zig");
const scheduler = @import("adapter_scheduler.zig");
const tasks = @import("adapter_tasks.zig");
const wait = @import("adapter_wait.zig");
const network = @import("adapter_net.zig");
const datagram = @import("adapter_datagram.zig");
const batch = @import("adapter_batch.zig");
const file = @import("adapter_file.zig");
const rest = @import("adapter_rest.zig");

pub const adapter_constants = constants;

/// True on the architectures the adapter has a context switch for.
pub const supported = switching.supported;

/// A context's index among the adapter's records. Index 0 is the main context: the thread's own
/// stack, which calls the adapter first. Indices 1 to `fibers` are fibers.
pub const Index = u16;

/// The index that names no context.
pub const index_none: Index = std.math.maxInt(Index);

/// The main context's index.
pub const index_main: Index = 0;

pub const State = enum(u8) {
    /// On the free list, with no task.
    free,
    /// On the ready list: it runs when the running context blocks.
    ready,
    running,
    blocked,
    /// A future's task returned. The fiber waits for `await` to take its result.
    finished,
};

/// What a blocked context waits for.
pub const Wait = enum(u8) {
    none,
    /// The final event of the operation `handle` names.
    operation,
    /// A `futexWake` on `futex_address`, or the final event of a timer when `handle` names one.
    futex,
    /// The fiber it awaits to finish.
    future,
    /// Every member of a group to finish.
    group,
    /// A cancel and nothing else: `sleep` with no timeout.
    cancel,
};

/// One context's record. 72 bytes, aligned to 8.
pub const Fiber = struct {
    context: switching.Context,
    /// The operation in flight for this context, or `Handle.none`.
    handle: rotor.Handle,
    /// The futex word a blocked `futexWait` waits on.
    futex_address: usize,
    /// The group of a group member.
    group: ?*Io.Group,
    /// The task's function: a future's takes a result, and a group member's does not.
    start: ?*const anyopaque,
    /// The last final event's result, or 0 for a wake.
    result: i32,
    /// The next index on the ready, free or futex list.
    next: Index,
    /// The context that awaits this future.
    awaiter: Index,
    state: State,
    wait: Wait,
    /// The task belongs to a group, and has no future.
    member: bool,
    cancel_requested: bool,
    /// The wait this context blocks in ends early for a cancel.
    cancelable: bool,
    /// A cancel ended the wait this context blocks in.
    interrupted: bool,
    protection: Io.CancelProtection,
    /// A cancel point returned `error.Canceled`, and no further one returns it until `recancel`.
    acknowledged: bool,

    pub const empty: Fiber = .{
        .context = undefined,
        .handle = .none,
        .futex_address = 0,
        .group = null,
        .start = null,
        .result = 0,
        .next = index_none,
        .awaiter = index_none,
        .state = .free,
        .wait = .none,
        .member = false,
        .cancel_requested = false,
        .cancelable = false,
        .interrupted = false,
        .protection = .unblocked,
        .acknowledged = false,
    };

    comptime {
        assert(@sizeOf(Fiber) == 72);
        assert(@alignOf(Fiber) == 8);
    }
};

/// Where an event that belongs to no operation of the adapter goes: the caller's own operations on
/// the same loop, and messages other loops post to it.
pub const Handler = struct {
    context: *anyopaque,
    handle: *const fn (context: *anyopaque, event: rotor.Event) void,
};

pub const Options = struct {
    /// The fibers, in [1, `constants.fibers_max`].
    fibers: u16,
    /// Each fiber's stack, a whole number of `constants.stack_granule_bytes` in
    /// [`constants.stack_bytes_min`, `constants.stack_bytes_max`].
    stack_bytes: u32,
    /// What runs every call the adapter does not run on the loop. Usually `std.Io.Threaded`.
    rest: Io,
    /// Null when every event of the loop belongs to the adapter.
    handler: ?Handler = null,
    /// The group the caller provided on the loop with `provide_datagram_buffers`, which each
    /// socket's standing receive reads into, or null for an adapter that receives no datagram.
    datagram_group: ?u16 = null,
    /// The sockets that may receive datagrams at once, at most `constants.datagram_sockets_max`.
    datagram_sockets: u16 = 0,
    /// The datagrams each socket's queue holds, at most `constants.datagram_queue_max`. A queue as
    /// long as the group's buffers drops none.
    datagram_queue: u16 = 0,
};

/// The alignment of the memory `init` takes. The stacks inside it are aligned to
/// `constants.stack_granule_bytes`: `init` moves them up to the next boundary, and `memory_bytes`
/// counts one granule more for that. A static aligned to a granule is not always placed on one: a
/// Mach-O build placed such a static at 16 KiB.
pub const memory_alignment = constants.closure_alignment;

/// The bytes of memory `init` needs for `options`: the records, the datagram table, then the
/// stacks.
pub fn memory_bytes(options: Options) usize {
    check_options(options);
    return records_bytes(options) + constants.stack_granule_bytes +
        @as(usize, options.fibers) * options.stack_bytes;
}

/// The fibers' records, then the datagram table and its queues: every part aligned to 8 bytes.
fn records_bytes(options: Options) usize {
    return (@as(usize, options.fibers) + 1) * @sizeOf(Fiber) +
        datagram.table_bytes(options.datagram_sockets, options.datagram_queue);
}

fn check_options(options: Options) void {
    assert(options.fibers >= 1);
    assert(options.fibers <= constants.fibers_max);
    assert(options.stack_bytes >= constants.stack_bytes_min);
    assert(options.stack_bytes <= constants.stack_bytes_max);
    assert(options.stack_bytes % constants.stack_granule_bytes == 0);
    assert(options.datagram_sockets <= constants.datagram_sockets_max);
    assert(options.datagram_queue <= constants.datagram_queue_max);
    // A table needs a group and a queue, and a group needs a table.
    assert((options.datagram_sockets == 0) == (options.datagram_group == null));
    assert((options.datagram_sockets == 0) == (options.datagram_queue == 0));
}

/// Any address of this variable names the thread that reads it, because each thread has its own.
threadlocal var thread_marker: u8 = 0;

fn thread_id() usize {
    return @intFromPtr(&thread_marker);
}

pub const Adapter = struct {
    loop: *rotor.Loop,
    rest: Io,
    handler: ?Handler,
    /// Index 0 is the main context, and indices 1 to `fibers` are the fibers.
    fibers: []Fiber,
    stacks: []align(constants.stack_granule_bytes) u8,
    stack_bytes: u32,
    /// The thread that called `init`, which owns the loop.
    thread: usize,
    current: Index,
    ready_head: Index,
    ready_tail: Index,
    free_head: Index,
    futex_head: Index,
    datagram_group: ?u16,
    /// One entry for each socket that may receive datagrams at once.
    datagrams: []datagram.Socket,
    /// Moves at every datagram event, so a batch that waits sees that one came.
    datagram_epoch: u32,
    events: [constants.events_per_tick]rotor.Event,

    /// Runs on the thread that owns `loop`. `memory` holds at least `memory_bytes(options)`.
    pub fn init(
        adapter: *Adapter,
        loop: *rotor.Loop,
        memory: []align(memory_alignment) u8,
        options: Options,
    ) void {
        check_options(options);
        assert(memory.len >= memory_bytes(options));
        const fiber_count = @as(usize, options.fibers) + 1;
        const fibers_end = fiber_count * @sizeOf(Fiber);
        const records: []Fiber = @ptrCast(@alignCast(memory[0..fibers_end]));
        const records_end = @intFromPtr(memory.ptr) + records_bytes(options);
        const stacks_start = std.mem.alignForward(usize, records_end, constants.stack_granule_bytes) -
            @intFromPtr(memory.ptr);
        adapter.* = .{
            .loop = loop,
            .rest = options.rest,
            .handler = options.handler,
            .fibers = records,
            .stacks = @alignCast(memory[stacks_start..][0 .. @as(usize, options.fibers) * options.stack_bytes]),
            .stack_bytes = options.stack_bytes,
            .thread = thread_id(),
            .current = index_main,
            .ready_head = index_none,
            .ready_tail = index_none,
            .free_head = index_none,
            .futex_head = index_none,
            .datagram_group = options.datagram_group,
            .datagrams = datagram.carve(memory[fibers_end..records_bytes(options)], options),
            .datagram_epoch = 0,
            .events = undefined,
        };
        for (records) |*record| record.* = .empty;
        records[index_main].state = .running;
        // The free list runs from the lowest index up, so the first task takes fiber 1.
        var index: Index = options.fibers;
        while (index >= 1) : (index -= 1) scheduler.push_free(adapter, index);
    }

    /// Requires every task awaited, and so every operation of the adapter ended. A fiber that runs,
    /// is ready, or waits on a futex is not free, so the one check covers each of those.
    pub fn deinit(adapter: *Adapter) void {
        assert(adapter.thread == thread_id());
        for (adapter.fibers[1..]) |record| assert(record.state == .free);
        // Every socket that received datagrams is closed, so no standing receive is in flight.
        for (adapter.datagrams) |entry| assert(entry.state == .free);
        adapter.* = undefined;
    }

    pub fn io(adapter: *Adapter) Io {
        return .{ .userdata = adapter, .vtable = &vtable };
    }

    /// The bytes at the top of fiber `index`'s stack that hold its task's arguments.
    pub fn context_bytes(adapter: *const Adapter, index: Index) []u8 {
        const top = stack_top(adapter, index);
        return adapter.stacks[top - constants.context_bytes_max .. top];
    }

    /// The bytes below the arguments that hold the task's result.
    pub fn result_bytes(adapter: *const Adapter, index: Index) []u8 {
        const top = stack_top(adapter, index) - constants.context_bytes_max;
        return adapter.stacks[top - constants.result_bytes_max .. top];
    }

    /// The address the fiber's stack starts from, below its arguments and its result.
    pub fn stack_end(adapter: *const Adapter, index: Index) usize {
        const top = stack_top(adapter, index) - constants.closure_bytes;
        return @intFromPtr(adapter.stacks.ptr) + top;
    }

    fn stack_top(adapter: *const Adapter, index: Index) usize {
        assert(index != index_main);
        assert(index < adapter.fibers.len);
        return @as(usize, index) * adapter.stack_bytes;
    }
};

/// The adapter behind `userdata`, from the thread that owns it. A call from another thread halts.
pub fn from(userdata: ?*anyopaque) *Adapter {
    const adapter: *Adapter = @ptrCast(@alignCast(userdata.?));
    assert(adapter.thread == thread_id());
    return adapter;
}

/// The calls the adapter runs itself, each named as the field of `Io.VTable` it fills.
const own = struct {
    pub const async = tasks.async_task;
    pub const concurrent = tasks.concurrent;
    pub const await = tasks.await_task;
    pub const cancel = tasks.cancel;
    pub const groupAsync = tasks.group_async;
    pub const groupConcurrent = tasks.group_concurrent;
    pub const groupAwait = tasks.group_await;
    pub const groupCancel = tasks.group_cancel;
    pub const recancel = tasks.recancel;
    pub const swapCancelProtection = tasks.swap_cancel_protection;
    pub const checkCancel = tasks.check_cancel;
    pub const futexWait = wait.futex_wait;
    pub const futexWaitUncancelable = wait.futex_wait_uncancelable;
    pub const futexWake = wait.futex_wake;
    pub const now = wait.now;
    pub const sleep = wait.sleep;
    pub const netListenIp = network.net_listen_ip;
    pub const netBindIp = network.net_bind_ip;
    pub const netConnectIp = network.net_connect_ip;
    pub const netAccept = network.net_accept;
    pub const netRead = network.net_read;
    pub const netWrite = network.net_write;
    pub const netSend = network.net_send;
    pub const netClose = network.net_close;
    pub const netShutdown = network.net_shutdown;
    pub const operate = batch.operate;
    pub const batchAwaitAsync = batch.batch_await_async;
    pub const batchAwaitConcurrent = batch.batch_await_concurrent;
    pub const batchCancel = batch.batch_cancel;
    pub const fileReadPositional = file.file_read_positional;
    pub const fileWritePositional = file.file_write_positional;
    pub const fileSync = file.file_sync;
    pub const fileClose = file.file_close;
};

/// Every call of `Io.VTable`: the adapter's own where `own` names it, and `rest`'s otherwise.
const vtable: Io.VTable = table: {
    var table: Io.VTable = undefined;
    for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        @field(table, field.name) = if (@hasDecl(own, field.name))
            &@field(own, field.name)
        else
            rest.forwarder(field.name);
    }
    break :table table;
};

/// The calls the adapter runs itself. The rest go to `rest`.
pub const own_calls = @typeInfo(own).@"struct".decls.len;

test {
    _ = @import("adapter_test.zig");
    _ = @import("adapter_test_cancel.zig");
    _ = @import("adapter_switch_test.zig");
    _ = @import("adapter_test_net.zig");
    _ = @import("adapter_net_errors.zig");
    _ = @import("adapter_test_datagram.zig");
    _ = @import("adapter_test_file.zig");
}
