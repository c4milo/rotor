//! A second process, for what measures a message between processes (decision 21): the cost probes
//! C24 and C25, and `rotor_post --peer process`. It is a child made by `fork` that runs one function
//! and exits with its status, the wait for it, and memory the two share, spelled once for both
//! targets. The Linux builds link no libc, so there these are the kernel's calls; on macOS they are
//! libSystem's.
//!
//! A child ends with `_exit`, or `exit_group` on Linux, so nothing of the parent runs in it after
//! the function returns.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

/// Why a call here failed. None of them leaves a child behind: `start` makes none when it fails.
pub const Error = error{
    /// `fork` made no child.
    ForkFailed,
    /// The wait for a child failed, so its status is not known.
    WaitFailed,
    /// A signal ended the child, which is how an assertion ends one.
    ChildHalted,
    /// The shared mapping was refused.
    MapFailed,
};

const kernel_calls = builtin.os.tag == .linux and !builtin.link_libc;

pub const Pid = i32;

/// What a child that ran to its end without a failure exits with.
pub const status_passed: u8 = 0;
/// What a child exits with when its function failed.
pub const status_failed: u8 = 1;

/// The most times `wait` makes its call again after a signal interrupted it.
const wait_retries_max = 16;

/// The signal that ends a child the parent gave up on: it cannot be caught.
const kill_signal = 9;

/// Forks. The child runs `body(context)` and exits with its status. The parent gets its id.
pub fn start(comptime Context: type, context: Context, comptime body: fn (Context) u8) Error!Pid {
    const pid = try fork();
    if (pid == 0) exit(body(context));
    return pid;
}

fn fork() Error!Pid {
    if (kernel_calls) {
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
        return @intCast(rc);
    }
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    return pid;
}

fn exit(status: u8) noreturn {
    if (kernel_calls) linux.exit_group(status);
    std.c._exit(status);
}

/// Waits for `pid` and returns its exit status.
pub fn wait(pid: Pid) Error!u8 {
    const status = try wait_status(pid);
    // Every Unix encodes it this way: the signal in the low 7 bits, 0 for an exit, and the exit
    // status in the byte above.
    if (status & 0x7f != 0) return error.ChildHalted;
    return @intCast((status >> 8) & 0xff);
}

fn wait_status(pid: Pid) Error!u32 {
    for (0..wait_retries_max) |_| {
        if (kernel_calls) {
            var status: u32 = 0;
            const rc = linux.waitpid(pid, &status, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => return status,
                .INTR => continue,
                else => return error.WaitFailed,
            }
        }
        var status: c_int = 0;
        if (std.c.waitpid(pid, &status, 0) == pid) return @bitCast(status);
        if (posix.errno(-1) != .INTR) return error.WaitFailed;
    }
    return error.WaitFailed;
}

/// Ends a child the parent stopped waiting for, so the wait after it returns.
pub fn kill(pid: Pid) void {
    if (kernel_calls) {
        _ = linux.kill(pid, @enumFromInt(kill_signal));
        return;
    }
    _ = std.c.kill(pid, @enumFromInt(kill_signal));
}

/// Memory every process forked after this call shares with the caller, aligned to a page.
pub fn shared(bytes: usize) Error![]align(std.heap.page_size_min) u8 {
    return posix.mmap(
        null,
        bytes,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .ANONYMOUS = true },
        -1,
        0,
    ) catch error.MapFailed;
}

pub fn release(memory: []align(std.heap.page_size_min) u8) void {
    posix.munmap(memory);
}
