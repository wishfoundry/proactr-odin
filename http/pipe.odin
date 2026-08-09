// Pipe POD + seal∥send physics (Plan A R4 / PR4–PR5 foundation).
//
// Pure admission, CT double-buffer, dual high-water, and mock-seal driver —
// no OpenSSL, no ring, no clear-H1 Wire_State hot path. Real SSL_write plugs
// later via Cipher_Seal_Fn. Cipher engine (SSL*) never lives here.
//
// Conn_Cap / Conn_Caps already defined in plan.odin (orthogonal axes).
package http

import "base:runtime"

// ---------------------------------------------------------------------------
// Pipe POD constants (peer-measured defaults; not public Plan_Context knobs)
// ---------------------------------------------------------------------------

// Max plaintext produce per unit from Static/Bytes/File into Conn_Pt_Ring.
// Pure firehose / pipe SM use this; live TLS bulk uses TLS_SEAL_WINDOW_DEFAULT.
PULL_WINDOW_DEFAULT :: 64 * 1024

// Live TLS seal window (oneshot + H2 frame seal into dual-CT slabs). Larger than
// PULL_WINDOW so bulk needs fewer SSL_write/CQE turns per MiB while dual-CT
// keeps one window encrypting while another sends. OpenSSL still frames at
// TLS_RECORD_PLAIN internally.
TLS_SEAL_WINDOW_DEFAULT :: 256 * 1024

// Ciphered-path default for Plan_Policy.max_write_unit (host sets when ciphered).
// Apps may respect this via plan_context; not a public knobs of its own.
PIPE_MAX_WRITE_UNIT_DEFAULT :: TLS_SEAL_WINDOW_DEFAULT

// Single TLS record plaintext budget.
TLS_RECORD_PLAIN :: 16 * 1024

// Coalesce toward ~4 records (~64 KiB plain) before submit when peer allows.
TLS_RECORD_BATCH_TARGET :: 4

// Double-buffer CT slots: encrypt ∥ send (seal_n ∈ {0,1,2}).
CT_SLOTS :: 2

// Fixed ciphertext slab capacity per CT slot (pure pipe mock / firehose).
CT_SLAB_SIZE :: PULL_WINDOW_DEFAULT

// Live dual-CT slab: seal window + TLS record/AEAD overhead headroom.
TLS_CT_SLAB_DEFAULT :: TLS_SEAL_WINDOW_DEFAULT + 16 * 1024

// Stop producing into conn PT ring when admitted PT bytes ≥ this.
// Pure pipe dual-slot peak = 2×PULL_WINDOW; live TLS raises per-conn on enable.
PT_HIGH_WATER_DEFAULT :: 128 * 1024

// Live ciphered PT high-water: two seal windows (depth-2 dual-CT).
PT_HIGH_WATER_TLS_DEFAULT :: 2 * TLS_SEAL_WINDOW_DEFAULT

// Stop sealing new CT when sealed/in-flight CT bytes ≥ this.
CT_HIGH_WATER_DEFAULT :: 128 * 1024
CT_HIGH_WATER_TLS_DEFAULT :: 2 * TLS_CT_SLAB_DEFAULT

// Bounded partial-record remainder (fixed; not growable).
RX_HOLD_CAP :: 16 * 1024

// Max queued Seal_Units per conn (admission; full queue → park produce, never drop).
SEAL_Q_CAP :: 32

// seal_n ceiling = CT_SLOTS (seal while one send inflight).
SEAL_N_MAX :: CT_SLOTS

// Firehose CI: peak > FIREHOSE_PEAK_MULT × high-water → fail (detector, not soft warn).
FIREHOSE_PEAK_MULT :: 4

// ---------------------------------------------------------------------------
// Seal pipeline SM (normative — not bare sock_send_inflight alone under TLS bulk)
// ---------------------------------------------------------------------------

Seal_SM :: enum u8 {
	Idle,            // no CT sealed, socket free
	Sealing,         // AEAD filling free CT[i] (or sealed CT held, not yet in sock send)
	Send_Armed,      // one CT in sock send; may seal other CT
	Send_And_Sealed, // sock send + second CT ready
}

