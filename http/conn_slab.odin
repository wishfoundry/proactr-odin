// Connection slab + growable per-worker temp slot pool.
// Separated from server.odin so the host loop stays focused on accept/CQE dispatch.
package http

import "core:log"
import "core:mem/virtual"

import proactr "../proactr"

// Default initial capacity of permanent Connection.resp_buf (1 MiB body + 4 KiB headers).
// Overridable via Server_Opts.resp_buf_initial (0 → this). Grows on demand; capacity retained.
// Owned by Connection.resp_buf (conn_allocator), never the request temp arena.
@(private)
HOST_RESP_BUF_INITIAL :: (1 << 20) + 4096

// Default grow quantum for the temp slot pool (Server_Opts.temp_chunk_slots; 0 → this).
// Grown on demand when free slots are empty — no multi‑GiB preallocation at serve().
@(private)
HOST_TEMP_CHUNK_SLOTS :: 8

// Default max concurrent temp slots per worker (Server_Opts.temp_slots_max; 0 → this).
// Soft cap so a runaway accept storm cannot RSS-bomb; raise via Server_Opts.temp_slots_max.
// Set Server_Opts.temp_slots_max < 0 for unlimited growth.
@(private)
HOST_TEMP_SLOTS_MAX_DEFAULT :: 256

// _server_thread_init_temp sets up an empty growable temp pool for a worker.
// Backing memory is allocated in chunks on first attach / when free is empty.
// Expects server_opts_resolve already applied (concrete slot size / chunk quanta).
@(private)
_server_thread_init_temp :: proc(t: ^Server_Thread, s: ^Server) {
	slot_bytes := s.opts.temp_slot_bytes
	// opts.temp_slots_max after resolve: >0 soft/hard cap; <0 → unlimited (store 0 on thread).
	slots_max := s.opts.temp_slots_max
	if slots_max < 0 {
		slots_max = 0 // 0 on the thread means unlimited in growth checks
	}
	chunk_n := max(1, s.opts.temp_chunk_slots)
	t.temp_slot_size = slot_bytes
	t.temp_slots_max = slots_max
	t.temp_chunks = make([dynamic][]u8, 0, 4, s.conn_allocator)
	t.temp_regions = make([dynamic][]u8, 0, chunk_n, s.conn_allocator)
	t.temp_free = make([dynamic]int, 0, chunk_n, s.conn_allocator)
}

// conn_temp_grow appends one chunk of buffer slots and pushes indices onto temp_free.
// Returns false if at max or slot size is invalid.
@(private)
conn_temp_grow :: proc(s: ^Server) -> bool {
	assert_has_td()
	if td.temp_slot_size <= 0 {
		return false
	}
	n := max(1, s.opts.temp_chunk_slots)
	if td.temp_slots_max > 0 {
		room := td.temp_slots_max - len(td.temp_regions)
		if room <= 0 {
			return false
		}
		n = min(n, room)
	}
	if n <= 0 {
		return false
	}
	chunk_bytes := n * td.temp_slot_size
	chunk := make([]u8, chunk_bytes, s.conn_allocator)
	if chunk == nil || len(chunk) != chunk_bytes {
		log.errorf("temp pool grow failed: n=%d bytes=%d", n, chunk_bytes)
		return false
	}
	append(&td.temp_chunks, chunk)
	for i in 0 ..< n {
		off := i * td.temp_slot_size
		region := chunk[off:off + td.temp_slot_size]
		idx := len(td.temp_regions)
		append(&td.temp_regions, region)
		append(&td.temp_free, idx)
	}
	log.debugf(
		"temp pool grew: +%d slots (total=%d max=%d bytes/slot=%d)",
		n,
		len(td.temp_regions),
		td.temp_slots_max,
		td.temp_slot_size,
	)
	return true
}

// conn_temp_reset rewinds the per-connection request scrap arena (headers/parse only).
// Response bodies live in Connection.resp_buf, not here — used range stays small.
// True bump: cursor = 0, no memset of the slot.
// Safe only while no live pointers into the scrap slot outlive the reset
// (call only after pending_send is cleared / send fully complete).
@(private)
conn_temp_reset :: proc(c: ^Connection) {
	a := &c.temp_allocator
	if a.kind != .Buffer || a.curr_block == nil {
		return
	}
	a.curr_block.used = 0
	a.total_used = 0
}

