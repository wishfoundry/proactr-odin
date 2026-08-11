// Package hpack: RFC 7541 HPACK for HTTP/2. Full decoder (static + dynamic
// table, all literal forms, size updates, Huffman). Encoder supports an optional
// HPackEncoder with a dynamic table (Indexed / incremental / never-indexed);
// without it, behaviour is static-only for tests and simple call sites.
// Header type is shared with QPACK/H3 (package httpfield).
package hpack

import "core:mem"
import "core:strings"

import "../huffman"
import "../httpfield"

DYNAMIC_ENTRY_OVERHEAD :: 32 // RFC 7541 §4.1

// Hard cap on a single HPACK string payload (decoded length). Protects against
// huge length prefixes before allocation; also rejects lengths past remaining
// input in decode_string.
MAX_STRING_LEN :: 16 * 1024 * 1024 // 16 MiB

// Shared with QPACK / H3 / client — see package httpfield.
Header :: httpfield.Header
// Re-export destroy so existing hpack.headers_destroy call sites keep working.
headers_destroy :: httpfield.headers_destroy

Hpack_Error :: enum {
	None,
	Truncated,
	Bad_Index,
	Bad_Huffman,
	Bad_Integer,
	Bad_Size_Update, // beyond the SETTINGS bound, or not at the block start
	List_Too_Large,  // decoded header list exceeded max_list_size budget
}

// ---- Dynamic table (RFC 7541 §2.3.2) — ring buffer, O(1) insert/get/evict ----

// Ring: index 0 on the wire-relative scale is the most recently inserted entry.
// Physical slot of relative r is (head - r) mod capacity.
HPackDynamicTable :: struct {
	slots:     [dynamic]Header, // ring storage; length == capacity
	head:      int,             // physical index of most recent when count > 0
	count:     int,             // live entries
	size:      int,             // current size in bytes
	max_size:  int,             // current limit (lowerable by size updates)
	limit:     int,             // SETTINGS_HEADER_TABLE_SIZE — updates may not exceed it
	allocator: mem.Allocator,
}

init :: proc(dt: ^HPackDynamicTable, max_size := 4096, allocator := context.allocator) {
	dt.allocator = allocator
	dt.slots.allocator = allocator
	dt.max_size = max_size
	dt.limit = max_size
	dt.head = 0
	dt.count = 0
	dt.size = 0
}

destroy :: proc(dt: ^HPackDynamicTable) {
	for i in 0 ..< dt.count {
		e := ring_at(dt, i)
		if e.name_owned do delete(e.name, dt.allocator)
		if e.value_owned do delete(e.value, dt.allocator)
	}
	delete(dt.slots)
	dt.head = 0
	dt.count = 0
	dt.size = 0
}

@(private)
entry_size :: proc(h: Header) -> int {
	return len(h.name) + len(h.value) + DYNAMIC_ENTRY_OVERHEAD
}

// Physical slot for relative index r (0 = most recent).
@(private)
ring_phys :: proc(dt: ^HPackDynamicTable, rel: int) -> int {
	cap := len(dt.slots)
	return (dt.head - rel + cap) % cap
}

@(private)
ring_at :: proc(dt: ^HPackDynamicTable, rel: int) -> Header {
	return dt.slots[ring_phys(dt, rel)]
}

@(private)
ring_ensure_slot :: proc(dt: ^HPackDynamicTable) {
	if dt.count < len(dt.slots) do return
	new_cap := 8 if len(dt.slots) == 0 else len(dt.slots) * 2
	new_slots := make([dynamic]Header, new_cap, dt.allocator)
	// Copy oldest → newest into [0 .. count).
	for i in 0 ..< dt.count {
		rel := dt.count - 1 - i // chronological position i has relative (count-1-i)
		new_slots[i] = ring_at(dt, rel)
	}
	delete(dt.slots)
	dt.slots = new_slots
	if dt.count > 0 {
		dt.head = dt.count - 1
	} else {
		dt.head = 0
	}
}

