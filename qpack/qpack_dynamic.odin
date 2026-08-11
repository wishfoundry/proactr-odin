// QPACK dynamic table (RFC 9204 §3.2) and encoder/decoder stream codecs (§4.3–4.4).
//
// The same `Dynamic_Table` shape is used on both sides:
//   - Decoder: peer encoder stream → table; field sections resolve dynamic refs.
//   - Encoder: we insert when peer capacity > 0, emit encoder-stream instructions,
//     and field sections may index entries (gated by known-received when the peer
//     advertises blocked_streams = 0).
package qpack

import "core:mem"
import "core:strings"

DYNAMIC_ENTRY_OVERHEAD :: 32 // RFC 9204 §3.2.1

// Shared encoder/decoder view of a QPACK dynamic table.
Dynamic_Table :: struct {
	entries:      [dynamic]Header, // index 0 = most recently inserted
	size:         int,             // current size in bytes
	capacity:     int,             // current capacity (Set Capacity instruction)
	max_capacity: int,             // SETTINGS_QPACK_MAX_TABLE_CAPACITY (local adv. or peer)
	insert_count: u64,             // total inserts ever (absolute index = insert_count-1 for newest)
	allocator:    mem.Allocator,
}

dyn_init :: proc(dt: ^Dynamic_Table, max_capacity: int, allocator := context.allocator) {
	dt^ = {}
	dt.allocator = allocator
	dt.entries.allocator = allocator
	dt.max_capacity = max_capacity
	// capacity starts at 0 until Set Dynamic Table Capacity is received.
}

dyn_destroy :: proc(dt: ^Dynamic_Table) {
	for e in dt.entries {
		delete(e.name, dt.allocator)
		delete(e.value, dt.allocator)
	}
	delete(dt.entries)
	dt^ = {}
}

@(private)
dyn_entry_size :: proc(h: Header) -> int {
	return len(h.name) + len(h.value) + DYNAMIC_ENTRY_OVERHEAD
}

// Absolute index of the entry at array index i (0 = newest).
@(private)
dyn_abs_of :: proc(dt: ^Dynamic_Table, i: int) -> u64 {
	// insert_count - 1 is newest; entries[i] has abs = insert_count - 1 - i
	return dt.insert_count - 1 - u64(i)
}

// Resolve absolute index → entry. Absolute indices start at 0 for the first insert.
dyn_get_abs :: proc(dt: ^Dynamic_Table, abs: u64) -> (Header, bool) {
	if dt.insert_count == 0 do return {}, false
	// Newest abs = insert_count-1; oldest present abs = insert_count - len(entries)
	if abs >= dt.insert_count do return {}, false
	oldest := dt.insert_count - u64(len(dt.entries))
	if abs < oldest do return {}, false // evicted
	i := int(dt.insert_count - 1 - abs)
	return dt.entries[i], true
}

// Encoder-stream relative index: 0 = most recently inserted.
dyn_get_rel_encoder :: proc(dt: ^Dynamic_Table, rel: u64) -> (Header, bool) {
	if rel >= u64(len(dt.entries)) do return {}, false
	return dt.entries[int(rel)], true
}

// Field-section relative index: 0 refers to absolute index Base-1.
dyn_get_rel_base :: proc(dt: ^Dynamic_Table, base: u64, rel: u64) -> (Header, bool) {
	if base == 0 || rel >= base do return {}, false
	return dyn_get_abs(dt, base - 1 - rel)
}

// Post-Base index: 0 refers to absolute index Base.
dyn_get_post_base :: proc(dt: ^Dynamic_Table, base: u64, post: u64) -> (Header, bool) {
	return dyn_get_abs(dt, base + post)
}

// Set capacity (may evict). Capacity must not exceed max_capacity.
dyn_set_capacity :: proc(dt: ^Dynamic_Table, capacity: int) -> Qpack_Error {
	if capacity < 0 || capacity > dt.max_capacity do return .Encoder_Stream_Error
	dt.capacity = capacity
	for dt.size > dt.capacity && len(dt.entries) > 0 {
		old := pop(&dt.entries)
		dt.size -= dyn_entry_size(old)
		delete(old.name, dt.allocator)
		delete(old.value, dt.allocator)
	}
	return .None
}

