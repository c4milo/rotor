//! two_adapters_check: starts `examples/two_adapters.zig` and checks the line that it prints for
//! each adapter. `zig build test` runs it on the host, and the Linux gate runs it on io_uring and on
//! epoll.
//!
//! Run:  two_adapters_check PROGRAM
//!
//! The program runs one library on a plain loop, then on a reactor, and prints one line for each
//! run. The check requires:
//!
//!   1. that the program exits 0 within `run_timeout_seconds`;
//!   2. a line for the plain run, then a line for the reactor run, and no other line;
//!   3. on each line, each message sent and received, and each beat of the program;
//!   4. the same backend on both lines;
//!   5. each deadline met less than `late_us_max` after it came due;
//!   6. each run shorter than `run_us_max` on the loop's clock.
//!
//! The program's first beat comes about 400 ms after the start, long after the library's last
//! message, and a tick of the program waits 10 s at most. So a library deadline that bounds no wait
//! is met about 400 ms late, and a beat that bounds no wait up to 10 s late. A tick that waits for
//! nothing makes its run 10 s longer. On 2026-11-11 check 6 found a poller that ran the last beat
//! and then let its tick wait 10 s.
//!
//! It is written on `std` and not on rotor, so a fault in rotor cannot hide in the checker. It
//! holds its own copy of the numbers that the program must reach.
const std = @import("std");

/// The messages that the library sends and receives on each run, and the beats of the program.
const messages = 4;
const beats = 8;
/// The latest that a deadline may be met: far under the 400 ms gap before the first beat. On
/// 2026-11-11, on a Mac at a load average of 35 to 43, the latest deadline of about 20 runs was
/// 26 ms late.
const late_us_max = 150_000;
/// The longest that one run may take. The last beat comes 421 ms after the start.
const run_us_max = 1_000_000;
/// How long the program may run. Its two runs take about 0.85 s on a Mac.
const run_timeout_seconds = 60;

/// What one line of the program says about one run.
const Run = struct {
    adapter: []const u8,
    backend: []const u8 = "",
    sent: ?u64 = null,
    received: ?u64 = null,
    beats: ?u64 = null,
    late_us: ?u64 = null,
    run_us: ?u64 = null,

    /// Stores the value of `key`. A key that the program does not print is an error.
    fn set(run: *Run, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "backend")) {
            run.backend = value;
            return;
        }
        const number = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, key, "sent")) {
            run.sent = number;
        } else if (std.mem.eql(u8, key, "received")) {
            run.received = number;
        } else if (std.mem.eql(u8, key, "beats")) {
            run.beats = number;
        } else if (std.mem.eql(u8, key, "late_us")) {
            run.late_us = number;
        } else if (std.mem.eql(u8, key, "run_us")) {
            run.run_us = number;
        } else return error.UnknownKey;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len != 2) return error.Usage;
    const result = try std.process.run(arena, init.io, .{
        .argv = arguments[1..],
        .timeout = .{ .duration = .{ .raw = .fromSeconds(run_timeout_seconds), .clock = .awake } },
    });
    const output = result.stdout;
    errdefer std.debug.print("two_adapters_check: the program printed:\n{s}{s}", .{ output, result.stderr });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ProgramFailed,
        else => return error.ProgramCrashed,
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\n"), '\n');
    const plain = try parse(lines.next() orelse return error.NoPlainLine);
    const reactor = try parse(lines.next() orelse return error.NoReactorLine);
    if (lines.next() != null) return error.ExtraLine;
    try expect(plain, "plain");
    try expect(reactor, "reactor");
    if (!std.mem.eql(u8, plain.backend, reactor.backend)) return error.BackendsDiffer;
    std.debug.print("two_adapters_check: {s} passed on {s}: {d} messages and {d} beats on each adapter, " ++
        "runs of {d} us and {d} us, the latest deadline met {d} us late\n", .{
        arguments[1],   plain.backend,    messages,                                 beats,
        plain.run_us.?, reactor.run_us.?, @max(plain.late_us.?, reactor.late_us.?),
    });
}

/// One line: `two_adapters`, the adapter's name, then `key=value` pairs.
fn parse(line: []const u8) !Run {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const program = words.next() orelse return error.EmptyLine;
    if (!std.mem.eql(u8, program, "two_adapters")) return error.NotAReport;
    var run: Run = .{ .adapter = words.next() orelse return error.NoAdapter };
    while (words.next()) |word| {
        const equals = std.mem.indexOfScalar(u8, word, '=') orelse return error.NoValue;
        try run.set(word[0..equals], word[equals + 1 ..]);
    }
    return run;
}

/// Fails unless `run` is the line of `adapter`, and reached what the program must reach.
fn expect(run: Run, adapter: []const u8) !void {
    if (!std.mem.eql(u8, run.adapter, adapter)) return error.WrongAdapter;
    if (run.backend.len == 0) return error.NoBackend;
    if (run.sent != messages or run.received != messages) return error.MessagesMissing;
    if (run.beats != beats) return error.BeatsMissing;
    const late_us = run.late_us orelse return error.NoLateness;
    if (late_us >= late_us_max) return error.DeadlineLate;
    const run_us = run.run_us orelse return error.NoRunLength;
    if (run_us >= run_us_max) return error.RunTooLong;
}