@(private)
evict_oldest :: proc(dt: ^HPackDynamicTable) {
	if dt.count == 0 do return
	// Oldest has relative index count-1.
	phys := ring_phys(dt, dt.count - 1)
	old := dt.slots[phys]
	dt.size -= entry_size(old)
	if old.name_owned do delete(old.name, dt.allocator)
	if old.value_owned do delete(old.value, dt.allocator)
	dt.slots[phys] = {}
	dt.count -= 1
}

// Insert a header by cloning name/value, then taking ownership of the clones.
insert :: proc(dt: ^HPackDynamicTable, h: Header) {
	owned := Header {
		name        = strings.clone(h.name, dt.allocator),
		value       = strings.clone(h.value, dt.allocator),
		name_owned  = true,
		value_owned = true,
	}
	insert_owned(dt, owned)
}

// Insert into the dynamic table, ensuring the table always owns its strings.
// If name/value are not owned (borrowed), clones them before storing so eviction
// never frees rodata. On reject (entry larger than max_size even when empty),
// frees any owned strings (including clones made here).
insert_owned :: proc(dt: ^HPackDynamicTable, h: Header) {
	// Table always owns: clone borrowed fields before any free-on-evict path.
	owned := h
	if !owned.name_owned {
		owned.name = strings.clone(owned.name, dt.allocator)
		owned.name_owned = true
	}
	if !owned.value_owned {
		owned.value = strings.clone(owned.value, dt.allocator)
		owned.value_owned = true
	}
	es := entry_size(owned)
	for dt.size + es > dt.max_size && dt.count > 0 {
		evict_oldest(dt)
	}
	if es > dt.max_size {
		// Entry alone exceeds table; RFC 7541 §4.4 — empty the table (already)
		// and refuse the entry. Free our owned strings.
		delete(owned.name, dt.allocator)
		delete(owned.value, dt.allocator)
		return
	}
	ring_ensure_slot(dt)
	if dt.count == 0 {
		dt.head = 0
	} else {
		dt.head = (dt.head + 1) % len(dt.slots)
	}
	dt.slots[dt.head] = owned
	dt.count += 1
	dt.size += es
}

set_max :: proc(dt: ^HPackDynamicTable, new_max: int) {
	dt.max_size = new_max
	for dt.size > dt.max_size && dt.count > 0 {
		evict_oldest(dt)
	}
}

// Resolve a 0-based dynamic-table index (0 = most recent).
get :: proc(dt: ^HPackDynamicTable, rel_index: int) -> (Header, bool) {
	if rel_index < 0 || rel_index >= dt.count do return {}, false
	return ring_at(dt, rel_index), true
}

// ---- Static table (RFC 7541 Appendix A), 1-indexed on the wire -------------

HPACK_STATIC_LEN :: 61