// Insert a cloned entry at the front; evict oldest until it fits.
// Returns error if the entry is larger than capacity.
dyn_insert :: proc(dt: ^Dynamic_Table, name, value: string) -> Qpack_Error {
	h := Header{name = name, value = value}
	es := dyn_entry_size(h)
	if es > dt.capacity do return .Encoder_Stream_Error
	for dt.size + es > dt.capacity && len(dt.entries) > 0 {
		old := pop(&dt.entries)
		dt.size -= dyn_entry_size(old)
		if old.name_owned do delete(old.name, dt.allocator)
		if old.value_owned do delete(old.value, dt.allocator)
	}
	owned := Header {
		name        = strings.clone(name, dt.allocator),
		value       = strings.clone(value, dt.allocator),
		name_owned  = true,
		value_owned = true,
	}
	inject_at(&dt.entries, 0, owned)
	dt.size += es
	dt.insert_count += 1
	return .None
}

// MaxEntries used for Required Insert Count wrap (RFC 9204 §4.5.1.1).
dyn_max_entries :: proc(dt: ^Dynamic_Table) -> u64 {
	if dt.max_capacity <= 0 do return 0
	return u64(dt.max_capacity / DYNAMIC_ENTRY_OVERHEAD)
}

// Decode Required Insert Count from its wire encoding.
decode_required_insert_count :: proc(
	dt: ^Dynamic_Table, encoded: u64,
) -> (ric: u64, err: Qpack_Error) {
	if encoded == 0 do return 0, .None
	max_entries := dyn_max_entries(dt)
	if max_entries == 0 do return 0, .Dynamic_Table_Unsupported
	full_range := 2 * max_entries
	if encoded > full_range do return 0, .Invalid_Index
	max_value := dt.insert_count + max_entries
	max_wrapped := (max_value / full_range) * full_range
	ric = max_wrapped + encoded - 1
	if ric > max_value {
		if ric <= full_range do return 0, .Invalid_Index
		ric -= full_range
	}
	if ric == 0 do return 0, .Invalid_Index
	return ric, .None
}

// Encode Required Insert Count for the field-section prefix (RFC 9204 §4.5.1.1).
// `ric == 0` encodes as 0. `max_capacity` is the decoder's SETTINGS max (same as
// `dt.max_capacity` on the peer decoder / our encoder table).
encode_required_insert_count :: proc(max_capacity: int, ric: u64) -> u64 {
	if ric == 0 do return 0
	max_entries := u64(0)
	if max_capacity > 0 do max_entries = u64(max_capacity / DYNAMIC_ENTRY_OVERHEAD)
	if max_entries == 0 do return 0
	return ric % (2 * max_entries) + 1
}

// Linear scan: exact name+value match. Returns encoder relative index (0 = newest)
// and absolute index.
dyn_find_pair :: proc(dt: ^Dynamic_Table, name, value: string) -> (rel: u64, abs: u64, ok: bool) {
	for e, i in dt.entries {
		if e.name == name && e.value == value {
			return u64(i), dyn_abs_of(dt, i), true
		}
	}
	return 0, 0, false
}

// Linear scan: first (newest) name-only match.
dyn_find_name :: proc(dt: ^Dynamic_Table, name: string) -> (rel: u64, abs: u64, ok: bool) {
	for e, i in dt.entries {
		if e.name == name {
			return u64(i), dyn_abs_of(dt, i), true
		}
	}
	return 0, 0, false
}

// ---- Encoder stream instructions (we emit these) -------------------------

// Set Dynamic Table Capacity (§4.3.1): 001 Capacity(5+)
qpack_encode_set_capacity :: proc(dst: ^[dynamic]u8, capacity: u64) {
	prefix_int_encode(dst, capacity, 5, 0x20)
}

