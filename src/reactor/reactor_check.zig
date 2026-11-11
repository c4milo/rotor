//! The check that `Reactor(Loop)` makes at comptime, before it makes anything (decision 33, "How a
//! twin's author learns the port"). It collects each name that `Loop` lacks: the names of the
//! core's surface, the names of the port, and the calls of the line that `heartbeat_line` returns.
//! It stops the build with one compile error that names them all, so the author of a twin of
//! decision 10 adds them in one pass. Split from `reactor.zig` for the 500-line limit.
//!
//! The check sees names, not signatures. A wrong signature fails where the reactor calls it.
const std = @import("std");
const core = @import("core");

/// A name the reactor needs, and what it is for.
const Need = struct { name: []const u8, what: []const u8 };

/// The port of decision 33, in the order of `core.surface.port_declarations`. The words are part of
/// the port's documentation: a change to the port changes them in the same commit.
const port_needs = [_]Need{
    .{ .name = "tick_backend", .what = "the backend's tick, with no check of a kept error" },
    .{ .name = "take_kept_error", .what = "returns the kept error once, and lowers outstanding" },
    .{ .name = "outstanding", .what = "a pointer to the word that takes a tick off the fast path" },
    .{ .name = "stored_limit", .what = "a pointer to the stored limit, which only the reactor writes" },
    .{ .name = "heartbeat_line", .what = "the line on which the reactor names each callback" },
    .{ .name = "push_reserved", .what = "a call or a return into a ring's kept slots, then the wake" },
    .{ .name = "assert_owner", .what = "the owner check (class B)" },
};

/// The calls that the reactor makes on the line that `heartbeat_line` returns (decision 33,
/// amendment of 2026-11-10). `name_poller` joins them at step 3.
const line_needs = [_]Need{
    .{ .name = "enter", .what = "before each callback" },
    .{ .name = "leave", .what = "after the records of a tick" },
    .{ .name = "leave_polling", .what = "after the pollers of a tick" },
    .{ .name = "leave_tasks", .what = "after a run of tasks" },
    .{ .name = "leave_group_tasks", .what = "after a run of the scheduling groups" },
};

comptime {
    // Each name of the port has its words here, so a name that joins the port needs them.
    std.debug.assert(port_needs.len == core.surface.port_declarations.len);
    for (port_needs, core.surface.port_declarations) |need, name| {
        std.debug.assert(std.mem.eql(u8, need.name, name));
    }
}

/// The last line of the message, which says what to pass.
const advice = "A program passes rotor.Loop. A twin of decision 10 declares each name " ++
    "(decision 33, \"The port\").";

/// Stops the build when `Loop` lacks a name that the reactor needs, and names each one.
pub fn check(comptime Loop: type) void {
    if (comptime message(Loop)) |text| @compileError(text);
}

/// The message of `check`, or null when `Loop` declares each name. Each name it lacks is one line.
pub fn message(comptime Loop: type) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        const lines = surface_lines(Loop) ++ port_lines(Loop) ++ line_lines(Loop);
        if (lines.len == 0) return null;
        return heading(Loop, std.mem.count(u8, lines, "\n")) ++ lines ++ "\n" ++ advice;
    }
}

/// The first line of the message, for `count` names that `Loop` lacks.
fn heading(comptime Loop: type, comptime count: usize) []const u8 {
    const noun = if (count == 1) "declaration" else "declarations";
    return std.fmt.comptimePrint("rotor.Reactor({s}): the type lacks {d} {s} that the reactor needs:", .{
        @typeName(Loop), count, noun,
    });
}

/// One line for each name of the core's surface that `Loop` lacks.
fn surface_lines(comptime Loop: type) []const u8 {
    var lines: []const u8 = "";
    for (core.surface.loop_declarations) |name| {
        if (@hasDecl(Loop, name)) continue;
        lines = lines ++ "\n  " ++ name ++ ": a name of the core's surface (core/surface.zig)";
    }
    return lines;
}

/// One line for each name of the port that `Loop` lacks.
fn port_lines(comptime Loop: type) []const u8 {
    var lines: []const u8 = "";
    for (port_needs) |need| {
        if (@hasDecl(Loop, need.name)) continue;
        lines = lines ++ "\n  " ++ need.name ++ ": " ++ need.what;
    }
    return lines;
}