// conn_temp_attach binds c.temp_allocator to a buffer slot for this worker.
// Slot stays with the Connection for the life of the slab entry.
// Grows the pool when free is empty. Returns false if maxed out or grow fails.
@(private)
conn_temp_attach :: proc(c: ^Connection) -> bool {
	assert_has_td()
	if c.temp_slot >= 0 {
		// Already attached (slab reuse): ensure buffer arena is ready.
		if c.temp_allocator.kind != .Buffer || c.temp_allocator.curr_block == nil {
			if c.temp_slot >= len(td.temp_regions) {
				return false
			}
			region := td.temp_regions[c.temp_slot]
			if virtual.arena_init_buffer(&c.temp_allocator, region) != nil {
				return false
			}
		} else {
			conn_temp_reset(c)
		}
		return true
	}
	if len(td.temp_free) == 0 {
		if !conn_temp_grow(c.server) {
			return false
		}
	}
	if len(td.temp_free) == 0 {
		return false
	}
	slot := pop(&td.temp_free)
	if slot < 0 || slot >= len(td.temp_regions) {
		return false
	}
	region := td.temp_regions[slot]
	if virtual.arena_init_buffer(&c.temp_allocator, region) != nil {
		append(&td.temp_free, slot)
		return false
	}
	c.temp_slot = slot
	return true
}

// conn_scanner_bind ensures c has a RECV_SIZE scanner window (registered pool or dynamic).
@(private)
conn_scanner_bind :: proc(c: ^Connection, s: ^Server) {
	if c.scanner_pooled && len(c.scanner.buf) > 0 {
		c.scanner.connection = c
		return
	}
	if proactr.ring_has_fixed_buffers(&td.ring) {
		if idx, slice, ok := proactr.ring_recv_buf_alloc(&td.ring); ok {
			c.reg_buf_index = idx
			c.scanner_pooled = true
			scanner_init_pooled(&c.scanner, c, slice)
			return
		}
	}
	c.reg_buf_index = -1
	c.scanner_pooled = false
	if c.scanner.buf == nil {
		scanner_init(&c.scanner, c, s.conn_allocator)
	} else {
		c.scanner.connection = c
	}
	recv_n := s.opts.recv_buf_size
	if cap(c.scanner.buf) < recv_n {
		reserve(&c.scanner.buf, recv_n)
	}
	if len(c.scanner.buf) < recv_n {
		resize(&c.scanner.buf, recv_n)
	}
}

// conn_alloc: pop free list or grow a chunk of Connection records (no hot-path new after warm-up).
// Returns nil if the temp pool cannot attach a slot (caller must close the client fd).
@(private)
conn_alloc :: proc(s: ^Server) -> ^Connection {
	assert_has_td()
	c: ^Connection
	if len(td.conn_free) > 0 {
		c = pop(&td.conn_free)
	} else {
		chunk_n := max(1, s.opts.conn_chunk_size)
		chunk := make([]Connection, chunk_n, s.conn_allocator)
		append(&td.conn_chunks, chunk)
		for i in 1 ..< chunk_n {
			chunk[i].fixed_idx = -1
			chunk[i].reg_buf_index = -1
			chunk[i].temp_slot = -1
			chunk[i].file_send_fd = -1
			append(&td.conn_free, &chunk[i])
		}
		c = &chunk[0]
		c.fixed_idx = -1
		c.reg_buf_index = -1
		c.temp_slot = -1
		c.file_send_fd = -1
	}

	c.server = s
	c.socket = {}
	c.state = .Pending
	c.pending_send = nil
	c.exec_i = 0
	c.exec_n = 0
	c.iov_count = 0
	c.kernel_writev_active = false
	c.kernel_sendfile_active = false
	c.file_send_fd = -1
	c.file_send_off = 0
	c.file_send_remaining = 0
	// file_send_buf retained across free-list reuse (allocated lazily).
	c.close_pending = false
	c.close_on_io = false
	c.fixed_idx = -1
	c.loop = {}

	if !conn_temp_attach(c) {
		append(&td.conn_free, c)
		return nil
	}
	conn_scanner_bind(c, s)
	return c
}

