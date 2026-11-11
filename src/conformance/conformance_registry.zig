//! The life of a registry in a scenario (decision 4, amendment of 2026-11-06).
//!
//! A registry of one process keeps the descriptor that wakes each loop until the program calls the
//! backend's `close_kept`, after every loop and remote of the registry ended. A scenario that does
//! not call it leaks one descriptor per loop id until the process exits. Camilo ruled that the
//! conformance helpers call it, so every scenario gets its registry from `RegistryLife`:
//!
//! - `start` counts the descriptors open in the process, then makes the registry.
//! - `end` closes the wakes the registry kept, counts again, and halts when the counts differ.
//!
//! A group's wakes are its creator's, which `group_module.close` closes, so a group calls `begin`
//! itself and `end` only counts. `Harness` refuses a loop on a registry when no life is open, and
//! `begin` refuses a second life while one is open. So a scenario that skips the life, or never ends
//! it, fails.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const backend = @import("backend");
const core = @import("core");
const layout = core.layout;
const constants = @import("constants.zig");

/// The lives a scenario began and has not ended: 0 or 1. Atomic because a peer thread's `Harness`
/// reads it. A child that `fork` made inherits the value of its parent.
var lives_open: std.atomic.Value(u32) align(@alignOf(std.atomic.Value(u32))) = .init(0);

pub const LifeError = error{
    /// A scenario before this one began a registry's life and did not end it.
    RegistryNotEnded,
};

/// One registry of a scenario, and the descriptors the process held open when its life began.
pub const RegistryLife = struct {
    registry: *backend.Registry,
    descriptors_open: u32,

    /// Begins the life, then makes a registry of one process of `loop_count` loops over `memory`.
    pub fn start(
        registry: *backend.Registry,
        memory: []align(layout.memory_alignment) u8,
        loop_count: u16,
    ) LifeError!RegistryLife {
        const life = try begin(registry);
        registry.init(memory, loop_count);
        return life;
    }

    /// Begins the life of `registry`, which the caller makes after this call. A group calls it before
    /// it makes the wakes, so that `end` counts them as closed.
    pub fn begin(registry: *backend.Registry) LifeError!RegistryLife {
        if (lives_open.load(.acquire) != 0) return error.RegistryNotEnded;
        lives_open.store(1, .release);
        return .{ .registry = registry, .descriptors_open = open_descriptors() };
    }

    /// Ends a life whose registry the caller never made, on the error path of its setup.
    pub fn forget(life: RegistryLife) void {
        _ = life;
        std.debug.assert(lives_open.load(.acquire) == 1);
        lives_open.store(0, .release);
    }

    /// Closes the wakes a registry of one process kept, and halts when `check` fails. Call it after
    /// every loop and remote of the registry ended, and before the registry's memory goes away. A
    /// group closes its wakes before this call.
    pub fn end(life: RegistryLife) void {
        std.debug.assert(lives_open.load(.acquire) == 1);
        life.report_claimed();
        if (!life.registry.group) backend.wake_module.close_kept(life.registry);
        lives_open.store(0, .release);
        life.check() catch std.debug.panic(
            "a registry's life began with {d} open descriptors and ended with {d}",
            .{ life.descriptors_open, open_descriptors() },
        );
    }

    /// Prints each id that a loop or a remote still holds. `close_kept` halts on such an id, and the
    /// halt would hide why: most often a scenario failed through `try` before its thread ended its
    /// loop, and the error of that `try` is the one to read.
    fn report_claimed(life: RegistryLife) void {
        if (life.registry.group) return;
        for (0..life.registry.loop_count()) |id| {
            const holder = life.registry.get(@intCast(id));
            if (holder == core.mailbox.descriptor_none) continue;
            std.debug.print("a registry's life ends while id {d} is still held; a step of the " ++
                "scenario likely failed before that loop or remote ended\n", .{id});
        }
    }

    /// Fails when the process holds a different count of open descriptors than when the life began.
    pub fn check(life: RegistryLife) error{DescriptorsLeft}!void {
        if (open_descriptors() != life.descriptors_open) return error.DescriptorsLeft;
    }
};

