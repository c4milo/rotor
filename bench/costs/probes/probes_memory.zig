//! Rows C1, C2 and C3: one load from L1, from L2, and from main memory.
//!
//! The three rows are one loop over three working sets. The loop follows a chain of nodes:
//! `current = current.next`. Every load's address is the value the load before it returned, so
//! the loads cannot overlap and the time per load is the latency of one load. The chain is one
//! random cycle through every node (Sattolo's shuffle), so no stride or stream prefetcher can
//! predict the next address, and every node is visited once before any node is visited again.
//!
//! A node is 128 bytes, one cache line on Apple silicon, so every load touches a line no other
//! node shares. The working set then decides which level answers. The cache sizes are the ones
//! `sysctl` reports on the `mac` machine of docs/costs.md:
//!   - C1, 32 KiB: inside the 64 KiB L1d of an efficiency core and the 128 KiB of a performance
//!     core, so every load hits L1.
//!   - C2, 2 MiB: 16 times a performance core's L1d and inside the smaller L2, the 4 MiB of the
//!     efficiency cores, so every load misses L1 and hits L2.
//!   - C3, 512 MiB: more than 40 times the larger L2, the 12 MiB that four performance cores
//!     share, and `sysctl` reports no L3. A line is reused after 4,194,303 other lines, so every
//!     load goes to memory.
//!
//! What C3 cannot separate: 512 MiB is 32,768 pages of 16 KiB, far more than a TLB holds, so
//! every load also pays a page-table walk. macOS gives a process no larger page on Apple silicon,
//! so this probe cannot measure the cache miss without the TLB miss, and the row says so.
//!
//! The `next` field is a plain pointer, the cheapest address the hardware can form. An index
//! scaled by 8 into the same array measured one cycle more per load on an M1 Pro: that is the
//! addressing mode, not the cache.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const measure = @import("../measure.zig");
const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;

/// The bytes of one node: the 128-byte cache line of Apple silicon, and two lines where a line is
/// 64 bytes, of which the chase touches the first.
const node_bytes = 128;

/// C1's working set: half of the smaller L1d of the `mac` machine.
const l1_working_set_bytes = 32 * kib;

/// C2's working set: half of the smaller L2 of the `mac` machine.
const l2_working_set_bytes = 2 * mib;

/// C3's working set: the whole arena, 512 MiB.
const memory_working_set_bytes = measure.arena_bytes;

const kib = 1024;
const mib = 1024 * kib;

/// The seed of the shuffle, so every run chases the same cycle.
const cycle_seed = 0x9e37_79b9_7f4a_7c15;

/// The batches are sized to last some tens of microseconds each: long against the 42 ns step of
/// the clock, short against the interval between interrupts.
const l1_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 32768 };
const l2_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 8192 };
const memory_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 512 };

const Node = extern struct {
    /// The node the chase loads next.
    next: *const Node,
    /// The index of `next`. The shuffle permutes indices; the pointers are written from them.
    successor: u64,
    padding: [node_bytes - @sizeOf(*const Node) - @sizeOf(u64)]u8,
};

comptime {
    assert(@sizeOf(Node) == node_bytes);
    assert(std.heap.page_size_min % node_bytes == 0);
}

pub const probes = [_]measure.Probe{
    .{ .row = 1, .operation = "L1 cache reference", .run = run_l1 },
    .{ .row = 2, .operation = "L2 cache reference", .run = run_l2 },
    .{
        .row = 3,
        .operation = "main memory reference, a last-level cache miss",
        .run = run_memory,
    },
};

/// What this OS does about large pages, for C3's note.
const large_page_text = switch (builtin.os.tag) {
    .macos => "macOS gives a process no larger page on Apple silicon",
    .linux => "transparent huge pages were not requested and may still apply, read" ++
        " /sys/kernel/mm/transparent_hugepage/enabled",
    else => "no larger page was requested",
};

fn run_l1(environment: *Environment) Error!Result {
    const summary = try run_chase(environment, l1_working_set_bytes, l1_plan);
    const note = environment.note(
        "{d} nodes of {d} bytes in one random cycle, {d} KiB in all; each load's address is" ++
            " the value the load before it returned, so the number is one load's latency",
        .{ l1_working_set_bytes / node_bytes, node_bytes, l1_working_set_bytes / kib },
    );
    return .{ .summary = summary, .plan = l1_plan, .unit = "loads", .note = note };
}

fn run_l2(environment: *Environment) Error!Result {
    const summary = try run_chase(environment, l2_working_set_bytes, l2_plan);
    const note = environment.note(
        "{d} nodes of {d} bytes in one random cycle, {d} KiB in all, on {d} pages: a load" ++
            " misses L1 and hits L2",
        .{
            l2_working_set_bytes / node_bytes,
            node_bytes,
            l2_working_set_bytes / kib,
            l2_working_set_bytes / std.heap.pageSize(),
        },
    );
    return .{ .summary = summary, .plan = l2_plan, .unit = "loads", .note = note };
}

