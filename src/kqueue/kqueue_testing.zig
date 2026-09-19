//! What the conformance suite needs from a backend beside its surface: a directory to make
//! files in, a number that tells this process's files from another's, and a way to remove a
//! file. Test support only: no path of the loop calls into this file.
const std = @import("std");
const assert = std.debug.assert;

/// Where the suite makes its files.
pub const directory = "/tmp";

pub fn process_id() u32 {
    const id = std.c.getpid();
    assert(id >= 1);
    return @intCast(id);
}

/// Removes the file at `path`. A file that is already gone is not an error: this runs from a
/// test's `defer`.
pub fn remove_file(path: [*:0]const u8) void {
    assert(path[0] != 0);
    _ = std.c.unlink(path);
}