/// True when a scenario began a registry's life and has not ended it.
pub fn life_open() bool {
    return lives_open.load(.acquire) != 0;
}

/// The descriptors open in this process below `constants.descriptors_counted_max`.
pub fn open_descriptors() u32 {
    var count: u32 = 0;
    for (0..constants.descriptors_counted_max) |descriptor| {
        if (is_open(@intCast(descriptor))) count += 1;
    }
    return count;
}

/// True when `descriptor` is open. On Linux this is the kernel's call, because the Linux test
/// executables link no C library.
fn is_open(descriptor: i32) bool {
    if (builtin.os.tag == .linux) {
        const rc = linux.fcntl(descriptor, linux.F.GETFD, 0);
        return linux.errno(rc) == .SUCCESS;
    }
    return std.c.fcntl(descriptor, std.c.F.GETFD) >= 0;
}

const testing = std.testing;
const conformance = @import("conformance.zig");

test "a harness refuses a loop on a registry whose life did not begin" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    var memory: [backend.Registry.memory_bytes(2)]u8 align(layout.memory_alignment) = undefined;
    registry.init(&memory, 2);
    var harness: conformance.Harness = undefined;
    try testing.expectError(error.RegistryNotStarted, harness.init(0, &registry));
    try testing.expectError(error.RegistryNotStarted, harness.init_blocking(0, &registry));
    // The harness of the reactor's scenarios refuses it too (decision 33).
    var reactor_harness: conformance.ReactorHarness = undefined;
    try testing.expectError(error.RegistryNotStarted, reactor_harness.init(0, &registry));
    try testing.expectError(error.RegistryNotStarted, reactor_harness.init_blocking(0, &registry));
}

test "a registry's life does not begin while another is open" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    var memory: [backend.Registry.memory_bytes(2)]u8 align(layout.memory_alignment) = undefined;
    const life = try RegistryLife.start(&registry, &memory, 2);
    defer life.end();
    var other: backend.Registry = undefined;
    try testing.expectError(error.RegistryNotEnded, RegistryLife.begin(&other));
}

/// A pipe has a read end and a write end.
const pipe_ends = 2;

fn open_pipe() ![pipe_ends]i32 {
    var ends: [pipe_ends]i32 = undefined;
    if (builtin.os.tag == .linux) {
        if (linux.errno(linux.pipe2(&ends, .{ .CLOEXEC = true })) != .SUCCESS) return error.NoPipe;
    } else if (std.c.pipe(&ends) != 0) return error.NoPipe;
    return ends;
}

fn close_one(descriptor: i32) void {
    if (builtin.os.tag == .linux) {
        _ = linux.close(descriptor);
    } else {
        _ = std.c.close(descriptor);
    }
}

test "the count of open descriptors sees a pipe opened and closed, and a wake the registry keeps" {
    if (conformance.unsupported()) return error.SkipZigTest;
    const before = open_descriptors();
    const ends = try open_pipe();
    try testing.expectEqual(before + pipe_ends, open_descriptors());
    for (ends) |end| close_one(end);
    try testing.expectEqual(before, open_descriptors());

    // A loop that ended leaves its wake to the registry, until the life ends.
    var registry: backend.Registry = undefined;
    var memory: [backend.Registry.memory_bytes(2)]u8 align(layout.memory_alignment) = undefined;
    const life = try RegistryLife.start(&registry, &memory, 2);
    defer life.end();
    var harness: conformance.Harness = undefined;
    try harness.init(0, &registry);
    harness.deinit();
    try testing.expectEqual(life.descriptors_open + 1, open_descriptors());
    try testing.expectError(error.DescriptorsLeft, life.check());
}
