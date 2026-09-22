//! rotor_reads: O_DIRECT reads and writes, sequential and random, which is the file half of
//! milestone 4's workload list and the only program in this tree that registers a buffer.
//!
//! Run:  rotor_reads PATH [--transfer read|write] [--pattern seq|random] [--depth N]
//!                        [--block-bytes B] [--registered yes|no] [--seconds S]
//!                        [--file-bytes N] [--file-policy blocking|offload] [--sync yes|no]
//!
//! The name says reads because that is what it measured first, and three decision records and
//! `bench/alternatives/README.md` refer to it. `--transfer write` runs the other direction.
//!
//! **A write run never touches the path it is given.** It appends `write_suffix` and creates that
//! file. A read changes nothing; a write overwrites whole blocks, so it may not overwrite a file
//! somebody else named. Pointing this program at something valuable costs a file beside it.
//!
//! **`--sync` decides whether a write is durable.** With `no`, the default, a write ends when the
//! kernel has handed the block to the device: O_DIRECT bypasses the page cache and not the drive's
//! own, so the row is the write path's latency and says nothing about durability. With `yes`, every
//! write is followed by an `fdatasync` and one operation is one durable write, which is what a
//! journal pays. The two are separate workload names so their rows can never share a `Series`.
//!
//! On an NVMe drive with power-loss protection the two rows nearly coincide, because the drive
//! reports no volatile write cache and the flush is almost free. On a consumer drive the flush
//! dominates. `machine.zig` records which, or a durable row cannot be read.
//!
//! It keeps `depth` reads in flight against one file and re-issues each as it completes, so the
//! device queue never drains and the measurement is of the path rather than of the program
//! waiting. That is C12 at depth 1 and C13 above it, in the shape `docs/costs.md` asks for.
//!
//! **It is the first thing here to call `register_buffers`.** Registration had no caller anywhere
//! in the tree: the machinery was built, wired into `READ_FIXED`, and never once exercised
//! outside a unit test of the prepare path, so decision 3's first speed source had an untested
//! half. `--registered no` runs the same workload without it, and the pair is the A/B that says
//! what pinning the pages is worth. Both shapes read the same bytes and prove it.
//!
//! **O_DIRECT means alignment.** Every buffer address, every offset and every length is a
//! multiple of `block_bytes`, or the kernel refuses the read. The program aligns all three and
//! asserts it rather than discovering it as EINVAL.
//!
//! **macOS is a development platform** (decision 2). It has no O_DIRECT; `open_file` sets
//! F_NOCACHE instead, and the kqueue backend runs a file read inline on the loop thread. A number
//! from there says what a laptop does, and no file number from macOS is published as a claim.
//!
//! It prints the result line every candidate of every workload prints, which
//! `bench/harness/report.zig` owns. The workload's name carries the pattern, because a sequential
//! row and a random row are not the same measurement and must never share a `Series`. The
//! candidate's name carries whether buffers were registered, for the same reason.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const backend = @import("backend");
const harness = @import("harness");
const setup_module = @import("rotor_reads_setup.zig");
const pool_module = @import("reads_pool.zig");

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;
const percentile = harness.percentile;
const Transfer = setup_module.Transfer;
const Pattern = setup_module.Pattern;
const Options = setup_module.Options;
const Policy = setup_module.Policy;

const depth_max = setup_module.depth_max;
const operations = setup_module.operations;
const entries = setup_module.entries;
const events_max = setup_module.events_max;
const block_bytes_max = setup_module.block_bytes_max;
const buffer_alignment = setup_module.buffer_alignment;
const sync_bit = setup_module.sync_bit;
const index_mask = setup_module.index_mask;

/// Reads in flight at once, at most: one slot and one buffer each.
/// Latency samples kept, the first this many, as the other workloads keep them.
const samples_max = 1 << 17;

/// Reads a run may issue, so every loop here is bounded.
const reads_max = 1 << 26;

