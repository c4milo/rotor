//! Halt scenarios for the `uring` module that need a Linux kernel. `zig build test-linux` builds
//! this file and `tools/halt_check.zig` for Linux, and `tools/linux_test.sh` runs the check on it
//! in Docker with `seccomp=unconfined`. `zig build halt-check` does not run it.
//!
//! A scenario proves an assertion only if the scenario returns once that assertion is deleted. Each
//! scenario here runs on a loop with a real ring (`Loop.init`), and each assertion under test comes
//! right before an io_uring call. With the assertion deleted, the loop makes the call, the kernel
//! refuses it, the loop returns the error, and the scenario returns. On a Mac the same call runs
//! some other system call (`uring_scenarios.zig`), and that is why these scenarios are here.
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const scenario = @import("scenario.zig");

const Loop = uring.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4 };

var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop = undefined;

/// The wait the tick from another thread asks for. It is above 0 so that `tick` enters the kernel:
/// a loop with nothing to submit that asks for no wait makes no system call.
const tick_wait_ns = core.constants.ns_per_ms;

/// A loop belongs to the thread that initialised it (decision 4), and its ring is `SINGLE_ISSUER`,
/// so the kernel binds the ring to that thread. Decision 4 asks for this scenario. With the owner
/// check deleted, the second thread's `io_uring_enter` gets EEXIST from the kernel, `tick` returns
/// `Unexpected`, and the scenario returns.
fn tick_from_another_thread() void {
    loop.init(&memory, options) catch return;
    const thread = std.Thread.spawn(.{}, tick_on_this_thread, .{}) catch return;
    thread.join();
}

fn tick_on_this_thread() void {
    var events: [1]core.Event = undefined;
    scenario.reached_violation();
    _ = loop.tick(&events, tick_wait_ns) catch {};
}

/// Memory for one small group, with two alignments of slack: the scenario aligns a pointer forward
/// inside this array and then moves it off the alignment, so it needs room for both steps.
const group_buffers = 2;
const group_buffer_bytes = 64;
const group_alignment = uring.buffers.group_alignment;
const group_scenario_bytes = uring.buffers.group_bytes(group_buffers, group_buffer_bytes);
var group_memory: [group_scenario_bytes + 2 * group_alignment]u8 align(group_alignment) = undefined;

/// A group whose memory starts one `io_uring_buf` past `group_alignment`. The kernel wants a buffer
/// ring on a page boundary and answers EINVAL otherwise. Until 2026-09-22 that EINVAL arrived as
/// one `Unexpected` with no name, and it cost a consumer a day. That consumer's memory passed every
/// cast and failed only in the kernel, and this offset has the same shape. With the check deleted,
/// `provide_buffers` returns `Unsupported` and the scenario returns.
///
/// The address is aligned forward at run time rather than taken from the array as declared, so the
/// scenario does not depend on how the loader aligns a static. The pointer is made with safety
/// checks off. In a checked build `@ptrFromInt` refuses an address that is not aligned as its type
/// says, as `@alignCast` does, and a caller built without checks gets no such refusal. rotor's
/// assertions stay on either way (CLAUDE.md non-negotiable 1).
fn provide_a_group_that_is_not_aligned() void {
    loop.init(&memory, options) catch return;
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const misaligned = blk: {
        @setRuntimeSafety(false);
        const start: [*]align(group_alignment) u8 =
            @ptrFromInt(base + @sizeOf(std.os.linux.io_uring_buf));
        break :blk start[0..group_scenario_bytes];
    };
    scenario.reached_violation();
    loop.provide_buffers(0, misaligned, group_buffers, group_buffer_bytes) catch {};
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "loop: tick from another thread", .run = tick_from_another_thread },
    .{
        .name = "buffers: provide a group that is not aligned",
        .run = provide_a_group_that_is_not_aligned,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
