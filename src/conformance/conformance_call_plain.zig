//! The calls of decision 32 beside the split of decision 33, on every backend: a reactor with no
//! poller that takes a call blocks again once its task ran, and a call to a plain loop of the same
//! registry is refused with `LoopNotFound`, so the plain loop, which has no hook, never takes it.
//! Split from `conformance_call.zig` for the 500-line limit.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const call = @import("conformance_call.zig");

const Event = core.Event;
const Harness = conformance.Harness;
const ReactorHarness = conformance.ReactorHarness;
const now_ns = backend.testing.monotonic_ns;

const ms = core.constants.ns_per_ms;
/// The wait of the tick that must block once the call's task ran, and the least time it may take.
const blocked_wait_ns = 20 * ms;
const blocked_least_ns = 10 * ms;

test "a reactor with no poller takes a call, runs its task, and then a tick with a wait blocks" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: call.Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    defer two.end();
    var tally: call.Tally = .{};
    var client = call.client_of(&two, &tally, 1);
    try client.send();
    var ticks: u32 = 0;
    while (tally.replied == 0 and ticks < call.ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, 1), tally.replied);
    // The target ran the handler's task and holds no call. It has no poller, so nothing bounds the
    // wait of its next tick: the hook stored no limit, and its last `end` stored none either.
    const target = &two.harnesses[1];
    try testing.expectEqual(@as(u32, 0), target.reactor.loop.tables.outstanding);
    try testing.expectEqual(core.WaitLimit.none, target.reactor.loop.tables.stored_limit);
    var events: [4]Event = undefined;
    const started_ns = now_ns();
    try testing.expectEqual(@as(u32, 0), try target.tick(&events, blocked_wait_ns));
    try testing.expect(now_ns() - started_ns >= blocked_least_ns);
}

var registry_memory: [backend.Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;

test "a call to a plain loop of the same registry is refused, and the plain loop does not halt" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, 2);
    defer life.end();
    var caller: ReactorHarness = undefined;
    try call.init_reactor(&caller, 0, &registry, &.empty);
    defer caller.deinit();
    var plain: Harness = undefined;
    try plain.init(1, &registry);
    defer plain.deinit();
    var service: call.EchoService = .init;
    var tally: call.Tally = .{};
    var client: call.Client = .{ .service = &service, .shared = caller.reactor.shared(), .target = 1, .tally = &tally };
    // The plain loop runs, so a post reaches it, and takes no calls, so a call does not (decision 33,
    // open question 12).
    try testing.expectError(error.LoopNotFound, client.send());
    try testing.expect(!client.call.is_out());
    try testing.expectEqual(@as(u32, 0), caller.reactor.loop.tables.outstanding);
    try testing.expectEqual(@as(u32, 0), registry.mailbox(0, 1).calls_out);
    // The plain loop's ring holds nothing, so its ticks take nothing, and it does not halt.
    try testing.expect(registry.mailbox(0, 1).is_empty());
    var events: [4]Event = undefined;
    for (0..3) |_| try testing.expectEqual(@as(u32, 0), try plain.tick(&events, 0));
}