// ---------------------------------------------------------------------------
// Fairness unit + wire_conn schedule bag (Law D4 / S1)
// ---------------------------------------------------------------------------

// Identity for fair schedule — gen for ABA; frame_id private (never app-visible).
Seal_Unit :: struct {
	slot_gen: u32,  // must match live slot.gen when dequeued
	slot_idx: u16,  // index into Connection.slots
	frame_id: u32,  // 0 if H1; private demux only
	bytes:    []u8, // view into Conn_Pt_Ring or CT after seal
	is_ct:    bool, // true = ciphertext view; false = clear
}

// Bounded Seal_Unit queue storage (SEAL_Q_CAP). Pure helpers and tests own this
// POD; Connection does NOT embed it. Phase 2 allocates a Seal_Queue for
// Ciphered/Multiplex conns and hangs it from Wire_Conn_State.q — clear-H1 keeps
// q == nil so every free-list Connection pays only the thin Wire_Conn_State bag.
Seal_Queue :: struct {
	units: [SEAL_Q_CAP]Seal_Unit,
	len:   int,
}

// Sole outbound schedule on the connection (clear or via Tls_Pipe completion).
// Only this bag may submit_send (Law S1). seal_n tracks CT seal depth when Ciphered.
//
// Size budget: keep this struct small (~16–24 B). Full SEAL_Q_CAP storage lives in
// Seal_Queue, pointed by q. q is nil until Phase 2 allocates for ciphered/multiplex;
// clear-H1 Wire_State path is unchanged and must not assume q is non-nil.
Wire_Conn_State :: struct {
	sock_send_inflight: bool, // socket send ∈ {0,1}
	seal_n:             u8,   // sealed or in-send ∈ {0,1,2}
	rr_cursor:          int,  // next slot_idx to prefer (deficit/RR)
	q:                  ^Seal_Queue, // nil until Phase 2 ciphered/multiplex alloc
}

// ---------------------------------------------------------------------------
// Conn-level PT admission (first-class; must-alias seal input — Law PT1)
// ---------------------------------------------------------------------------

// Single admission point for plaintext under bulk / multiplex.
// Per-slot growable staging is FORBIDDEN as the bulk path.
// Full fixed-slab free-list lands in a later PR; this POD tracks admission only.
Conn_Pt_Ring :: struct {
	admitted:   u32, // bytes currently checked out to slots/seal path
	high_water: u32, // PT_HIGH_WATER (default PT_HIGH_WATER_DEFAULT)
	// fixed slab bookkeeping (free list of slab indices) — later PR
}

// ---------------------------------------------------------------------------
// CT double-buffer storage (fixed slabs; never growable multi-MiB)
// ---------------------------------------------------------------------------

// Ownership of one CT slab: free → sealing (holds sealed CT) → sending → free.
Ct_Slot_Own :: enum u8 {
	Free,
	Sealing, // sealed CT ready (or mid-AEAD); not yet in sock send
	Sending, // view submitted; wait CQE before recycle
}

// Companion CT storage for Tls_Pipe. Allocated by tls_pipe_alloc_buffers;
// not embedded multi-MiB on free-list Connection.
Tls_Pipe_Buffers :: struct {
	ct:        [CT_SLOTS][]u8,
	ct_len:    [CT_SLOTS]u32,
	ct_own:    [CT_SLOTS]Ct_Slot_Own,
	ct_pt_len: [CT_SLOTS]u32, // PT bytes sealed into this slot (pt_release on complete)
}

// ---------------------------------------------------------------------------
// Tls_Pipe POD skeleton (no SSL*, no OpenSSL link)
// ---------------------------------------------------------------------------

Tls_Pipe_State :: enum u8 {
	Handshake,
	Open,
	Closing,
	Closed,
}