/// The loop's memory, sized for the larger of the two policies. Under `offload` the loop holds one
/// `Work` per slot, so a block sized for `blocking` would be too small and `init` would refuse it.
const loop_bytes = Loop.memory_bytes(.{
    .operations = operations,
    .entries = entries,
    .file_policy = if (backend.files_block) .offload else .blocking,
    .offload = if (backend.files_block) .{
        .context = null,
        .submit = pool_module.Pool.submit,
        .workers = pool_module.workers,
    } else null,
});

var loop_memory: [loop_bytes]u8 align(core.layout.memory_alignment) = undefined;

/// One buffer per read in flight, each aligned and sized for the largest block offered.
var buffer_memory: [setup_module.buffer_bytes_total]u8 align(buffer_alignment) = undefined;

/// The offload's rings. The caller owns this memory because the caller's threads write it. It is
/// one byte on a backend that offloads nothing, so the io_uring build carries none of it.
const ring_bytes = if (backend.files_block)
    backend.offload_module.memory_bytes(pool_module.workers)
else
    1;
var ring_memory: [ring_bytes]u8 align(core.layout.memory_alignment) = undefined;

var started_ns: [depth_max]u64 = undefined;
var latency_ns: [samples_max]u64 = undefined;

const Run = struct {
    loop: *Loop,
    options: Options,
    file: core.Descriptor,
    blocks: u64,
    deadline_ns: u64,
    random: core.random.Random,
    reads: u64 = 0,
    taken: u32 = 0,
    in_flight: u32 = 0,
    next_block: u64 = 0,
    stopping: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const options = try setup_module.parse(init);

    // The pool the `offload` policy uses. Started before the loop, so a thread is already waiting
    // when the first flush hands an operation out.
    var pool: pool_module.Pool = undefined;
    if (options.policy == .offload) try pool.start(init.io);

    var loop: Loop = undefined;
    // `blocking` is what this workload measured on kqueue before decision 18: the loop performs
    // the read itself and stalls for its duration. The default policy refuses, so a run that wants
    // the stall asks for it. On io_uring both policies behave the same: the kernel needs no thread.
    try loop.init(&loop_memory, .{
        .operations = operations,
        .entries = entries,
        .file_policy = switch (options.policy) {
            .blocking => .blocking,
            .offload => .offload,
        },
        .offload = if (options.policy == .offload) .{
            .context = &pool,
            .submit = pool_module.Pool.submit,
            .workers = pool_module.workers,
        } else null,
        .offload_memory = &ring_memory,
    });
    defer loop.deinit();
    // Runs after the loop's own defer, so the loop is drained first: only the worker can end an
    // operation it holds (decision 18).
    defer if (options.policy == .offload) pool.stop();

    const file = try setup_module.open_and_fill(.{
        .path = options.path,
        .transfer = options.transfer,
        .file_bytes = options.file_bytes,
    }, buffer_memory[0..options.block_bytes]);
    defer sync.close_now(file);

    if (options.registered) try register(&loop, options);

    var state: Run = .{
        .loop = &loop,
        .options = options,
        .file = file,
        .blocks = options.file_bytes / options.block_bytes,
        .deadline_ns = 0,
        // A seed the report names, so a run that finds something is replayable (decision 2).
        .random = core.random.Random.init(seed),
    };
    const span_ns = try run(&state);
    try report(init, &state, span_ns);
}

/// The seed every run draws its offsets from. Fixed, so two runs read the same blocks in the
/// same order and a comparison is of the loop and not of which blocks the device had cached.
const seed: u64 = 0x5eed_da7a;

/// The buffers the loop pins, one per read in flight. This is the call `register_buffers` never
/// had, and `READ_FIXED` is unreachable without it.
fn register(loop: *Loop, options: Options) !void {
    var slices: [depth_max][]u8 = undefined;
    var index: u32 = 0;
    while (index < options.depth) : (index += 1) {
        slices[index] = buffer_of(options, index);
    }
    try loop.register_buffers(slices[0..options.depth]);
}

fn buffer_of(options: Options, index: u32) []u8 {
    const start = @as(usize, index) * options.block_bytes;
    return buffer_memory[start..][0..options.block_bytes];
}

