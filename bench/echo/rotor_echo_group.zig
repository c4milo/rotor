//! The provided-buffer group of `rotor_echo`: which group each loop draws from, and how many
//! buffers it holds. Split from `rotor_echo.zig` for the 500-line limit.
const std = @import("std");
const core = @import("core");

/// The provided-buffer group the multishot receives draw from: the first one each loop reserves,
/// which is id 0. The server is the only user of its loops, so it names that id as a constant, and
/// `serve` asserts that the loop gave it (decision 29).
pub const group_id: core.BufferGroup = @enumFromInt(0);

/// The count a group gets: `most` when nothing was asked for, and otherwise what was asked for,
/// which must be a power of two, as a buffer ring's size is, and no more than `most`. A count too
/// large is refused rather than cut down, so a run never measures a group it did not ask for.
pub fn group_buffers_from(wanted: ?u16, most: u16) !u16 {
    std.debug.assert(std.math.isPowerOfTwo(most));
    const asked = wanted orelse return most;
    if (asked == 0 or !std.math.isPowerOfTwo(asked)) return error.GroupBuffersNotPowerOfTwo;
    if (asked > most) return error.GroupBuffersBeyondPool;
    return asked;
}