/// One line for each call that the line of `Loop.heartbeat_line` lacks. A loop that lacks
/// `heartbeat_line` has no line to check: `port_lines` names it.
fn line_lines(comptime Loop: type) []const u8 {
    if (!@hasDecl(Loop, "heartbeat_line")) return "";
    const Line = line_of(Loop);
    var lines: []const u8 = "";
    for (line_needs) |need| {
        if (Line != void and @hasDecl(Line, need.name)) continue;
        lines = lines ++ "\n  heartbeat_line()." ++ need.name ++ ": a call of the line, " ++ need.what;
    }
    return lines;
}

/// The type of the line that `Loop.heartbeat_line` points to, or `void` when it returns no pointer
/// to a type that can declare a call.
fn line_of(comptime Loop: type) type {
    const function = @typeInfo(@TypeOf(Loop.heartbeat_line));
    if (function != .@"fn") return void;
    const returned = function.@"fn".return_type orelse return void;
    const pointer = @typeInfo(returned);
    if (pointer != .pointer or pointer.pointer.size != .one) return void;
    return switch (@typeInfo(pointer.pointer.child)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => pointer.pointer.child,
        else => void,
    };
}

const testing = std.testing;

/// A line that lacks `leave_tasks`.
const ShortLine = struct {
    pub fn enter() void {}
    pub fn leave() void {}
    pub fn leave_polling() void {}
    pub fn leave_group_tasks() void {}
};

/// Five names of the port, over a line that lacks one call, and no name of the core's surface.
const Partial = struct {
    pub fn tick_backend() void {}
    pub fn take_kept_error() void {}
    pub fn outstanding() void {}
    pub fn heartbeat_line() *ShortLine {
        unreachable;
    }
    pub fn assert_owner() void {}
};

test "the message names each name that the type lacks, with its words, and only those" {
    const text = comptime message(Partial).?;
    comptime var expected: []const u8 = heading(Partial, core.surface.loop_declarations.len + 3);
    inline for (core.surface.loop_declarations) |name| {
        expected = expected ++ "\n  " ++ name ++ ": a name of the core's surface (core/surface.zig)";
    }
    expected = expected ++
        "\n  stored_limit: a pointer to the stored limit, which only the reactor writes" ++
        "\n  push_reserved: a call or a return into a ring's kept slots, then the wake" ++
        "\n  heartbeat_line().leave_tasks: a call of the line, after a run of tasks\n" ++ advice;
    try testing.expectEqualStrings(expected, text);
}

test "the first line names the type and the count, and one name is one declaration" {
    try testing.expectEqualStrings(
        "rotor.Reactor(reactor_check.Partial): the type lacks 46 declarations that the reactor needs:",
        heading(Partial, 46),
    );
    try testing.expectEqualStrings(
        "rotor.Reactor(reactor_check.Partial): the type lacks 1 declaration that the reactor needs:",
        heading(Partial, 1),
    );
}

/// A `heartbeat_line` that returns no pointer to a line.
const NoLine = struct {
    pub fn heartbeat_line() void {}
};

test "a heartbeat_line that returns no line lacks each call of the line" {
    const text = comptime message(NoLine).?;
    inline for (line_needs) |need| {
        try testing.expect(std.mem.indexOf(u8, text, "\n  heartbeat_line()." ++ need.name ++ ": ") != null);
    }
    const names = core.surface.loop_declarations.len + port_needs.len - 1 + line_needs.len;
    try testing.expect(std.mem.startsWith(u8, text, heading(NoLine, names)));
}

test "a type with nothing lacks each name of the surface and of the port, and has no line" {
    const Empty = struct {};
    const text = comptime message(Empty).?;
    const names = core.surface.loop_declarations.len + port_needs.len;
    try testing.expect(std.mem.startsWith(u8, text, heading(Empty, names)));
    try testing.expect(std.mem.indexOf(u8, text, "heartbeat_line().") == null);
    try testing.expect(std.mem.endsWith(u8, text, "\n" ++ advice));
}
