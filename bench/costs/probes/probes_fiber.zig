//! Row C26: one fiber switch out and back, with the instructions of `std.Io.fiber.contextSwitch`,
//! the switch std's own `Kqueue` and `Uring` use. Decision 22's first check asks for this row
//! before anything of the adapter is built: a blocking call through the adapter costs two such
//! switches beside the operation it wraps.
//!
//! The probe runs `switch_context`, below, and not std's function: in Zig 0.16.0 std's function
//! faults in an optimized build, and `switch_context` says why. The instructions are the same.
//!
//! The probe starts one fiber on a stack of its own, as std's `Kqueue` starts its idle fiber: the
//! stack's top holds an argument, and a naked entry passes it to an ordinary function. After that
//! the main context and the fiber switch to each other and back, and nothing else runs. So the row
//! is the switch alone: no scheduler, no ready queue and no operation, which an adapter adds.
//!
//! Each sample times two loops back to back (`measure.sample_pairs`), as C5 and C21 do. The first
//! calls a never-inlined function that does nothing; the second switches to the fiber and back.
//! The cell is the second loop's time, and the note carries the first.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const fiber = std.Io.fiber;
const measure = @import("../measure.zig");
const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;

/// `switch_context` and `fiber_entry` exist for these two architectures, of the three std's
/// fibers support.
const switch_supported = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => true,
    else => false,
};

pub const probes = if (switch_supported) [_]measure.Probe{.{
    .row = 26,
    .operation = "one fiber switch out and back, the instructions of `std.Io.fiber.contextSwitch`",
    .run = run_switch,
}} else [_]measure.Probe{};

const switch_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 16384 };

/// The fiber's stack. It runs one function that keeps two words of state, so a small stack is
/// enough, and the static keeps the probe free of an allocator.
const stack_bytes = 64 * 1024;

/// The fiber's stack is aligned to 16 bytes, as both System V and AAPCS64 require of a stack.
const stack_alignment = 16;

var fiber_stack: [stack_bytes]u8 align(stack_alignment) = undefined;

/// The two contexts and the two messages that move between them. A message names the context to
/// save into and the context to restore.
const Switcher = struct {
    main_context: fiber.Context = undefined,
    fiber_context: fiber.Context = undefined,
    to_fiber: fiber.Switch = undefined,
    to_main: fiber.Switch = undefined,
    /// Switches the fiber made back to the main context, so the probe can check that every switch
    /// in reached the fiber.
    returns: u64 = 0,

    fn init(switcher: *Switcher) void {
        switcher.* = .{};
        switcher.to_fiber = .{ .old = &switcher.main_context, .new = &switcher.fiber_context };
        switcher.to_main = .{ .old = &switcher.fiber_context, .new = &switcher.main_context };
        // The stack's top holds the switcher, which `fiber_entry` reads.
        const stack_end: [*]align(stack_alignment) usize =
            @ptrCast(@alignCast(fiber_stack[stack_bytes..].ptr));
        (stack_end - 1)[0] = @intFromPtr(switcher);
        switcher.fiber_context = switch (builtin.cpu.arch) {
            .aarch64 => .{ .sp = @intFromPtr(stack_end), .fp = 0, .pc = @intFromPtr(&fiber_entry) },
            .x86_64 => .{
                .rsp = @intFromPtr(stack_end - 1),
                .rbp = 0,
                .rip = @intFromPtr(&fiber_entry),
            },
            else => @compileError("no fiber entry for this architecture"),
        };
    }
};

/// Where the fiber starts: reads the switcher from the stack's top into the first argument, as
/// std's `Kqueue.mainIdleEntry` does, and jumps to `fiber_main`.
fn fiber_entry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ movq (%%rsp), %%rdi
            \\ jmp %[fiber_main:P]
            :
            : [fiber_main] "X" (&fiber_main),
        ),
        .aarch64 => asm volatile (
            \\ ldr x0, [sp, #-8]
            \\ b %[fiber_main]
            :
            : [fiber_main] "X" (&fiber_main),
        ),
        else => @compileError("no fiber entry for this architecture"),
    }
}

/// The fiber's whole life: switch back to the main context each time the main context switches in.
/// The main context never switches in again after the last sample, so the fiber stays suspended at
/// its switch until the process ends, and the function never returns.
fn fiber_main(switcher: *Switcher) callconv(.withStackAlign(.c, stack_alignment)) noreturn {
    while (true) {
        switcher.returns += 1;
        _ = switch_context(&switcher.to_main);
    }
}

/// The baseline: a call that does nothing and is never inlined.
noinline fn nothing(switcher: *Switcher) void {
    const returns: *volatile u64 = &switcher.returns;
    _ = returns.*;
}

const Loops = struct {
    switcher: *Switcher,

    pub fn run_first(loops: *Loops, batch: u32) Error!void {
        var remaining = batch;
        while (remaining != 0) : (remaining -= 1) nothing(loops.switcher);
    }

    pub fn run_second(loops: *Loops, batch: u32) Error!void {
        var remaining = batch;
        while (remaining != 0) : (remaining -= 1) {
            _ = switch_context(&loops.switcher.to_fiber);
        }
    }
};

