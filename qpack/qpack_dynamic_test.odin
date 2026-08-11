package qpack

import "core:slice"
import "core:testing"

@(test)
test_dyn_insert_and_index :: proc(t: ^testing.T) {
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)

	testing.expect_value(t, dyn_set_capacity(&dt, 4096), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dt, "custom-key", "custom-value"), Qpack_Error.None)
	testing.expect_value(t, dt.insert_count, u64(1))
	testing.expect_value(t, len(dt.entries), 1)
	testing.expect_value(t, dt.size, len("custom-key") + len("custom-value") + DYNAMIC_ENTRY_OVERHEAD)

	// Absolute index 0, encoder relative 0, base-relative with base=1 → rel 0
	e, ok := dyn_get_abs(&dt, 0)
	testing.expect(t, ok)
	testing.expect_value(t, e.name, "custom-key")
	testing.expect_value(t, e.value, "custom-value")

	e, ok = dyn_get_rel_encoder(&dt, 0)
	testing.expect(t, ok && e.name == "custom-key")

	e, ok = dyn_get_rel_base(&dt, 1, 0)
	testing.expect(t, ok && e.value == "custom-value")
}

@(test)
test_dyn_evict_on_capacity :: proc(t: ^testing.T) {
	// Capacity for exactly one small entry: name "a" + value "b" + 32 = 34
	dt: Dynamic_Table
	dyn_init(&dt, 100)
	defer dyn_destroy(&dt)
	testing.expect_value(t, dyn_set_capacity(&dt, 34), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dt, "a", "b"), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dt, "c", "d"), Qpack_Error.None)
	// Second insert evicts first
	testing.expect_value(t, dt.insert_count, u64(2))
	testing.expect_value(t, len(dt.entries), 1)
	e, ok := dyn_get_abs(&dt, 1)
	testing.expect(t, ok && e.name == "c")
	_, ok0 := dyn_get_abs(&dt, 0)
	testing.expect(t, !ok0, "absolute 0 was evicted")
}

@(test)
test_encoder_stream_set_capacity_and_insert_literal :: proc(t: ^testing.T) {
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)

	// Manually build encoder stream:
	//   Set Capacity 4096: 001 + 5-bit prefix for 4096
	//   Insert with Literal Name: custom-key / custom-value (no huffman)
	stream: [dynamic]u8
	defer delete(stream)
	prefix_int_encode(&stream, 4096, 5, 0x20) // Set Capacity
	// Insert literal: 01 H=0 name "custom-key" (len 10), value "custom-value" (len 12)
	// Name is 6-bit prefix string → flags 0x40, length prefix 5 bits
	qpack_encode_string(&stream, "custom-key", 5, 0x40, false)
	qpack_encode_string(&stream, "custom-value", 7, 0x00, false)

	n, err := qpack_decode_encoder_stream(&dt, stream[:])
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, n, len(stream))
	testing.expect_value(t, dt.capacity, 4096)
	testing.expect_value(t, dt.insert_count, u64(1))
	e, ok := dyn_get_abs(&dt, 0)
	testing.expect(t, ok)
	testing.expect_value(t, e.name, "custom-key")
	testing.expect_value(t, e.value, "custom-value")
}

@(test)
test_encoder_stream_insert_name_ref_static :: proc(t: ^testing.T) {
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)
	testing.expect_value(t, dyn_set_capacity(&dt, 4096), Qpack_Error.None)

	// Insert with Name Ref T=1 static index 17 (:method) value "GET"
	// Actually use name-only useful static: index 0 :authority with value "ex.com"
	stream: [dynamic]u8
	defer delete(stream)
	// 1 T=1 Index 0 → 0xC0 | 0 = 0xC0
	prefix_int_encode(&stream, 0, 6, 0xC0)
	qpack_encode_string(&stream, "ex.com", 7, 0x00, false)

	n, err := qpack_decode_encoder_stream(&dt, stream[:])
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, n, len(stream))
	e, ok := dyn_get_abs(&dt, 0)
	testing.expect(t, ok)
	testing.expect_value(t, e.name, ":authority")
	testing.expect_value(t, e.value, "ex.com")
}