// L2 cipher pipe skeleton. Encrypt input MUST alias Connection.pt (Conn_Pt_Ring)
// views — Law PT1 forbids a second full PT window inside Tls_Pipe.
// No engine / SSL* field here; cipher module is a later PR under this type.
Tls_Pipe :: struct {
	state:              Tls_Pipe_State,
	seal_sm:            Seal_SM,
	seal_n:             u8,   // count sealed or in-send ∈ {0,1,2}
	ct_bytes_held:      u32,  // dual high-water with PT
	ct_high_water:      u32,  // 0 → CT_HIGH_WATER_DEFAULT after init
	sock_send_inflight: bool, // socket send ∈ {0,1}
	// CT double-buffer bookkeeping (slabs via bufs; CT_SLOTS = 2)
	ct_seal_idx:        u8,
	ct_send_idx:        u8,
	// Partial-record remainder length; bytes live in fixed buffer ≤ RX_HOLD_CAP
	rx_hold_len:        u16,
	// Heap CT slabs; nil until tls_pipe_alloc_buffers
	bufs:               ^Tls_Pipe_Buffers,
	// PT: do not store a second window — alias Conn_Pt_Ring views at seal time
}

// ---------------------------------------------------------------------------
// Peak meters + firehose detector (Phase 2 CI gate)
// ---------------------------------------------------------------------------

Pipe_Meters :: struct {
	peak_pt_admitted: u32,
	peak_ct_held:     u32,
	seal_units:       u64,
	ct_sends:         u64,
	pt_hw_hits:       u64,
	ct_hw_hits:       u64,
}

// ---------------------------------------------------------------------------
// Mock / real seal callback (identity mock for pure tests; SSL_write later)
// ---------------------------------------------------------------------------

// Seal PT into CT destination. Mock: identity copy. Real: SSL_write / record batch.
// n_ct is ciphertext bytes written; ok=false on hard fail (not WANT_*).
Cipher_Seal_Fn :: #type proc(user: rawptr, pt: []u8, ct_dst: []u8) -> (n_ct: int, ok: bool)

// Pause / outcome of one pipe_seal_step.
Pipe_Seal_Reason :: enum u8 {
	Ok,          // sealed CT view ready to submit_send
	No_Pt,       // empty PT source
	Pt_Hw,       // reserved for produce-side admit refuse (not set by seal alone)
	Ct_Hw,       // CT high-water would be exceeded
	Seal_N_Full, // seal_n == SEAL_N_MAX
	No_Free_Ct,  // no Free CT slot
	No_Bufs,     // tls_pipe buffers not allocated
	Seal_Fail,   // seal_fn returned !ok
}

Pipe_Seal_Result :: struct {
	reason:  Pipe_Seal_Reason,
	ct_view: []u8, // valid when reason == .Ok
	slot:    u8,   // CT slot index when Ok
	pt_used: u32,  // PT bytes consumed when Ok
}

// ---------------------------------------------------------------------------
// Pure helpers — free-order + admission laws (unit-testable, no I/O)
// ---------------------------------------------------------------------------

// pt_ring_init sets high_water (0 → PT_HIGH_WATER_DEFAULT) and clears admitted.
pt_ring_init :: proc(pt: ^Conn_Pt_Ring, high_water: u32 = 0) {
	pt.admitted = 0
	pt.high_water = high_water if high_water > 0 else PT_HIGH_WATER_DEFAULT
}

// pt_admit: Law — if admitted+need > high_water return false (pause produce; never grow).
// On success, admitted increases by need.
pt_admit :: proc(pt: ^Conn_Pt_Ring, need: u32) -> bool {
	if need == 0 {
		return true
	}
	// u64 avoids overflow on admitted+need near u32 max
	if u64(pt.admitted) + u64(need) > u64(pt.high_water) {
		return false
	}
	pt.admitted += need
	return true
}

// pt_admit_metered: pt_admit + peak_pt / pt_hw_hits updates.
pt_admit_metered :: proc(pt: ^Conn_Pt_Ring, need: u32, meters: ^Pipe_Meters) -> bool {
	if !pt_admit(pt, need) {
		if meters != nil {
			meters.pt_hw_hits += 1
		}
		return false
	}
	if meters != nil && pt.admitted > meters.peak_pt_admitted {
		meters.peak_pt_admitted = pt.admitted
	}
	return true
}

// pt_release returns n admitted bytes (floor at 0). Seal/CQE recycle path.
pt_release :: proc(pt: ^Conn_Pt_Ring, n: u32) {
	if n >= pt.admitted {
		pt.admitted = 0
		return
	}
	pt.admitted -= n
}

