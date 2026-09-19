//! The rows only Linux has: C7, C8 and C9 (io_uring submission and reap), C12 and C13 (O_DIRECT
//! NVMe reads) and C17 (`IORING_OP_MSG_RING`). Not written yet: this file is where they go.
//!
//! The file exists, with an empty list, because probes.zig names it and Zig resolves the path of
//! every `@import` when it parses a file, on every target. Filling this list is the whole change:
//! probes.zig sorts it in with the other rows when `builtin.os.tag` is `.linux`.
//!
//! A probe here has the shape of every other one: a `measure.Probe` whose `run` times its work
//! with `measure.sample` or `measure.sample_pairs` and hands back a `measure.Result`.
const measure = @import("../measure.zig");

pub const probes = [_]measure.Probe{};
