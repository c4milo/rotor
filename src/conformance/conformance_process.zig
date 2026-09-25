//! The processes the group scenarios start (decision 21): a child made by `fork` that runs one
//! function and exits with its status, the wait for it, and the memory both share. rotor starts no
//! process; only these scenarios do.
//!
//! The Linux test executables link no C library, so on Linux these are the kernel's calls, and
//! elsewhere they are the C library's. A child exits with `_exit` or `exit_group`, so nothing of the
//! parent's test runner runs in it, and it writes nothing to the runner's output.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const core = @import("core");

const kernel_calls = builtin.os.tag == .linux and !builtin.link_libc;

pub const Pid = i32;

/// A child's status when it ran to its end and found everything as expected.
pub const status_passed: u8 = 0;

/// Forks. The child runs `body(context)` and exits with what it returns. The parent gets the
/// child's id, for `wait`.
pub fn start(comptime Context: type, context: Context, comptime body: fn (Context) u8) !Pid {
    const pid = try fork();
    if (pid == 0) exit(body(context));
    return pid;
}

fn fork() !Pid {
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

/// Waits for `pid` to end, and returns its exit status. A child a signal ended, which is how an
/// assertion ends one, is `error.ChildHalted`.
pub fn wait(pid: Pid) !u8 {
    const status = try wait_status(pid);
    // Every Unix encodes it this way: the signal in the low 7 bits, 0 for an exit, and the exit
    // status in the byte above.
    if (status & 0x7f != 0) return error.ChildHalted;
    return @intCast((status >> 8) & 0xff);
}

fn wait_status(pid: Pid) !u32 {
    for (0..16) |_| {
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
        if (std.posix.errno(-1) != .INTR) return error.WaitFailed;
    }
    return error.WaitFailed;
}

/// Memory every process forked after this call shares with the caller: a registry's. A mapping
/// starts on a page, which is aligned to 128 as `Registry.init_group` requires.
pub fn shared_memory(bytes: usize) ![]align(core.layout.memory_alignment) u8 {
    return std.posix.mmap(
        null,
        bytes,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .ANONYMOUS = true },
        -1,
        0,
    );
}

pub fn release_memory(memory: []align(core.layout.memory_alignment) u8) void {
    std.posix.munmap(@alignCast(memory));
}
