//! What each network call of the adapter returns for a loop's failure code or a `sync` error: the
//! nearest error of the call's own `std.Io` set, and `Unexpected` where it has none.
const std = @import("std");
const net = std.Io.net;
const rotor = @import("../rotor.zig");

pub fn listen(failure: rotor.sync.ListenError) net.IpAddress.ListenError {
    return switch (failure) {
        error.AddressInUse => error.AddressInUse,
        error.AddressNotAvailable => error.AddressUnavailable,
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.DescriptorLimit => error.ProcessFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.AccessDenied, error.Unexpected => error.Unexpected,
    };
}

pub fn bind(failure: rotor.sync.ListenError) net.IpAddress.BindError {
    return switch (failure) {
        error.AddressInUse => error.AddressInUse,
        error.AddressNotAvailable => error.AddressUnavailable,
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.DescriptorLimit => error.ProcessFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.AccessDenied, error.Unexpected => error.Unexpected,
    };
}

pub fn socket(failure: rotor.sync.SocketError) net.IpAddress.ConnectError {
    return switch (failure) {
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.DescriptorLimit => error.ProcessFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.Unexpected => error.Unexpected,
    };
}

pub fn connect(code: rotor.Code) net.IpAddress.ConnectError {
    return switch (code) {
        .connection_refused => error.ConnectionRefused,
        .connection_reset => error.ConnectionResetByPeer,
        .network_unreachable => error.NetworkUnreachable,
        .timeout, .connection_timed_out => error.Timeout,
        .system_resources => error.SystemResources,
        .would_block => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub fn accept(code: rotor.Code) net.Server.AcceptError {
    return switch (code) {
        .descriptor_limit => error.ProcessFdQuotaExceeded,
        .system_resources => error.SystemResources,
        .connection_aborted => error.ConnectionAborted,
        .would_block => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub fn read(code: rotor.Code) net.Stream.Reader.Error {
    return switch (code) {
        .connection_reset, .connection_aborted => error.ConnectionResetByPeer,
        .timeout, .connection_timed_out => error.Timeout,
        .not_connected => error.SocketUnconnected,
        .system_resources => error.SystemResources,
        .network_unreachable => error.NetworkDown,
        else => error.Unexpected,
    };
}

pub fn write(code: rotor.Code) net.Stream.Writer.Error {
    return switch (code) {
        .connection_reset, .connection_aborted => error.ConnectionResetByPeer,
        // std's own `netWrite` answers EPIPE so.
        .broken_pipe, .not_connected => error.SocketUnconnected,
        .system_resources => error.SystemResources,
        .network_unreachable => error.NetworkUnreachable,
        .connection_refused => error.ConnectionRefused,
        else => error.Unexpected,
    };
}

pub fn send(code: rotor.Code) net.Socket.SendError {
    return switch (code) {
        .message_too_long => error.MessageOversize,
        .system_resources => error.SystemResources,
        .network_unreachable => error.NetworkUnreachable,
        .connection_refused => error.ConnectionRefused,
        .connection_reset => error.ConnectionResetByPeer,
        .not_connected => error.SocketUnconnected,
        else => error.Unexpected,
    };
}

pub fn shutdown(code: rotor.Code) net.ShutdownError {
    return switch (code) {
        .connection_aborted => error.ConnectionAborted,
        .connection_reset => error.ConnectionResetByPeer,
        .not_connected => error.SocketUnconnected,
        .system_resources => error.SystemResources,
        else => error.Unexpected,
    };
}

const testing = std.testing;

test "every failure code of a read maps to an error of the read's own set" {
    inline for (@typeInfo(rotor.Code).@"enum".fields) |field| {
        const code: rotor.Code = @enumFromInt(field.value);
        try testing.expect(@errorName(read(code)).len != 0);
        try testing.expect(@errorName(write(code)).len != 0);
        try testing.expect(@errorName(connect(code)).len != 0);
        try testing.expect(@errorName(accept(code)).len != 0);
        try testing.expect(@errorName(send(code)).len != 0);
        try testing.expect(@errorName(shutdown(code)).len != 0);
    }
    try testing.expectEqual(error.ConnectionResetByPeer, read(.connection_reset));
    try testing.expectEqual(error.SocketUnconnected, write(.broken_pipe));
    try testing.expectEqual(error.ConnectionRefused, connect(.connection_refused));
    try testing.expectEqual(error.Timeout, connect(.timeout));
}
