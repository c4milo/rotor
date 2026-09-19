//! uring_probe: asks the running Linux kernel for every io_uring feature rotor's version one
//! depends on, and prints one line per feature. tools/linux_test.sh runs it before any test,
//! because a test that passes on a kernel without these features shows something else.
//!
//! Build: zig build test-linux, which installs it as zig-out/linux/uring_probe.
//! Run:   bash tools/linux_test.sh, which runs it in the container that script starts.
//!
//! The features are the rows of the table under "Minimum kernel" in
//! docs/decisions/0002-scope.md, checked in that table's order, each with the tool that answers
//! for it:
//!
//!   - IORING_FEAT_NODROP and IORING_FEAT_EXT_ARG are bits of the features word that
//!     io_uring_setup returns.
//!   - IORING_OP_MSG_RING is an opcode, and IORING_REGISTER_PROBE is the kernel's own list of the
//!     opcodes it supports.
//!   - Multishot accept, provided buffer rings (IORING_REGISTER_PBUF_RING) and multishot receive
//!     have no feature bit and no opcode of their own, so the probe runs each one over a loopback
//!     TCP connection (uring_probe_multishot.zig). A kernel without one answers EINVAL.
//!   - IORING_SETUP_SINGLE_ISSUER and IORING_SETUP_DEFER_TASKRUN are setup flags, so the probe
//!     sets up a ring with each. A kernel without one answers EINVAL.
//!
//! The probe then answers the question that record leaves open: whether IORING_OP_MSG_RING can
//! post into a ring set up with IORING_SETUP_DEFER_TASKRUN (uring_probe_post.zig).
//!
//! Every wait is an io_uring_enter with a timeout argument, so a kernel that never completes an
//! operation costs `wait_seconds` and cannot hang the probe.
//!
//! Exit status: 0 when every required feature is present. 1 when one is not, after a last line
//! that names the first of them. An error exit when a system call the probe needs for its own
//! plumbing fails, which means a broken host and not a missing feature.
//!
//! This is developer tooling. It is never linked into the library. It runs once and exits, so it
//! leaves its sockets for the kernel to close. This file is the entry point and holds what the
//! other two share: the report, the bounded wait, and the limits.

const std = @import("std");
const builtin = @import("builtin");
const multishot = @import("uring_probe_multishot.zig");
const post = @import("uring_probe_post.zig");

pub const linux = std.os.linux;
pub const IoUring = linux.IoUring;
const assert = std.debug.assert;

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("uring_probe runs on Linux alone; build it with zig build test-linux");
    }
}

/// Every line the probe prints starts with this, which tells its lines from a test's.
const line_prefix = "uring_probe: ";

/// Bytes of the buffer a report line is formatted into. The longest line is under 300 bytes.
const line_buffer_bytes = 512;

/// The exit status when a required feature is not present.
const exit_missing = 1;

/// Submission entries of every ring the probe sets up. No check has more than two in flight.
pub const ring_entries = 8;

/// Seconds one wait for completions may last. A completion over loopback arrives in well under
/// a millisecond, so a wait that runs out means the kernel will not deliver it.
pub const wait_seconds = 2;

/// How many times one wait is entered again after a signal interrupts it.
const wait_attempts_max = 8;

/// The flags of a loop's ring: completions run only when the owning thread asks
/// (docs/decisions/0002-scope.md). The kernel refuses DEFER_TASKRUN without SINGLE_ISSUER.
pub const loop_ring_flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN;

/// Whether a feature that is not present fails the probe.
pub const Need = enum { required, optional };

pub const Feature = struct { name: []const u8, need: Need = .required };

const io_uring_setup: Feature = .{ .name = "io_uring_setup" };
const feat_nodrop: Feature = .{ .name = "IORING_FEAT_NODROP" };
const feat_ext_arg: Feature = .{ .name = "IORING_FEAT_EXT_ARG" };
pub const op_msg_ring: Feature = .{ .name = "IORING_OP_MSG_RING" };
const single_issuer: Feature = .{ .name = "IORING_SETUP_SINGLE_ISSUER" };
pub const defer_taskrun: Feature = .{ .name = "IORING_SETUP_DEFER_TASKRUN" };

