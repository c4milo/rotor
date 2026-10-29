//! The monotonic clock both Linux backends' ticks read.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");

/// A Mac compiles this file for the epoll suite, which skips there, and links libc. Its libc's
/// `timespec` is not Linux's, so only a Linux target reads through libc.
const read_through_libc = builtin.os.tag == .linux and builtin.link_libc;

/// The monotonic clock, in nanoseconds. A tick reads it once, and once more after a wait that
/// blocked (decision 9, rule 4). The tests read it too, so a test measures with the clock
/// the tick reads.
///
/// A program that links libc reads it through libc, which calls the vDSO. Zig 0.16's own
/// `clock_gettime` finds the vDSO through `elf_aux_maybe`, which only Zig's start code sets. Under
/// libc nothing sets it, so every read was a system call: two thirds of a loop's system calls in
/// colibri's h2 server on 2026-10-29 (issue 8).
pub fn clock_ns() u64 {
    var now: linux.timespec = undefined;
    if (read_through_libc) {
        const rc = std.c.clock_gettime(.MONOTONIC, &now);
        assert(rc == 0);
    } else {
        const rc = linux.clock_gettime(.MONOTONIC, &now);
        assert(linux.errno(rc) == .SUCCESS);
    }
    assert(now.sec >= 0);
    const seconds: u64 = @intCast(now.sec);
    const nanoseconds: u64 = @intCast(now.nsec);
    return seconds * core.constants.ns_per_s + nanoseconds;
}

const testing = std.testing;

/// The exit statuses of the child in the test below, beside 0 for a pass.
const status_no_filter: u8 = 2;
const status_no_vdso: u8 = 3;

/// The clock reads the child of the test below makes.
const reads = 1000;

/// A classic BPF instruction, as `struct sock_filter` of `linux/filter.h`.
const Instruction = extern struct { code: u16, jump_true: u8, jump_false: u8, k: u32 };

/// `struct sock_fprog` of `linux/filter.h`.
const Program = extern struct { len: u16, filter: [*]const Instruction };

/// The instructions of a filter below: load the call's number, compare it, and two answers.
const filter_instructions = 4;
const Filter = [filter_instructions]Instruction;

fn instruction(code: u16, k: u32, jump_false: u8) Instruction {
    return .{ .code = code, .jump_true = 0, .jump_false = jump_false, .k = k };
}

const bpf = linux.BPF;
const seccomp = linux.SECCOMP;

/// A seccomp filter that answers `clock_gettime` with the action `refusal` and allows every other
/// call.
fn refuse_clock(comptime refusal: u32) Filter {
    return .{
        instruction(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "nr"), 0),
        instruction(bpf.JMP | bpf.JEQ | bpf.K, @intFromEnum(linux.SYS.clock_gettime), 1),
        instruction(bpf.RET | bpf.K, refusal, 0),
        instruction(bpf.RET | bpf.K, seccomp.RET.ALLOW, 0),
    };
}

const answer_eperm = refuse_clock(seccomp.RET.ERRNO | @as(u32, @intFromEnum(linux.E.PERM)));
const kill_process = refuse_clock(seccomp.RET.KILL_PROCESS);

fn install(filter: *const Filter) bool {
    const program: Program = .{ .len = filter.len, .filter = filter };
    return linux.errno(linux.seccomp(seccomp.SET_MODE_FILTER, 0, &program)) == .SUCCESS;
}

/// The child of the test below. It reads the clock with the `clock_gettime` system call refused.
/// A read that enters the kernel kills it with SIGSYS. A kill and not an error, because the
/// assertion in `clock_ns` would halt the child in the panic handler, and that handler hung in a
/// child forked from a test on 2026-10-29.
fn read_without_the_system_call() u8 {
    // The kernel lets a process without privileges install a filter only after this call.
    const privileges = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (linux.errno(privileges) != .SUCCESS) return status_no_filter;
    // libc enters the kernel too when the host's clock source has no vDSO path, as on some
    // virtual machines. Then nothing here can tell the two reads apart. The first filter finds
    // that with an error. The second one kills, and the kernel applies the stricter of the two.
    if (!install(&answer_eperm)) return status_no_filter;
    var now: linux.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &now) != 0) return status_no_vdso;
    if (!install(&kill_process)) return status_no_filter;
    for (0..reads) |_| _ = clock_ns();
    return 0;
}

test "a program that links libc reads the clock without a system call" {
    if (builtin.os.tag != .linux or !builtin.link_libc) return error.SkipZigTest;
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) std.c._exit(read_without_the_system_call());
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const bits: u32 = @bitCast(status);
    // A signal in the low 7 bits means a read entered the kernel, and the filter killed the child.
    try testing.expectEqual(@as(u32, 0), bits & 0x7f);
    const exit_status: u8 = @intCast((bits >> 8) & 0xff);
    if (exit_status == status_no_filter or exit_status == status_no_vdso) {
        return error.SkipZigTest;
    }
    try testing.expectEqual(@as(u8, 0), exit_status);
}
