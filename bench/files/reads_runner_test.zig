//! The tests of `reads_runner.zig`. They live beside it because the runner is at the 500-line limit
//! CLAUDE.md sets, and that limit counts a file plus its tests. The runner's own `test` block
//! imports this file, so `zig build test-bench-programs` runs them.
const std = @import("std");
const runner = @import("reads_runner.zig");

const Candidate = runner.Candidate;
const Configuration = runner.Configuration;
const Numbers = runner.Numbers;
const Options = runner.Options;
const argv_max = runner.argv_max;
const candidates = runner.candidates;
const patterns = runner.patterns;
const transfers = runner.transfers;
const testing = std.testing;

test "a block size O_DIRECT cannot use is refused" {
    try testing.expectError(error.BlockTooSmall, runner.check_block_bytes(0));
    try testing.expectError(error.BlockTooSmall, runner.check_block_bytes(511));
    try testing.expectError(error.BlockNotPowerOfTwo, runner.check_block_bytes(4095));
    try testing.expectError(error.BlockNotPowerOfTwo, runner.check_block_bytes(6144));

    try runner.check_block_bytes(512);
    try runner.check_block_bytes(4096);
    try runner.check_block_bytes(65536);
}

test "the two rotor candidates differ only in registration, and both name it" {
    // The A and the B of decision 3's first speed source have to be two candidates and not two
    // runs of one, or a `Series` would average them into a number that describes neither.
    const registered = candidates[0];
    const plain = candidates[1];
    try testing.expectEqualStrings(registered.program, plain.program);
    try testing.expect(!std.mem.eql(u8, registered.name, plain.name));
    try testing.expectEqualStrings("yes", registered.arguments[1]);
    try testing.expectEqualStrings("no", plain.arguments[1]);
}

test "every candidate has a distinct name, and its arguments come in pairs" {
    for (candidates, 0..) |candidate, index| {
        try testing.expect(candidate.name.len >= 1);
        try testing.expect(candidate.program.len >= 1);
        try testing.expectEqual(@as(usize, 0), candidate.arguments.len % 2);
        for (candidates[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, candidate.name, other.name));
        }
    }
}

test "one run's arguments fit the buffer, with the longest candidate's own" {
    var longest: usize = 0;
    for (candidates) |candidate| longest = @max(longest, candidate.arguments.len);
    // 14 fixed: the program, the path, and six name-value pairs.
    try testing.expect(14 + longest <= argv_max);
}

test "the sweep covers both directions, both patterns and both flush policies" {
    // A sweep that dropped a dimension would quietly publish part of a table.
    try testing.expectEqual(@as(usize, 2), transfers.len);
    try testing.expectEqualStrings("read", transfers[0]);
    try testing.expectEqualStrings("write", transfers[1]);
    try testing.expectEqual(@as(usize, 2), patterns.len);
    try testing.expectEqual(@as(usize, 2), runner.syncs.len);
    // `no` first, so a read's one value is the unsynced one: a read cannot be flushed.
    try testing.expectEqualStrings("no", runner.syncs[0]);
    try testing.expectEqualStrings("yes", runner.syncs[1]);
}

test "a read is swept unsynced only, and a write both ways" {
    // A read program refuses `--sync yes`, so pairing it with a read would put a failure line in the
    // table where a row belongs.
    const for_read = runner.syncs_for("read");
    try testing.expectEqual(@as(usize, 1), for_read.len);
    try testing.expectEqualStrings("no", for_read[0]);

    const for_write = runner.syncs_for("write");
    try testing.expectEqual(@as(usize, 2), for_write.len);
    try testing.expectEqualStrings("no", for_write[0]);
    try testing.expectEqualStrings("yes", for_write[1]);
}

test "the default block sweep holds the size costs.md names, and one command four times it" {
    const options: Options = .{ .path = "/tmp/scratch" };
    try testing.expectEqual(@as(usize, 2), options.blocks.len);
    try testing.expectEqual(@as(u32, 4096), options.blocks[0]);
    try testing.expectEqual(@as(u32, 16384), options.blocks[1]);
    // Both are sizes O_DIRECT accepts, which `check_block_bytes` is what enforces.
    for (options.blocks) |block_bytes| try runner.check_block_bytes(block_bytes);
}

