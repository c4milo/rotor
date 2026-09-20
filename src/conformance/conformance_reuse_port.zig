//! How a kernel spreads connections across several listeners that share one port, which is what
//! `SO_REUSEPORT` is for and what decision 4's `listener_per_core` shape rests on.
//!
//! Decision 4 recalls that Linux spreads and macOS does not, and says milestone 3 settles it
//! "with a test that counts accepts per socket". This is that test, and it lives in the
//! conformance suite rather than the harness because what it measures is a count and not a time:
//! a busy machine cannot corrupt it, so it runs under the same gates every other scenario does,
//! on whichever kernel the build gives it.
//!
//! It asserts only what both kernels must do: every connection is accepted exactly once, by
//! exactly one listener, and no connection is lost. **How** they are spread is recorded and not
//! asserted, because the two kernels differ and the difference is the finding. The scenario
//! prints the distribution it saw, so a run of the suite is also the measurement.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

/// Listeners sharing the port, which stands for one loop per core.
const listeners_count = 4;

/// Connections opened across them. Enough that an even kernel gives each listener several, and a
/// kernel that sends every connection to one listener is unmistakable.
const connections_count = 32;

/// A listener and what it accepted.
const Listener = struct {
    descriptor: core.Descriptor,
    accepted: u32 = 0,
};

/// Every listener shares one port, so the first one takes a port from the kernel and the rest
/// bind the port it was given.
fn open_all(listeners: *[listeners_count]Listener) !core.Address {
    const wildcard = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    listeners[0] = .{ .descriptor = try sync.listen(&wildcard, .{
        .backlog = connections_count,
        .reuse_port = true,
    }) };
    const address = try sync.local_address(listeners[0].descriptor);
    if (address.port == 0) return error.PortNotAssigned;
    for (listeners[1..]) |*listener| {
        listener.* = .{ .descriptor = try sync.listen(&address, .{
            .backlog = connections_count,
            .reuse_port = true,
        }) };
    }
    return address;
}

fn close_all(listeners: *[listeners_count]Listener) void {
    for (listeners) |listener| sync.close_now(listener.descriptor);
}

/// The index a completion's `user_data` names: one multishot accept per listener.
fn listener_of(user_data: u64) usize {
    return @intCast(user_data);
}

test "several listeners share one port, and every connection is accepted exactly once" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var listeners: [listeners_count]Listener = undefined;
    const address = open_all(&listeners) catch |failure| switch (failure) {
        // A kernel that refuses two listeners on one port cannot carry decision 4's shape at
        // all, which is a finding and not a failure of this suite.
        error.AddressInUse => return error.SkipZigTest,
        else => return failure,
    };
    defer close_all(&listeners);

    var accepts: [listeners_count]Operation = undefined;
    for (&accepts, 0..) |*accept, index| {
        accept.* = tcp.accept(index, listeners[index].descriptor, true);
    }
    try harness.submit(&accepts, &.{});

    var clients: [connections_count]core.Descriptor = undefined;
    var opened: usize = 0;
    defer for (clients[0..opened]) |client| sync.close_now(client);

    var accepted: [connections_count]core.Descriptor = undefined;
    var taken: u32 = 0;
    var events: [connections_count]Event = undefined;
    // One connection at a time, so a listener that is slow to be served cannot make the count
    // depend on the order the harness happened to tick in.
    while (opened < connections_count) : (opened += 1) {
        clients[opened] = try sync.open_socket(.ipv4);
        try harness.submit(&.{.{ .user_data = connections_count + opened, .kind = .{ .connect = .{
            .socket = clients[opened],
            .address = &address,
        } } }}, &.{});
        taken += try collect_one(&harness, &events, &listeners, accepted[taken..]);
    }

    // The accepts are multishot and still armed, and `deinit` requires an empty loop
    // (decision 5, rule 7).
    harness.loop.cancel_all();
    try harness.loop.drain(&events);

    // Every connection was accepted, once, by one listener.
    try testing.expectEqual(@as(u32, connections_count), taken);
    var total: u32 = 0;
    for (listeners) |listener| total += listener.accepted;
    try testing.expectEqual(@as(u32, connections_count), total);
    for (accepted[0..taken]) |descriptor| try testing.expect(descriptor >= 0);
    defer for (accepted[0..taken]) |descriptor| sync.close_now(descriptor);

    report(&listeners);
}

/// Ticks until this connection's accept and its connect have both been seen, and returns how
/// many accepts arrived. Counts them against their listener on the way.
fn collect_one(
    harness: *Harness,
    events: []Event,
    listeners: *[listeners_count]Listener,
    accepted: []core.Descriptor,
) !u32 {
    var taken: u32 = 0;
    var connected = false;
    var rounds: u32 = 0;
    while (!(connected and taken == 1) and rounds < conformance.collect_rounds_max) {
        rounds += 1;
        const count = try harness.loop.tick(events, 10 * core.constants.ns_per_ms);
        for (events[0..count]) |event| {
            if (event.user_data >= connections_count) {
                _ = try event.outcome();
                connected = true;
                continue;
            }
            const descriptor: core.Descriptor = @intCast(try event.outcome());
            listeners[listener_of(event.user_data)].accepted += 1;
            accepted[taken] = descriptor;
            taken += 1;
        }
    }
    if (!connected or taken != 1) return error.EventsMissing;
    return taken;
}

/// Prints what the kernel did, because the distribution is the finding and the assertions above
/// deliberately do not pin it.
fn report(listeners: *const [listeners_count]Listener) void {
    var lowest: u32 = std.math.maxInt(u32);
    var highest: u32 = 0;
    for (listeners) |listener| {
        lowest = @min(lowest, listener.accepted);
        highest = @max(highest, listener.accepted);
    }
    var served: u32 = 0;
    for (listeners) |listener| served += @intFromBool(listener.accepted != 0);
    std.debug.print(
        "\nSO_REUSEPORT on {s}: {d} connections over {d} listeners; {d} took any," ++
            " fewest {d}, most {d}. Per listener:",
        .{
            @tagName(@import("builtin").os.tag),
            connections_count,
            listeners_count,
            served,
            lowest,
            highest,
        },
    );
    for (listeners, 0..) |listener, index| {
        std.debug.print(" [{d}]={d}", .{ index, listener.accepted });
    }
    std.debug.print("\n", .{});
}
