//! Halt scenarios for the `core` module: one per assertion a caller's mistake can reach, and one
//! per assertion a scenario reaches through a function's own parameters, as the made-up answers
//! handed to `file_call.result` do. Each name says what the scenario does wrong. How the tables end
//! an operation the loop answered itself is in `core_scenarios_finish.zig`.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");
const finish = @import("core_scenarios_finish.zig");
const spin = @import("core_scenarios_spin.zig");
const registry = @import("core_scenarios_registry.zig");

const Slot = core.Slot;
const SlotTable = core.slot_table.SlotTable;
const TimerHeap = core.timer_heap.TimerHeap;

const slots_count = 4;

var slots: [slots_count]Slot align(@alignOf(Slot)) = undefined;
var entries: [slots_count]TimerHeap.Entry align(@alignOf(TimerHeap.Entry)) = undefined;
var starts: [slots_count]u64 = undefined;

fn table() SlotTable {
    var result: SlotTable = undefined;
    result.init(&slots);
    return result;
}

/// A second slot stays claimed, so the table's count of free slots stays below its capacity and
/// the state check is the one assertion that can refuse the second release.
fn release_a_free_slot() void {
    var slot_table = table();
    const index = slot_table.claim().?;
    _ = slot_table.claim().?;
    slot_table.release(index);
    scenario.reached_violation();
    slot_table.release(index);
}

fn release_a_slot_with_a_deadline_armed() void {
    var slot_table = table();
    var heap: TimerHeap = undefined;
    heap.init(&entries, &slots);
    const index = slot_table.claim().?;
    heap.arm(index, 1);
    scenario.reached_violation();
    slot_table.release(index);
}

fn look_up_a_handle_outside_the_table() void {
    var slot_table = table();
    scenario.reached_violation();
    _ = slot_table.lookup(.{ .index = slots_count, .generation = 1 });
}

fn arm_a_slot_twice() void {
    var slot_table = table();
    var heap: TimerHeap = undefined;
    heap.init(&entries, &slots);
    const index = slot_table.claim().?;
    heap.arm(index, 1);
    scenario.reached_violation();
    heap.arm(index, 2);
}

fn disarm_a_slot_that_is_not_armed() void {
    var slot_table = table();
    var heap: TimerHeap = undefined;
    heap.init(&entries, &slots);
    const index = slot_table.claim().?;
    scenario.reached_violation();
    heap.disarm(index);
}

fn submit_a_transfer_of_no_bytes() void {
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .send = .{
        .socket = 3,
        .buffer = .{ .bytes = &.{} },
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

fn submit_a_timer_with_a_deadline_of_its_own() void {
    const operation: core.Operation = .{
        .user_data = 1,
        .timeout_ns = 1,
        .kind = .{ .timer = .{ .after_ns = 1 } },
    };
    scenario.reached_violation();
    operation.assert_valid();
}

fn post_a_tag_above_the_limit() void {
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .post = .{
        .target = 1,
        .message = .{ .payload = 0, .tag = core.constants.message_tag_max + 1 },
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

fn close_a_registered_descriptor() void {
    const operation: core.Operation = .{
        .user_data = 1,
        .descriptor_registered = true,
        .kind = .{ .close = .{ .descriptor = 0 } },
    };
    scenario.reached_violation();
    operation.assert_valid();
}

fn name_a_registered_descriptor_in_a_timer() void {
    const operation: core.Operation = .{
        .user_data = 1,
        .descriptor_registered = true,
        .kind = .{ .timer = .{ .after_ns = 1 } },
    };
    scenario.reached_violation();
    operation.assert_valid();
}

fn name_a_registered_descriptor_above_the_limit() void {
    const operation: core.Operation = .{
        .user_data = 1,
        .descriptor_registered = true,
        .kind = .{ .fdatasync = .{ .file = core.constants.registered_descriptors_max } },
    };
    scenario.reached_violation();
    operation.assert_valid();
}

const registered_count = 2;

/// Index 2 of a loop that registered 2 descriptors.
fn name_a_registered_descriptor_the_loop_lacks() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, .{});
    tables.note_descriptors(registered_count);
    const sync = [_]core.Operation{.{
        .user_data = 1,
        .descriptor_registered = true,
        .kind = .{ .fdatasync = .{ .file = registered_count } },
    }};
    scenario.reached_violation();
    _ = tables.submit(&sync, &.{});
}

fn register_descriptors_twice() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, .{});
    tables.note_descriptors(registered_count);
    scenario.reached_violation();
    tables.note_descriptors(registered_count);
}