// ct_admit: dual high-water — refuse if ct_bytes_held+need > ct_high_water.
// On success, ct_bytes_held increases by need.
ct_admit :: proc(pipe: ^Tls_Pipe, need: u32) -> bool {
	if need == 0 {
		return true
	}
	hw := pipe.ct_high_water if pipe.ct_high_water > 0 else u32(CT_HIGH_WATER_DEFAULT)
	if u64(pipe.ct_bytes_held) + u64(need) > u64(hw) {
		return false
	}
	pipe.ct_bytes_held += need
	return true
}

// ct_admit_metered: ct_admit + peak_ct / ct_hw_hits updates.
ct_admit_metered :: proc(pipe: ^Tls_Pipe, need: u32, meters: ^Pipe_Meters) -> bool {
	if !ct_admit(pipe, need) {
		if meters != nil {
			meters.ct_hw_hits += 1
		}
		return false
	}
	if meters != nil && pipe.ct_bytes_held > meters.peak_ct_held {
		meters.peak_ct_held = pipe.ct_bytes_held
	}
	return true
}

// ct_release returns n held CT bytes (floor at 0). On send complete / recycle.
ct_release :: proc(pipe: ^Tls_Pipe, n: u32) {
	if n >= pipe.ct_bytes_held {
		pipe.ct_bytes_held = 0
		return
	}
	pipe.ct_bytes_held -= n
}

// seal_n_try_inc advances seal depth if under SEAL_N_MAX (CT_SLOTS). Returns false at max.
seal_n_try_inc :: proc(seal_n: ^u8) -> bool {
	if seal_n^ >= u8(SEAL_N_MAX) {
		return false
	}
	seal_n^ += 1
	return true
}

// seal_n_try_dec decrements seal depth on CT recycle. Returns false if already 0.
seal_n_try_dec :: proc(seal_n: ^u8) -> bool {
	if seal_n^ == 0 {
		return false
	}
	seal_n^ -= 1
	return true
}

// seal_q_push enqueues unit. Returns false if full (backpressure → park slot; never drop).
// Caller owns q (stack in tests; Phase 2 heap for ciphered/multiplex Wire_Conn_State.q).
seal_q_push :: proc(q: ^Seal_Queue, unit: Seal_Unit) -> bool {
	if q.len >= SEAL_Q_CAP {
		return false
	}
	q.units[q.len] = unit
	q.len += 1
	return true
}

// _seal_q_pop_front removes index 0 and shifts (POD queue; CAP=32, pure tests only).
@(private = "file")
_seal_q_pop_front :: proc(q: ^Seal_Queue) -> (unit: Seal_Unit, ok: bool) {
	if q.len <= 0 {
		return {}, false
	}
	unit = q.units[0]
	for i in 1 ..< q.len {
		q.units[i - 1] = q.units[i]
	}
	q.units[q.len - 1] = {}
	q.len -= 1
	return unit, true
}

// seal_q_pop_gen_checked: Law D4 — dequeue only if unit.slot_gen matches live gen.
// live_gens is indexed by slot_idx. Stale (gen mismatch / OOB slot) units are skipped
// (removed without returning). Returns ok=false when queue empty of live units.
seal_q_pop_gen_checked :: proc(q: ^Seal_Queue, live_gens: []u32) -> (unit: Seal_Unit, ok: bool) {
	for q.len > 0 {
		front, pop_ok := _seal_q_pop_front(q)
		if !pop_ok {
			break
		}
		idx := int(front.slot_idx)
		if idx < 0 || idx >= len(live_gens) {
			// unknown slot — treat as stale, skip
			continue
		}
		if front.slot_gen != live_gens[idx] {
			// gen mismatch (stream abort / ABA) — skip
			continue
		}
		return front, true
	}
	return {}, false
}

