//! The command line of `rotor_post`, split out of `rotor_post.zig` to keep that file under the
//! length limit: the modes a loop waits in, the options a run takes, how they are parsed and
//! checked, and the candidate name a run's row carries.
const std = @import("std");
const harness = @import("harness");

const placement = harness.placement;

/// Round trips measured, and the ones before them that are not.
const samples_default: u32 = 20_000;
const warmup_default: u32 = 2_000;

/// The most round trips a run may ask for. It bounds nothing that is allocated, because the
/// histogram is a fixed size whatever the count, but a run is a bounded loop (CLAUDE.md).
const samples_max: u32 = 1_000_000;

/// What a blocking tick is given. Long enough that a tick blocks rather than spins, short enough
/// that a peer that died ends the run instead of hanging it.
pub const wait_ns: u64 = std.time.ns_per_ms;

/// How long `spin-then-wait` polls before it blocks. Longer than a message takes when the peer is
/// awake, and far shorter than the sleep it is trying to avoid.
const spin_budget_ns: u64 = 50 * std.time.ns_per_us;

/// The most pings one burst may carry. Each holds a slot until its own completion, and a slot is
/// left for the answer.
pub const burst_max: u32 = 32;

/// The longest gap a run may put before a ping: a tenth of a second, far longer than any spin
/// budget, so the idle case is reachable without a run that takes hours.
const gap_us_max: u32 = 100_000;

/// How a loop waits for its peer's message.
pub const Mode = enum {
    /// Blocks until the message comes, so the number includes waking a sleeping receiver. The
    /// only mode an alternative can be compared against.
    waiting,
    /// Never blocks, so the number is the message alone. It costs a core that does nothing else.
    spinning,
    /// Polls for `spin_budget_ns`, then blocks. A peer that answers inside the budget is never
    /// slept on.
    spin_then_wait,
    /// Blocks as `waiting` does, on a loop whose own options give it `spin_budget_ns` as its spin
    /// budget: the spin decision 13 built into the loop, where `spin_then_wait` spins in this
    /// program. The two should measure alike.
    spin_budget,

    /// What a tick of this mode is given when it is not polling.
    pub fn wait(mode: Mode) u64 {
        return if (mode == .spinning) 0 else wait_ns;
    }

    /// How long a tick of this mode polls before it blocks, in this program.
    pub fn spin(mode: Mode) u64 {
        return if (mode == .spin_then_wait) spin_budget_ns else 0;
    }

    /// The spin budget a loop of this mode is given in its options.
    pub fn loop_budget(mode: Mode) u64 {
        return if (mode == .spin_budget) spin_budget_ns else 0;
    }

    /// The candidate name a row of this mode carries. Only `waiting` is rotor against another
    /// library; the other two are rotor against itself, and a table must not read as though a
    /// alternative had been offered the same choice.
    pub fn candidate(mode: Mode) []const u8 {
        return switch (mode) {
            .waiting => "rotor",
            .spinning => "rotor (spinning, not a comparison)",
            .spin_then_wait => "rotor (spin then wait, not a comparison)",
            .spin_budget => "rotor (spin budget, not a comparison)",
        };
    }
};

pub const Options = struct {
    mode: Mode = .waiting,
    samples: u32 = samples_default,
    warmup: u32 = warmup_default,
    /// The core the measuring loop takes, and the one its peer takes. Null places neither, which
    /// is what a host that cannot pin reports.
    cpu: ?usize = placement.first_cpu,
    peer_cpu: ?usize = placement.second_cpu,
    /// Pings per round trip, all in one submit. A round trip carries them and one pong.
    burst: u32 = 1,
    /// Microseconds the measuring side waits before each ping, so the peer is idle that long.
    gap_us: u32 = 0,

    pub fn messages_per_round_trip(options: Options) u32 {
        return options.burst + 1;
    }
};

/// The candidate name of a run with bursts: rotor against itself, as the two extra modes are.
const burst_candidate = "rotor (burst of posts, not a comparison)";

/// The candidate name of a run with a gap before each ping, which is rotor against itself too.
const gap_candidate = "rotor (idle gap, not a comparison)";

/// The name a run's row carries. Only a plain run in `waiting` is a comparison.
pub fn candidate_of(options: Options) []const u8 {
    if (options.burst != 1) return burst_candidate;
    if (options.gap_us != 0) return gap_candidate;
    return options.mode.candidate();
}

pub fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    try validate(options);
    return options;
}

/// Refuses a run that measures nothing or that asks for more than the slots hold.
fn validate(options: Options) !void {
    if (options.samples == 0 or options.samples > samples_max) return error.SampleCount;
    if (options.burst == 0 or options.burst > burst_max) return error.BurstSize;
    if (options.gap_us > gap_us_max) return error.GapTooLong;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--mode")) {
        options.mode = mode_of(value) orelse return error.UnknownMode;
    } else if (std.mem.eql(u8, name, "--samples")) {
        options.samples = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--warmup")) {
        options.warmup = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--cpu")) {
        options.cpu = try parse_cpu(value);
    } else if (std.mem.eql(u8, name, "--peer-cpu")) {
        options.peer_cpu = try parse_cpu(value);
    } else if (std.mem.eql(u8, name, "--burst")) {
        options.burst = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--gap-us")) {
        options.gap_us = try std.fmt.parseInt(u32, value, 10);
    } else {
        return error.UnknownArgument;
    }
}