/// Buffer 2 of a loop that registered 2 buffers. Until 2026-09-23 nothing checked the index: kqueue
/// and epoll ignored it, and io_uring handed the kernel an index it did not hold.
fn name_a_registered_buffer_the_loop_lacks() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, .{});
    tables.note_buffers(registered_count);
    var bytes: [16]u8 = undefined;
    const read = [_]core.Operation{core.Operation.read(1, 3, &bytes, 0)};
    var named = read;
    named[0].kind.read.buffer.registered = registered_count;
    scenario.reached_violation();
    _ = tables.submit(&named, &.{});
}

fn register_buffers_twice() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, .{});
    tables.note_buffers(registered_count);
    scenario.reached_violation();
    tables.note_buffers(registered_count);
}

fn register_no_buffers() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, .{});
    scenario.reached_violation();
    tables.note_buffers(0);
}

/// The plain send opcode takes no registered buffer, so naming one is refused rather than
/// ignored. Before the assertion existed the index was stored in the slot and read by nobody.
fn name_a_registered_buffer_in_a_send() void {
    var bytes: [16]u8 = undefined;
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .send = .{
        .socket = 3,
        .buffer = .{ .bytes = &bytes, .registered = 0 },
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

/// The same for a receive into a buffer the caller names. A receive from a group names no
/// buffer at all, so it cannot reach this.
fn name_a_registered_buffer_in_a_receive() void {
    var bytes: [16]u8 = undefined;
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .receive = .{
        .socket = 3,
        .target = .{ .buffer = .{ .bytes = &bytes, .registered = 0 } },
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

/// A registered buffer on a file transfer is legal, and its index must be one the loop can have
/// registered.
fn name_a_registered_buffer_above_the_limit() void {
    var bytes: [16]u8 = undefined;
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .write = .{
        .file = 3,
        .buffer = .{ .bytes = &bytes, .registered = core.constants.registered_buffers_max },
        .offset = 0,
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

/// A datagram lands in a group, and the group is one the loop can have. The shapes this used to
/// refuse — a single-shot receive, and one into a buffer the caller names — cannot be written
/// any more: `ReceiveFrom` names a group and nothing else, so the compiler refuses them and no
/// scenario is needed (decision 15).
fn receive_a_datagram_from_a_group_above_the_limit() void {
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .receive_from = .{
        .socket = 3,
        .group = core.constants.buffer_groups_max,
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

/// A datagram send says where it goes: a peer, an address to send from, or both.
fn send_a_datagram_to_nowhere() void {
    var bytes: [16]u8 = undefined;
    const out: core.datagram.Outbound = .{
        .peer = core.Address.ipv4(.{ 127, 0, 0, 1 }, 1),
        .local = core.Address.ipv4(.{ 0, 0, 0, 0 }, 0),
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{},
    };
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .send_to = .{
        .socket = 3,
        .buffer = .{ .bytes = &bytes },
        .to = &out,
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

/// Cutting a buffer into one piece is what a segment size of 0 already means.
fn send_a_datagram_in_one_segment() void {
    var bytes: [16]u8 = undefined;
    const out: core.datagram.Outbound = .{
        .peer = core.Address.ipv4(.{ 127, 0, 0, 1 }, 1),
        .local = core.Address.ipv4(.{ 0, 0, 0, 0 }, 0),
        .segment_bytes = bytes.len,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .send_to = .{
        .socket = 3,
        .buffer = .{ .bytes = &bytes },
        .to = &out,
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

/// More segments than `constants.segments_max`, which the kernel would refuse after the loop had
/// already claimed a slot.
fn send_a_datagram_in_too_many_segments() void {
    var bytes: [2 * core.constants.segments_max]u8 = undefined;
    const out: core.datagram.Outbound = .{
        .peer = core.Address.ipv4(.{ 127, 0, 0, 1 }, 1),
        .local = core.Address.ipv4(.{ 0, 0, 0, 0 }, 0),
        .segment_bytes = 1,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .send_to = .{
        .socket = 3,
        .buffer = .{ .bytes = &bytes },
        .to = &out,
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

/// A mask must be a power of two minus one: the decision is one AND, and any other mask would
/// sample a pattern nobody could state (decision 9, rule 2).
fn sample_with_a_mask_that_is_not_a_run_of_bits() void {
    var tables: core.Tables = undefined;
    scenario.reached_violation();
    tables.init(&slots, &entries, &starts, .{ .sampling = .{ .sample_mask = 6 } });
}

fn sample_a_phase_the_mask_can_never_match() void {
    var tables: core.Tables = undefined;
    const sampling: core.statistics.Options = .{ .sample_mask = 3, .sample_phase = 4 };
    scenario.reached_violation();
    tables.init(&slots, &entries, &starts, .{ .sampling = sampling });
}

/// The operation has left the pending list, as after a backend's flush, so the count of slots
/// in use is the one check that can see it: a scenario whose operation is still queued halts on
/// the lists as well, and would pass with this assertion gone.
fn end_a_loop_whose_operation_the_kernel_holds() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, .{});
    const timer = [_]core.Operation{
        .{ .user_data = 1, .kind = .{ .timer = .{ .after_ns = 1 } } },
    };
    _ = tables.submit(&timer, &.{});
    const index = tables.pending.pop(tables.table.slots).?;
    const slot = tables.table.at(index);
    slot.state = .submitted;
    tables.arm(index, slot);
    scenario.reached_violation();
    tables.assert_empty();
}

/// Rings for more workers than a loop holds. A caller reaches this through
/// `rotor.offload_memory_bytes` before any loop exists. A loop's own options halt on the same count
/// earlier, in `assert_options`, so only this scenario can prove the sizing's check.
fn size_the_rings_for_more_workers_than_the_limit() void {
    scenario.reached_violation();
    _ = core.offload.memory_bytes(core.constants.offload_workers_max + 1);
}

/// A backend reaches `request_cancel` through `cancellable` or `next_cancellable`, and both refuse
/// a finishing slot unless it is a repeating timer whose fire is queued. This one-shot timer's
/// final event is queued, so a cancel must not reach it: with the assertion gone, the cancel
/// would overwrite the result the caller is owed.
fn cancel_a_slot_whose_final_event_is_queued() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, .{});
    const timer = [_]core.Operation{
        .{ .user_data = 1, .kind = .{ .timer = .{ .after_ns = 1 } } },
    };
    _ = tables.submit(&timer, &.{});
    const index = tables.pending.pop(tables.table.slots).?;
    tables.finish_local(index, 0);
    scenario.reached_violation();
    _ = tables.request_cancel(index, tables.table.at(index));
}

const FileAnswer = core.file_call.Answer(std.posix.E);

/// A call that answers one more byte than it was given, which no kernel does.
const OverCount = struct {
    pub fn answer(_: OverCount, request: core.file_call.Request) FileAnswer {
        return .{ .count = request.bytes.len + 1 };
    }
};

/// A call that transfers nothing and succeeds, so only the request's own shape can halt.
const NoCount = struct {
    pub fn answer(_: NoCount, request: core.file_call.Request) FileAnswer {
        _ = request;
        return .{ .count = 0 };
    }
};

/// The bound handed to `file_call.result`. Each call here answers the first time.
const file_retries_max = 1;

var file_bytes: [1]u8 = undefined;

fn answer_a_read_with_more_bytes_than_it_was_given() void {
    const request: core.file_call.Request = .{
        .code = .read,
        .descriptor = 0,
        .bytes = &file_bytes,
        .offset = 0,
    };
    scenario.reached_violation();
    _ = core.file_call.result(OverCount{}, request, file_retries_max);
}

fn hand_a_sync_bytes_to_transfer() void {
    const request: core.file_call.Request = .{
        .code = .fdatasync,
        .descriptor = 0,
        .bytes = &file_bytes,
        .offset = 0,
    };
    scenario.reached_violation();
    _ = core.file_call.result(NoCount{}, request, file_retries_max);
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "slot_table: release a free slot", .run = release_a_free_slot },
    .{
        .name = "slot_table: release a slot with a deadline armed",
        .run = release_a_slot_with_a_deadline_armed,
    },
    .{
        .name = "slot_table: look up a handle outside the table",
        .run = look_up_a_handle_outside_the_table,
    },
    .{ .name = "timer_heap: arm a slot twice", .run = arm_a_slot_twice },
    .{
        .name = "timer_heap: disarm a slot that is not armed",
        .run = disarm_a_slot_that_is_not_armed,
    },
    .{ .name = "operation: submit a transfer of no bytes", .run = submit_a_transfer_of_no_bytes },
    .{
        .name = "operation: submit a timer with a deadline of its own",
        .run = submit_a_timer_with_a_deadline_of_its_own,
    },
    .{ .name = "operation: post a tag above the limit", .run = post_a_tag_above_the_limit },
    .{
        .name = "operation: close a registered descriptor",
        .run = close_a_registered_descriptor,
    },
    .{
        .name = "operation: name a registered descriptor in a timer",
        .run = name_a_registered_descriptor_in_a_timer,
    },
    .{
        .name = "operation: name a registered descriptor above the limit",
        .run = name_a_registered_descriptor_above_the_limit,
    },
    .{
        .name = "operation: name a registered buffer in a send",
        .run = name_a_registered_buffer_in_a_send,
    },
    .{
        .name = "operation: name a registered buffer in a receive",
        .run = name_a_registered_buffer_in_a_receive,
    },
    .{
        .name = "operation: name a registered buffer above the limit",
        .run = name_a_registered_buffer_above_the_limit,
    },
    .{
        .name = "operation: receive a datagram from a group above the limit",
        .run = receive_a_datagram_from_a_group_above_the_limit,
    },
    .{ .name = "operation: send a datagram to nowhere", .run = send_a_datagram_to_nowhere },
    .{
        .name = "operation: send a datagram in one segment",
        .run = send_a_datagram_in_one_segment,
    },
    .{
        .name = "operation: send a datagram in too many segments",
        .run = send_a_datagram_in_too_many_segments,
    },
    .{
        .name = "tables: name a registered descriptor the loop lacks",
        .run = name_a_registered_descriptor_the_loop_lacks,
    },
    .{ .name = "tables: register descriptors twice", .run = register_descriptors_twice },
    .{
        .name = "tables: name a registered buffer the loop lacks",
        .run = name_a_registered_buffer_the_loop_lacks,
    },
    .{ .name = "tables: register buffers twice", .run = register_buffers_twice },
    .{ .name = "tables: register no buffers", .run = register_no_buffers },
    .{
        .name = "statistics: sample with a mask that is not a run of bits",
        .run = sample_with_a_mask_that_is_not_a_run_of_bits,
    },
    .{
        .name = "statistics: sample a phase the mask can never match",
        .run = sample_a_phase_the_mask_can_never_match,
    },
    .{
        .name = "tables: end a loop whose operation the kernel holds",
        .run = end_a_loop_whose_operation_the_kernel_holds,
    },
    .{
        .name = "offload: size the rings for more workers than the limit",
        .run = size_the_rings_for_more_workers_than_the_limit,
    },
    .{
        .name = "tables: cancel a slot whose final event is queued",
        .run = cancel_a_slot_whose_final_event_is_queued,
    },
    .{
        .name = "file_call: answer a read with more bytes than it was given",
        .run = answer_a_read_with_more_bytes_than_it_was_given,
    },
    .{
        .name = "file_call: hand a sync bytes to transfer",
        .run = hand_a_sync_bytes_to_transfer,
    },
} ++ finish.scenarios ++ spin.scenarios ++ registry.scenarios;

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