// seal_q_remove_gen removes every unit with slot_gen == gen (stream RST / slot death §E.4).
// Compacts remaining units toward the head. Returns count removed.
// Mid-socket-send ownership is a later wire concern — this only mutates the POD queue.
seal_q_remove_gen :: proc(q: ^Seal_Queue, gen: u32) -> int {
	removed := 0
	w := 0
	for r in 0 ..< q.len {
		if q.units[r].slot_gen == gen {
			removed += 1
			continue
		}
		if w != r {
			q.units[w] = q.units[r]
		}
		w += 1
	}
	for i in w ..< q.len {
		q.units[i] = {}
	}
	q.len = w
	return removed
}

// wire_conn_init zeroes schedule state (clean Connection start).
// Leaves q == nil — Seal_Queue storage is deferred until Phase 2 ciphered/multiplex.
// Call wire_conn_disable_seal_q first if q was heap-allocated.
wire_conn_init :: proc(wc: ^Wire_Conn_State) {
	wc^ = {}
}

// wire_conn_enable_seal_q allocates Seal_Queue and hangs it on wc.q.
// Idempotent if q already non-nil. Returns false on alloc failure.
wire_conn_enable_seal_q :: proc(wc: ^Wire_Conn_State, allocator := context.allocator) -> bool {
	if wc.q != nil {
		return true
	}
	q := new(Seal_Queue, allocator)
	if q == nil {
		return false
	}
	q^ = {}
	wc.q = q
	return true
}

// wire_conn_disable_seal_q frees Seal_Queue if non-nil and clears q.
wire_conn_disable_seal_q :: proc(wc: ^Wire_Conn_State, allocator := context.allocator) {
	if wc.q == nil {
		return
	}
	free(wc.q, allocator)
	wc.q = nil
}

// _conn_pipe_allocator prefers server.conn_allocator when the conn is server-backed.
@(private = "file")
_conn_pipe_allocator :: proc(conn: ^Connection, fallback := context.allocator) -> runtime.Allocator {
	if conn != nil && conn.server != nil {
		return conn.server.conn_allocator
	}
	return fallback
}

// connection_enable_ciphered: lightweight host path after TLS Open.
// Sets conn.ciphered so plan_policy_for forces no sendfile and
// max_write_unit = PIPE_MAX_WRITE_UNIT_DEFAULT; raises PT high-water for
// dual-CT large seal windows. Live oneshot uses dual CT slabs (tls_ct_tx +
// tls_ct_hold), not pure-pipe Seal_Queue. Clear-H1 never calls this.
// For pure firehose SM, call connection_enable_ciphered_pipe_sm.
connection_enable_ciphered :: proc(conn: ^Connection, allocator := context.allocator) -> bool {
	if conn == nil {
		return false
	}
	if conn.ciphered {
		// Keep TLS high-water even if already ciphered (re-open / tests).
		if conn.pt.high_water < PT_HIGH_WATER_TLS_DEFAULT {
			conn.pt.high_water = PT_HIGH_WATER_TLS_DEFAULT
		}
		return true
	}
	// Live dual-CT: admit up to two TLS seal windows (not pure-pipe 128 KiB HW).
	if conn.pt.high_water < PT_HIGH_WATER_TLS_DEFAULT {
		conn.pt.high_water = PT_HIGH_WATER_TLS_DEFAULT
	}
	conn.ciphered = true
	return true
}

// connection_enable_ciphered_pipe_sm: full SM bags for pure seal∥send tests / future live pipe.
// Lightweight-enables ciphered, then allocates Seal_Queue + Tls_Pipe CT[2] slabs (~128 KiB).
// Live HTTPS oneshot does not call this (avoids zombie dual-CT tax).
connection_enable_ciphered_pipe_sm :: proc(conn: ^Connection, allocator := context.allocator) -> bool {
	if conn == nil {
		return false
	}
	if !connection_enable_ciphered(conn, allocator) {
		return false
	}
	if conn.wire_conn.q != nil && conn.tls_pipe.bufs != nil {
		return true
	}
	alloc := _conn_pipe_allocator(conn, allocator)
	if !wire_conn_enable_seal_q(&conn.wire_conn, alloc) {
		return false
	}
	if !tls_pipe_alloc_buffers(&conn.tls_pipe, alloc) {
		wire_conn_disable_seal_q(&conn.wire_conn, alloc)
		return false
	}
	return true
}