@(rodata)
HPACK_STATIC := [HPACK_STATIC_LEN]Header {
	{name = ":authority", value = ""},                  //  1
	{name = ":method", value = "GET"},                  //  2
	{name = ":method", value = "POST"},                 //  3
	{name = ":path", value = "/"},                      //  4
	{name = ":path", value = "/index.html"},            //  5
	{name = ":scheme", value = "http"},                 //  6
	{name = ":scheme", value = "https"},                //  7
	{name = ":status", value = "200"},                  //  8
	{name = ":status", value = "204"},                  //  9
	{name = ":status", value = "206"},                  // 10
	{name = ":status", value = "304"},                  // 11
	{name = ":status", value = "400"},                  // 12
	{name = ":status", value = "404"},                  // 13
	{name = ":status", value = "500"},                  // 14
	{name = "accept-charset", value = ""},              // 15
	{name = "accept-encoding", value = "gzip, deflate"},// 16
	{name = "accept-language", value = ""},             // 17
	{name = "accept-ranges", value = ""},               // 18
	{name = "accept", value = ""},                      // 19
	{name = "access-control-allow-origin", value = ""}, // 20
	{name = "age", value = ""},                         // 21
	{name = "allow", value = ""},                       // 22
	{name = "authorization", value = ""},               // 23
	{name = "cache-control", value = ""},               // 24
	{name = "content-disposition", value = ""},         // 25
	{name = "content-encoding", value = ""},            // 26
	{name = "content-language", value = ""},            // 27
	{name = "content-length", value = ""},              // 28
	{name = "content-location", value = ""},            // 29
	{name = "content-range", value = ""},               // 30
	{name = "content-type", value = ""},                // 31
	{name = "cookie", value = ""},                      // 32
	{name = "date", value = ""},                        // 33
	{name = "etag", value = ""},                        // 34
	{name = "expect", value = ""},                      // 35
	{name = "expires", value = ""},                     // 36
	{name = "from", value = ""},                        // 37
	{name = "host", value = ""},                        // 38
	{name = "if-match", value = ""},                    // 39
	{name = "if-modified-since", value = ""},           // 40
	{name = "if-none-match", value = ""},               // 41
	{name = "if-range", value = ""},                    // 42
	{name = "if-unmodified-since", value = ""},         // 43
	{name = "last-modified", value = ""},               // 44
	{name = "link", value = ""},                        // 45
	{name = "location", value = ""},                    // 46
	{name = "max-forwards", value = ""},                // 47
	{name = "proxy-authenticate", value = ""},          // 48
	{name = "proxy-authorization", value = ""},         // 49
	{name = "range", value = ""},                       // 50
	{name = "referer", value = ""},                     // 51
	{name = "refresh", value = ""},                     // 52
	{name = "retry-after", value = ""},                 // 53
	{name = "server", value = ""},                      // 54
	{name = "set-cookie", value = ""},                  // 55
	{name = "strict-transport-security", value = ""},   // 56
	{name = "transfer-encoding", value = ""},           // 57
	{name = "user-agent", value = ""},                  // 58
	{name = "vary", value = ""},                        // 59
	{name = "via", value = ""},                         // 60
	{name = "www-authenticate", value = ""},            // 61
}

// Resolve a 1-based HPACK index (RFC 7541 §2.3.3): static table first, then the
// dynamic table. Index 0 is invalid for an indexed reference.
table_get :: proc(dt: ^HPackDynamicTable, index: int) -> (Header, bool) {
	if index < 1 do return {}, false
	if index <= HPACK_STATIC_LEN do return HPACK_STATIC[index - 1], true
	di := index - HPACK_STATIC_LEN - 1
	return get(dt, di)
}

// ---- String literals (RFC 7541 §5.2) — 7-bit length prefix, H bit on top ---

@(private = "file")
encode_string :: proc(dst: ^[dynamic]u8, s: string, use_huffman: bool) {
	data := transmute([]u8)s
	if use_huffman {
		hlen := huffman.encoded_len(data)
		if hlen < len(data) {
			prefix_int_encode(dst, u64(hlen), 7, 0x80)
			scratch := make([]u8, hlen, context.temp_allocator)
			huffman.encode(scratch, data)
			append(dst, ..scratch)
			return
		}
	}
	prefix_int_encode(dst, u64(len(data)), 7, 0x00)
	append(dst, ..data)
}

