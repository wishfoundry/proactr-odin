package http

import "core:mem"

import proactr "../proactr"

// Client_Bridge lets package client plug into the host without http→client import
// (client already imports http for Status / Response). Registered via @(init) in client.
// Law: inbound CQE demux stays zero-map when user is ^Connection; client claims only
// when user is tagged (CLIENT_USER_TAG low bit) then magic/live checks (see client package).
Client_Bridge :: struct {
	// After worker ring_init; before harvest loop. ring is ^proactr.Ring.
	on_worker_enter: proc(ring: rawptr, allocator: mem.Allocator),
	// After worker loop ends; before ring_destroy.
	on_worker_leave: proc(),
	// If true, client applied the CQE and freed the op when not Submitted.
	// Host must not host_dispatch or op_free.
	on_cqe:          proc(ring: rawptr, c: proactr.Completion, op: ^proactr.Operation) -> bool,
	// True when outbound client has in-flight proactr ops (Darwin dual-wait).
	has_work:        proc() -> bool,
	// Cancel all outbound jobs bound to this exchange (slot is ^Stream_Slot).
	cancel_slot:     proc(slot: rawptr, exchange_gone: bool),
	// Cancel jobs on H1 slot + all H2 slots (conn is ^Connection).
	cancel_conn:     proc(conn: rawptr, exchange_gone: bool),
}

// Process-wide hooks (function pointers only — not per-request state).
client_bridge: Client_Bridge

// register_client_bridge installs hooks. Safe to call once from client @(init).
register_client_bridge :: proc(b: Client_Bridge) {
	client_bridge = b
}

// exchange_cancel_slot — host helper for clean_request_loop / H2 slot free.
@(private)
exchange_cancel_slot :: proc(slot: ^Stream_Slot, exchange_gone := true) {
	if slot == nil do return
	if client_bridge.cancel_slot != nil {
		client_bridge.cancel_slot(rawptr(slot), exchange_gone)
	}
	// Bump epoch after cancel so any stale job CQE fails epoch check.
	stream_slot_bump_exchange_epoch(slot)
}

// exchange_cancel_conn — connection_destroy / pipe teardown.
@(private)
exchange_cancel_conn :: proc(conn: ^Connection, exchange_gone := true) {
	if conn == nil do return
	if client_bridge.cancel_conn != nil {
		client_bridge.cancel_conn(rawptr(conn), exchange_gone)
		// Still bump epochs so reused slots are fresh.
		stream_slot_bump_exchange_epoch(&conn.slot)
		if conn.h2_slots != nil {
			for i in 0 ..< H2_SLOT_CAP {
				stream_slot_bump_exchange_epoch(&conn.h2_slots[i])
			}
		}
		return
	}
	exchange_cancel_slot(&conn.slot, exchange_gone)
	if conn.h2_slots != nil {
		for i in 0 ..< H2_SLOT_CAP {
			exchange_cancel_slot(&conn.h2_slots[i], exchange_gone)
		}
	}
}
