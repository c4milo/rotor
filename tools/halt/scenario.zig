//! What every halt-scenario executable shares. A scenario violates one assertion on purpose, and
//! `tools/halt_check.zig` runs it in a child process and requires that process to die by a
//! signal: the only way to test that an assertion halts, because a Zig test cannot expect a panic
//! in its own process (decision 8).
//!
//! Run:  <scenarios> --list          prints every scenario's name, one per line
//!       <scenarios> NAME            sets the scenario up, prints `marker`, then violates
//!
//! A scenario calls `reached_violation` right before the statement that must halt. The check
//! requires the marker on stdout, so a scenario that dies during its own set-up does not pass as
//! a halt.
const std = @import("std");
const Io = std.Io;

/// Printed right before the violating statement runs.
pub const marker = "violating";

pub const Scenario = struct {
    name: []const u8,
    run: *const fn () void,
};

/// The exit status of a scenario that ran to its end: the assertion did not halt.
pub const exit_did_not_halt = 0;
/// The exit status for a name no scenario has, or for no argument at all.
pub const exit_usage = 2;

const output_bytes = 256;

var stdout_buffer: [output_bytes]u8 = undefined;
var stdout_writer: ?Io.File.Writer align(@alignOf(Io.File.Writer)) = null;

/// Prints the marker and flushes it, so it is on the pipe before the process dies.
pub fn reached_violation() void {
    const writer = &stdout_writer.?.interface;
    writer.print("{s}\n", .{marker}) catch {};
    writer.flush() catch {};
}

pub fn main(init: std.process.Init, comptime scenarios: []const Scenario) !void {
    stdout_writer = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &stdout_writer.?.interface;
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const wanted = arguments.next() orelse std.process.exit(exit_usage);
    if (std.mem.eql(u8, wanted, "--list")) {
        inline for (scenarios) |scenario| try writer.print("{s}\n", .{scenario.name});
        return writer.flush();
    }
    inline for (scenarios) |scenario| {
        if (std.mem.eql(u8, wanted, scenario.name)) {
            scenario.run();
            std.process.exit(exit_did_not_halt);
        }
    }
    std.process.exit(exit_usage);
}