pub const State = enum {
    present,
    missing,
    not_tried,

    fn text(state: State) []const u8 {
        return switch (state) {
            .present => "present",
            .missing => "missing",
            .not_tried => "not tried",
        };
    }
};

pub const Report = struct {
    out: *std.Io.Writer,
    /// The first required feature that was not shown present, in the order the checks ran.
    first_missing: ?[]const u8 = null,

    /// Prints one line and flushes it, so the lines before a fault are already out.
    pub fn line(report: *Report, comptime format: []const u8, arguments: anytype) !void {
        try report.out.print(line_prefix ++ format ++ "\n", arguments);
        try report.out.flush();
    }

    /// Prints one feature's line. A required feature that is not present, a check that was not
    /// tried included, is what the last line names and what makes the exit status non-zero.
    pub fn verdict(
        report: *Report,
        feature: Feature,
        state: State,
        comptime detail: []const u8,
        arguments: anytype,
    ) !void {
        try report.out.print(line_prefix ++ "{s}: {s}", .{ feature.name, state.text() });
        try report.out.print(detail ++ "\n", arguments);
        try report.out.flush();
        if (state == .present or feature.need == .optional) return;
        if (report.first_missing == null) report.first_missing = feature.name;
    }

    /// Prints a feature as missing because `who` answered `errno`.
    pub fn refused(
        report: *Report,
        feature: Feature,
        comptime who: []const u8,
        errno: linux.E,
    ) !void {
        assert(errno != .SUCCESS);
        const detail = ", " ++ who ++ " answered errno {d} (E{s})";
        try report.verdict(feature, .missing, detail, .{ @intFromEnum(errno), errno_name(errno) });
    }
};

fn errno_name(errno: linux.E) []const u8 {
    return std.enums.tagName(linux.E, errno) orelse "?";
}

/// Says which system call of the probe's own plumbing the kernel refused. A refusal there is a
/// broken host and not a missing feature, so it ends the probe with an error.
fn fail(comptime call: []const u8, errno: linux.E) error{SystemCallFailed} {
    assert(errno != .SUCCESS);
    const format = line_prefix ++ call ++ " failed with errno {d} (E{s})\n";
    std.debug.print(format, .{ @intFromEnum(errno), errno_name(errno) });
    return error.SystemCallFailed;
}

/// Returns the value of a system call the probe needs for its own plumbing, or fails.
pub fn check(comptime call: []const u8, result: usize) !usize {
    const errno = linux.errno(result);
    return if (errno == .SUCCESS) result else fail(call, errno);
}

/// Submits what `ring` has queued, waits for `wanted` completions or for `wait_seconds`, and
/// copies out what arrived. The wait is an io_uring_enter with IORING_ENTER_EXT_ARG, and it is
/// also where a DEFER_TASKRUN ring runs its completions, on the thread that owns it. std's
/// io_uring_enter passes the size of a signal set, so the probe makes the call itself.
pub fn reap(ring: *IoUring, cqes: []linux.io_uring_cqe, wanted: u32) !u32 {
    assert(wanted > 0);
    assert(wanted <= cqes.len);
    var timeout: linux.kernel_timespec = .{ .sec = wait_seconds, .nsec = 0 };
    var argument = std.mem.zeroes(linux.io_uring_getevents_arg);
    argument.ts = @intFromPtr(&timeout);
    const flags = linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG;
    var attempt: u32 = 0;
    while (attempt < wait_attempts_max) : (attempt += 1) {
        const result = linux.syscall6(
            .io_uring_enter,
            @intCast(ring.fd),
            ring.flush_sq(),
            wanted,
            flags,
            @intFromPtr(&argument),
            @sizeOf(linux.io_uring_getevents_arg),
        );
        switch (linux.errno(result)) {
            .SUCCESS, .TIME => break,
            .INTR => continue,
            else => |errno| return fail("io_uring_enter", errno),
        }
    }
    return ring.copy_cqes(cqes, 0);
}

