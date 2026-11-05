//! The context switch's own test (decision 22, check 1). It lives in a file of its own because it
//! needs a stack and contexts that outlive a function, which the lint allows only in a test file.
const std = @import("std");
const builtin = @import("builtin");
const switching = @import("adapter_switch.zig");
const Context = switching.Context;
const Switch = switching.Switch;
const initial_context = switching.initial_context;
const stack_end_alignment = switching.stack_end_alignment;
const supported = switching.supported;
const switch_context = switching.switch_context;

const testing = std.testing;

/// Clears the register the switch takes its message in, `x1` or `rsi`, and jumps to the switch with
/// the message in the first argument register. A switch that reads the message register without
/// loading it then reads 0 and faults. Check 1's first error made the optimized build skip that
/// load, and a test that called the switch the usual way passed anyway: the register held a usable
/// pointer by chance.
fn call_with_message_register_cleared() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ xorl %%esi, %%esi
            \\ jmp %[switch_context:P]
            :
            : [switch_context] "X" (&switch_context),
        ),
        .aarch64 => asm volatile (
            \\ mov x1, xzr
            \\ b %[switch_context]
            :
            : [switch_context] "X" (&switch_context),
        ),
        else => @compileError("no fiber switch for this architecture"),
    }
}

fn switch_with_message_register_cleared(message: *const Switch) void {
    const call: *const fn (*const Switch) callconv(.c) void = @ptrCast(&call_with_message_register_cleared);
    call(message);
}

const test_stack_bytes = 64 * 1024;

var test_stack: [test_stack_bytes]u8 align(stack_end_alignment) = undefined;
var test_main_context: Context align(@alignOf(Context)) = undefined;
var test_fiber_context: Context align(@alignOf(Context)) = undefined;
var test_to_fiber: Switch align(@alignOf(Switch)) = undefined;
var test_to_main: Switch align(@alignOf(Switch)) = undefined;
var test_returns: usize = 0;

/// Switches back twice, and is switched in twice, so it never reaches its end.
fn test_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    test_returns += argument;
    switch_with_message_register_cleared(&test_to_main);
    test_returns += 1;
    switch_with_message_register_cleared(&test_to_main);
    unreachable;
}

test "the switch loads its message from its argument, whatever the message register holds" {
    if (!supported) return error.SkipZigTest;
    test_returns = 0;
    test_to_fiber = .{ .old = &test_main_context, .new = &test_fiber_context };
    test_to_main = .{ .old = &test_fiber_context, .new = &test_main_context };
    test_fiber_context = initial_context(@intFromPtr(&test_stack) + test_stack_bytes, 1, test_fiber);
    switch_with_message_register_cleared(&test_to_fiber);
    try testing.expectEqual(1, test_returns);
    switch_with_message_register_cleared(&test_to_fiber);
    try testing.expectEqual(2, test_returns);
}
