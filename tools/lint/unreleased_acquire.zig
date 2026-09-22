//! unreleased-acquire: a descriptor taken with `try` that nothing in its block releases, where a
//! statement under it can still fail. When that statement returns, the descriptor is lost. This is
//! the leak inside one function, where `defer_order.zig` reads the order of a cleanup already
//! written.
//!
//! The two rules found the same bug from opposite ends. `bench/echo/client.zig` opened one socket
//! per connection and lost every one of them when a connect failed, which killed a comparison run
//! out of descriptors on 2026-09-22. `defer-order` sees a cleanup registered too late;
//! this rule sees the acquire that has no cleanup at all.
//!
//! The acquire list names the calls of this tree that hand back a descriptor, and nothing else.
//! Every one is released by `close_now`, which the rule's default `close` prefix already covers.
//! The list is written out call by call rather than as the prefix `open`, because `open_flags`
//! returns flags and `open_how` fills a structure: neither owns anything, and a prefix would
//! report both. The rule reads names and not types, so the list is the whole of its precision.
//! `probe_descriptor` is left out for the same reason: it closes the socket it opened and hands
//! back the number, so a caller that closes what it returns closes a descriptor twice.
//!
//! `read_loop_reentry` is on, and it earns its keep: an acquire that ends a loop body has nothing
//! under it, so without this switch nothing in the acquire's own block could fail and the rule
//! passed it, while the next turn took another value and named the last one nowhere. That is
//! exactly the leak `bench/echo/rotor_echo.zig` had, where the listeners' cleanup sat below the
//! loop that opened them.
//!
//! It first reported `connect_all` in `bench/echo/client.zig` too, which opened a socket into a
//! local and then handed it to an entry it marked live. That window only stayed safe because
//! nothing fallible sat in it. The socket is now opened straight into the entry that owns it, so
//! there is no window and no finding; the rule pointed at something real rather than at itself.
//!
//! `Loop.init` and `Ring.init` are left out. Both are written `try loop.init(&memory)` against a
//! variable that already exists, so no declaration binds them and the rule cannot see them. Their
//! pairing with `deinit` is what the halt check covers (decision 5, rule 7: a loop must be empty
//! at `deinit`).
//!
//! The scope is `bench` alone, and `src` is left out on purpose. Run over `src` on 2026-09-22 the
//! rule reported four acquires and every one was in a test body, all of one deliberate shape: open
//! a descriptor, exercise it, close it, then assert that each call refuses the closed number. The
//! close is load-bearing there, so the window between the acquire and it cannot be covered by a
//! `defer`, and an `errdefer` would close a number that the next line of two of those tests
//! reopens. The library's own non-test code reported nothing: it already writes
//! `errdefer close_now(...)` under every acquire. A leak a failing test reaches costs a process
//! that is ending anyway, which is the reason `defer_order.zig` leaves `tools/` out.
//!
//! So this rule guards the harness, where the bug it is named for cost a real run. Widening it to
//! `src` means changing those four tests, and that is the owner's call.
//!
//! The rule is pepegrillo's `unreleased_acquire`. This file holds rotor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const unreleased_acquire = lint.rules.unreleased_acquire;

/// The calls of this tree that hand back a descriptor the block must close. Each is a whole name
/// and not a prefix of a family, for the reason the header gives.
const acquires = [_][]const u8{
    "open_socket",
    "open_datagram",
    "open_file",
    "listen",
    "socket_pair",
    "connected_pair",
};

pub const config: unreleased_acquire.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"bench"},
    },
    .acquire_prefixes = &acquires,
    .read_assignments = true,
    .read_loop_reentry = true,
    .read_subscript_targets = true,
};

const Rule = unreleased_acquire.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

/// The finding the rule reports for a lost `socket`, which the harness matches whole.
const socket_message = "socket is acquired here and a statement under it can fail," ++
    " and no defer releases socket";

test "unreleased-acquire passes a descriptor a defer closes" {
    try expect_findings("bench/echo/client.zig",
        \\pub fn connect_one(address: *const Address) !Descriptor {
        \\    const socket = try open_socket(address.family);
        \\    errdefer close_now(socket);
        \\    try connect_now(socket, address);
        \\    return socket;
        \\}
    , &.{});
}

