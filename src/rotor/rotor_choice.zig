//! The backend a process chose on Linux, kept for the life of the process (decision 20, open
//! question 5). It is the one value rotor keeps outside the memory a caller hands it, and the one
//! container-level `var` under `src/` that every thread shares. The global-state lint rule reads
//! every file under `src/` but this one (`tools/lint/global_state.zig`).
//!
//! It is shared on purpose. A `threadlocal` copy would let each thread ask the kernel for itself,
//! and a seccomp filter installed between two asks would split one process's loops and sockets
//! between io_uring and epoll, which cannot post to each other. So the first answer stored is the
//! one every thread gets, and it is an atomic written once.
const std = @import("std");
const assert = std.debug.assert;

/// What `load` answers before any thread stored a choice.
pub const undecided: u8 = std.math.maxInt(u8);

/// The stored choice, as a backend tag's value, or `undecided`.
var linux_choice: std.atomic.Value(u8) align(@alignOf(std.atomic.Value(u8))) = .init(undecided);

/// The choice stored, or `undecided` before any thread stored one.
pub fn load() u8 {
    return linux_choice.load(.acquire);
}

/// Stores `decided` unless another thread stored a choice first, and returns the choice that
/// stands. Two threads that decide at once both call this, and both get the first one stored.
pub fn settle(decided: u8) u8 {
    assert(decided != undecided);
    const stored = linux_choice.cmpxchgStrong(undecided, decided, .acq_rel, .acquire);
    const standing = stored orelse decided;
    assert(standing != undecided);
    return standing;
}

/// Replaces the stored choice, for a test that plants one and restores it after.
pub fn plant(value: u8) void {
    assert(@import("builtin").is_test);
    linux_choice.store(value, .release);
}
