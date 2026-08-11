// QPACK (RFC 9204) field-section encoder/decoder.
//
// Encoder: static table always; optional dynamic table when `enc_dt` is provided
// and capacity > 0. New entries may be inserted onto `enc_stream` (Insert with
// Name Reference / Literal Name). Field lines use dynamic indexed / name-ref
// when the entry is referenceable (see `allow_unacked` / `known_received`).
// With no encoder table, output is static-only (RIC = 0) — same as capacity 0.
//
// Decoder: optional dynamic table. Pass a `^Dynamic_Table` (populated from the
// peer's QPACK encoder stream) to accept indexed / name-ref / post-base
// dynamic references. With `dt == nil`, dynamic references are rejected
// (legacy capacity-0 behaviour).
//
// Building blocks:
//   - Prefix integer (RFC 7541 §5.1, reused by RFC 9204 §4.1.1) — NOT QUIC varint.
//   - String literal (RFC 9204 §4.1.2), optionally Huffman-coded.
//   - Field section prefix (RFC 9204 §4.5.1): Required Insert Count + Base.
//   - Field line representations (RFC 9204 §4.5.2–4.5.6).
package qpack

import "core:mem"
import "core:strings"

import "../huffman"
import "../httpfield"

// Shared with HPACK / H2 / client — see package httpfield.
Header :: httpfield.Header
headers_destroy :: httpfield.headers_destroy

Qpack_Error :: enum {
	None,
	Truncated,
	Integer_Overflow,
	Invalid_Index,
	Dynamic_Table_Unsupported, // dynamic ref with no table / capacity 0
	Bad_Huffman,
	Encoder_Stream_Error,      // bad encoder instruction / capacity
	Blocked,                   // RIC > insert count (would need blocked streams)
}

// ---- Prefix integer (RFC 7541 §5.1) ---------------------------------------

// Encode `value` with an `n`-bit prefix. `flags` holds the high (8-n) bits of
// the first byte already set (the representation pattern); they must not touch
// the low n bits.
prefix_int_encode :: proc(dst: ^[dynamic]u8, value: u64, n: uint, flags: u8) {
	max_prefix := u64(1 << n) - 1
	if value < max_prefix {
		append(dst, flags | u8(value))
		return
	}
	append(dst, flags | u8(max_prefix))
	v := value - max_prefix
	for v >= 128 {
		append(dst, u8(v & 0x7f) | 0x80)
		v >>= 7
	}
	append(dst, u8(v))
}

// Decode an `n`-bit-prefix integer from the front of `src`. Returns the value
// and the number of bytes consumed.
prefix_int_decode :: proc(src: []u8, n: uint) -> (value: u64, consumed: int, err: Qpack_Error) {
	if len(src) == 0 do return 0, 0, .Truncated
	mask := u64(1 << n) - 1
	value = u64(src[0]) & mask
	consumed = 1
	if value < mask do return value, consumed, .None

	m: uint = 0
	for {
		if consumed >= len(src) do return 0, 0, .Truncated
		b := src[consumed]
		consumed += 1
		value += u64(b & 0x7f) << m
		if b & 0x80 == 0 do break
		m += 7
		if m > 62 do return 0, 0, .Integer_Overflow
	}
	return value, consumed, .None
}

// ---- String literal (RFC 9204 §4.1.2) -------------------------------------

// Encode `s` with an n-bit length prefix. `flags` = the representation pattern
// bits above the length field (NOT the Huffman bit). The Huffman bit is at bit
// position `n` and is set automatically when Huffman is shorter.
qpack_encode_string :: proc(dst: ^[dynamic]u8, s: string, n: uint, flags: u8, use_huffman: bool) {
	data := transmute([]u8)s
	if use_huffman {
		hlen := huffman.encoded_len(data)
		if hlen < len(data) {
			prefix_int_encode(dst, u64(hlen), n, flags | u8(1 << n))
			scratch := make([]u8, hlen, context.temp_allocator)
			huffman.encode(scratch, data)
			append(dst, ..scratch)
			return
		}
	}
	prefix_int_encode(dst, u64(len(data)), n, flags)
	append(dst, ..data)
}