test "unreleased-acquire reports a descriptor lost by the statement under it" {
    // This is `bench/echo/client.zig` as it stood when a comparison run died out of descriptors.
    try expect_findings("bench/echo/client.zig",
        \\pub fn connect_all(client: *Client) !void {
        \\    const socket = try open_socket(.ipv4);
        \\    try connect_now(socket, &client.address);
        \\}
    , &.{socket_message});
}

test "unreleased-acquire leaves a call that owns nothing alone" {
    // `open_flags` is the reason the acquire list is written out call by call: it returns flags.
    try expect_findings("bench/echo/client.zig",
        \\pub fn settings(socket: Descriptor) !Flags {
        \\    const flags = try open_flags(socket);
        \\    try check_socket(socket);
        \\    return flags;
        \\}
    , &.{});
}

test "unreleased-acquire reads bench, and leaves src and tools alone" {
    const leaking: [:0]const u8 =
        \\pub fn run() !void {
        \\    const socket = try open_socket(.ipv4);
        \\    try connect_now(socket, &address);
        \\}
    ;
    try expect_findings("bench/echo/client.zig", leaking, &.{socket_message});
    // `src` is out of scope for the reason the header gives, and this test holds it to that.
    try expect_findings("src/kqueue/kqueue_sync_socket.zig", leaking, &.{});
    try expect_findings("tools/lint/main.zig", leaking, &.{});
}

test "unreleased-acquire reads a loop that fills descriptors through a pointer" {
    // `read_assignments` is what makes this a finding: the acquire binds no name of its own, so
    // the rule reports the root of the target, `client`. This is the shape a loop uses to fill an
    // array of descriptors, and `tools/uring_probe_multishot.zig` has it. A subscript target,
    // `clients[index] = try open_socket(...)`, has no root to follow and the rule says so: it is
    // invisible either way, which is the limit of what this switch buys.
    try expect_findings("bench/echo/client.zig",
        \\pub fn connect_all(clients: []Descriptor) !void {
        \\    for (clients) |*client| {
        \\        client.* = try open_socket(.ipv4);
        \\        try connect_now(client.*, &address);
        \\    }
        \\}
    , &.{client_message});
}

/// The finding the rule reports for a descriptor assigned through `client`.
const client_message = "client is acquired here and a statement under it can fail," ++
    " and no defer releases client";

test "unreleased-acquire reads a subscript target, which has no root of its own" {
    // `read_subscript_targets` is what makes this a finding: the acquire binds no name, and the
    // target is an element, so the rule reports the array. Without the switch the whole statement
    // is invisible, which its header says plainly.
    try expect_findings("bench/echo/client.zig",
        \\pub fn connect_all(sockets: []Descriptor) !void {
        \\    sockets[0] = try open_socket(.ipv4);
        \\    try connect_now(sockets[0], &address);
        \\}
    , &.{sockets_message});
}

/// The finding the rule reports for a descriptor assigned into `sockets`.
const sockets_message = "sockets is acquired here and a statement under it can fail," ++
    " and no defer releases sockets";

test "unreleased-acquire reads an acquire that ends a loop body" {
    // `read_loop_reentry` is what makes this a finding. Nothing sits under the acquire inside its
    // own block, so without the switch the rule passed it while every turn dropped the last
    // descriptor. This is `bench/echo/rotor_echo.zig` as it stood before 2026-09-22, with the
    // cleanup below the loop instead of above it.
    try expect_findings("bench/echo/rotor_echo.zig",
        \\pub fn serve_all(loops: u32) !void {
        \\    var listeners: [8]Descriptor = undefined;
        \\    var opened: u32 = 0;
        \\    while (opened < loops) : (opened += 1) {
        \\        listeners[opened] = try listen(&address, .{});
        \\    }
        \\    defer for (listeners[0..loops]) |l| close_now(l);
        \\}
    , &.{listeners_message});
}

/// The finding the rule reports for listeners a loop opens and nothing above it releases.
const listeners_message = "listeners is acquired here and a statement under it can fail," ++
    " and no defer releases listeners";