// connection_disable_ciphered: free seal_q + CT slabs if present; clear ciphered.
// Safe if only lightweight-enabled or never enabled. Called from connection_destroy.
connection_disable_ciphered :: proc(conn: ^Connection, allocator := context.allocator) {
	if conn == nil {
		return
	}
	alloc := _conn_pipe_allocator(conn, allocator)
	wire_conn_disable_seal_q(&conn.wire_conn, alloc)
	tls_pipe_free_buffers(&conn.tls_pipe, alloc)
	conn.ciphered = false
}

// tls_pipe_init zeroes Tls_Pipe into Handshake / Idle (no engine, no CT slabs).
tls_pipe_init :: proc(pipe: ^Tls_Pipe) {
	pipe^ = {}
	pipe.state = .Handshake
	pipe.seal_sm = .Idle
	pipe.ct_high_water = CT_HIGH_WATER_DEFAULT
}

// tls_pipe_alloc_buffers allocates fixed CT slabs (CT_SLOTS × CT_SLAB_SIZE) on pipe.bufs.
// Idempotent if already allocated. Returns false on alloc failure (partial cleaned).
tls_pipe_alloc_buffers :: proc(pipe: ^Tls_Pipe, allocator := context.allocator) -> bool {
	if pipe.bufs != nil {
		return true
	}
	bufs := new(Tls_Pipe_Buffers, allocator)
	if bufs == nil {
		return false
	}
	bufs^ = {}
	for i in 0 ..< CT_SLOTS {
		slab, err := make([]u8, CT_SLAB_SIZE, allocator)
		if err != nil || slab == nil {
			// free any prior slabs + header
			for j in 0 ..< i {
				delete(bufs.ct[j], allocator)
				bufs.ct[j] = nil
			}
			free(bufs, allocator)
			return false
		}
		bufs.ct[i] = slab
		bufs.ct_own[i] = .Free
	}
	pipe.bufs = bufs
	return true
}

// tls_pipe_free_buffers releases CT slabs and the companion struct.
tls_pipe_free_buffers :: proc(pipe: ^Tls_Pipe, allocator := context.allocator) {
	if pipe.bufs == nil {
		return
	}
	for i in 0 ..< CT_SLOTS {
		if pipe.bufs.ct[i] != nil {
			delete(pipe.bufs.ct[i], allocator)
			pipe.bufs.ct[i] = nil
		}
		pipe.bufs.ct_len[i] = 0
		pipe.bufs.ct_own[i] = .Free
		pipe.bufs.ct_pt_len[i] = 0
	}
	free(pipe.bufs, allocator)
	pipe.bufs = nil
	pipe.ct_bytes_held = 0
	pipe.seal_n = 0
	pipe.sock_send_inflight = false
	pipe.seal_sm = .Idle
}

// mock_cipher_seal_identity: PT → CT copy (no AEAD). Plug-in for pure bulk sim.
mock_cipher_seal_identity :: proc(user: rawptr, pt: []u8, ct_dst: []u8) -> (n_ct: int, ok: bool) {
	_ = user
	if len(ct_dst) < len(pt) {
		return 0, false
	}
	if len(pt) > 0 {
		copy(ct_dst[:len(pt)], pt)
	}
	return len(pt), true
}

// _pipe_find_free_ct returns first Free CT slot index, or -1.
@(private = "file")
_pipe_find_free_ct :: proc(bufs: ^Tls_Pipe_Buffers) -> int {
	for i in 0 ..< CT_SLOTS {
		if bufs.ct_own[i] == .Free {
			return i
		}
	}
	return -1
}

// _pipe_refresh_seal_sm derives Seal_SM from sock_send_inflight + sealing/sending counts.
@(private = "file")
_pipe_refresh_seal_sm :: proc(pipe: ^Tls_Pipe) {
	if pipe.bufs == nil {
		pipe.seal_sm = .Idle
		return
	}
	n_ready := 0 // Sealing (held CT not yet Sending)
	n_sending := 0
	for i in 0 ..< CT_SLOTS {
		switch pipe.bufs.ct_own[i] {
		case .Sealing:
			n_ready += 1
		case .Sending:
			n_sending += 1
		case .Free:
		}
	}
	if n_sending > 0 && n_ready > 0 {
		pipe.seal_sm = .Send_And_Sealed
	} else if n_sending > 0 {
		pipe.seal_sm = .Send_Armed
	} else if n_ready > 0 {
		pipe.seal_sm = .Sealing
	} else {
		pipe.seal_sm = .Idle
	}
}