@(test)
test_encoder_stream_duplicate :: proc(t: ^testing.T) {
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)
	testing.expect_value(t, dyn_set_capacity(&dt, 4096), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dt, "k", "v"), Qpack_Error.None)

	// Duplicate relative index 0
	stream: [dynamic]u8
	defer delete(stream)
	prefix_int_encode(&stream, 0, 5, 0x00)

	n, err := qpack_decode_encoder_stream(&dt, stream[:])
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, n, len(stream))
	testing.expect_value(t, dt.insert_count, u64(2))
	testing.expect_value(t, len(dt.entries), 2)
	e0, _ := dyn_get_rel_encoder(&dt, 0) // newest = duplicate
	e1, _ := dyn_get_rel_encoder(&dt, 1)
	testing.expect_value(t, e0.name, "k")
	testing.expect_value(t, e1.name, "k")
}

@(test)
test_field_section_dynamic_indexed_roundtrip :: proc(t: ^testing.T) {
	// Build table: one entry, then decode a field section that indexes it.
	// RIC = 1 → EncodedInsertCount = (1 mod (2*MaxEntries)) + 1
	// With max_capacity 4096, MaxEntries = 128, FullRange = 256
	// Encoded = (1 % 256) + 1 = 2
	// Base = RIC (S=0, DB=0) → Base = 1
	// Indexed dynamic T=0 rel 0 → absolute 0: 0x80 | 0 = 0x80
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)
	testing.expect_value(t, dyn_set_capacity(&dt, 4096), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dt, "x-dyn", "hello"), Qpack_Error.None)

	section := []u8{0x02, 0x00, 0x80} // enc_ric=2, S=0 DB=0, indexed dyn 0
	out, ric, err := qpack_decode_field_section(section, context.allocator, &dt)
	defer {
		headers_destroy(out[:])
		delete(out)
	}
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, ric, u64(1))
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, "x-dyn")
	testing.expect_value(t, out[0].value, "hello")
}

@(test)
test_field_section_dynamic_name_ref :: proc(t: ^testing.T) {
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)
	testing.expect_value(t, dyn_set_capacity(&dt, 4096), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dt, "x-name", "ignored"), Qpack_Error.None)

	// Literal with dynamic name ref: 01 N=0 T=0 NameIdx=0 → 0x40
	// + value "newval"
	section: [dynamic]u8
	defer delete(section)
	append(&section, 0x02, 0x00) // enc_ric=2, base = ric
	append(&section, 0x40)       // literal name ref dyn 0
	qpack_encode_string(&section, "newval", 7, 0x00, false)

	out, ric, err := qpack_decode_field_section(section[:], context.allocator, &dt)
	defer {
		headers_destroy(out[:])
		delete(out)
	}
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, ric, u64(1))
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, "x-name")
	testing.expect_value(t, out[0].value, "newval")
}

@(test)
test_field_section_post_base_index :: proc(t: ^testing.T) {
	// Two inserts; RIC=2, Base=1 (S=1, DeltaBase=0 → Base = 2-0-1 = 1)
	// Post-base index 0 → absolute 1 (second insert)
	// Encoded RIC for 2: (2 % 256) + 1 = 3
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)
	testing.expect_value(t, dyn_set_capacity(&dt, 4096), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dt, "a", "1"), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dt, "b", "2"), Qpack_Error.None)

	// enc_ric=3, S=1 DB=0 → Base = 2 - 0 - 1 = 1
	// Indexed post-base: 0001 + idx 0 = 0x10
	section := []u8{0x03, 0x80, 0x10}
	out, ric, err := qpack_decode_field_section(section, context.allocator, &dt)
	defer {
		headers_destroy(out[:])
		delete(out)
	}
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, ric, u64(2))
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, "b")
	testing.expect_value(t, out[0].value, "2")
}

@(test)
test_encoder_stream_incomplete_holds_bytes :: proc(t: ^testing.T) {
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)

	// Complete set capacity + partial insert (only first byte of insert)
	stream: [dynamic]u8
	defer delete(stream)
	prefix_int_encode(&stream, 100, 5, 0x20)
	complete_len := len(stream)
	append(&stream, 0x40) // start of insert literal, truncated

	n, err := qpack_decode_encoder_stream(&dt, stream[:])
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, n, complete_len)
	testing.expect_value(t, dt.capacity, 100)
	testing.expect_value(t, dt.insert_count, u64(0))
}

@(test)
test_decoder_stream_instructions_wire :: proc(t: ^testing.T) {
	// Section Ack stream id 4 → 0x80 | 4 = 0x84
	buf: [dynamic]u8
	defer delete(buf)
	qpack_encode_section_ack(&buf, 4)
	testing.expect(t, slice.equal(buf[:], []u8{0x84}))

	clear(&buf)
	// Insert Count Increment 3 → 0x00 | 3 = 0x03
	qpack_encode_insert_count_increment(&buf, 3)
	testing.expect(t, slice.equal(buf[:], []u8{0x03}))
}

