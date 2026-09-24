//! The check that `bench-echo-no-class-a` builds `rotor_echo` from a graph with decision 8's class A
//! compiled out. `build/bench.zig` builds this file's test against that same graph, and
//! `zig build test` runs it, so a change that turned class A back on there fails the gate instead
//! of making the echo half of the experiment measure nothing.
const std = @import("std");
const core = @import("core");

test "the graph bench-echo-no-class-a builds from compiles class A out" {
    try std.testing.expect(!core.assertion_class.enabled);
}
