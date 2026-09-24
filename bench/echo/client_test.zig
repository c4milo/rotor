//! The tests of `client.zig`. They live beside it because the client and its tests together pass
//! the 500-line limit of CLAUDE.md. The client's own `test` block imports this file, so
//! `zig build test-bench-programs` runs them.
//!
//! The tests that run the client start `faulty_server.zig`, which does one thing wrong on purpose.
//! Each such run is two spans of one round per connection, so it takes milliseconds.
const std = @import("std");
const backend = @import("backend");
const harness = @import("harness");
const client = @import("client.zig");
const faulty_server = @import("faulty_server.zig");

const Options = client.Options;
const sync = backend.sync;
const testing = std.testing;

/// Connections the leak test opens, and a port nothing listens on. The port is high and odd enough
/// that a listener there would be somebody else's, and the test says so if one answers.
const leak_connections = 8;
const leak_port: u16 = 39_417;

test "a connect that fails closes every socket it had already opened" {
    if (!backend.supported) return error.SkipZigTest;
    // POSIX hands out the lowest free descriptor, so the number a fresh socket gets says whether
    // the run before it gave its own back. This is what catches the leak: `connect_all` opens one
    // socket per connection and returns on the first failure, so a `defer close_all()` below it
    // would strand every socket already opened, and the next probe would land `leak_connections`
    // higher. A run of the harness met that on 2026-09-22 and ran out of descriptors.
    const before = try sync.open_socket(.ipv4);
    sync.close_now(before);

    const options: Options = .{
        .port = leak_port,
        .connections = leak_connections,
        .seconds = 1,
        .warmup_seconds = 0,
    };
    // Nothing listens there, so every connect is refused and the run fails. A host where
    // something does answer would make this test pass for the wrong reason, so it is refused.
    const outcome = client.run(options);
    try testing.expectError(error.ConnectFailed, outcome);

    const after = try sync.open_socket(.ipv4);
    defer sync.close_now(after);
    try testing.expectEqual(before, after);
}

/// Connections a run against the faulty server opens: one pair, which `crossed` needs.
const pair = 2;

/// A payload that crosses loopback in one piece, and fits one receive of the faulty server.
const test_payload_bytes = 1024;

/// Runs the client against a server with `fault`, for one round per connection in each span, and
/// returns what the client returned. The server is stopped before this returns.
fn run_against(fault: faulty_server.Fault) !harness.report.Result {
    var server: faulty_server.Server = undefined;
    try server.start(fault);
    const outcome = client.run(.{
        .port = server.port,
        .connections = pair,
        .payload_bytes = test_payload_bytes,
        // A deadline that has passed when the first round ends: one round per connection.
        .seconds = 0,
        .warmup_seconds = 0,
    });
    try server.stop();
    return outcome;
}

test "a server that echoes every byte gives a row of every round" {
    if (!backend.supported) return error.SkipZigTest;
    // The row counts the measured span's rounds alone: one per connection. The warm-up's rounds are
    // the connections' first, which `compared` always picks, so this also proves that a round
    // compares what it sent.
    const result = try run_against(.none);
    try testing.expectEqual(@as(u64, pair), result.operations);
}

test "a server that closes its connections fails the run, and gives no row" {
    if (!backend.supported) return error.SkipZigTest;
    // Before 2026-09-24 every connection stopped, the span ended early, and the run returned a row
    // of 0 operations, which `echo_runner` fed into its series.
    try testing.expectError(error.CandidateClosed, run_against(.close));
}

test "a server that changes the bytes it echoes fails the run" {
    if (!backend.supported) return error.SkipZigTest;
    try testing.expectError(error.CandidateCorrupted, run_against(.corrupt));
}

test "a server that echoes one connection's bytes on another fails the run" {
    if (!backend.supported) return error.SkipZigTest;
    // Every byte count is right. Only the bytes tell the two connections apart, which the bytes
    // before 2026-09-24 did not: every connection sent the same ones. The pattern is emptied
    // first, so the run has to fill it: with every byte 0 the two connections look the same.
    @memset(&client.pattern, 0);
    try testing.expectError(error.CandidateCorrupted, run_against(.crossed));
}

test "every connection and each of its next rounds sends from a window of its own" {
    var seen: [client.windows]bool = @splat(false);
    var index: u32 = 0;
    while (index < client.connections_max) : (index += 1) {
        var round: u64 = 0;
        while (round < client.rounds_apart) : (round += 1) {
            const start = client.window_of(index, round);
            // A round of the largest payload fits the pattern from any window.
            try testing.expect(start + client.payload_bytes_max <= client.pattern.len);
            try testing.expectEqual(@as(usize, 0), start % client.window_step_bytes);
            const window = start / client.window_step_bytes;
            try testing.expect(!seen[window]);
            seen[window] = true;
        }
        // The windows repeat after `rounds_apart` rounds, and only then.
        try testing.expectEqual(client.window_of(index, 0), client.window_of(index, round));
    }
}

test "a round is compared first, then once in every compare_every" {
    try testing.expect(client.compared(0));
    try testing.expect(!client.compared(1));
    try testing.expect(!client.compared(client.compare_every - 1));
    try testing.expect(client.compared(client.compare_every));
    try testing.expect(client.compared(7 * client.compare_every));
}

/// Bytes of the pattern the shift test compares at each shift.
const shift_compare_bytes = 64;

test "the pattern does not repeat at any power-of-two shift a buffer could move a piece by" {
    // A server's buffers are powers of two, so a piece put back in the wrong buffer moves by one.
    // The bytes before 2026-09-24 repeated every 256, and hid every such move of 256 or more.
    client.fill_pattern();
    const head = client.pattern[0..shift_compare_bytes];
    var shift: usize = 1;
    while (shift <= client.payload_bytes_max) : (shift *= 2) {
        const moved = client.pattern[shift..][0..shift_compare_bytes];
        try testing.expect(!std.mem.eql(u8, head, moved));
    }
}