@(test)
test_blocked_when_ric_ahead :: proc(t: ^testing.T) {
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)
	// empty table, enc_ric=2 means RIC=1 but insert_count=0
	out, _, err := qpack_decode_field_section([]u8{0x02, 0x00}, context.allocator, &dt)
	defer delete(out)
	testing.expect_value(t, err, Qpack_Error.Blocked)
}

@(test)
test_static_field_section_still_works_with_dt :: proc(t: ^testing.T) {
	// Passing a table must not break static-only sections (RIC=0).
	dt: Dynamic_Table
	dyn_init(&dt, 4096)
	defer dyn_destroy(&dt)

	buf: [dynamic]u8
	defer delete(buf)
	qpack_encode_field_section(&buf, []Header{{name = ":method", value = "GET"}}, use_huffman = false)
	out, ric, err := qpack_decode_field_section(buf[:], context.allocator, &dt)
	defer {
		headers_destroy(out[:])
		delete(out)
	}
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, ric, u64(0))
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].value, "GET")
}

@(test)
test_encoder_stream_encode_set_capacity_and_insert :: proc(t: ^testing.T) {
	// Encoder emits instructions; decoder table consumes them.
	enc: Dynamic_Table
	dyn_init(&enc, 4096)
	defer dyn_destroy(&enc)
	testing.expect_value(t, dyn_set_capacity(&enc, 4096), Qpack_Error.None)

	stream: [dynamic]u8
	defer delete(stream)
	qpack_encode_set_capacity(&stream, 4096)
	testing.expect_value(t,
		qpack_encoder_insert(&enc, &stream, "custom-key", "custom-value", false),
		Qpack_Error.None,
	)
	testing.expect_value(t, enc.insert_count, u64(1))

	dec: Dynamic_Table
	dyn_init(&dec, 4096)
	defer dyn_destroy(&dec)
	n, err := qpack_decode_encoder_stream(&dec, stream[:])
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, n, len(stream))
	testing.expect_value(t, dec.capacity, 4096)
	testing.expect_value(t, dec.insert_count, u64(1))
	e, ok := dyn_get_abs(&dec, 0)
	testing.expect(t, ok)
	testing.expect_value(t, e.name, "custom-key")
	testing.expect_value(t, e.value, "custom-value")
}

@(test)
test_dynamic_encode_decode_roundtrip_allow_unacked :: proc(t: ^testing.T) {
	// Full encode path: inserts + dynamic-indexed field section → peer decoder.
	enc: Dynamic_Table
	dyn_init(&enc, 4096)
	defer dyn_destroy(&enc)
	testing.expect_value(t, dyn_set_capacity(&enc, 4096), Qpack_Error.None)

	enc_stream: [dynamic]u8
	defer delete(enc_stream)
	// Capacity instruction first (decoder starts at capacity 0).
	qpack_encode_set_capacity(&enc_stream, 4096)

	hs := []Header {
		{name = ":method", value = "GET"},                      // static indexed
		{name = ":path", value = "/"},                          // static indexed
		{name = "x-dyn", value = "hello"},                      // insert + dynamic index
		{name = "x-dyn", value = "hello"},                      // second use → same entry
		{name = "user-agent", value = "vapor-http-qpack-test"},  // static name + insert full pair
	}

	section: [dynamic]u8
	defer delete(section)
	opts := Qpack_Encode_Opts {
		enc_dt         = &enc,
		enc_stream     = &enc_stream,
		known_received = 0,
		allow_unacked  = true,
	}
	ric_enc := qpack_encode_field_section(&section, hs, false, opts)
	testing.expect(t, ric_enc > 0, "RIC should be non-zero with dynamic refs")
	testing.expect(t, enc.insert_count >= 1)
	testing.expect(t, len(enc_stream) > 1, "encoder stream should carry capacity + inserts")

	// Decode: apply encoder stream, then field section.
	dec: Dynamic_Table
	dyn_init(&dec, 4096)
	defer dyn_destroy(&dec)
	n, eerr := qpack_decode_encoder_stream(&dec, enc_stream[:])
	testing.expect_value(t, eerr, Qpack_Error.None)
	testing.expect_value(t, n, len(enc_stream))
	testing.expect_value(t, dec.insert_count, enc.insert_count)

	out, ric, derr := qpack_decode_field_section(section[:], context.allocator, &dec)
	defer {
		headers_destroy(out[:])
		delete(out)
	}
	testing.expect_value(t, derr, Qpack_Error.None)
	testing.expect_value(t, ric, ric_enc)
	testing.expect_value(t, len(out), len(hs))
	for h, i in hs {
		testing.expect_value(t, out[i].name, h.name)
		testing.expect_value(t, out[i].value, h.value)
	}
}