/// Opens the file with O_DIRECT, creating and preallocating it when it is not there. A file the
/// filesystem cannot carry O_DIRECT for is refused here and not discovered inside the first read.
fn run(state: *Run) !u64 {
    const started = now_ns();
    state.deadline_ns = started + state.options.seconds * core.constants.ns_per_s;
    var index: u32 = 0;
    while (index < state.options.depth) : (index += 1) issue(state, index);

    var events: [events_max]Event = undefined;
    var rounds: u64 = 0;
    while (state.in_flight != 0 and rounds < reads_max) : (rounds += 1) {
        const count = try state.loop.tick(&events, core.constants.ns_per_ms);
        for (events[0..count]) |event| complete(state, event);
    }
    const span = now_ns() - started;
    state.loop.cancel_all();
    try state.loop.drain(&events);
    return span;
}

/// What one transfer is: everything the operation needs, gathered so `operation_of` is a function
/// of its arguments and a test can read what it builds.
pub const Request = struct {
    transfer: Transfer,
    user_data: u64,
    file: core.Descriptor,
    buffer: []u8,
    registered: ?u16,
    offset: u64,
};

/// The operation one request becomes. A write submitted as a read would measure the wrong direction
/// under a row named for the right one, and nothing else in this program would notice, so this is a
/// function a test can check.
pub fn operation_of(request: Request) Operation {
    // A read takes a `Buffer` and a write a `ConstBuffer`, so each arm names its own.
    return switch (request.transfer) {
        .read => .{ .user_data = request.user_data, .kind = .{ .read = .{
            .file = request.file,
            .buffer = .{ .bytes = request.buffer, .registered = request.registered },
            .offset = request.offset,
        } } },
        .write => .{ .user_data = request.user_data, .kind = .{ .write = .{
            .file = request.file,
            .buffer = .{ .bytes = request.buffer, .registered = request.registered },
            .offset = request.offset,
        } } },
    };
}

/// The flush half of one durable write. It syncs the whole file, not one block: `fdatasync` has no
/// narrower form. So at depth 1 this is a clean durable-write measurement, and above it the flushes
/// of several slots overlap and the device coalesces them. libuv's program has the same property,
/// so the comparison is of two loops and not of two flush policies.
fn sync_one(state: *Run, index: u32) void {
    const taken = state.loop.submit(&.{.{
        .user_data = sync_bit | index,
        .kind = .{ .fdatasync = .{ .file = state.file } },
    }}, &.{});
    std.debug.assert(taken == 1);
    state.in_flight += 1;
}

/// One read, at the next offset the pattern names, into this slot's own buffer.
fn issue(state: *Run, index: u32) void {
    if (state.stopping) return;
    const block = next_block(state);
    const offset = block * state.options.block_bytes;
    // O_DIRECT refuses anything unaligned, and finding that out as EINVAL inside a run would
    // waste the run. All three are checked here instead.
    std.debug.assert(offset % state.options.block_bytes == 0);
    const buffer = buffer_of(state.options, index);
    std.debug.assert(@intFromPtr(buffer.ptr) % buffer_alignment == 0);
    std.debug.assert(buffer.len % state.options.block_bytes == 0);

    const registered: ?u16 = if (state.options.registered) @intCast(index) else null;
    started_ns[index] = now_ns();
    const taken = state.loop.submit(&.{operation_of(.{
        .transfer = state.options.transfer,
        .user_data = index,
        .file = state.file,
        .buffer = buffer,
        .registered = registered,
        .offset = offset,
    })}, &.{});
    // A refusal means the slot table is too small for the depth this run was given, and a
    // benchmark that swallowed it would report the stall as throughput.
    std.debug.assert(taken == 1);
    state.in_flight += 1;
}

/// The block the next read takes: the file in order, or one the seeded draw names.
fn next_block(state: *Run) u64 {
    switch (state.options.pattern) {
        .seq => {
            const block = state.next_block;
            state.next_block = (state.next_block + 1) % state.blocks;
            return block;
        },
        .random => return state.random.below(state.blocks),
    }
}