@(private = "file")
decode_string :: proc(
	src: []u8, allocator: mem.Allocator,
) -> (s: string, consumed: int, err: Hpack_Error) {
	if len(src) == 0 do return "", 0, .Truncated
	huff := src[0] & 0x80 != 0
	length, c, ie := prefix_int_decode(src, 7)
	if ie != .None do return "", 0, ie
	consumed = c
	// Reject absurd / non-fitting lengths before any allocation or int cast.
	if length > u64(MAX_STRING_LEN) do return "", 0, .Bad_Integer
	remaining := len(src) - consumed
	if remaining < 0 || length > u64(remaining) do return "", 0, .Truncated
	n := int(length) // safe: length <= MAX_STRING_LEN <= max(int) for our targets
	raw := src[consumed:consumed + n]
	consumed += n
	if huff {
		// Single alloc when shrink succeeds: decode → shrink(cap==len) → transfer to
		// string (no second copy). delete(string) frees with len; needs cap==len.
		// If shrink fails, fall back to exact make+copy so free size is correct.
		dec: [dynamic]u8
		dec.allocator = allocator
		// Huffman expands at most ~2x for typical HTTP; reserve avoids grow thrash.
		reserve(&dec, max(8, n * 2))
		if huffman.decode(&dec, raw) != .None {
			delete(dec)
			return "", 0, .Bad_Huffman
		}
		out_n := len(dec)
		if out_n == 0 {
			delete(dec)
			return "", consumed, .None
		}
		// Transfer only when free size matches len (delete(string) uses len).
		_, _ = shrink(&dec)
		if cap(dec) == out_n {
			// Transfer buffer ownership; do not delete(dec) — caller owns the string.
			return string(dec[:out_n]), consumed, .None
		}
		exact := make([]u8, out_n, allocator)
		copy(exact, dec[:out_n])
		delete(dec)
		return string(exact), consumed, .None
	}
	return strings.clone(string(raw), allocator), consumed, .None
}

// ---- Encoder ---------------------------------------------------------------

// Optional encoder state: mirrors what the peer decoder will see after our
// incremental-indexing emissions. When nil is passed to encode, behaviour is
// static-only (Literal Without Indexing for non-static pairs).
HPackEncoder :: struct {
	dt:                 HPackDynamicTable,
	pending_size:       int,  // value for a Dynamic Table Size Update to emit
	has_pending_size:   bool,
}

encoder_init :: proc(enc: ^HPackEncoder, max_size := 4096, allocator := context.allocator) {
	init(&enc.dt, max_size, allocator)
	enc.pending_size = 0
	enc.has_pending_size = false
}

encoder_destroy :: proc(enc: ^HPackEncoder) {
	destroy(&enc.dt)
	enc.has_pending_size = false
}

// Apply peer SETTINGS_HEADER_TABLE_SIZE (or a manual max). Raises/lowers the
// encoder hard limit, queues a Dynamic Table Size Update for the next encode,
// and shrinks the live table if needed (via set_max at encode time).
encoder_set_max :: proc(enc: ^HPackEncoder, new_max: int) {
	if new_max < 0 do return
	// Peer may raise or lower the hard ceiling.
	enc.dt.limit = new_max
	enc.pending_size = new_max
	enc.has_pending_size = true
}

// Sensitive header names (HTTP/2 lowercase) — encoded as Never Indexed so they
// never enter the dynamic table (RFC 7541 §7.1.3 guidance).
@(private = "file")
is_sensitive_header :: proc(name: string) -> bool {
	switch name {
	case "authorization", "cookie", "set-cookie", "proxy-authorization":
		return true
	}
	return false
}

