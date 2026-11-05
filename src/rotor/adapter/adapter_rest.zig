//! The calls the adapter hands to `rest`, the `std.Io` the caller supplies (decision 22, "The rules
//! it keeps"). Each forwarder takes the adapter as its `userdata` and calls the same field of
//! `rest`'s table with `rest`'s own.
//!
//! The forwarders are built from `Io.VTable` at compile time, so a Zig release that adds, removes
//! or changes a call changes them with it, and a call the adapter runs itself is named in
//! `adapter.zig` alone.
const std = @import("std");
const Io = std.Io;
const adapter_module = @import("adapter.zig");

/// The calls of the table, by how many parameters they take, `userdata` included. The widest
/// call of Zig 0.16.0's table takes six.
const Arity = enum(usize) { one = 1, two, three, four, five, six };

/// A parameter's position after `userdata`, which is position 0.
const Position = enum(usize) { first = 1, second, third, fourth, fifth };

fn rest_of(userdata: ?*anyopaque) Io {
    const adapter: *adapter_module.Adapter = @ptrCast(@alignCast(userdata.?));
    return adapter.rest;
}

fn Function(comptime name: []const u8) std.builtin.Type.Fn {
    return @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
}

/// The type of the parameter at `position` of the call `name`.
fn Parameter(comptime name: []const u8, comptime position: Position) type {
    return Function(name).params[@intFromEnum(position)].type.?;
}

/// The forwarder for the call `name` of `Io.VTable`.
pub fn forwarder(comptime name: []const u8) @FieldType(Io.VTable, name) {
    const R = Function(name).return_type.?;
    const arity: Arity = @enumFromInt(Function(name).params.len);
    return switch (arity) {
        .one => &struct {
            fn call(userdata: ?*anyopaque) R {
                const rest = rest_of(userdata);
                return @field(rest.vtable.*, name)(rest.userdata);
            }
        }.call,
        .two => &struct {
            fn call(userdata: ?*anyopaque, a: Parameter(name, .first)) R {
                const rest = rest_of(userdata);
                return @field(rest.vtable.*, name)(rest.userdata, a);
            }
        }.call,
        .three => &struct {
            fn call(userdata: ?*anyopaque, a: Parameter(name, .first), b: Parameter(name, .second)) R {
                const rest = rest_of(userdata);
                return @field(rest.vtable.*, name)(rest.userdata, a, b);
            }
        }.call,
        .four => &struct {
            fn call(
                userdata: ?*anyopaque,
                a: Parameter(name, .first),
                b: Parameter(name, .second),
                c: Parameter(name, .third),
            ) R {
                const rest = rest_of(userdata);
                return @field(rest.vtable.*, name)(rest.userdata, a, b, c);
            }
        }.call,
        .five => &struct {
            fn call(
                userdata: ?*anyopaque,
                a: Parameter(name, .first),
                b: Parameter(name, .second),
                c: Parameter(name, .third),
                d: Parameter(name, .fourth),
            ) R {
                const rest = rest_of(userdata);
                return @field(rest.vtable.*, name)(rest.userdata, a, b, c, d);
            }
        }.call,
        .six => &struct {
            fn call(
                userdata: ?*anyopaque,
                a: Parameter(name, .first),
                b: Parameter(name, .second),
                c: Parameter(name, .third),
                d: Parameter(name, .fourth),
                e: Parameter(name, .fifth),
            ) R {
                const rest = rest_of(userdata);
                return @field(rest.vtable.*, name)(rest.userdata, a, b, c, d, e);
            }
        }.call,
    };
}

const testing = std.testing;

test "every call of the table has a forwarder of its arity" {
    inline for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        const forward = comptime forwarder(field.name);
        try testing.expect(@TypeOf(forward) == field.type);
    }
}
