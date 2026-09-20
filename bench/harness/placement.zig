//! Where a benchmark's thread runs. Milestone 4's workload list asks for every workload "on 1
//! core and N cores", and a row that says which cannot be believed unless something placed the
//! threads: a scheduler is free to put a client and a server on one core, or on two, and to
//! change its mind mid-run.
//!
//! This is `bench/costs/measure.zig`'s placement, lifted so the echo and datagram programs share
//! one definition with the cost probes. A row measured here and a row of `docs/costs.md` then
//! mean the same thing by "one core".
//!
//! **Linux pins; macOS cannot.** Apple silicon has no hard affinity — `thread_policy_set`'s
//! affinity tags are a hint the scheduler may ignore — so a run there reports `pin_refused` and
//! the row says so rather than claiming a placement it does not have. That is decision 2's
//! "macOS is a development platform" again, in the one place it would otherwise be invisible.
const std = @import("std");
const builtin = @import("builtin");

/// What actually happened to the calling thread, which every report prints.
pub const Placement = enum {
    /// Pinned to the core asked for. Only this one lets a row claim a core count.
    pinned,
    /// The pin was asked for and refused, so the scheduler placed the thread.
    pin_refused,
    /// macOS took the quality-of-service class instead, which is a priority and not a core.
    qos_user_interactive,
    qos_refused,
    /// No placement was asked for.
    scheduler_default,

    /// True when a row measured under this placement may say how many cores it used.
    pub fn names_a_core(placement: Placement) bool {
        return placement == .pinned;
    }

    pub fn text(placement: Placement) []const u8 {
        return @tagName(placement);
    }
};

/// Asks for the best the host offers without naming a core.
pub fn place_current_thread() Placement {
    switch (builtin.os.tag) {
        .macos => {
            const rc = std.c.pthread_set_qos_class_self_np(.USER_INTERACTIVE, 0);
            return if (rc == 0) .qos_user_interactive else .qos_refused;
        },
        else => return .scheduler_default,
    }
}

/// Pins the calling thread to `cpu`. A caller that gets anything but `.pinned` must report it:
/// the two ends may have shared a core, which is the thing a core count separates.
pub fn pin_current_thread(cpu: usize) Placement {
    if (builtin.os.tag != .linux) return place_current_thread();
    const linux = std.os.linux;
    const bits = @bitSizeOf(usize);
    var set: linux.cpu_set_t = @splat(0);
    if (cpu / bits >= set.len) return .pin_refused;
    set[cpu / bits] |= @as(usize, 1) << @intCast(cpu % bits);
    linux.sched_setaffinity(0, &set) catch return .pin_refused;
    return .pinned;
}

/// The core a program takes when it is given none: the one every machine has.
pub const first_cpu: usize = 0;

/// The other core a two-core row uses. A machine whose cores 0 and 1 are two threads of one
/// physical core would understate such a row, which is why every report names the machine.
pub const second_cpu: usize = 1;

/// Pins to `cpu` when one is named, and otherwise takes what the host offers.
pub fn place(cpu: ?usize) Placement {
    return if (cpu) |value| pin_current_thread(value) else place_current_thread();
}

const testing = std.testing;

test "only a pinned thread lets a row name a core count" {
    try testing.expect(Placement.pinned.names_a_core());
    try testing.expect(!Placement.pin_refused.names_a_core());
    try testing.expect(!Placement.qos_user_interactive.names_a_core());
    try testing.expect(!Placement.scheduler_default.names_a_core());
}

test "placing without a core asks for what the host offers and never claims a pin" {
    const placement = place(null);
    try testing.expect(!placement.names_a_core());
    switch (builtin.os.tag) {
        .macos => try testing.expect(placement == .qos_user_interactive or
            placement == .qos_refused),
        else => try testing.expectEqual(Placement.scheduler_default, placement),
    }
}

test "a core above what the host has is refused rather than silently ignored" {
    // `cpu_set_t` covers a fixed number of cores; one past it cannot be asked for. On a host
    // with no hard affinity this reports what that host does instead, which is also not a pin.
    const beyond = @bitSizeOf(usize) * 1024;
    try testing.expect(!place(beyond).names_a_core());
}