// connection_destroy: return to free list (keep pooled scanner, temp slot, resp_buf for reuse).
// Caller must not destroy while pending_send still points at response bytes.
@(private)
connection_destroy :: proc(c: ^Connection) {
	c.state = .Closed
	conn_temp_reset(c)

	if td != nil {
		delete_key(&td.conns, c.socket)
	}
	c.socket = {}
	// Drop multi-buffer queue + pending + file-send cursor (keep free-list clean).
	c.pending_send = nil
	c.exec_i = 0
	c.exec_n = 0
	c.iov_count = 0
	c.kernel_writev_active = false
	c.kernel_sendfile_active = false
	for i in 0 ..< len(c.exec_bufs) {
		c.exec_bufs[i] = nil
	}
	c.file_send_fd = -1
	c.file_send_off = 0
	c.file_send_remaining = 0
	// Keep file_send_buf allocation for reuse.
	c.close_pending = false
	c.close_on_io = false
	// Capture any growth from the last Response binding; keep capacity on free list.
	if c.loop.res._buf.buf != nil {
		c.resp_buf = c.loop.res._buf.buf
	}
	c.loop = {}

	scanner_prepare(c)
	c.scanner.connection = nil

	// fixed_idx already cleared in host_on_close / sync close path.
	c.fixed_idx = -1

	if td != nil {
		append(&td.conn_free, c)
	} else {
		if !c.scanner_pooled {
			scanner_destroy(&c.scanner)
		}
		if c.resp_buf != nil {
			delete(c.resp_buf)
			c.resp_buf = nil
		}
		if c.file_send_buf != nil {
			if c.server != nil {
				delete(c.file_send_buf, c.server.conn_allocator)
			} else {
				delete(c.file_send_buf)
			}
			c.file_send_buf = nil
		}
		free(c, c.server.conn_allocator)
	}
}

// _server_thread_free_slab releases conn chunks, scanners, resp_buf, and temp pool after workers exit.
@(private)
_server_thread_free_slab :: proc(t: ^Server_Thread) {
	// Tear down scanners / permanent response buffers before freeing chunks
	// (dynamic owns buf; pooled scanner points into ring pool).
	for chunk in t.conn_chunks {
		for &c in chunk {
			if c.scanner_pooled {
				// Pool memory is owned by the ring (already destroyed); drop the view.
				c.scanner.buf = nil
				c.scanner_pooled = false
				c.reg_buf_index = -1
			} else if c.scanner.buf != nil {
				scanner_destroy(&c.scanner)
			}
			// Ownership is Connection.resp_buf; r._buf.buf is a header copy that
			// may have grown past a stale resp_buf. Sync first (same as destroy).
			if c.loop.res._buf.buf != nil {
				c.resp_buf = c.loop.res._buf.buf
			}
			if c.resp_buf != nil {
				delete(c.resp_buf)
				c.resp_buf = nil
			}
			if c.file_send_buf != nil {
				// Allocated with server.conn_allocator (see _conn_ensure_file_send_buf).
				if c.server != nil {
					delete(c.file_send_buf, c.server.conn_allocator)
				} else {
					delete(c.file_send_buf)
				}
				c.file_send_buf = nil
			}
			c.loop.res._buf = {}
			c.temp_slot = -1
			c.temp_allocator = {}
		}
		delete(chunk)
	}
	delete(t.conn_chunks)
	delete(t.conn_free)
	for chunk in t.temp_chunks {
		delete(chunk)
	}
	delete(t.temp_chunks)
	delete(t.temp_regions)
	delete(t.temp_free)
	t.conn_chunks = nil
	t.conn_free = nil
	t.temp_chunks = nil
	t.temp_regions = nil
	t.temp_free = nil
	t.temp_slot_size = 0
	t.temp_slots_max = 0
}