// Insert with Name Reference (§4.3.2): 1 T NameIdx(6+) + value string
// `static_table` selects T (true = static table, false = dynamic relative).
qpack_encode_insert_name_ref :: proc(
	dst: ^[dynamic]u8, static_table: bool, name_idx: u64, value: string, use_huffman := true,
) {
	flags: u8 = 0x80
	if static_table do flags |= 0x40
	prefix_int_encode(dst, name_idx, 6, flags)
	qpack_encode_string(dst, value, 7, 0x00, use_huffman)
}

// Insert with Literal Name (§4.3.3): 01 H NameLen(5+) + name + value
qpack_encode_insert_literal :: proc(
	dst: ^[dynamic]u8, name, value: string, use_huffman := true,
) {
	qpack_encode_string(dst, name, 5, 0x40, use_huffman)
	qpack_encode_string(dst, value, 7, 0x00, use_huffman)
}

// Duplicate (§4.3.4): 000 Index(5+)
qpack_encode_duplicate :: proc(dst: ^[dynamic]u8, rel_idx: u64) {
	prefix_int_encode(dst, rel_idx, 5, 0x00)
}

// Insert `name`/`value` into `dt` and append the matching encoder-stream
// instruction to `enc_stream`. Prefers static name-ref, then dynamic name-ref,
// else literal name. Returns error if the entry does not fit.
qpack_encoder_insert :: proc(
	dt: ^Dynamic_Table,
	enc_stream: ^[dynamic]u8,
	name, value: string,
	use_huffman := true,
) -> Qpack_Error {
	if dt.capacity <= 0 do return .Encoder_Stream_Error
	es := dyn_entry_size(Header{name = name, value = value})
	if es > dt.capacity do return .Encoder_Stream_Error

	if nidx, ok := static_find_name(name); ok {
		qpack_encode_insert_name_ref(enc_stream, true, u64(nidx), value, use_huffman)
	} else if rel, _, ok := dyn_find_name(dt, name); ok {
		// Name may be evicted by this insert; wire uses relative index against
		// the table *before* the insert (correct for the instruction).
		qpack_encode_insert_name_ref(enc_stream, false, rel, value, use_huffman)
	} else {
		qpack_encode_insert_literal(enc_stream, name, value, use_huffman)
	}
	return dyn_insert(dt, name, value)
}

// Process zero or more complete encoder-stream instructions.
// Incomplete trailing instruction: returns consumed bytes so far and .None so the
// caller can retain the remainder.
qpack_decode_encoder_stream :: proc(
	dt: ^Dynamic_Table, src: []u8,
) -> (consumed: int, err: Qpack_Error) {
	pos := 0
	for pos < len(src) {
		n, e := decode_one_encoder_instruction(dt, src[pos:])
		if e == .Truncated do return pos, .None
		if e != .None do return pos, e
		pos += n
	}
	return pos, .None
}

