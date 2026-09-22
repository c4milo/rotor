//! rotor_reads: O_DIRECT reads, sequential and random, which is the file half of milestone 4's
//! workload list and the only program in this tree that registers a buffer.
//!
//! Run:  rotor_reads PATH [--pattern seq|random] [--depth N] [--block-bytes B]
//!                        [--registered yes|no] [--seconds S] [--file-bytes N]
//!                        [--file-policy blocking|offload]
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
const pool_module = @import("reads_pool.zig");

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

/// Reads in flight at once, at most: one slot and one buffer each.
const depth_max = 128;

const operations = depth_max + 64;
const entries = 256;
const events_max = 256;

/// The block a read moves, at most. Every offset and length is a multiple of the block asked for,
/// and O_DIRECT refuses anything else.
const block_bytes_max = 1 << 20;

/// The alignment every O_DIRECT buffer needs. A page is at least the logical block of every
/// device rotor runs on, and aligning to it costs nothing here.
const buffer_alignment = 4096;

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
var buffer_memory: [depth_max * block_bytes_max]u8 align(buffer_alignment) = undefined;

/// The offload's rings. The caller owns this memory because the caller's threads write it. It is
/// one byte on a backend that offloads nothing, so the io_uring build carries none of it.
const ring_bytes = if (backend.files_block)
    backend.offload_module.memory_bytes(pool_module.workers)
else
    1;
var ring_memory: [ring_bytes]u8 align(core.layout.memory_alignment) = undefined;

var started_ns: [depth_max]u64 = undefined;
var latency_ns: [samples_max]u64 = undefined;

const Pattern = enum { seq, random };

const Options = struct {
    path: [:0]const u8,
    pattern: Pattern = .seq,
    depth: u32 = 16,
    block_bytes: u32 = 4096,
    registered: bool = true,
    seconds: u64 = 3,
    file_bytes: u64 = 256 << 20,
    /// What the loop does with a read it cannot perform without blocking (decision 18). On
    /// io_uring it changes nothing; on kqueue it is the difference this workload's newest row
    /// measures. `refuse` is not offered: a run that refused every read would measure nothing.
    policy: Policy = .blocking,
};

/// The policies this workload runs, which are decision 18's two that perform the read.
const Policy = enum { blocking, offload };

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
    const options = try parse(init);

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

    const file = try open_and_fill(options);
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
fn open_and_fill(options: Options) !core.Descriptor {
    const direct: sync.OpenOptions = .{ .create = false, .direct = true };
    if (sync.open_file(options.path, direct)) |file| {
        const have = try sync.file_size(file);
        if (have >= options.file_bytes) return file;
        try sync.set_file_size(file, options.file_bytes);
        return file;
    } else |failure| switch (failure) {
        error.FileNotFound => {},
        else => return failure,
    }
    const created = try sync.open_file(options.path, .{ .create = true, .direct = true });
    errdefer sync.close_now(created);
    try sync.set_file_size(created, options.file_bytes);
    return created;
}

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

    started_ns[index] = now_ns();
    const taken = state.loop.submit(&.{.{
        .user_data = index,
        .kind = .{ .read = .{
            .file = state.file,
            .buffer = .{
                .bytes = buffer,
                .registered = if (state.options.registered) @intCast(index) else null,
            },
            .offset = offset,
        } },
    }}, &.{});
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
    const index: u32 = @intCast(event.user_data);
    const at_ns = now_ns();
    state.in_flight -= 1;
    const count = event.outcome() catch {
        state.stopping = true;
        return;
    };
    // A short read means the file is smaller than the run was told, which makes every later
    // offset wrong: it is a configuration fault and not a result.
    std.debug.assert(count == state.options.block_bytes);
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
fn workload_of(pattern: Pattern) []const u8 {
    return switch (pattern) {
        .seq => "file-read-seq",
        .random => "file-read-random",
    };
}

/// The candidate's name for one buffer choice. Registration is decision 3's first speed source,
/// so the A and the B of it are two candidates and not two runs of one.
fn candidate_of(registered: bool, policy: Policy) []const u8 {
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
        .workload = workload_of(state.options.pattern),
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
        .p50_ns = percentile(samples, 500),
        .p99_ns = percentile(samples, 990),
        .p999_ns = percentile(samples, 999),
        .overflow = 0,
    };

    var buffer: [output_buffer_bytes]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try result.render_json_line(&out.interface);
    try out.interface.flush();
}

const per_mille = 1000;

fn percentile(samples: []const u64, parts_per_thousand: u64) u64 {
    if (samples.len == 0) return 0;
    const rank = (samples.len * parts_per_thousand + per_mille - 1) / per_mille;
    const index = @min(@max(rank, 1) - 1, samples.len - 1);
    return samples[index];
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

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPath;
    var options: Options = .{ .path = arguments[1] };
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    try check(options);
    return options;
}

fn check(options: Options) !void {
    // A depth above the pool's queue would make `Pool.submit` block the loop thread, which is the
    // stall the offload removes. Refused here rather than found part way through a run.
    if (options.policy == .offload and options.depth > pool_module.queue_max) {
        return error.DepthAboveOffloadQueue;
    }
    if (options.depth == 0 or options.depth > depth_max) return error.DepthOutOfRange;
    if (options.block_bytes < buffer_alignment) return error.BlockTooSmall;
    if (options.block_bytes > block_bytes_max) return error.BlockTooLarge;
    if (options.block_bytes % buffer_alignment != 0) return error.BlockNotAligned;
    if (options.depth * options.block_bytes > buffer_memory.len) return error.BuffersTooLarge;
    if (options.file_bytes < options.depth * options.block_bytes) return error.FileTooSmall;
    if (options.seconds == 0) return error.EmptyConfiguration;
    // `register_buffers` takes at most this many, and one per read in flight is what it is given.
    if (options.registered and options.depth > core.constants.registered_buffers_max) {
        return error.TooManyRegistered;
    }
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--pattern")) {
        options.pattern = std.meta.stringToEnum(Pattern, value) orelse return error.UnknownPattern;
    } else if (std.mem.eql(u8, name, "--depth")) {
        options.depth = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--block-bytes")) {
        options.block_bytes = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--registered")) {
        options.registered = try yes_or_no(value);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--file-bytes")) {
        options.file_bytes = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--file-policy")) {
        options.policy = std.meta.stringToEnum(Policy, value) orelse return error.UnknownPolicy;
    } else {
        return error.UnknownArgument;
    }
}

fn yes_or_no(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "no")) return false;
    return error.NotYesOrNo;
}