@(test)
test_dynamic_encode_known_received_defers_index :: proc(t: ^testing.T) {
	// With allow_unacked=false and known_received=0, inserts still happen but the
	// field section stays RIC=0 (static/literal) for the first use.
	enc: Dynamic_Table
	dyn_init(&enc, 4096)
	defer dyn_destroy(&enc)
	testing.expect_value(t, dyn_set_capacity(&enc, 4096), Qpack_Error.None)

	enc_stream: [dynamic]u8
	defer delete(enc_stream)
	section: [dynamic]u8
	defer delete(section)

	opts := Qpack_Encode_Opts {
		enc_dt         = &enc,
		enc_stream     = &enc_stream,
		known_received = 0,
		allow_unacked  = false,
	}
	ric := qpack_encode_field_section(
		&section,
		[]Header{{name = "x-custom", value = "v1"}, {name = ":method", value = "GET"}},
		false,
		opts,
	)
	testing.expect_value(t, ric, u64(0))
	testing.expect_value(t, enc.insert_count, u64(1))
	testing.expect(t, len(enc_stream) > 0)

	// After "acknowledgment", second encode may index the dynamic entry.
	opts.known_received = enc.insert_count
	clear(&section)
	// No new insert needed for the same pair.
	opts.enc_stream = nil
	ric2 := qpack_encode_field_section(
		&section,
		[]Header{{name = "x-custom", value = "v1"}},
		false,
		opts,
	)
	testing.expect_value(t, ric2, u64(1))

	dec: Dynamic_Table
	dyn_init(&dec, 4096)
	defer dyn_destroy(&dec)
	testing.expect_value(t, dyn_set_capacity(&dec, 4096), Qpack_Error.None)
	testing.expect_value(t, dyn_insert(&dec, "x-custom", "v1"), Qpack_Error.None)
	out, ric_dec, err := qpack_decode_field_section(section[:], context.allocator, &dec)
	defer {
		headers_destroy(out[:])
		delete(out)
	}
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, ric_dec, u64(1))
	testing.expect_value(t, out[0].name, "x-custom")
	testing.expect_value(t, out[0].value, "v1")
}

@(test)
test_capacity_zero_encode_stays_static :: proc(t: ^testing.T) {
	enc: Dynamic_Table
	dyn_init(&enc, 4096)
	defer dyn_destroy(&enc)
	// capacity left at 0

	enc_stream: [dynamic]u8
	defer delete(enc_stream)
	section: [dynamic]u8
	defer delete(section)
	opts := Qpack_Encode_Opts {
		enc_dt        = &enc,
		enc_stream    = &enc_stream,
		allow_unacked = true,
	}
	ric := qpack_encode_field_section(
		&section,
		[]Header{{name = "x-custom", value = "nope"}, {name = ":method", value = "GET"}},
		false,
		opts,
	)
	testing.expect_value(t, ric, u64(0))
	testing.expect_value(t, len(enc_stream), 0)
	testing.expect_value(t, enc.insert_count, u64(0))
	// Wire matches static-only path.
	static_only: [dynamic]u8
	defer delete(static_only)
	qpack_encode_field_section(
		&static_only,
		[]Header{{name = "x-custom", value = "nope"}, {name = ":method", value = "GET"}},
		false,
	)
	testing.expect(t, slice.equal(section[:], static_only[:]))
}

@(test)
test_decoder_stream_ici_and_section_ack :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	qpack_encode_insert_count_increment(&buf, 2)
	qpack_encode_section_ack(&buf, 4)

	events: [dynamic]Decoder_Stream_Event
	defer delete(events)
	n, err := qpack_decode_decoder_stream(buf[:], &events)
	testing.expect_value(t, err, Qpack_Error.None)
	testing.expect_value(t, n, len(buf))
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, events[0].kind, Decoder_Stream_Kind.Insert_Count_Increment)
	testing.expect_value(t, events[0].increment, u64(2))
	testing.expect_value(t, events[1].kind, Decoder_Stream_Kind.Section_Ack)
	testing.expect_value(t, events[1].stream_id, u64(4))
}