test "only libuv's io_uring candidate is Linux-only, and only rotor's offload is macOS-only" {
    for (candidates) |candidate| {
        const is_uring = std.mem.eql(u8, candidate.name, "libuv-uring");
        try testing.expectEqual(is_uring, candidate.linux_only);
        const is_offload = std.mem.eql(u8, candidate.name, "rotor-offload");
        try testing.expectEqual(is_offload, candidate.kqueue_only);
        // No candidate is both: no host could run it.
        try testing.expect(!(candidate.linux_only and candidate.kqueue_only));
    }
}

test "the offload candidate registers its buffers, so the row differs only in the policy" {
    // The two candidates must differ in one setting, or the row measures two changes at once.
    // Both register their buffers; only the policy differs.
    const registered = candidates[0];
    const offload = candidates[2];
    try testing.expectEqualStrings("rotor-registered", registered.name);
    try testing.expectEqualStrings("rotor-offload", offload.name);
    try testing.expectEqualStrings(registered.program, offload.program);
    try testing.expectEqualStrings("yes", offload.arguments[1]);
    try testing.expectEqualStrings("--file-policy", offload.arguments[2]);
    try testing.expectEqualStrings("offload", offload.arguments[3]);
}

test "a run is asked for the configuration its row will name" {
    // Every option the sweep varies has to reach the program. One that stopped being passed would
    // leave the candidate on its default, and the row would carry a name for a run nobody made.
    var argv: [argv_max][]const u8 = undefined;
    var numbers: Numbers = undefined;
    const options: Options = .{ .path = "/tmp/scratch", .seconds = 3 };
    const configuration: Configuration = .{
        .transfer = "write",
        .pattern = "random",
        .depth = 32,
        .block_bytes = 16384,
        .sync = "yes",
    };

    const used = try runner.fill_argv(
        &argv,
        &numbers,
        "zig-out/bin/rotor_reads",
        options,
        configuration,
        candidates[0],
    );
    const passed = argv[0..used];

    try testing.expectEqualStrings("zig-out/bin/rotor_reads", passed[0]);
    try testing.expectEqualStrings("/tmp/scratch", passed[1]);
    try expect_pair(passed, "--transfer", "write");
    try expect_pair(passed, "--pattern", "random");
    try expect_pair(passed, "--depth", "32");
    // The block size and the sync come from the configuration, not the options: both are swept.
    try expect_pair(passed, "--block-bytes", "16384");
    try expect_pair(passed, "--sync", "yes");
    try expect_pair(passed, "--seconds", "3");
    // The candidate's own arguments come last and are not lost to the fixed ones.
    try expect_pair(passed, "--registered", "yes");
}

/// Fails unless `argv` holds `name` followed by `value`.
fn expect_pair(argv: []const []const u8, name: []const u8, value: []const u8) !void {
    for (argv, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry, name)) continue;
        if (index + 1 >= argv.len) return error.ValueMissing;
        return testing.expectEqualStrings(value, argv[index + 1]);
    }
    return error.ArgumentMissing;
}

test "an argument list too long for the buffer is an error, not a silent cut" {
    var argv: [argv_max][]const u8 = undefined;
    var numbers: Numbers = undefined;
    const options: Options = .{ .path = "/tmp/scratch" };
    const configuration: Configuration = .{
        .transfer = "read",
        .pattern = "seq",
        .depth = 1,
        .block_bytes = 4096,
        .sync = "no",
    };
    // More candidate arguments than the buffer has room for after the fixed ones.
    var many: [argv_max][]const u8 = @splat("--x");
    const greedy: Candidate = .{ .name = "greedy", .program = "p", .arguments = &many };
    try testing.expectError(
        error.TooManyArguments,
        runner.fill_argv(&argv, &numbers, "p", options, configuration, greedy),
    );
}