fn complete(state: *Run, event: Event) void {
    const syncing = (event.user_data & sync_bit) != 0;
    const index: u32 = @intCast(event.user_data & index_mask);
    const at_ns = now_ns();
    state.in_flight -= 1;
    const count = event.outcome() catch {
        state.stopping = true;
        return;
    };
    if (syncing) {
        // An `fdatasync` transfers nothing, so it answers 0.
        std.debug.assert(count == 0);
    } else {
        // A short transfer means the file is smaller than the run was told, which makes every later
        // offset wrong: it is a configuration fault and not a result.
        std.debug.assert(count == state.options.block_bytes);
        // A durable write is not over until its flush is. The slot's latency spans the pair, and the
        // operation is counted once, when the flush lands.
        if (state.options.sync) return sync_one(state, index);
    }
    state.reads += 1;
    record(state, at_ns - started_ns[index]);
    if (at_ns >= state.deadline_ns) {
        state.stopping = true;
        return;
    }
    issue(state, index);
}

fn record(state: *Run, elapsed_ns: u64) void {
    if (state.taken == samples_max) return;
    latency_ns[state.taken] = elapsed_ns;
    state.taken += 1;
}

/// The bytes one result line needs.
const output_buffer_bytes = 1024;

/// The workload's name for one pattern. Sequential and random are different measurements, so a
/// row of each carries a different name and `Series.init` refuses to mix them.
pub fn workload_of(transfer: Transfer, pattern: Pattern, synced: bool) []const u8 {
    return switch (transfer) {
        .read => switch (pattern) {
            .seq => "file-read-seq",
            .random => "file-read-random",
        },
        .write => if (synced) switch (pattern) {
            .seq => "file-durable-seq",
            .random => "file-durable-random",
        } else switch (pattern) {
            .seq => "file-write-seq",
            .random => "file-write-random",
        },
    };
}

/// The candidate's name for one buffer choice. Registration is decision 3's first speed source,
/// so the A and the B of it are two candidates and not two runs of one.
pub fn candidate_of(registered: bool, policy: Policy) []const u8 {
    // The direction is in the workload's name, not the candidate's: a read row and a write row are
    // different workloads, and the candidate is the same rotor either way.
    return switch (policy) {
        .blocking => if (registered) "rotor (registered)" else "rotor",
        .offload => if (registered) "rotor (registered, offload)" else "rotor (offload)",
    };
}

fn report(init: std.process.Init, state: *const Run, span_ns: u64) !void {
    const samples = latency_ns[0..state.taken];
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const duration_ns = @max(span_ns, 1);

    const result: harness.Result = .{
        .workload = workload_of(
            state.options.transfer,
            state.options.pattern,
            state.options.sync,
        ),
        .candidate = candidate_of(state.options.registered, state.options.policy),
        .candidate_version = "this tree",
        .configuration = .{
            // `connections` carries the queue depth and `payload_bytes` the block size, because
            // those are what this workload's rows vary.
            .cores = 0,
            .connections = state.options.depth,
            .payload_bytes = state.options.block_bytes,
            .load = .even,
        },
        .duration_ns = duration_ns,
        .operations = state.reads,
        .operations_per_second = harness.report.per_second(state.reads, duration_ns),
        .p50_ns = percentile.nearest_rank(samples, percentile.p50),
        .p99_ns = percentile.nearest_rank(samples, percentile.p99),
        .p999_ns = percentile.nearest_rank(samples, percentile.p999),
        .overflow = 0,
    };

    var buffer: [output_buffer_bytes]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try result.render_json_line(&out.interface);
    try out.interface.flush();
}

fn now_ns() u64 {
    var value: if (builtin.os.tag == .linux) std.os.linux.timespec else std.c.timespec = undefined;
    if (builtin.os.tag == .linux) {
        std.debug.assert(std.os.linux.clock_gettime(.MONOTONIC, &value) == 0);
    } else {
        std.debug.assert(std.c.clock_gettime(.MONOTONIC, &value) == 0);
    }
    const seconds: u64 = @intCast(value.sec);
    return seconds * core.constants.ns_per_s + @as(u64, @intCast(value.nsec));
}

test {
    _ = @import("rotor_reads_test.zig");
}
