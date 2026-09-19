//! libxev_sizes: prints the size and alignment in bytes of libxev's per-operation structure, the
//! `Completion`, for every backend of the target it was built for. Row 7 of the table in
//! docs/decisions/0003-speed-sources.md cites these numbers.
//!
//! Built by `zig build bench-competitors` against the libxev pinned in build.zig.zon.
const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");

pub fn main() void {
    // A backend compiles only for the system it drives, so each system names its own.
    switch (builtin.os.tag) {
        .linux => {
            print("io_uring", xev.IO_Uring.Completion);
            print("epoll", xev.Epoll.Completion);
        },
        .macos => print("kqueue", xev.Kqueue.Completion),
        else => @compileError("libxev_sizes names the backends of Linux and macOS alone"),
    }
}

fn print(comptime backend: []const u8, comptime Completion: type) void {
    std.debug.print("xev.Completion {s} size {d} align {d}\n", .{
        backend, @sizeOf(Completion), @alignOf(Completion),
    });
}
