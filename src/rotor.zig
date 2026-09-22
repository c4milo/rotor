//! rotor's public API: the one module a consumer imports.
//!
//! What a consumer needs is a `Loop`, the types it takes and returns, and the helpers that open a
//! socket and hand the loop its buffers. That is what this file names. What it does not name is
//! how a backend does its work — the submit, reap, perform and cancel paths, the mailbox, the
//! waiters, the test doubles — because none of that is anybody else's business and a name once
//! exported is a name that has to keep working.
//!
//! The backend is this host's: `uring` on Linux, `kqueue` on Darwin. Both carry the surface
//! `core/surface.zig` names (decision 1), so what a consumer writes is the same either way, and
//! the `check` at the bottom of this file fails the compile if the one this host chose has
//! drifted from it.
//!
//! A consumer that needs a backend this host did not choose — a deterministic twin, for replay
//! (decision 10) — writes a module carrying that surface and imports it instead of this one.
//! rotor exports no second backend for it to reach around to.
const builtin = @import("builtin");
const core = @import("core");
const uring = @import("uring");
const kqueue = @import("kqueue");

/// This host's backend. Private: a consumer reaches the parts of it named below, and nothing
/// else.
const backend = switch (builtin.os.tag) {
    .linux => uring,
    .macos, .ios, .tvos, .watchos, .visionos => kqueue,
    else => @compileError("rotor has no backend for this operating system"),
};

/// The loop. One belongs to one thread, holds no lock and starts no thread (decision 4).
pub const Loop = backend.Loop;

/// The registry a group of loops shares, for `post` between them.
pub const Registry = backend.Registry;

/// Opening, closing and naming a socket: the calls a caller makes before it has a loop, and the
/// ones a loop does not make for it.
pub const sync = backend.sync;

/// Registering buffers and providing buffer groups, including the sizes and the alignment a
/// caller's memory for them must have.
pub const buffers = backend.buffers;

/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Loop.Options.file_policy` and an offload mean anything here (decision 18).
pub const files_block = backend.files_block;

/// True when this backend's kernel is the one running. False in a cross build.
pub const supported = backend.supported;

// The types a caller builds operations from and reads events with.
pub const constants = core.constants;
pub const datagram = core.datagram;
pub const layout = core.layout;
pub const offload = core.offload;
pub const statistics = core.statistics;

pub const Address = core.Address;
pub const Code = core.Code;
pub const Delivery = core.Delivery;
pub const Descriptor = core.Descriptor;
pub const Error = core.Error;
pub const Event = core.Event;
pub const Handle = core.Handle;
pub const LoopId = core.LoopId;
pub const Message = core.Message;
pub const Operation = core.Operation;

comptime {
    // The host's backend carries the surface every backend must (decision 1). The backends check
    // this for themselves; checking it here as well is what makes this file's promise its own.
    core.surface.check(Loop);
}
