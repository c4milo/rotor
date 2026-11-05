//! The four file calls on the loop (decision 22, step 3): `read`, `write`, `fsync` and `close`,
//! under the loop's file policy (decision 18).
//!
//! On kqueue and epoll a loop refuses a file operation unless its caller named a policy, and the
//! operation ends with `unsupported`. Then the adapter hands the same call to `rest`, by Camilo's
//! choice of 2026-11-05, so code that reads files works on any loop. A caller that wants files on
//! the loop names `blocking` or `offload`. io_uring runs them on the loop whatever the policy says.
//!
//! A read or a write moves one buffer, as `netRead` and `netWrite` do (`adapter_net.zig`).
const std = @import("std");
const Io = std.Io;
const File = Io.File;
const rotor = @import("../rotor.zig");
const adapter_module = @import("adapter.zig");
const scheduler = @import("adapter_scheduler.zig");
const network = @import("adapter_net.zig");

const unsupported_result: i32 = -@as(i32, @intFromEnum(rotor.Code.unsupported));

pub fn file_read_positional(userdata: ?*anyopaque, file: File, data: []const []u8, offset: u64) File.ReadPositionalError!usize {
    const adapter = adapter_module.from(userdata);
    const buffer = for (data) |buffer| {
        if (buffer.len != 0) break buffer;
    } else return 0;
    const result = try scheduler.perform(adapter, .{ .read = .{
        .file = file.handle,
        .buffer = .{ .bytes = buffer },
        .offset = offset,
    } }, 0);
    if (result == unsupported_result) {
        return adapter.rest.vtable.fileReadPositional(adapter.rest.userdata, file, data, offset);
    }
    if (result < 0) return read_error(code_of(result));
    return @intCast(result);
}

pub fn file_write_positional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    const adapter = adapter_module.from(userdata);
    const bytes = network.first_bytes(header, data, splat);
    if (bytes.len == 0) return 0;
    const result = try scheduler.perform(adapter, .{ .write = .{
        .file = file.handle,
        .buffer = .{ .bytes = bytes },
        .offset = offset,
    } }, 0);
    if (result == unsupported_result) {
        return adapter.rest.vtable.fileWritePositional(adapter.rest.userdata, file, header, data, splat, offset);
    }
    if (result < 0) return write_error(code_of(result));
    return @intCast(result);
}

pub fn file_sync(userdata: ?*anyopaque, file: File) File.SyncError!void {
    const adapter = adapter_module.from(userdata);
    const result = try scheduler.perform(adapter, .{ .fsync = .{ .file = file.handle } }, 0);
    if (result == unsupported_result) return adapter.rest.vtable.fileSync(adapter.rest.userdata, file);
    if (result < 0) return sync_error(code_of(result));
}

/// Closes each file on the loop. A close is no cancel point, and no file policy refuses it.
pub fn file_close(userdata: ?*anyopaque, files: []const File) void {
    const adapter = adapter_module.from(userdata);
    for (files) |file| {
        scheduler.submit(adapter, .{ .close = .{ .descriptor = file.handle } });
        scheduler.block(adapter, .operation, false);
    }
}

fn code_of(result: i32) rotor.Code {
    return @enumFromInt(@as(u8, @intCast(-result)));
}

fn read_error(code: rotor.Code) File.ReadPositionalError {
    return switch (code) {
        .input_output => error.InputOutput,
        .system_resources => error.SystemResources,
        .would_block => error.WouldBlock,
        else => error.Unexpected,
    };
}

fn write_error(code: rotor.Code) File.WritePositionalError {
    return switch (code) {
        .input_output => error.InputOutput,
        .no_space_left => error.NoSpaceLeft,
        .broken_pipe => error.BrokenPipe,
        .system_resources => error.SystemResources,
        .would_block => error.WouldBlock,
        else => error.Unexpected,
    };
}

fn sync_error(code: rotor.Code) File.SyncError {
    return switch (code) {
        .input_output => error.InputOutput,
        .no_space_left => error.NoSpaceLeft,
        else => error.Unexpected,
    };
}