pub fn main(init: std.process.Init) !void {
    var line_buffer: [line_buffer_bytes]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &line_buffer);
    var report: Report = .{ .out = &stdout.interface };

    var names: linux.utsname = undefined;
    _ = try check("uname", linux.uname(&names));
    const release = std.mem.sliceTo(&names.release, 0);
    try report.line("kernel {s} {s}", .{ release, std.mem.sliceTo(&names.machine, 0) });

    if (try check_features(&report)) try check_operations(&report);

    const missing = report.first_missing orelse {
        return report.line("every required feature is present", .{});
    };
    try report.line("missing: {s}", .{missing});
    std.process.exit(exit_missing);
}

const Setup = union(enum) {
    /// The kernel set the ring up and reported these IORING_FEAT_* bits.
    features: u32,
    /// The kernel refused with this errno.
    refused: linux.E,
};

/// Sets up a ring with `flags` and closes it at once.
fn try_setup(flags: u32) Setup {
    var params = std.mem.zeroes(linux.io_uring_params);
    params.flags = flags;
    const result = linux.io_uring_setup(ring_entries, &params);
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return .{ .refused = errno };
    assert(params.sq_entries == ring_entries);
    const closed = linux.close(@intCast(result));
    assert(linux.errno(closed) == .SUCCESS);
    return .{ .features = params.features };
}

/// Reports io_uring_setup and the two feature bits. Returns whether the other checks can run:
/// they need a ring, and each bounds its wait with IORING_FEAT_EXT_ARG.
fn check_features(report: *Report) !bool {
    const features = switch (try_setup(0)) {
        .features => |features| features,
        .refused => |errno| {
            try report.refused(io_uring_setup, "the kernel", errno);
            if (errno != .PERM) return false;
            try report.line("Docker's default seccomp profile refuses io_uring_setup with EPERM;" ++
                " run the container with --security-opt seccomp=unconfined", .{});
            return false;
        },
    };
    try report.verdict(io_uring_setup, .present, ", features 0x{x}", .{features});
    const bits = [_]struct { feature: Feature, bit: u32 }{
        .{ .feature = feat_nodrop, .bit = linux.IORING_FEAT_NODROP },
        .{ .feature = feat_ext_arg, .bit = linux.IORING_FEAT_EXT_ARG },
    };
    for (bits) |entry| {
        const state: State = if (features & entry.bit != 0) .present else .missing;
        try report.verdict(entry.feature, state, ", bit 0x{x} of the features", .{entry.bit});
    }
    if (features & linux.IORING_FEAT_EXT_ARG != 0) return true;
    const detail = "the other checks were not tried: each bounds its wait with {s}";
    try report.line(detail, .{feat_ext_arg.name});
    return false;
}

/// Runs every check that needs a ring, in the order of decision 2's table.
fn check_operations(report: *Report) !void {
    var ring = try IoUring.init(ring_entries, 0);
    defer ring.deinit();
    const msg_ring_present = try check_msg_ring_opcode(report, &ring);
    try multishot.check(report, &ring);

    const flag_checks = [_]struct { feature: Feature, flags: u32 }{
        .{ .feature = single_issuer, .flags = linux.IORING_SETUP_SINGLE_ISSUER },
        .{ .feature = defer_taskrun, .flags = loop_ring_flags },
    };
    var flags_present = true;
    for (flag_checks) |entry| {
        switch (try_setup(entry.flags)) {
            .features => try report.verdict(entry.feature, .present, "", .{}),
            .refused => |errno| {
                try report.refused(entry.feature, "io_uring_setup", errno);
                flags_present = false;
            },
        }
    }
    try post.check(report, msg_ring_present and flags_present);
}

fn check_msg_ring_opcode(report: *Report, ring: *IoUring) !bool {
    var probe = std.mem.zeroes(linux.io_uring_probe);
    const result = linux.io_uring_register(ring.fd, .REGISTER_PROBE, &probe, probe.ops.len);
    if (linux.errno(result) != .SUCCESS) {
        try report.refused(op_msg_ring, "IORING_REGISTER_PROBE", linux.errno(result));
        return false;
    }
    const opcode = @intFromEnum(linux.IORING_OP.MSG_RING);
    const last = @intFromEnum(probe.last_op);
    const state: State = if (probe.is_supported(.MSG_RING)) .present else .missing;
    const detail = ", opcode {d}; IORING_REGISTER_PROBE lists opcodes up to {d}";
    try report.verdict(op_msg_ring, state, detail, .{ opcode, last });
    return state == .present;
}
