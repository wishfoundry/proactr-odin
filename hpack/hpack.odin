// Package hpack: RFC 7541 HPACK for HTTP/2. Full decoder (static + dynamic
// table, all literal forms, size updates, Huffman). Encoder is deliberately
// simple: static exact match → Indexed; else Literal Without Indexing (no
// encoder dynamic table / size updates). Owned Header type; no vapor/qpack.
package hpack

import "core:mem"
import "core:strings"

import "../huffman"

DYNAMIC_ENTRY_OVERHEAD :: 32 // RFC 7541 §4.1

Header :: struct {
	name, value: string,
}

Hpack_Error :: enum {
	None,
	Truncated,
	Bad_Index,
	Bad_Huffman,
	Bad_Integer,
	Bad_Size_Update, // beyond the SETTINGS bound, or not at the block start
}

// ---- Dynamic table (RFC 7541 §2.3.2) — ordered, size-evicting ---------------

HPackDynamicTable :: struct {
	entries:   [dynamic]Header, // index 0 = most recently inserted
	size:      int,             // current size in bytes
	max_size:  int,             // current limit (lowerable by size updates)
	limit:     int,             // SETTINGS_HEADER_TABLE_SIZE — updates may not exceed it
	allocator: mem.Allocator,
}

init :: proc(dt: ^HPackDynamicTable, max_size := 4096, allocator := context.allocator) {
	dt.allocator = allocator
	dt.entries.allocator = allocator
	dt.max_size = max_size
	dt.limit = max_size
}

destroy :: proc(dt: ^HPackDynamicTable) {
	for e in dt.entries {
		delete(e.name, dt.allocator)
		delete(e.value, dt.allocator)
	}
	delete(dt.entries)
}

@(private)
entry_size :: proc(h: Header) -> int {
	return len(h.name) + len(h.value) + DYNAMIC_ENTRY_OVERHEAD
}

// Insert a header (cloned) at the front, evicting oldest entries until within
// max_size. An entry larger than max_size empties the table (RFC 7541 §4.4).
insert :: proc(dt: ^HPackDynamicTable, h: Header) {
	es := entry_size(h)
	for dt.size + es > dt.max_size && len(dt.entries) > 0 {
		old := pop(&dt.entries) // evict oldest (back)
		dt.size -= entry_size(old)
		delete(old.name, dt.allocator)
		delete(old.value, dt.allocator)
	}
	if es > dt.max_size do return // doesn't fit even when empty
	owned := Header{strings.clone(h.name, dt.allocator), strings.clone(h.value, dt.allocator)}
	inject_at(&dt.entries, 0, owned)
	dt.size += es
}

set_max :: proc(dt: ^HPackDynamicTable, new_max: int) {
	dt.max_size = new_max
	for dt.size > dt.max_size && len(dt.entries) > 0 {
		old := pop(&dt.entries)
		dt.size -= entry_size(old)
		delete(old.name, dt.allocator)
		delete(old.value, dt.allocator)
	}
}

// Resolve a 0-based dynamic-table index (0 = most recent).
get :: proc(dt: ^HPackDynamicTable, rel_index: int) -> (Header, bool) {
	if rel_index < 0 || rel_index >= len(dt.entries) do return {}, false
	return dt.entries[rel_index], true
}

// ---- Static table (RFC 7541 Appendix A), 1-indexed on the wire -------------

HPACK_STATIC_LEN :: 61

@(rodata)
HPACK_STATIC := [HPACK_STATIC_LEN]Header {
	{":authority", ""},                  //  1
	{":method", "GET"},                  //  2
	{":method", "POST"},                 //  3
	{":path", "/"},                      //  4
	{":path", "/index.html"},            //  5
	{":scheme", "http"},                 //  6
	{":scheme", "https"},                //  7
	{":status", "200"},                  //  8
	{":status", "204"},                  //  9
	{":status", "206"},                  // 10
	{":status", "304"},                  // 11
	{":status", "400"},                  // 12
	{":status", "404"},                  // 13
	{":status", "500"},                  // 14
	{"accept-charset", ""},              // 15
	{"accept-encoding", "gzip, deflate"},// 16
	{"accept-language", ""},             // 17
	{"accept-ranges", ""},               // 18
	{"accept", ""},                      // 19
	{"access-control-allow-origin", ""}, // 20
	{"age", ""},                         // 21
	{"allow", ""},                       // 22
	{"authorization", ""},               // 23
	{"cache-control", ""},               // 24
	{"content-disposition", ""},         // 25
	{"content-encoding", ""},            // 26
	{"content-language", ""},            // 27
	{"content-length", ""},              // 28
	{"content-location", ""},            // 29
	{"content-range", ""},               // 30
	{"content-type", ""},                // 31
	{"cookie", ""},                      // 32
	{"date", ""},                        // 33
	{"etag", ""},                        // 34
	{"expect", ""},                      // 35
	{"expires", ""},                     // 36
	{"from", ""},                        // 37
	{"host", ""},                        // 38
	{"if-match", ""},                    // 39
	{"if-modified-since", ""},           // 40
	{"if-none-match", ""},               // 41
	{"if-range", ""},                    // 42
	{"if-unmodified-since", ""},         // 43
	{"last-modified", ""},               // 44
	{"link", ""},                        // 45
	{"location", ""},                    // 46
	{"max-forwards", ""},                // 47
	{"proxy-authenticate", ""},          // 48
	{"proxy-authorization", ""},         // 49
	{"range", ""},                       // 50
	{"referer", ""},                     // 51
	{"refresh", ""},                     // 52
	{"retry-after", ""},                 // 53
	{"server", ""},                      // 54
	{"set-cookie", ""},                  // 55
	{"strict-transport-security", ""},   // 56
	{"transfer-encoding", ""},           // 57
	{"user-agent", ""},                  // 58
	{"vary", ""},                        // 59
	{"via", ""},                         // 60
	{"www-authenticate", ""},            // 61
}

