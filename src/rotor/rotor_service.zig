//! The cross-core call of decision 32, as the public module names it: a `Service` is one kind of
//! call, and a `CallRecord` is the caller's record of one call. Both take the public `SharedLoop`,
//! which a library holds, so a thread that holds only a `Remote` cannot call. `core/call/` holds
//! the design and the code.
const core = @import("core");
const loop_module = @import("rotor_loop.zig");

const SharedLoop = loop_module.SharedLoop;

/// One kind of call: a context, a request type, a reply type and a handler. The program declares
/// it once, as a static, and the loop of each core that serves it calls `serve` before its first
/// tick. The handler takes `*CallRecord(Request, Reply)`.
pub fn Service(
    comptime Context: type,
    comptime Request: type,
    comptime Reply: type,
    comptime handler: fn (context: *Context, call: *CallRecord(Request, Reply)) Answer(Reply),
) type {
    return core.call.Service(SharedLoop, Context, Request, Reply, handler);
}

/// The caller's record of one call, in the caller's struct. Size 64 B + `Request` + `Reply`.
pub fn CallRecord(comptime Request: type, comptime Reply: type) type {
    return core.call.CallRecord(SharedLoop, Request, Reply);
}

/// What a handler returns: `.now` with the reply, or `.later` and an `answer` after it.
pub const Answer = core.call.Answer;
/// What `finish` receives: `replied`, `expired` or `target_stopped`.
pub const CallResult = core.call.CallResult;
/// The group of a call, which has no default, and its deadline.
pub const CallOptions = core.call.CallOptions;
/// Why `send` sent nothing.
pub const CallError = core.call.CallError;