// pipe_seal_step: one seal∥send SM step.
// Given admitted PT view + free CT + room under CT_HW and seal_n, mock/real seal
// into CT[i]. Returns sealed CT view ready to submit_send, or pause reason.
// Does NOT mark sock send — call pipe_mark_send after when !sock_send_inflight.
pipe_seal_step :: proc(
	pipe:      ^Tls_Pipe,
	pt_src:    []u8,
	seal_fn:   Cipher_Seal_Fn,
	seal_user: rawptr = nil,
	meters:    ^Pipe_Meters = nil,
) -> Pipe_Seal_Result {
	if pipe.bufs == nil {
		return Pipe_Seal_Result{reason = .No_Bufs}
	}
	if len(pt_src) == 0 {
		return Pipe_Seal_Result{reason = .No_Pt}
	}
	if pipe.seal_n >= u8(SEAL_N_MAX) {
		return Pipe_Seal_Result{reason = .Seal_N_Full}
	}
	slot_i := _pipe_find_free_ct(pipe.bufs)
	if slot_i < 0 {
		return Pipe_Seal_Result{reason = .No_Free_Ct}
	}

	// Cap at slab size (one pull window).
	pt_n := len(pt_src)
	if pt_n > CT_SLAB_SIZE {
		pt_n = CT_SLAB_SIZE
	}
	need := u32(pt_n)

	// Dual HW: refuse seal when CT backlog would exceed high-water.
	if !ct_admit_metered(pipe, need, meters) {
		return Pipe_Seal_Result{reason = .Ct_Hw}
	}

	if !seal_n_try_inc(&pipe.seal_n) {
		// should be unreachable after seal_n check; roll back CT admit
		ct_release(pipe, need)
		return Pipe_Seal_Result{reason = .Seal_N_Full}
	}

	ct_dst := pipe.bufs.ct[slot_i]
	n_ct, ok := seal_fn(seal_user, pt_src[:pt_n], ct_dst)
	if !ok || n_ct < 0 {
		seal_n_try_dec(&pipe.seal_n)
		ct_release(pipe, need)
		return Pipe_Seal_Result{reason = .Seal_Fail}
	}
	// Identity mock: n_ct == pt_n. If real AEAD grows CT, adjust held bytes.
	if u32(n_ct) != need {
		if u32(n_ct) > need {
			extra := u32(n_ct) - need
			if !ct_admit_metered(pipe, extra, meters) {
				// CT expansion would breach HW — treat as fail for pure path
				seal_n_try_dec(&pipe.seal_n)
				ct_release(pipe, need)
				return Pipe_Seal_Result{reason = .Ct_Hw}
			}
		} else {
			ct_release(pipe, need - u32(n_ct))
		}
	}

	pipe.bufs.ct_len[slot_i] = u32(n_ct)
	pipe.bufs.ct_pt_len[slot_i] = need
	pipe.bufs.ct_own[slot_i] = .Sealing
	pipe.ct_seal_idx = u8(slot_i)

	if meters != nil {
		meters.seal_units += 1
		if pipe.ct_bytes_held > meters.peak_ct_held {
			meters.peak_ct_held = pipe.ct_bytes_held
		}
	}

	_pipe_refresh_seal_sm(pipe)

	return Pipe_Seal_Result {
		reason  = .Ok,
		ct_view = ct_dst[:n_ct],
		slot    = u8(slot_i),
		pt_used = need,
	}
}