// encode: if enc == nil, static exact match → Indexed, else Literal Without
// Indexing. If enc != nil: static/dynamic exact → Indexed; sensitive → Never
// Indexed; else Literal with Incremental Indexing + insert_owned into enc.dt.
encode :: proc(
	dst: ^[dynamic]u8,
	headers: []Header,
	enc: ^HPackEncoder = nil,
	use_huffman := true,
) {
	if enc != nil && enc.has_pending_size {
		prefix_int_encode(dst, u64(enc.pending_size), 5, 0x20)
		set_max(&enc.dt, enc.pending_size)
		enc.has_pending_size = false
	}

	for h in headers {
		if enc != nil {
			if idx, ok := find_pair(&enc.dt, h.name, h.value); ok {
				prefix_int_encode(dst, u64(idx), 7, 0x80)
				continue
			}
			if is_sensitive_header(h.name) {
				// Never Indexed — 4-bit name prefix, pattern 0001.
				if nidx, ok := find_name(&enc.dt, h.name); ok {
					prefix_int_encode(dst, u64(nidx), 4, 0x10)
				} else {
					prefix_int_encode(dst, 0, 4, 0x10)
					encode_string(dst, h.name, use_huffman)
				}
				encode_string(dst, h.value, use_huffman)
				continue
			}
			// Literal With Incremental Indexing — 6-bit name prefix, pattern 01.
			if nidx, ok := find_name(&enc.dt, h.name); ok {
				prefix_int_encode(dst, u64(nidx), 6, 0x40)
			} else {
				prefix_int_encode(dst, 0, 6, 0x40)
				encode_string(dst, h.name, use_huffman)
			}
			encode_string(dst, h.value, use_huffman)
			owned := Header {
				name        = strings.clone(h.name, enc.dt.allocator),
				value       = strings.clone(h.value, enc.dt.allocator),
				name_owned  = true,
				value_owned = true,
			}
			insert_owned(&enc.dt, owned)
			continue
		}

		// Stateless path (enc == nil).
		if idx, ok := static_find_pair(h.name, h.value); ok {
			prefix_int_encode(dst, u64(idx), 7, 0x80)
			continue
		}
		if nidx, ok := static_find_name(h.name); ok {
			prefix_int_encode(dst, u64(nidx), 4, 0x00)
		} else {
			prefix_int_encode(dst, 0, 4, 0x00)
			encode_string(dst, h.name, use_huffman)
		}
		encode_string(dst, h.value, use_huffman)
	}
}

@(private = "file")
static_find_pair :: proc(name, value: string) -> (index: int, ok: bool) {
	for e, i in HPACK_STATIC {
		if e.name == name && e.value == value do return i + 1, true
	}
	return 0, false
}

@(private = "file")
static_find_name :: proc(name: string) -> (index: int, ok: bool) {
	for e, i in HPACK_STATIC {
		if e.name == name do return i + 1, true
	}
	return 0, false
}

// Exact name+value in static then dynamic (1-based wire index).
@(private = "file")
find_pair :: proc(dt: ^HPackDynamicTable, name, value: string) -> (index: int, ok: bool) {
	if idx, found := static_find_pair(name, value); found do return idx, true
	for rel in 0 ..< dt.count {
		e := ring_at(dt, rel)
		if e.name == name && e.value == value {
			return HPACK_STATIC_LEN + 1 + rel, true
		}
	}
	return 0, false
}

// Name-only match in static then dynamic (1-based wire index).
@(private = "file")
find_name :: proc(dt: ^HPackDynamicTable, name: string) -> (index: int, ok: bool) {
	if idx, found := static_find_name(name); found do return idx, true
	for rel in 0 ..< dt.count {
		e := ring_at(dt, rel)
		if e.name == name {
			return HPACK_STATIC_LEN + 1 + rel, true
		}
	}
	return 0, false
}

// ---- Decoder ---------------------------------------------------------------
// Full: indexed, all literal forms, and dynamic table size updates. Maintains
// `dt` so the peer's incremental-indexing stays in sync. Appends decoded
// headers to `out`; strings are allocated from `allocator` except borrowed
// static indexed headers (name_owned/value_owned false).
// max_list_size: if > 0, cap the decoded list using HPACK entry sizing
// (name+value+32) per emitted field. Exceeding returns List_Too_Large.