// Decode an n-bit-prefix string. Always allocates (clones literal bytes /
// produces the Huffman-decoded buffer) so the result owns its memory.
qpack_decode_string :: proc(
	src: []u8, n: uint, allocator: mem.Allocator,
) -> (s: string, consumed: int, err: Qpack_Error) {
	if len(src) == 0 do return "", 0, .Truncated
	huff := src[0] & u8(1 << n) != 0
	length, c, e := prefix_int_decode(src, n)
	if e != .None do return "", 0, e
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

// ---- Field section ---------------------------------------------------------

// Encode options for dynamic-table field sections. Zero value = static-only.
Qpack_Encode_Opts :: struct {
	// Encoder dynamic table (mutated on insert). nil → static-only.
	enc_dt:         ^Dynamic_Table,
	// Destination for encoder-stream instructions (Set Capacity is caller's job).
	// Required for inserts when capacity > 0; if nil, never insert.
	enc_stream:     ^[dynamic]u8,
	// Inserts the peer has acknowledged (ICI / section ack). Used when
	// allow_unacked is false.
	known_received: u64,
	// If true, newly inserted entries in this call may be referenced immediately
	// (RIC covers them). Safe for unit tests and peers with blocked_streams > 0.
	// If false (typical HTTP/3 with blocked_streams = 0), only index entries with
	// absolute index < known_received; still emit inserts for future sections.
	allow_unacked:  bool,
}

// Encode a header list into a complete QPACK field section (prefix + lines).
// Without opts / with enc_dt == nil: static-only (RIC = 0, Base = 0).
// Returns the Required Insert Count used in the section prefix (0 if static-only).
qpack_encode_field_section :: proc(
	dst: ^[dynamic]u8,
	headers: []Header,
	use_huffman := true,
	opts: Qpack_Encode_Opts = {},
) -> (required_insert_count: u64) {
	if opts.enc_dt == nil || opts.enc_dt.capacity <= 0 {
		append(dst, 0, 0)
		for h in headers {
			encode_field_line_static(dst, h, use_huffman)
		}
		return 0
	}

	// Two-phase: decide representations (maybe insert), then write prefix + lines.
	// Track the highest absolute index we will reference (+1 = RIC).
	ric: u64 = 0
	Line :: struct {
		kind: enum u8 {
			Static_Indexed,
			Dyn_Indexed,
			Static_Name_Ref,
			Dyn_Name_Ref,
			Literal,
		},
		idx:   u64, // static index, or absolute index for dynamic
		value: string, // for name-ref / literal value
		name:  string, // for full literal
	}
	lines := make([dynamic]Line, 0, len(headers), context.temp_allocator)

	for h in headers {
		// 1) Static full match always wins (no dynamic dependency).
		if sidx, ok := static_find_pair(h.name, h.value); ok {
			append(&lines, Line{kind = .Static_Indexed, idx = u64(sidx)})
			continue
		}

		// 2) Dynamic full match if referenceable.
		if drel, dabs, ok := dyn_find_pair(opts.enc_dt, h.name, h.value); ok {
			_ = drel
			if opts.allow_unacked || dabs < opts.known_received {
				if dabs + 1 > ric do ric = dabs + 1
				append(&lines, Line{kind = .Dyn_Indexed, idx = dabs})
				continue
			}
		}

		// 3) Insert new pair when we have an encoder stream and room, if not present.
		inserted_abs: u64
		did_insert := false
		if opts.enc_stream != nil {
			if _, _, exists := dyn_find_pair(opts.enc_dt, h.name, h.value); !exists {
				if qpack_encoder_insert(opts.enc_dt, opts.enc_stream, h.name, h.value, use_huffman) == .None {
					inserted_abs = opts.enc_dt.insert_count - 1
					did_insert = true
				}
			}
		}

		if did_insert && opts.allow_unacked {
			if inserted_abs + 1 > ric do ric = inserted_abs + 1
			append(&lines, Line{kind = .Dyn_Indexed, idx = inserted_abs})
			continue
		}

		// 4) Name reference (static preferred, then dynamic if referenceable).
		if nidx, ok := static_find_name(h.name); ok {
			append(&lines, Line{kind = .Static_Name_Ref, idx = u64(nidx), value = h.value})
			continue
		}
		if drel, dabs, ok := dyn_find_name(opts.enc_dt, h.name); ok {
			_ = drel
			if opts.allow_unacked || dabs < opts.known_received {
				if dabs + 1 > ric do ric = dabs + 1
				append(&lines, Line{kind = .Dyn_Name_Ref, idx = dabs, value = h.value})
				continue
			}
		}

		// 5) Full literal.
		append(&lines, Line{kind = .Literal, name = h.name, value = h.value})
	}

	// Base = insert_count after any inserts (S=0, Delta Base = Base - RIC).
	base := opts.enc_dt.insert_count
	if ric == 0 {
		// No dynamic refs: static-only prefix even if we inserted for later.
		append(dst, 0, 0)
	} else {
		enc_ric := encode_required_insert_count(opts.enc_dt.max_capacity, ric)
		prefix_int_encode(dst, enc_ric, 8, 0x00)
		// Base >= RIC always here (base is full insert_count).
		delta_base := base - ric
		// Sign = 0, Delta Base in 7 bits
		prefix_int_encode(dst, delta_base, 7, 0x00)
	}

	for line in lines {
		switch line.kind {
		case .Static_Indexed:
			prefix_int_encode(dst, line.idx, 6, 0xC0)
		case .Dyn_Indexed:
			// Relative to Base: rel = Base - 1 - abs; T=0
			rel := base - 1 - line.idx
			prefix_int_encode(dst, rel, 6, 0x80)
		case .Static_Name_Ref:
			prefix_int_encode(dst, line.idx, 4, 0x50)
			qpack_encode_string(dst, line.value, 7, 0x00, use_huffman)
		case .Dyn_Name_Ref:
			rel := base - 1 - line.idx
			prefix_int_encode(dst, rel, 4, 0x40)
			qpack_encode_string(dst, line.value, 7, 0x00, use_huffman)
		case .Literal:
			qpack_encode_string(dst, line.name, 3, 0x20, use_huffman)
			qpack_encode_string(dst, line.value, 7, 0x00, use_huffman)
		}
	}
	return ric
}

@(private)
encode_field_line_static :: proc(dst: ^[dynamic]u8, h: Header, use_huffman: bool) {
	if idx, ok := static_find_pair(h.name, h.value); ok {
		// Indexed Field Line (§4.5.2): 1 T=1 Index(6+)
		prefix_int_encode(dst, u64(idx), 6, 0xC0)
		return
	}
	if nidx, ok := static_find_name(h.name); ok {
		// Literal Field Line w/ Name Ref (§4.5.4): 0 1 N=0 T=1 NameIdx(4+)
		prefix_int_encode(dst, u64(nidx), 4, 0x50)
		qpack_encode_string(dst, h.value, 7, 0x00, use_huffman)
		return
	}
	// Literal Field Line w/ Literal Name (§4.5.6): 0 0 1 N=0 H NameLen(3+)
	qpack_encode_string(dst, h.name, 3, 0x20, use_huffman)
	qpack_encode_string(dst, h.value, 7, 0x00, use_huffman)
}

// Decode a complete QPACK field section.
//
// `dt` is optional. When non-nil, dynamic-table references (T=0, post-base,
// RIC/Base) are resolved against it. When nil, any dynamic reference fails with
// Dynamic_Table_Unsupported (static-only mode).
//
// Allocates each header string from `allocator`; free with headers_destroy +
// delete on the returned array.
//
// On success with a non-zero Required Insert Count, `required_insert_count` is
// set so the caller can emit a Section Acknowledgment on the decoder stream.
qpack_decode_field_section :: proc(
	src: []u8,
	allocator := context.allocator,
	dt: ^Dynamic_Table = nil,
) -> (headers: [dynamic]Header, required_insert_count: u64, err: Qpack_Error) {
	headers.allocator = allocator
	pos := 0

	// Field Section Prefix (§4.5.1).
	enc_ric, c0, e0 := prefix_int_decode(src[pos:], 8)
	if e0 != .None { err = e0; return }
	pos += c0

	ric: u64
	if enc_ric == 0 {
		ric = 0
	} else if dt == nil {
		err = .Dynamic_Table_Unsupported
		return
	} else {
		r, re := decode_required_insert_count(dt, enc_ric)
		if re != .None { err = re; return }
		ric = r
		if ric > dt.insert_count {
			// Would require blocked-stream buffering; we advertise blocked=0.
			err = .Blocked
			return
		}
	}
	required_insert_count = ric

	if pos >= len(src) { err = .Truncated; return }
	sign := src[pos] & 0x80 != 0
	db, c1, e1 := prefix_int_decode(src[pos:], 7)
	if e1 != .None { err = e1; return }
	pos += c1

	base: u64
	if sign {
		if ric == 0 || db >= ric {
			err = .Invalid_Index
			return
		}
		base = ric - db - 1
	} else {
		base = ric + db
	}

	if (sign || db != 0 || ric != 0) && dt == nil {
		err = .Dynamic_Table_Unsupported
		return
	}

	for pos < len(src) {
		b := src[pos]
		h: Header

		if b & 0x80 != 0 {
			// Indexed Field Line (§4.5.2).
			idx, c, e := prefix_int_decode(src[pos:], 6)
			if e != .None { err = e; return }
			pos += c
			if b & 0x40 != 0 {
				ent, ok := static_get(int(idx))
				if !ok { err = .Invalid_Index; return }
				h.name = strings.clone(ent.name, allocator)
				h.value = strings.clone(ent.value, allocator)
			} else {
				if dt == nil { err = .Dynamic_Table_Unsupported; return }
				ent, ok := dyn_get_rel_base(dt, base, idx)
				if !ok { err = .Invalid_Index; return }
				if abs, _ := _abs_from_rel_base(base, idx); abs >= ric {
					err = .Invalid_Index
					return
				}
				h.name = strings.clone(ent.name, allocator)
				h.value = strings.clone(ent.value, allocator)
			}
		} else if b & 0x40 != 0 {
			// Literal Field Line w/ Name Reference (§4.5.4).
			nidx, c, e := prefix_int_decode(src[pos:], 4)
			if e != .None { err = e; return }
			pos += c
			if b & 0x10 != 0 {
				ent, ok := static_get(int(nidx))
				if !ok { err = .Invalid_Index; return }
				h.name = strings.clone(ent.name, allocator)
			} else {
				if dt == nil { err = .Dynamic_Table_Unsupported; return }
				ent, ok := dyn_get_rel_base(dt, base, nidx)
				if !ok { err = .Invalid_Index; return }
				if abs, _ := _abs_from_rel_base(base, nidx); abs >= ric {
					err = .Invalid_Index
					return
				}
				h.name = strings.clone(ent.name, allocator)
			}
			val, cv, ev := qpack_decode_string(src[pos:], 7, allocator)
			if ev != .None { err = ev; return }
			pos += cv
			h.value = val
		} else if b & 0x20 != 0 {
			// Literal Field Line w/ Literal Name (§4.5.6).
			// Pattern 001 N H NameLen(3+) — length uses 3 bits, H at bit 3.
			// N bit is ignored for decode (intermediary never-index hint).
			name, cn, en := qpack_decode_string(src[pos:], 3, allocator)
			if en != .None { err = en; return }
			pos += cn
			val, cv, ev := qpack_decode_string(src[pos:], 7, allocator)
			if ev != .None { err = ev; return }
			pos += cv
			h.name = name
			h.value = val
		} else if b & 0x10 != 0 {
			// Indexed Field Line with Post-Base Index (§4.5.3): 0001 Index(4+)
			if dt == nil { err = .Dynamic_Table_Unsupported; return }
			pidx, c, e := prefix_int_decode(src[pos:], 4)
			if e != .None { err = e; return }
			pos += c
			ent, ok := dyn_get_post_base(dt, base, pidx)
			if !ok { err = .Invalid_Index; return }
			abs := base + pidx
			if abs >= ric { err = .Invalid_Index; return }
			h.name = strings.clone(ent.name, allocator)
			h.value = strings.clone(ent.value, allocator)
		} else {
			// Literal Field Line with Post-Base Name Reference (§4.5.5):
			// 0000 N NameIdx(3+)
			if dt == nil { err = .Dynamic_Table_Unsupported; return }
			pidx, c, e := prefix_int_decode(src[pos:], 3)
			if e != .None { err = e; return }
			pos += c
			ent, ok := dyn_get_post_base(dt, base, pidx)
			if !ok { err = .Invalid_Index; return }
			abs := base + pidx
			if abs >= ric { err = .Invalid_Index; return }
			h.name = strings.clone(ent.name, allocator)
			val, cv, ev := qpack_decode_string(src[pos:], 7, allocator)
			if ev != .None { err = ev; return }
			pos += cv
			h.value = val
		}

		// All decode paths allocate name/value from `allocator`.
		h.name_owned = true
		h.value_owned = true
		append(&headers, h)
	}
	return headers, required_insert_count, .None
}

@(private)
_abs_from_rel_base :: proc(base: u64, rel: u64) -> (abs: u64, ok: bool) {
	if base == 0 || rel >= base do return 0, false
	return base - 1 - rel, true
}