// pipe_mark_send arms sock send for a Sealing CT slot (socket send ∈ {0,1}).
// Returns false if socket already inflight or slot not Sealing.
pipe_mark_send :: proc(pipe: ^Tls_Pipe, slot: u8, meters: ^Pipe_Meters = nil) -> bool {
	if pipe.bufs == nil {
		return false
	}
	if pipe.sock_send_inflight {
		return false
	}
	si := int(slot)
	if si < 0 || si >= CT_SLOTS {
		return false
	}
	if pipe.bufs.ct_own[si] != .Sealing {
		return false
	}
	pipe.bufs.ct_own[si] = .Sending
	pipe.sock_send_inflight = true
	pipe.ct_send_idx = slot
	if meters != nil {
		meters.ct_sends += 1
	}
	_pipe_refresh_seal_sm(pipe)
	return true
}

// pipe_on_send_complete: recycle CT after send CQE.
// seal_n--, ct_release, pt_release for PT held by that slot, clear sock_send_inflight.
// Returns PT bytes released (caller may already track).
pipe_on_send_complete :: proc(
	pipe:   ^Tls_Pipe,
	pt:     ^Conn_Pt_Ring,
	slot:   u8,
	meters: ^Pipe_Meters = nil,
) -> (pt_released: u32) {
	if pipe.bufs == nil {
		return 0
	}
	si := int(slot)
	if si < 0 || si >= CT_SLOTS {
		return 0
	}
	// Allow complete only from Sending (or Sealing if caller skips mark — defensive).
	own := pipe.bufs.ct_own[si]
	if own != .Sending && own != .Sealing {
		return 0
	}

	ct_n := pipe.bufs.ct_len[si]
	pt_n := pipe.bufs.ct_pt_len[si]

	pipe.bufs.ct_own[si] = .Free
	pipe.bufs.ct_len[si] = 0
	pipe.bufs.ct_pt_len[si] = 0

	if own == .Sending || pipe.sock_send_inflight {
		pipe.sock_send_inflight = false
	}
	_ = seal_n_try_dec(&pipe.seal_n)
	ct_release(pipe, ct_n)
	if pt != nil && pt_n > 0 {
		pt_release(pt, pt_n)
	}
	_pipe_refresh_seal_sm(pipe)
	return pt_n
}

// pipe_find_ready_ct: first Sealing (ready to submit) CT slot, or -1.
pipe_find_ready_ct :: proc(pipe: ^Tls_Pipe) -> int {
	if pipe.bufs == nil {
		return -1
	}
	for i in 0 ..< CT_SLOTS {
		if pipe.bufs.ct_own[i] == .Sealing {
			return i
		}
	}
	return -1
}

// pipe_ct_view returns the sealed CT bytes for a slot (Sealing or Sending).
pipe_ct_view :: proc(pipe: ^Tls_Pipe, slot: u8) -> []u8 {
	if pipe.bufs == nil {
		return nil
	}
	si := int(slot)
	if si < 0 || si >= CT_SLOTS {
		return nil
	}
	n := int(pipe.bufs.ct_len[si])
	if n <= 0 || n > len(pipe.bufs.ct[si]) {
		return nil
	}
	return pipe.bufs.ct[si][:n]
}

// firehose_fail: true if peak PT or CT exceeded FIREHOSE_PEAK_MULT × high-water.
// CI gate for bulk O(window) — fails if peak ≳ 4× HW (firehose detector).
firehose_fail :: proc(
	meters: ^Pipe_Meters,
	pt_hw:  u32 = PT_HIGH_WATER_DEFAULT,
	ct_hw:  u32 = CT_HIGH_WATER_DEFAULT,
) -> bool {
	if meters == nil {
		return false
	}
	if meters.peak_pt_admitted > FIREHOSE_PEAK_MULT * pt_hw {
		return true
	}
	if meters.peak_ct_held > FIREHOSE_PEAK_MULT * ct_hw {
		return true
	}
	return false
}

// pipe_meters_note_pt updates peak_pt from a live admitted sample (optional helper).
pipe_meters_note_pt :: proc(meters: ^Pipe_Meters, admitted: u32) {
	if meters != nil && admitted > meters.peak_pt_admitted {
		meters.peak_pt_admitted = admitted
	}
}

// pipe_meters_note_ct updates peak_ct from a live held sample (optional helper).
pipe_meters_note_ct :: proc(meters: ^Pipe_Meters, held: u32) {
	if meters != nil && held > meters.peak_ct_held {
		meters.peak_ct_held = held
	}
}