// Resolve a 1-based HPACK index (RFC 7541 §2.3.3): static table first, then the
// dynamic table. Index 0 is invalid for an indexed reference.
table_get :: proc(dt: ^HPackDynamicTable, index: int) -> (Header, bool) {
	if index < 1 do return {}, false
	if index <= HPACK_STATIC_LEN do return HPACK_STATIC[index - 1], true
	di := index - HPACK_STATIC_LEN - 1
	if di < 0 || di >= len(dt.entries) do return {}, false
	return dt.entries[di], true
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
	if ie != .None do return "", 0, .Bad_Integer
	consumed = c
	if consumed + int(length) > len(src) do return "", 0, .Truncated
	raw := src[consumed:consumed + int(length)]
	consumed += int(length)
	if huff {
		dec: [dynamic]u8
		dec.allocator = allocator
		if huffman.decode(&dec, raw) != .None {
			delete(dec)
			return "", 0, .Bad_Huffman
		}
		return string(dec[:]), consumed, .None
	}
	return strings.clone(string(raw), allocator), consumed, .None
}

// ---- Encoder ---------------------------------------------------------------
// Simple + stateless: exact static match → Indexed; else Literal Without
// Indexing (does not grow our dynamic table). The peer's decoder still tracks
// any entries it chooses to index.

encode :: proc(dst: ^[dynamic]u8, headers: []Header, use_huffman := true) {
	for h in headers {
		if idx, ok := static_find_pair(h.name, h.value); ok {
			prefix_int_encode(dst, u64(idx), 7, 0x80) // Indexed Header Field
			continue
		}
		// Literal Without Indexing (0000) — name ref if known, else literal.
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

// ---- Decoder ---------------------------------------------------------------
// Full: indexed, all literal forms, and dynamic table size updates. Maintains
// `dt` so the peer's incremental-indexing stays in sync. Appends decoded
// headers to `out`; strings are allocated from `allocator`.

decode :: proc(
	dt: ^HPackDynamicTable, block: []u8, out: ^[dynamic]Header, allocator := context.allocator,
) -> Hpack_Error {
	pos := 0
	seen_field := false
	for pos < len(block) {
		b := block[pos]
		switch {
		case b & 0x80 != 0:
			// Indexed Header Field — index is a 7-bit prefix.
			idx, c, e := prefix_int_decode(block[pos:], 7)
			if e != .None do return .Bad_Integer
			pos += c
			h, ok := table_get(dt, int(idx))
			if !ok do return .Bad_Index
			append(out, clone_header(h, allocator))
			seen_field = true

		case b & 0xC0 == 0x40:
			// Literal With Incremental Indexing — name 6-bit prefix; adds to dt.
			h := decode_literal(dt, block[pos:], 6, &pos, allocator) or_return
			insert(dt, h)
			append(out, h)
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
			append(out, h)
			seen_field = true
		}
	}
	return .None
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
	} else {
		ent, ok := table_get(dt, int(nidx))
		if !ok do return {}, .Bad_Index
		h.name = strings.clone(ent.name, allocator)
	}
	value, vc := decode_string(src[off:], allocator) or_return
	off += vc
	h.value = value
	pos^ += off
	return h, .None
}

@(private = "file")
clone_header :: proc(h: Header, allocator: mem.Allocator) -> Header {
	return Header{strings.clone(h.name, allocator), strings.clone(h.value, allocator)}
}

// Free a decoded header list (the strings; not the backing array).
headers_destroy :: proc(headers: []Header, allocator := context.allocator) {
	for h in headers {
		delete(h.name, allocator)
		delete(h.value, allocator)
	}
}