/// One fiber at a time. `Switcher.init` starts a new fiber at the bottom of the stack, which
/// abandons the fiber an earlier `init` started: that one is never resumed, so its stack is free.
var switcher_static: Switcher align(@alignOf(Switcher)) = .{};

fn run_switch(environment: *Environment) Error!Result {
    const switcher = &switcher_static;
    switcher.init();
    var loops: Loops = .{ .switcher = switcher };
    const plan = switch_plan;
    const pair = try measure.sample_pairs(Loops, &loops, plan, &environment.values);
    // Every switch in reached the fiber, and the fiber switched back each time.
    const total = @as(u64, plan.warmup + plan.samples) * plan.batch;
    if (switcher.returns != total) return error.UnexpectedResult;
    const note = environment.note(
        "a switch to a fiber and back to the caller, two `contextSwitch` calls, nothing else;" ++
            " a call of a never-inlined function that does nothing took {d:.2} ns",
        .{pair.first.median_ns},
    );
    return .{ .summary = pair.second, .plan = plan, .unit = "switches out and back", .note = note };
}

/// std 0.16.0's `fiber.contextSwitch`, instruction for instruction, with three changes to the
/// clobber lists. Without them std's function faults in a ReleaseSafe build, on an M1 Pro under
/// macOS and under Linux, and works in a Debug build. Zig 0.17.1 has the same lists.
///
/// 1. The register that carries the message, `x1` on aarch64 and `rsi` on x86_64, is not in the
///    list. std names it there and also as the input, and the optimized build then never loads the
///    input: it jumped through whatever `x1` held and faulted at address 0.
/// 2. On aarch64 the list also names `lr`. std names `x30`, the same register, and the optimized
///    build still kept a value in it across the switch, which does not save it: the fiber read its
///    `switcher` back from `x30` after the main context had used it, and faulted.
/// 3. On aarch64 Linux the list also names `x18`, which std leaves out because macOS reserves it.
///    Linux does not, and the optimized build kept the loop's counter and the fiber's `switcher`
///    in `x18` across the switch, and faulted in the Linux gate's container.
inline fn switch_context(s: *const fiber.Switch) *const fiber.Switch {
    const Switch = fiber.Switch;
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ldp x0, x2, [x1]
            \\ ldr x3, [x2, #16]
            \\ mov x4, sp
            \\ stp x4, fp, [x0]
            \\ adr x5, 0f
            \\ ldp x4, fp, [x2]
            \\ str x5, [x0, #16]
            \\ mov sp, x4
            \\ br x3
            \\0:
            : [received_message] "={x1}" (-> *const Switch),
            : [message_to_send] "{x1}" (s),
            : .{
              .x0 = true,
              .x2 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x8 = true,
              .x9 = true,
              .x10 = true,
              .x11 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              .x18 = !builtin.target.os.tag.isDarwin(),
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .x30 = true,
              .lr = true,
              .z0 = true,
              .z1 = true,
              .z2 = true,
              .z3 = true,
              .z4 = true,
              .z5 = true,
              .z6 = true,
              .z7 = true,
              .z8 = true,
              .z9 = true,
              .z10 = true,
              .z11 = true,
              .z12 = true,
              .z13 = true,
              .z14 = true,
              .z15 = true,
              .z16 = true,
              .z17 = true,
              .z18 = true,
              .z19 = true,
              .z20 = true,
              .z21 = true,
              .z22 = true,
              .z23 = true,
              .z24 = true,
              .z25 = true,
              .z26 = true,
              .z27 = true,
              .z28 = true,
              .z29 = true,
              .z30 = true,
              .z31 = true,
              .p0 = true,
              .p1 = true,
              .p2 = true,
              .p3 = true,
              .p4 = true,
              .p5 = true,
              .p6 = true,
              .p7 = true,
              .p8 = true,
              .p9 = true,
              .p10 = true,
              .p11 = true,
              .p12 = true,
              .p13 = true,
              .p14 = true,
              .p15 = true,
              .fpcr = true,
              .fpsr = true,
              .ffr = true,
              .memory = true,
            }),
        .x86_64 => asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            : [received_message] "={rsi}" (-> *const Switch),
            : [message_to_send] "{rsi}" (s),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            }),
        else => @compileError("no fiber switch for this architecture"),
    };
}

const testing = std.testing;

test "the fiber returns once for every switch in" {
    if (!switch_supported) return error.SkipZigTest;
    const switcher = &switcher_static;
    switcher.init();
    var loops: Loops = .{ .switcher = switcher };
    try loops.run_second(3);
    try testing.expectEqual(@as(u64, 3), switcher.returns);
    try loops.run_second(5);
    try testing.expectEqual(@as(u64, 8), switcher.returns);
}
