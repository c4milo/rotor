//! `Event`, what `tick` hands the caller for each completion (decision 1): 16 bytes, so a reap of
//! 32 events reads 512 contiguous bytes. It is the kernel's completion entry with rotor's error
//! mapping applied.
//!
//! `result` is a count, a descriptor or 0 when it is not negative, and the negation of a `Code`
//! when it is. A backend maps the kernel's errno to a `Code` at reap, on the branch that an
//! operation that succeeded never takes. `outcome` turns the pair into a Zig error union.
//!
//! The flag bits `buffer`, `more` and `buffer_id` sit where io_uring puts `IORING_CQE_F_BUFFER`,
//! `IORING_CQE_F_MORE` and the buffer id, so the uring reap masks the kernel's flags and does not
//! re-encode them. The uring backend pins that equality at comptime; nothing here names a kernel
//! type.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// Why an operation failed. The values are positive and fit `u8`; `Event.result` holds the
/// negation. Append only: a value, once published, keeps its meaning.
pub const Code = enum(u8) {
    /// A `cancel` won and nothing was transferred (decision 5, rule 2).
    canceled = 1,
    /// The operation's own deadline passed and nothing was transferred (decision 5, rule 4).
    timeout,
    /// The kernel refused transiently more than `transfer_retries_max` times.
    would_block,
    /// ENOMEM or ENOBUFS: the kernel had no memory for the operation.
    system_resources,
    /// EMFILE or ENFILE: an accept found no free descriptor.
    descriptor_limit,
    connection_reset,
    connection_refused,
    connection_aborted,
    /// The peer stopped answering: TCP's own timeout, not the operation's deadline.
    connection_timed_out,
    broken_pipe,
    not_connected,
    network_unreachable,
    input_output,
    no_space_left,
    /// A multishot receive found its buffer group empty. The operation ended.
    buffers_exhausted,
    /// A `post` found the target loop's mailbox full.
    mailbox_full,
    unexpected,
};

/// `Code` as a Zig error set, one error per code.
pub const Error = error{
    Canceled,
    Timeout,
    WouldBlock,
    SystemResources,
    DescriptorLimit,
    ConnectionReset,
    ConnectionRefused,
    ConnectionAborted,
    ConnectionTimedOut,
    BrokenPipe,
    NotConnected,
    NetworkUnreachable,
    InputOutput,
    NoSpaceLeft,
    BuffersExhausted,
    MailboxFull,
    Unexpected,
};

/// 16 bytes, aligned to 8. `user_data` first, so an array of events reads in order.
pub const Event = extern struct {
    /// The value the caller put in the `Operation`. For a message, the payload.
    user_data: u64,
    /// Not negative: a byte count, a new descriptor, or 0. Negative: `-@intFromEnum(Code)`. For a
    /// message, the tag, as its 32 bits.
    result: i32,
    flags: Flags,

    pub const Flags = packed struct(u32) {
        /// `buffer_id` names the provided buffer that holds the bytes of this receive.
        buffer: bool = false,
        /// More events of this operation follow, and its slot stays claimed. An event without
        /// this flag is the operation's final event (decision 5, rule 1).
        more: bool = false,
        reserved_kernel: u2 = 0,
        /// Another loop posted this event. It belongs to no operation of this loop.
        message: bool = false,
        reserved: u11 = 0,
        buffer_id: u16 = 0,
    };

    /// The final event of an operation that succeeded with `count`.
    pub fn success(user_data: u64, count: u32) Event {
        assert(count <= constants.transfer_bytes_max);
        return .{ .user_data = user_data, .result = @intCast(count), .flags = .{} };
    }

    /// The final event of an operation that failed with `code`.
    pub fn failure(user_data: u64, code: Code) Event {
        const event: Event = .{ .user_data = user_data, .result = result_of(code), .flags = .{} };
        assert(event.result < 0);
        return event;
    }

    /// True when no further event of this operation follows.
    pub fn is_final(event: Event) bool {
        return !event.flags.more and !event.flags.message;
    }

    /// The result as a Zig error union: the count, or the error its code names.
    pub fn outcome(event: Event) Error!u32 {
        assert(!event.flags.message);
        if (event.result >= 0) return @intCast(event.result);
        return error_of(code_of(event.result));
    }
};

