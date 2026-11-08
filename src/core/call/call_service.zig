//! The typed surface of the cross-core call (decision 32): `Service`, one kind of call, and
//! `CallRecord`, the caller's record of one call. Both are generic over `View`, the loop as a
//! library holds it, so the public module instantiates them with its `SharedLoop` and a test with
//! a model loop of its own. A `View` has `call`, `answer`, `serve`, `stop_serving` and `now_ns`.
//!
//! The compiler checks the types: a request, a reply or a context of the wrong type, a handler or a
//! `finish` with the wrong signature, and `.now` with no reply fail to compile.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const call_module = @import("call.zig");
const call_take = @import("call_take.zig");
const stall = @import("../stall.zig");
const Task = @import("../tasks.zig").Task;
const LoopId = @import("../operation.zig").LoopId;

const Answer = call_module.Answer;
const CallError = call_module.CallError;
const CallLink = call_module.CallLink;
const CallOptions = call_module.CallOptions;
const CallResult = call_module.CallResult;
const CallStation = call_module.CallStation;

/// The caller's record of one call, in the caller's struct. Size 64 B + `Request` + `Reply`,
/// alignment 8 or more. Its link holds the call's task and the pointer to the count of the pair.
pub fn CallRecord(comptime View: type, comptime Request: type, comptime Reply: type) type {
    return struct {
        const Record = @This();

        link: CallLink,
        request: Request,
        reply: Reply,

        /// A record at `field` of `Parent` whose `finish` runs exactly once for each `send` that
        /// returns success, in the call's task on the caller's loop. Its static `Task.Call` is
        /// named after `Parent` and `field`, so a stall of `finish` names the field.
        pub fn init(
            comptime Parent: type,
            comptime field: []const u8,
            comptime finish: fn (parent: *Parent, result: CallResult(Reply)) void,
        ) Record {
            comptime assert(@FieldType(Parent, field) == Record);
            const Static = struct {
                fn function(task: *Task) void {
                    const link: *CallLink = @alignCast(@fieldParentPtr("task", task));
                    const record: *Record = @alignCast(@fieldParentPtr("link", link));
                    const parent: *Parent = @alignCast(@fieldParentPtr(field, record));
                    const result: CallResult(Reply) = switch (call_module.end_call(link)) {
                        .replied => .{ .replied = &record.reply },
                        .expired => .expired,
                        .target_stopped => .target_stopped,
                    };
                    finish(parent, result);
                }
                const call: Task.Call = .{
                    .name = stall.name_of(Parent, field),
                    .function = function,
                    .call_record = true,
                };
            };
            return .{ .link = .idle(&Static.call), .request = undefined, .reply = undefined };
        }

        /// True from a `send` that returned success until its `finish` starts. The program must
        /// not touch the request or the reply while it is true.
        pub fn is_out(record: *const Record) bool {
            return record.link.state != .idle;
        }

        /// Target side: the request, from the handler's start until the answer.
        pub fn request_of(record: *const Record) *const Request {
            assert(record.link.state == .held);
            return &record.request;
        }

        /// Target side, after the handler returned `.later`: answers once, on the target's thread.
        /// A second answer halts, and so does an answer through another loop.
        pub fn answer(record: *Record, shared: *View, reply: Reply) void {
            assert(record.link.state == .held);
            record.reply = reply;
            record.link.outcome = .replied;
            shared.answer(&record.link);
        }
    };
}

/// One kind of call: a context, a request type, a reply type and a handler. The program declares
/// it once, as a static, and it holds one station for each loop. Size 32 KiB at `loops_max` 256.
pub fn Service(
    comptime View: type,
    comptime Context: type,
    comptime Request: type,
    comptime Reply: type,
    comptime handler: fn (context: *Context, call: *CallRecord(View, Request, Reply)) Answer(Reply),
) type {
    return struct {
        const This = @This();

        /// One station for each loop, indexed by `LoopId`. Program memory, 128 B each.
        stations: [constants.loops_max]CallStation,

        /// Every station unused.
        pub const init: This = .{ .stations = @splat(CallStation.unused) };
        pub const Call = CallRecord(View, Request, Reply);

        /// The static entry that a call's task runs on the target. Its name is this type's, which
        /// names the handler, so a stall of a handler names the service.
        pub const entry: Task.Call = .{ .name = @typeName(This), .function = run, .call_record = true };

        /// The loop of `shared` serves this service with `context`. Its thread calls it before its
        /// first tick. It halts on a station that serves, and in a decision 21 group.
        pub fn serve(service: *This, shared: *View, context: *Context) void {
            const station = shared.serve(&service.stations);
            station.context = context;
            station.loop = shared;
        }

        /// The loop of `shared` stops. A call that reaches it later gets `target_stopped`.
        pub fn stop_serving(service: *This, shared: *View) void {
            shared.stop_serving(&service.stations);
        }

        /// Sends `request` to loop `target`. On an error nothing was sent, and `finish` does not
        /// run. It halts when `call` is out already, and on a forged group id.
        pub fn send(
            service: *This,
            shared: *View,
            target: LoopId,
            call: *Call,
            request: Request,
            options: CallOptions,
        ) CallError!void {
            // `prepare` halts on a record that is out, before the request is written.
            call.link.prepare(&service.stations, &entry, target, options);
            call.request = request;
            return shared.call(&call.link);
        }

        /// The record's task on the target (decision 32, "The flow", step 4). A station that
        /// stopped answers `target_stopped`, and a deadline at or before `now_ns` answers
        /// `expired`. Otherwise the handler runs.
        fn run(task: *Task) void {
            const link: *CallLink = @alignCast(@fieldParentPtr("task", task));
            const call: *Call = @alignCast(@fieldParentPtr("link", link));
            const station = &link.stations[link.target];
            const shared: *View = @ptrCast(@alignCast(station.loop.?));
            if (call_take.verdict(link, shared.now_ns())) |outcome| {
                link.outcome = outcome;
                return shared.answer(link);
            }
            const context: *Context = @ptrCast(@alignCast(station.context.?));
            switch (handler(context, call)) {
                .now => |reply| call.answer(shared, reply),
                .later => {},
            }
        }
    };
}
