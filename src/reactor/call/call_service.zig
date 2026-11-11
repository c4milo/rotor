//! The functions of the typed surface of the cross-core call (decision 32): `Service`, one kind of
//! call, and `CallRecord`, the caller's record of one call. Each reactor type declares both over its
//! own view, so the compiler prints `reactor.Reactor(kqueue.Loop).Service(...)` (decision 33,
//! "Where each type is declared"), and each of their methods is an alias of a function here. A
//! test declares its own over a model loop. A `View` has `call`, `answer`, `serve`,
//! `stop_serving`, `now_ns` and `is_scheduled`.
//!
//! The compiler checks the types: a request, a reply or a context of the wrong type, a handler or a
//! `finish` with the wrong signature, and `.now` with no reply fail to compile.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("../constants.zig");
const call_module = @import("call.zig");
const call_take = @import("call_take.zig");
const reactor_module = @import("../reactor.zig");

const Answer = reactor_module.Answer;
const CallError = call_module.CallError;
const CallLink = reactor_module.CallLink;
const CallOptions = reactor_module.CallOptions;
const CallResult = reactor_module.CallResult;
const CallStation = reactor_module.CallStation;
const LoopId = core.LoopId;
const Task = reactor_module.Task;

/// The functions of `Record`, the caller's record of one call, in the caller's struct: a struct
/// with the fields `link`, `request` and `reply`. Size 64 B + `Request` + `Reply`, alignment 8 or
/// more. Its link holds the call's task and the pointer to the count of the pair.
pub fn CallRecord(comptime Record: type, comptime View: type, comptime Request: type, comptime Reply: type) type {
    comptime assert(@FieldType(Record, "link") == CallLink);
    comptime assert(@FieldType(Record, "request") == Request);
    comptime assert(@FieldType(Record, "reply") == Reply);
    return struct {
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
                    .name = core.stall.name_of(Parent, field),
                    .function = function,
                    .call_record = true,
                };
            };
            return .{ .link = CallLink.idle(&Static.call), .request = undefined, .reply = undefined };
        }

        /// True from a `send` that returned success until its `finish` starts. The program must
        /// not touch the request or the reply while it is true.
        pub fn is_out(record: *const Record) bool {
            return record.link.sent;
        }

        /// Target side: the request, from the handler's start until the answer.
        pub fn request_of(record: *const Record) *const Request {
            assert(record.link.state == .held);
            return &record.request;
        }

        /// Target side, after the handler returned `.later`: answers once, on the target's thread.
        /// A second answer halts, and so does an answer through another loop. Both checks come
        /// before the reply is written, so a halt leaves the record as it was.
        pub fn answer(record: *Record, shared: *View, reply: *const Reply) void {
            // `is_scheduled` checks that the loop's own thread calls it (class B). A held call's
            // task is not queued: it ran the handler.
            assert(!shared.is_scheduled(&record.link.task));
            assert(record.link.state == .held);
            record.reply = reply.*;
            record.link.outcome = .replied;
            shared.answer(&record.link);
        }
    };
}

/// The functions of `This`, one kind of call: a context, a request type, a reply type and a
/// handler. `This` is a struct with the field `stations`, the declaration `Call`, the record of one
/// call, and the declaration `entry`, the static entry that a call's task runs on the target, whose
/// function is `run`. Its name is the type's, which names the handler, so a stall of a handler
/// names the service. The program declares it once, as a static, and it holds one station for each loop.
/// Size 32 KiB at `loops_max` 256.
pub fn Service(
    comptime This: type,
    comptime View: type,
    comptime Context: type,
    comptime Request: type,
    comptime Reply: type,
    comptime handler: fn (context: *Context, call: *This.Call) Answer(Reply),
) type {
    comptime assert(@FieldType(This, "stations") == [constants.loops_max]CallStation);
    return struct {
        const Call = This.Call;
        const entry = &This.entry;

        /// The loop of `shared` serves this service with `context`. Its thread calls it before its
        /// first tick. It halts on a station that serves, and in a decision 21 group.
        pub fn serve(service: *This, shared: *View, context: *Context) void {
            const station = shared.serve(&service.stations);
            // The loop's `serve` returns a station of this service that serves (class B).
            assert(station.state == .serving);
            assert(@intFromPtr(station) - @intFromPtr(&service.stations) < @sizeOf(@TypeOf(service.stations)));
            station.context = context;
            station.loop = shared;
        }

        /// The loop of `shared` stops. A call that reaches it later gets `target_stopped`.
        pub fn stop_serving(service: *This, shared: *View) void {
            shared.stop_serving(&service.stations);
        }

        /// Sends `request` to loop `target`. On an error nothing was sent, and `finish` does not
        /// run. It halts when `call` is out already, on a target id that no loop may hold, and on
        /// a forged group id.
        pub fn send(
            service: *This,
            shared: *View,
            target: LoopId,
            call: *Call,
            request: *const Request,
            options: CallOptions,
        ) CallError!void {
            assert(target < constants.loops_max);
            // `prepare` halts on a record that is out, before the request is written.
            call.link.prepare(&service.stations, entry, target, options);
            call.request = request.*;
            return shared.call(&call.link);
        }

        /// The record's task on the target (decision 32, "The flow", step 4). A station that
        /// stopped answers `target_stopped`, and a deadline at or before `now_ns` answers
        /// `expired`. Otherwise the handler runs.
        pub fn run(task: *Task) void {
            // Only the record's task of this service runs it (class B).
            assert(task.call == entry);
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
                .now => |reply| call.answer(shared, &reply),
                .later => {},
            }
        }
    };
}