/// The `Event.result` that carries `code`.
pub fn result_of(code: Code) i32 {
    const result = -@as(i32, @intFromEnum(code));
    assert(result < 0);
    return result;
}

/// The code a negative `Event.result` carries.
pub fn code_of(result: i32) Code {
    assert(result < 0);
    assert(result >= -@as(i32, @intFromEnum(Code.unexpected)));
    return @enumFromInt(@as(u8, @intCast(-result)));
}

pub fn error_of(code: Code) Error {
    return switch (code) {
        .canceled => error.Canceled,
        .timeout => error.Timeout,
        .would_block => error.WouldBlock,
        .system_resources => error.SystemResources,
        .descriptor_limit => error.DescriptorLimit,
        .connection_reset => error.ConnectionReset,
        .connection_refused => error.ConnectionRefused,
        .connection_aborted => error.ConnectionAborted,
        .connection_timed_out => error.ConnectionTimedOut,
        .broken_pipe => error.BrokenPipe,
        .not_connected => error.NotConnected,
        .network_unreachable => error.NetworkUnreachable,
        .input_output => error.InputOutput,
        .no_space_left => error.NoSpaceLeft,
        .buffers_exhausted => error.BuffersExhausted,
        .mailbox_full => error.MailboxFull,
        .unexpected => error.Unexpected,
    };
}

comptime {
    assert(@sizeOf(Event) == constants.event_bytes);
    assert(@alignOf(Event) == @alignOf(u64));
    assert(@offsetOf(Event, "user_data") == 0);
    assert(@bitOffsetOf(Event.Flags, "buffer") == 0);
    assert(@bitOffsetOf(Event.Flags, "more") == 1);
    assert(@bitOffsetOf(Event.Flags, "buffer_id") == 16);
    assert(@typeInfo(Code).@"enum".fields.len == @typeInfo(Error).error_set.?.len);
    assert(@intFromEnum(Code.canceled) == 1);
}

const testing = std.testing;

test "a success carries its count and a failure carries its code, negated" {
    const done = Event.success(9, 4096);
    try testing.expectEqual(@as(u32, 4096), try done.outcome());
    try testing.expect(done.is_final());
    const refused = Event.failure(9, .connection_refused);
    try testing.expectEqual(@as(i32, -7), refused.result);
    try testing.expectError(error.ConnectionRefused, refused.outcome());
}

test "every code round-trips through a result and names its own error" {
    const fields = @typeInfo(Code).@"enum".fields;
    inline for (fields, 0..) |field, position| {
        const code: Code = @enumFromInt(field.value);
        try testing.expectEqual(position + 1, field.value);
        try testing.expectEqual(code, code_of(result_of(code)));
        // The error's name is the code's name in upper camel case, so the two lists stay in step.
        var name_buffer: [32]u8 = undefined;
        const error_name = @errorName(error_of(code));
        var length: usize = 0;
        for (error_name) |byte| {
            if (std.ascii.isUpper(byte) and length > 0) {
                name_buffer[length] = '_';
                length += 1;
            }
            name_buffer[length] = std.ascii.toLower(byte);
            length += 1;
        }
        try testing.expectEqualStrings(field.name, name_buffer[0..length]);
    }
}

test "the codes keep their published values" {
    // Append only: a consumer's deterministic twin writes these values, so none may move.
    const published = [_]Code{
        .canceled,             .timeout,          .would_block,        .system_resources,
        .descriptor_limit,     .connection_reset, .connection_refused, .connection_aborted,
        .connection_timed_out, .broken_pipe,      .not_connected,      .network_unreachable,
        .input_output,         .no_space_left,    .buffers_exhausted,  .mailbox_full,
        .unexpected,
    };
    try testing.expectEqual(@typeInfo(Code).@"enum".fields.len, published.len);
    for (published, 1..) |code, value| try testing.expectEqual(value, @intFromEnum(code));
}

test "an event flagged more or message is not final" {
    var event = Event.success(1, 0);
    event.flags.more = true;
    try testing.expect(!event.is_final());
    event.flags = .{ .message = true };
    try testing.expect(!event.is_final());
}
