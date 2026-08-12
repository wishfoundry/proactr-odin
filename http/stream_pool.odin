// Fixed-size stream send buffers for progressive Stream / Session (follow-up pins).
// Each Stream send takes one 8 KiB slab from a per-worker free list; returned on CQE.
package http

import "core:log"
import "core:sync"

// Default slab size for one Stream send (design pin: 8 KiB).
STREAM_BUF_SIZE_DEFAULT :: 8 * 1024

// Default worker total admitted stream buffer bytes.
STREAM_BYTES_TOTAL_DEFAULT :: 64 * 1024 * 1024

// Per-worker pool state (lives on Server_Thread).
Stream_Buf_Pool :: struct {
	slot_size:   int,
	// Free list of []u8 slabs (each len==slot_size, owned by pool chunks).
	free:        [dynamic][]u8,
	// Owned backing chunks for free/delete on teardown.
	chunks:      [dynamic][]u8,
	// Bytes currently checked out (slots outstanding).
	admitted:    int,
	// Cap on admitted bytes (0 → STREAM_BYTES_TOTAL_DEFAULT).
	max_total:   int,
}

@(private)
_stream_pool_init :: proc(p: ^Stream_Buf_Pool, slot_size: int, max_total: int, allocator := context.allocator) {
	p.slot_size = slot_size if slot_size > 0 else STREAM_BUF_SIZE_DEFAULT
	p.max_total = max_total if max_total > 0 else STREAM_BYTES_TOTAL_DEFAULT
	p.free = make([dynamic][]u8, 0, 32, allocator)
	p.chunks = make([dynamic][]u8, 0, 4, allocator)
	p.admitted = 0
}

@(private)
_stream_pool_destroy :: proc(p: ^Stream_Buf_Pool, allocator := context.allocator) {
	for c in p.chunks {
		delete(c, allocator)
	}
	delete(p.chunks)
	delete(p.free)
	p^ = {}
}

// Grow free list by one slab if under max_total (admitted + free inventory).
@(private)
_stream_pool_grow :: proc(p: ^Stream_Buf_Pool, allocator := context.allocator) -> bool {
	inventory := p.admitted + len(p.free) * p.slot_size
	if inventory + p.slot_size > p.max_total {
		return false
	}
	slab := make([]u8, p.slot_size, allocator)
	if slab == nil {
		return false
	}
	append(&p.chunks, slab)
	append(&p.free, slab)
	return true
}

// Take one slab for Stream send. Returns nil if admission fails.
@(private)
stream_pool_take :: proc() -> []u8 {
	assert_has_td()
	p := &td.stream_pool
	if len(p.free) == 0 {
		if !_stream_pool_grow(p, td.server.conn_allocator) {
			sync.atomic_add(&session_metrics_pool_reject, 1)
			return nil
		}
	}
	if len(p.free) == 0 {
		sync.atomic_add(&session_metrics_pool_reject, 1)
		return nil
	}
	slab := pop(&p.free)
	p.admitted += p.slot_size
	sync.atomic_add(&session_metrics_stream_bytes_admitted, i64(p.slot_size))
	return slab
}

@(private)
stream_pool_put :: proc(slab: []u8) {
	if slab == nil || len(slab) == 0 {
		return
	}
	assert_has_td()
	p := &td.stream_pool
	// Only accept exact pool-sized slabs.
	if len(slab) != p.slot_size {
		log.debugf("stream_pool_put: unexpected size %d (want %d)", len(slab), p.slot_size)
		return
	}
	p.admitted -= p.slot_size
	if p.admitted < 0 {
		p.admitted = 0
	}
	sync.atomic_add(&session_metrics_stream_bytes_admitted, -i64(p.slot_size))
	append(&p.free, slab)
}
