// Stream_Slot — sole exchange ownership unit (Plan A R4 / PR2).
//
// Connection is the pipe (socket, wire, scanner, resp_buf). Stream_Slot owns
// Response + session + progressive stream state for one exchange. H1 embeds N=1
// as conn.slot; H2 later admits a multi-slot array with the same type.
package http

import "core:mem"

// Sole exchange storage: Response + session + progressive stream markers.
// Pipe backref (conn) is set at connection init/recycle; gen is ABA epoch for Session.id.
Stream_Slot :: struct {
	// ABA generation; Session.id / public gen use this (incremented on attach).
	gen:  u32,
	// Outbound client job ABA: bumped on exchange clean / slot free (client-proactr PR2).
	// Distinct from gen (session attach). Jobs snapshot at get_async start.
	exchange_epoch: u32,
	// Head of intrusive outbound Client_Job list (package client owns nodes; opaque here).
	client_jobs:    rawptr,
	// Pipe backref; set at connection init. Never independently owned session state.
	conn: ^Connection,

	// Exchange response (Plan A: slot owns Response; was Loop.res).
	res: Response,

	// Effect-based Session (D1). Nil until sse_start / ws_start / attach.
	session:          ^Session_State,
	// Pad from sse_alloc before/during session life (conn_allocator); freed after on_close.
	session_pad:      rawptr,
	session_pad_size: int,

	// Progressive multi-CQE stream (D0). Body mid-stream: do not clean_request_loop
	// until stream_ending and all bytes delivered (or session Closed).
	stream_open:          bool,
	stream_ending:        bool,
	stream_sent:          int, // bytes of resp_buf fully delivered to peer
	stream_flush_pending: bool, // reflush after in-flight Stream CQE
	stream_respond_fired: bool, // on_respond once at first successful flush
	// In-flight Stream send slab from stream_pool (len==slot_size capacity).
	// pending_send aliases slab[:stream_send_len] during wire.kind==.Stream.
	stream_send_slab: []u8,
	stream_send_len:  int, // bytes copied into slab for this arm
	// PIN hangup: 1-byte recv when wire idle + only Idle timer (no concurrent send).
	stream_pin_armed: bool,
	stream_pin_gen:   u32,
	stream_pin_byte:  [1]u8,
}

// Free sse_alloc pad if present. Safe no-op when pad is nil.
// Allocator: server.conn_allocator when slot.conn.server is set (sse_alloc path);
// otherwise context.allocator (defensive).
@(private)
stream_slot_free_pad :: proc(slot: ^Stream_Slot) {
	if slot == nil || slot.session_pad == nil {
		return
	}
	alloc := context.allocator
	if slot.conn != nil && slot.conn.server != nil {
		alloc = slot.conn.server.conn_allocator
	}
	mem.free(slot.session_pad, alloc)
	slot.session_pad = nil
	slot.session_pad_size = 0
}

// Wire slot.conn and zero exchange fields; preserve gen across free-list reuse (ABA).
// Fail-closed: return stream pool slab + free pad before zero — never drop heap/pool.
// Caller must cancel outbound client jobs BEFORE this (exchange_cancel_slot).
@(private)
stream_slot_reset_exchange :: proc(slot: ^Stream_Slot, pipe: ^Connection) {
	if slot.stream_send_slab != nil {
		stream_pool_put(slot.stream_send_slab)
		slot.stream_send_slab = nil
		slot.stream_send_len = 0
	}
	stream_slot_free_pad(slot)
	gen := slot.gen
	epoch := slot.exchange_epoch
	slot^ = {}
	slot.gen = gen
	slot.exchange_epoch = epoch
	slot.conn = pipe
	// client_jobs must already be nil (cancel unlinks); do not retain stale head.
	slot.client_jobs = nil
}

// Bump slot.gen for a new session attach (skip 0). Returns the new gen for Session.id.
@(private)
stream_slot_bump_gen :: proc(slot: ^Stream_Slot) -> u32 {
	slot.gen += 1
	if slot.gen == 0 {
		slot.gen = 1
	}
	return slot.gen
}

// Bump exchange_epoch for outbound client job ABA (skip 0).
stream_slot_bump_exchange_epoch :: proc(slot: ^Stream_Slot) -> u32 {
	if slot == nil do return 0
	slot.exchange_epoch += 1
	if slot.exchange_epoch == 0 {
		slot.exchange_epoch = 1
	}
	return slot.exchange_epoch
}