/// A core, or `none` for a run that places nothing and reports that it did not.
fn parse_cpu(value: []const u8) !?usize {
    if (std.mem.eql(u8, value, "none")) return null;
    return try std.fmt.parseInt(usize, value, 10);
}

/// The mode named on the command line. `spin-then-wait` is spelled with dashes there and with
/// underscores in the enum, so the two are mapped here rather than by `stringToEnum`.
fn mode_of(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "waiting")) return .waiting;
    if (std.mem.eql(u8, value, "spinning")) return .spinning;
    if (std.mem.eql(u8, value, "spin-then-wait")) return .spin_then_wait;
    if (std.mem.eql(u8, value, "spin-budget")) return .spin_budget;
    return null;
}

const testing = std.testing;

test "every mode the command line names maps to one, and nothing else does" {
    try testing.expectEqual(Mode.waiting, mode_of("waiting").?);
    try testing.expectEqual(Mode.spinning, mode_of("spinning").?);
    try testing.expectEqual(Mode.spin_then_wait, mode_of("spin-then-wait").?);
    try testing.expectEqual(Mode.spin_budget, mode_of("spin-budget").?);
    try testing.expectEqual(@as(?Mode, null), mode_of("spin_then_wait"));
    try testing.expectEqual(@as(?Mode, null), mode_of(""));
    try testing.expectEqual(@as(?Mode, null), mode_of("waiting "));
}

test "only the waiting mode is named as a comparison" {
    try testing.expectEqualStrings("rotor", Mode.waiting.candidate());
    for ([_]Mode{ .spinning, .spin_then_wait, .spin_budget }) |mode| {
        try testing.expect(std.mem.indexOf(u8, mode.candidate(), "not a comparison") != null);
    }
}

test "waiting blocks, spinning never does, and spin-then-wait does both" {
    try testing.expect(Mode.waiting.wait() > 0);
    try testing.expectEqual(@as(u64, 0), Mode.waiting.spin());

    try testing.expectEqual(@as(u64, 0), Mode.spinning.wait());
    try testing.expectEqual(@as(u64, 0), Mode.spinning.spin());

    try testing.expect(Mode.spin_then_wait.wait() > 0);
    try testing.expect(Mode.spin_then_wait.spin() > 0);

    // The loop spins in this mode, so the program does not, and the loop is given the budget.
    try testing.expect(Mode.spin_budget.wait() > 0);
    try testing.expectEqual(@as(u64, 0), Mode.spin_budget.spin());
    try testing.expectEqual(Mode.spin_then_wait.spin(), Mode.spin_budget.loop_budget());
    for ([_]Mode{ .waiting, .spinning, .spin_then_wait }) |mode| {
        try testing.expectEqual(@as(u64, 0), mode.loop_budget());
    }
}

test "a core is a number or the word none, and nothing else" {
    try testing.expectEqual(@as(usize, 3), (try parse_cpu("3")).?);
    try testing.expectEqual(@as(?usize, null), try parse_cpu("none"));
    try testing.expectError(error.InvalidCharacter, parse_cpu("first"));
    // A negative core is refused as an overflow and not as a bad character: `usize` has no sign,
    // so the parser reads the digit and finds it does not fit.
    try testing.expectError(error.Overflow, parse_cpu("-1"));
}

test "a round trip is its pings and one pong, so a ping-pong is two messages" {
    // The count is what `measure` multiplies by and what `ping_pong` divides by. A change to one
    // without the other would make the throughput and the percentiles disagree.
    const ping_pong_options: Options = .{};
    try testing.expectEqual(@as(u32, 2), ping_pong_options.messages_per_round_trip());
    const burst_options: Options = .{ .burst = 16 };
    try testing.expectEqual(@as(u32, 17), burst_options.messages_per_round_trip());
}

test "a burst is at least one ping and at most what the slots hold" {
    var options: Options = .{};
    try apply(&options, "--burst", "16");
    try testing.expectEqual(@as(u32, 16), options.burst);
    try testing.expectError(error.InvalidCharacter, apply(&options, "--burst", "many"));
    try validate(options);
    try validate(.{ .burst = burst_max });
    try testing.expectError(error.BurstSize, validate(.{ .burst = 0 }));
    try testing.expectError(error.BurstSize, validate(.{ .burst = burst_max + 1 }));
}

test "a gap is none by default and at most a tenth of a second" {
    var options: Options = .{};
    try testing.expectEqual(@as(u32, 0), options.gap_us);
    try apply(&options, "--gap-us", "1000");
    try testing.expectEqual(@as(u32, 1000), options.gap_us);
    try validate(options);
    try validate(.{ .gap_us = gap_us_max });
    try testing.expectError(error.GapTooLong, validate(.{ .gap_us = gap_us_max + 1 }));
    try testing.expectError(error.InvalidCharacter, apply(&options, "--gap-us", "long"));
}

test "a run with a gap is not named as a comparison, whatever its mode" {
    try testing.expectEqualStrings("rotor", candidate_of(.{}));
    for ([_]Mode{ .waiting, .spinning, .spin_then_wait }) |mode| {
        const name = candidate_of(.{ .mode = mode, .gap_us = 100 });
        try testing.expect(std.mem.indexOf(u8, name, "not a comparison") != null);
    }
}