decode :: proc(
	dt: ^HPackDynamicTable,
	block: []u8,
	out: ^[dynamic]Header,
	allocator := context.allocator,
	max_list_size := 0,
) -> Hpack_Error {
	pos := 0
	seen_field := false
	list_size := 0
	for pos < len(block) {
		b := block[pos]
		switch {
		case b & 0x80 != 0:
			// Indexed Header Field — index is a 7-bit prefix.
			idx, c, e := prefix_int_decode(block[pos:], 7)
			if e != .None do return .Bad_Integer
			pos += c
			if idx == 0 do return .Bad_Index
			// Safe cast: prefix_int_decode caps at MAX_PREFIX_INT.
			h, ok := table_get(dt, int(idx))
			if !ok do return .Bad_Index
			emitted: Header
			if idx <= u64(HPACK_STATIC_LEN) {
				// Borrow eternal static strings — owned flags stay false.
				emitted = Header{name = h.name, value = h.value}
			} else {
				emitted = clone_header(h, allocator)
			}
			if err := account_list_size(&list_size, max_list_size, emitted, allocator); err != .None {
				header_free(emitted, allocator)
				return err
			}
			append(out, emitted)
			seen_field = true

		case b & 0xC0 == 0x40:
			// Literal With Incremental Indexing — name 6-bit prefix; adds to dt.
			h := decode_literal(dt, block[pos:], 6, &pos, allocator) or_return
			// out gets an independent clone; table takes ownership of h.
			emitted := clone_header(h, allocator)
			if err := account_list_size(&list_size, max_list_size, emitted, allocator); err != .None {
				// Free both the out clone and the table-bound original.
				header_free(emitted, allocator)
				header_free(h, allocator)
				return err
			}
			append(out, emitted)
			insert_owned(dt, h)
			seen_field = true

		case b & 0xE0 == 0x20:
			// Dynamic Table Size Update — 5-bit prefix. Must precede every
			// header field (RFC 7541 §4.2) and stay within the size we
			// advertised in SETTINGS_HEADER_TABLE_SIZE.
			if seen_field do return .Bad_Size_Update
			sz, c, e := prefix_int_decode(block[pos:], 5)
			if e != .None do return .Bad_Integer
			if int(sz) > dt.limit do return .Bad_Size_Update
			pos += c
			set_max(dt, int(sz))

		case:
			// Literal Without Indexing (0000) / Never Indexed (0001) — 4-bit.
			h := decode_literal(dt, block[pos:], 4, &pos, allocator) or_return
			if err := account_list_size(&list_size, max_list_size, h, allocator); err != .None {
				header_free(h, allocator)
				return err
			}
			append(out, h)
			seen_field = true
		}
	}
	return .None
}

// Accumulate HPACK entry size for one emitted field; free nothing — caller
// frees on error. Returns List_Too_Large if the budget is exceeded.
@(private = "file")
account_list_size :: proc(
	list_size: ^int, max_list_size: int, h: Header, allocator: mem.Allocator,
) -> Hpack_Error {
	_ = allocator
	if max_list_size <= 0 do return .None
	list_size^ += entry_size(h)
	if list_size^ > max_list_size do return .List_Too_Large
	return .None
}

@(private = "file")
header_free :: proc(h: Header, allocator: mem.Allocator) {
	if h.name_owned do delete(h.name, allocator)
	if h.value_owned do delete(h.value, allocator)
}

@(private = "file")
decode_literal :: proc(
	dt: ^HPackDynamicTable, src: []u8, name_prefix: uint, pos: ^int, allocator: mem.Allocator,
) -> (h: Header, err: Hpack_Error) {
	nidx, c, e := prefix_int_decode(src, name_prefix)
	if e != .None do return {}, .Bad_Integer
	off := c
	if nidx == 0 {
		name, nc := decode_string(src[off:], allocator) or_return
		off += nc
		h.name = name
		h.name_owned = true
	} else {
		ent, ok := table_get(dt, int(nidx))
		if !ok do return {}, .Bad_Index
		// Always clone: may come from static or dynamic; out/table need owned
		// strings when this header is later insert_owned.
		h.name = strings.clone(ent.name, allocator)
		h.name_owned = true
	}
	value, vc, ve := decode_string(src[off:], allocator)
	if ve != .None {
		// Name was already allocated; free before returning the error.
		if h.name_owned do delete(h.name, allocator)
		return {}, ve
	}
	off += vc
	h.value = value
	h.value_owned = true
	pos^ += off
	return h, .None
}

@(private = "file")
clone_header :: proc(h: Header, allocator: mem.Allocator) -> Header {
	return Header {
		name        = strings.clone(h.name, allocator),
		value       = strings.clone(h.value, allocator),
		name_owned  = true,
		value_owned = true,
	}
}


