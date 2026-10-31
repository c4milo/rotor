//! task_calls: the system calls a macOS process has made, as its kernel counts them. It is the
//! macOS half of the call gate (`bench/calls/count_calls_macos.sh`), and it needs no root.
//!
//! Run:  task_calls PID
//!
//! It prints one line, `UNIX MACH`: the Unix system calls and the Mach traps the process made since
//! it started. `proc_pidinfo` with `PROC_PIDTASKINFO` reads them, and the kernel answers it for a
//! process of the same user. A call that the commpage answers, such as `mach_absolute_time`, enters
//! no kernel and is not counted.
//!
//! The kernel keeps each count in 32 bits, so a caller takes a difference modulo 2^32.
//!
//! Exit status: 0 when it printed the line, 1 when the kernel did not answer, 2 when the argument
//! is not a process id.
const std = @import("std");
const builtin = @import("builtin");

/// `struct proc_taskinfo` of `sys/proc_info.h`.
const TaskInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    csw: i32,
    threadnum: i32,
    numrunning: i32,
    priority: i32,
};

comptime {
    // The size `sys/proc_info.h` gives it on every macOS processor.
    std.debug.assert(@sizeOf(TaskInfo) == 96);
}

/// `PROC_PIDTASKINFO` of `sys/proc_info.h`.
const proc_pid_task_info = 4;

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, size: c_int) c_int;

pub const Calls = struct { unix: u32, mach: u32 };

/// The counts of process `pid`, or null when the kernel does not answer: the process is gone, or
/// it belongs to another user.
pub fn read(pid: i32) ?Calls {
    comptime std.debug.assert(builtin.os.tag == .macos);
    var info: TaskInfo = undefined;
    const answered = proc_pidinfo(pid, proc_pid_task_info, 0, &info, @sizeOf(TaskInfo));
    if (answered != @sizeOf(TaskInfo)) return null;
    return .{ .unix = @bitCast(info.syscalls_unix), .mach = @bitCast(info.syscalls_mach) };
}

const exit_unanswered = 1;
const exit_usage = 2;

/// Bytes of standard output held before a flush.
const output_buffer_bytes = 256;

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [output_buffer_bytes]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    // The program's name and the process id.
    const arguments_expected = 2;
    if (arguments.len != arguments_expected) {
        try out.print("usage: task_calls PID\n", .{});
        return exit_usage;
    }
    const pid = std.fmt.parseInt(i32, arguments[1], 10) catch {
        try out.print("task_calls: {s} is not a process id\n", .{arguments[1]});
        return exit_usage;
    };
    const calls = read(pid) orelse {
        try out.print("task_calls: the kernel gave no counts for process {d}\n", .{pid});
        return exit_unanswered;
    };
    try out.print("{d} {d}\n", .{ calls.unix, calls.mach });
    return 0;
}

const testing = std.testing;

test "the Unix count rises by at least the system calls the process makes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const calls = 1000;
    const before = read(std.c.getpid()).?;
    for (0..calls) |_| _ = std.c.getppid();
    const after = read(std.c.getpid()).?;
    // The second read is a system call too, and the runner's other threads may make some.
    try testing.expect(after.unix -% before.unix >= calls);
    try testing.expect(read(-1) == null);
}
