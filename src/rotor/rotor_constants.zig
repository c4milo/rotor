//! Every named limit of the public module (CLAUDE.md, non-negotiable 1): the core's, then the
//! reactor's, which decision 33 moved to `src/reactor/constants.zig` with no value changed. A
//! program reads `rotor.constants` as it did at v0.10.0. The test of `rotor_test.zig` holds this
//! file to the two modules' lists, so a limit that one of them adds and this file lacks fails
//! `zig build test`.
const core = @import("core");
const reactor = @import("reactor");

// The core's limits.
pub const ns_per_us = core.constants.ns_per_us;
pub const ns_per_ms = core.constants.ns_per_ms;
pub const ns_per_s = core.constants.ns_per_s;
pub const slot_bytes = core.constants.slot_bytes;
pub const event_bytes = core.constants.event_bytes;
pub const operations_max = core.constants.operations_max;
pub const batch_max = core.constants.batch_max;
pub const descriptor_entries_per_slot = core.constants.descriptor_entries_per_slot;
pub const mailbox_messages = core.constants.mailbox_messages;
pub const messages_per_drain = core.constants.messages_per_drain;
pub const kernel_share_divisor = core.constants.kernel_share_divisor;
pub const mailbox_share_divisor = core.constants.mailbox_share_divisor;
pub const kernel_own_max = core.constants.kernel_own_max;
pub const fair_events_min = core.constants.fair_events_min;
pub const mailbox_index_alignment = core.constants.mailbox_index_alignment;
pub const timer_heap_arity = core.constants.timer_heap_arity;
pub const generation_first = core.constants.generation_first;
pub const wait_ns_max = core.constants.wait_ns_max;
pub const spin_budget_ns_max = core.constants.spin_budget_ns_max;
pub const spin_rounds_max = core.constants.spin_rounds_max;
pub const timeout_ns_max = core.constants.timeout_ns_max;
pub const transfer_bytes_max = core.constants.transfer_bytes_max;
pub const loops_max = core.constants.loops_max;
pub const offload_workers_max = core.constants.offload_workers_max;
pub const offload_in_flight_max = core.constants.offload_in_flight_max;
pub const message_tag_max = core.constants.message_tag_max;
pub const message_tag_call = core.constants.message_tag_call;
pub const message_tag_return = core.constants.message_tag_return;
pub const calls_per_pair_max = core.constants.calls_per_pair_max;
pub const mailbox_posts_max = core.constants.mailbox_posts_max;
pub const message_tag_wake = core.constants.message_tag_wake;
pub const drain_rounds_max = core.constants.drain_rounds_max;
pub const drain_wait_ns = core.constants.drain_wait_ns;
pub const latency_buckets = core.constants.latency_buckets;
pub const sample_mask_default = core.constants.sample_mask_default;
pub const registered_descriptors_max = core.constants.registered_descriptors_max;
pub const transfer_retries_max = core.constants.transfer_retries_max;
pub const registered_buffers_max = core.constants.registered_buffers_max;
pub const scheduling_groups_max = core.constants.scheduling_groups_max;
pub const stall_turn_ns_default = core.constants.stall_turn_ns_default;
pub const heartbeat_alignment = core.constants.heartbeat_alignment;
pub const buffer_groups_max = core.constants.buffer_groups_max;
pub const buffers_per_group_max = core.constants.buffers_per_group_max;
pub const buffer_ring_alignment = core.constants.buffer_ring_alignment;
pub const buffer_ring_entry_bytes = core.constants.buffer_ring_entry_bytes;
pub const interrupt_retries_max = core.constants.interrupt_retries_max;
pub const socket_buffer_bytes_max = core.constants.socket_buffer_bytes_max;
pub const errno_max = core.constants.errno_max;
pub const segments_max = core.constants.segments_max;
pub const coalesced_segments_max = core.constants.coalesced_segments_max;
pub const coalesced_bytes_max = core.constants.coalesced_bytes_max;

// The reactor's limits.
pub const pollers_max = reactor.constants.pollers_max;
pub const tasks_per_tick_max = reactor.constants.tasks_per_tick_max;
pub const tasks_queued_max = reactor.constants.tasks_queued_max;
pub const scheduling_shares_max = reactor.constants.scheduling_shares_max;
pub const scheduling_shares_default = reactor.constants.scheduling_shares_default;
pub const scheduling_unit_credit = reactor.constants.scheduling_unit_credit;
pub const task_charge_max = reactor.constants.task_charge_max;
pub const visits_per_run_max = reactor.constants.visits_per_run_max;
pub const services_max = reactor.constants.services_max;
pub const call_tasks_max = reactor.constants.call_tasks_max;
pub const task_queue_length_max = reactor.constants.task_queue_length_max;