fn run_memory(environment: *Environment) Error!Result {
    const summary = try run_chase(environment, memory_working_set_bytes, memory_plan);
    const page_bytes = std.heap.pageSize();
    const note = environment.note(
        "the number includes a TLB miss on nearly every load: the working set is {d} pages of" ++
            " {d} KiB, and {s}; {d} nodes of {d} bytes in one random cycle, {d} MiB in all",
        .{
            memory_working_set_bytes / page_bytes,
            page_bytes / kib,
            large_page_text,
            memory_working_set_bytes / node_bytes,
            node_bytes,
            memory_working_set_bytes / mib,
        },
    );
    return .{ .summary = summary, .plan = memory_plan, .unit = "loads", .note = note };
}

/// The timed loop: `loads` dependent loads, and nothing else that touches memory.
///
/// It is never inlined, and takes and returns the node in a register, for a measured reason.
/// Inlined into the sampling loop, the compiler folded the read of `Chase.current` into the loop,
/// so that one load instruction read a just-stored stack slot once per batch and nodes the rest
/// of the time. On an M1 Pro that loop ran for milliseconds at 3 cycles per load and then for
/// milliseconds at 4, and the median landed on either. This shape ran at a steady 3. The cause
/// was not measured; a core that has seen a load depend on a recent store may make that load
/// wait for the stores before it, which would cost the fourth cycle.
noinline fn follow(start: *const Node, loads: u32) *const Node {
    var current = start;
    var remaining = loads;
    while (remaining != 0) : (remaining -= 1) current = current.next;
    return current;
}

const Chase = struct {
    current: *const Node,

    pub fn run_batch(chase: *Chase, loads: u32) Error!void {
        chase.current = follow(chase.current, loads);
    }
};

fn run_chase(
    environment: *Environment,
    working_set_bytes: usize,
    plan: Plan,
) Error!measure.Summary {
    assert(working_set_bytes <= environment.arena.len);
    assert(working_set_bytes % node_bytes == 0);
    const base: [*]Node = @ptrCast(environment.arena.ptr);
    const nodes = base[0 .. working_set_bytes / node_bytes];
    build_cycle(nodes);
    assert(cycle_length(nodes) == nodes.len);

    var chase: Chase = .{ .current = &nodes[0] };
    const summary = try measure.sample(Chase, &chase, plan, environment.values[0]);

    // The chase must stand where a walk over the indices, which the timed loop never reads, says
    // it stands: that is the proof that every load of every batch ran.
    const loads = @as(u64, plan.warmup + plan.samples) * plan.batch;
    const reached = (@intFromPtr(chase.current) - @intFromPtr(nodes.ptr)) / node_bytes;
    assert(reached == index_after(nodes, loads));
    return summary;
}

/// Links `nodes` into one cycle through all of them, in an order drawn from `cycle_seed`.
/// Sattolo's shuffle: swapping each element with one strictly before it yields a permutation
/// with exactly one cycle, and every such permutation is equally likely.
fn build_cycle(nodes: []Node) void {
    assert(nodes.len >= 2);
    for (nodes, 0..) |*node, index| node.successor = index;
    var generator = std.Random.DefaultPrng.init(cycle_seed);
    const random = generator.random();
    var index = nodes.len - 1;
    while (index >= 1) : (index -= 1) {
        const other = random.uintLessThan(usize, index);
        std.mem.swap(u64, &nodes[index].successor, &nodes[other].successor);
    }
    for (nodes) |*node| node.next = &nodes[node.successor];
}

/// The steps from node 0 back to node 0, which is `nodes.len` when the links are one cycle. A
/// shorter cycle would shrink the working set without a word, so the probe asserts on it.
fn cycle_length(nodes: []const Node) usize {
    var current = &nodes[0];
    var steps: usize = 0;
    while (steps < nodes.len) {
        current = current.next;
        steps += 1;
        if (current == &nodes[0]) break;
    }
    return steps;
}

/// The index `loads` steps after node 0, read from the indices and not from the pointers.
fn index_after(nodes: []const Node, loads: u64) u64 {
    var index: u64 = 0;
    var remaining = loads % nodes.len;
    while (remaining != 0) : (remaining -= 1) index = nodes[index].successor;
    return index;
}

// Tests. `zig build test` compiles the probes and does not run these; run them with
// `zig test bench/costs/probes/probes_memory.zig`.

const testing = std.testing;

test "build_cycle links every node into one cycle" {
    var nodes: [257]Node = undefined;
    build_cycle(&nodes);
    try testing.expectEqual(nodes.len, cycle_length(&nodes));
    for (&nodes) |*node| try testing.expect(node.next != node);
}

test "cycle_length reports a cycle that skips nodes" {
    var nodes: [8]Node = undefined;
    build_cycle(&nodes);
    // Point node 0 at itself: the cycle through node 0 now has one node.
    nodes[0].next = &nodes[0];
    try testing.expectEqual(@as(usize, 1), cycle_length(&nodes));
}

test "a chase lands where the indices say" {
    var nodes: [64]Node = undefined;
    build_cycle(&nodes);
    var chase: Chase = .{ .current = &nodes[0] };
    try chase.run_batch(1000);
    const reached = (@intFromPtr(chase.current) - @intFromPtr(&nodes)) / node_bytes;
    try testing.expectEqual(index_after(&nodes, 1000), reached);
}
