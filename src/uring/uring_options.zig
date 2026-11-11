//! The options of an io_uring loop, `Loop.Options`. Split from `uring.zig` for the 500-line limit.
const core = @import("core");

const Registry = core.mailbox.Registry;

pub const Options = struct {
    /// The most operations in flight, which is the slots in the table:
    /// [1, core.constants.operations_max].
    operations: u32,
    /// Submission ring entries, a power of two in [1, constants.entries_max], or 0 for the
    /// default: `operations` rounded up to a power of two and capped at `entries_max`. One
    /// tick submits at most this many operations; the rest wait for the next.
    entries: u16 = 0,
    /// How often the loop measures an operation (decision 9, rule 2).
    sampling: core.statistics.Options = .{},
    /// How long a tick polls without waiting before it blocks, in nanoseconds, at most
    /// `core.constants.spin_budget_ns_max` (decision 13). 0, the default, never polls. A loop
    /// with a budget answers a message that comes inside it without being woken, and spends
    /// the budget in CPU on every wait that outlasts it.
    spin_budget_ns: u64 = 0,
    /// A turn of the loop at or above this, in nanoseconds, counts as a stall in
    /// `statistics()`, and null counts none (decision 28). A host that sleeps in its own wait
    /// sets null, because its sleep reads as one long turn (decision 23).
    stall_turn_ns: ?u64 = core.constants.stall_turn_ns_default,
    /// This loop's id among the loops of `registry`.
    id: core.LoopId = 0,
    /// Where loops find each other's mailbox rings. Null for a loop that posts to none and
    /// that none posts to.
    registry: ?*Registry = null,
    /// **Checked and ignored** (decision 18). The kernel performs `read`, `write` and
    /// `fdatasync` and `fsync` without a thread here, which is the whole point of this backend, so there is
    /// nothing to hand out and no policy to apply. It is in the options so that a caller's
    /// options are the same on every backend, as `entries` is on the others. `init` checks it
    /// with `offload` and `offload_memory` as kqueue and epoll do
    /// (`core.offload.assert_options`), so options that halt there halt here.
    file_policy: core.offload.FilePolicy = .refuse,
    /// Checked and ignored, for the same reason as `file_policy`: required when `file_policy`
    /// is `offload`, and refused otherwise.
    offload: ?core.offload.Offload = null,
    /// Checked and ignored, for the same reason as `file_policy`. This backend holds no ring for
    /// an offload and asks for no memory for one, but under the `offload` policy it requires
    /// `core.offload.Offload.memory_bytes(offload.?.workers)` bytes, as epoll does.
    offload_memory: []align(core.layout.memory_alignment) u8 = &.{},
};
