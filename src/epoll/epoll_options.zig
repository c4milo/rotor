//! The options of an epoll loop, `Loop.Options`. Split from `epoll.zig` for the 500-line limit.
const core = @import("core");

const Registry = core.mailbox.Registry;

pub const Options = struct {
    /// The most operations in flight, which is the slots in the table:
    /// [1, core.constants.operations_max].
    operations: u32,
    /// What the uring backend sizes its submission ring by, or 0 for its default. This
    /// backend sizes nothing by it, and takes it so that a caller's options are the same on
    /// every backend.
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
    /// The program's named scheduling groups, which `init` reserves as ids 1 to n at their
    /// declared shares (decision 30). Empty by default. The public module sets it from the
    /// program's root file, so every loop of a program holds the same names.
    named_groups: core.scheduling.NamedTable = .empty,
    /// This loop's id among the loops of `registry`.
    id: core.LoopId = 0,
    registry: ?*Registry = null,
    /// What the loop does with `read`, `write` and `fdatasync`, which this backend cannot
    /// perform without blocking (decision 18). The uring backend checks it and ignores it.
    file_policy: core.offload.FilePolicy = .refuse,
    /// The caller's threads, required when `file_policy` is `offload` and refused otherwise.
    offload: ?core.offload.Offload = null,
    /// Memory for the offload's rings, of at least
    /// `offload_module.memory_bytes(offload.?.workers)`. The caller owns it because its own
    /// threads write it, as the application owns the registry's.
    offload_memory: []align(core.layout.memory_alignment) u8 = &.{},
};