@(private)
decode_one_encoder_instruction :: proc(
	dt: ^Dynamic_Table, src: []u8,
) -> (consumed: int, err: Qpack_Error) {
	if len(src) == 0 do return 0, .Truncated
	b := src[0]

	if b & 0x80 != 0 {
		// Insert with Name Reference (§4.3.2): 1 T NameIdx(6+) + value string
		idx, c, e := prefix_int_decode(src, 6)
		if e != .None do return 0, e
		pos := c
		name: string
		if b & 0x40 != 0 {
			ent, ok := static_get(int(idx))
			if !ok do return 0, .Invalid_Index
			name = ent.name
		} else {
			ent, ok := dyn_get_rel_encoder(dt, idx)
			if !ok do return 0, .Invalid_Index
			// Clone name early: insert may evict the referenced entry.
			name = strings.clone(ent.name, context.temp_allocator)
		}
		val, cv, ev := qpack_decode_string(src[pos:], 7, context.temp_allocator)
		if ev != .None do return 0, ev
		pos += cv
		if ie := dyn_insert(dt, name, val); ie != .None do return 0, ie
		return pos, .None
	}

	if b & 0x40 != 0 {
		// Insert with Literal Name (§4.3.3): 01 H NameLen(5+) + name + value
		// 6-bit prefix string with pattern bits 01 → length uses 5 bits, H at bit 5.
		name, cn, en := qpack_decode_string(src, 5, context.temp_allocator)
		if en != .None do return 0, en
		pos := cn
		val, cv, ev := qpack_decode_string(src[pos:], 7, context.temp_allocator)
		if ev != .None do return 0, ev
		pos += cv
		if ie := dyn_insert(dt, name, val); ie != .None do return 0, ie
		return pos, .None
	}

	if b & 0x20 != 0 {
		// Set Dynamic Table Capacity (§4.3.1): 001 Capacity(5+)
		capv, c, e := prefix_int_decode(src, 5)
		if e != .None do return 0, e
		if se := dyn_set_capacity(dt, int(capv)); se != .None do return 0, se
		return c, .None
	}

	// Duplicate (§4.3.4): 000 Index(5+)
	rel, c, e := prefix_int_decode(src, 5)
	if e != .None do return 0, e
	ent, ok := dyn_get_rel_encoder(dt, rel)
	if !ok do return 0, .Invalid_Index
	// Copy before insert may evict.
	name := strings.clone(ent.name, context.temp_allocator)
	value := strings.clone(ent.value, context.temp_allocator)
	if ie := dyn_insert(dt, name, value); ie != .None do return 0, ie
	return c, .None
}

// ---- Decoder stream instructions -----------------------------------------

// Section Acknowledgment (§4.4.1): 1 StreamID(7+)
qpack_encode_section_ack :: proc(dst: ^[dynamic]u8, stream_id: u64) {
	prefix_int_encode(dst, stream_id, 7, 0x80)
}

// Insert Count Increment (§4.4.3): 00 Increment(6+)
qpack_encode_insert_count_increment :: proc(dst: ^[dynamic]u8, increment: u64) {
	prefix_int_encode(dst, increment, 6, 0x00)
}

// Decoder-stream instruction kinds we care about for the encoder side.
Decoder_Stream_Kind :: enum u8 {
	Insert_Count_Increment,
	Section_Ack,
	Stream_Cancellation,
}

Decoder_Stream_Event :: struct {
	// Insert Count Increment: known_received += increment.
	// Section Ack: caller raises known_received from the section's pending RIC.
	kind:      Decoder_Stream_Kind,
	increment: u64, // ICI
	stream_id: u64, // Section Ack / Stream Cancellation
}

// Decode zero or more complete decoder-stream instructions. Incomplete trailing
// instruction: returns consumed so far and .None (retain remainder).
// Events are appended to `events` (caller-owned).
qpack_decode_decoder_stream :: proc(
	src: []u8, events: ^[dynamic]Decoder_Stream_Event,
) -> (consumed: int, err: Qpack_Error) {
	pos := 0
	for pos < len(src) {
		if len(src) - pos < 1 do break
		b := src[pos]
		if b & 0x80 != 0 {
			// Section Acknowledgment: 1 StreamID(7+)
			sid, c, e := prefix_int_decode(src[pos:], 7)
			if e == .Truncated do return pos, .None
			if e != .None do return pos, e
			append(events, Decoder_Stream_Event{kind = .Section_Ack, stream_id = sid})
			pos += c
		} else if b & 0x40 != 0 {
			// Stream Cancellation: 01 StreamID(6+)
			sid, c, e := prefix_int_decode(src[pos:], 6)
			if e == .Truncated do return pos, .None
			if e != .None do return pos, e
			append(events, Decoder_Stream_Event{kind = .Stream_Cancellation, stream_id = sid})
			pos += c
		} else {
			// Insert Count Increment: 00 Increment(6+)
			inc, c, e := prefix_int_decode(src[pos:], 6)
			if e == .Truncated do return pos, .None
			if e != .None do return pos, e
			if inc == 0 do return pos, .Encoder_Stream_Error
			append(events, Decoder_Stream_Event{kind = .Insert_Count_Increment, increment = inc})
			pos += c
		}
	}
	return pos, .None
}
