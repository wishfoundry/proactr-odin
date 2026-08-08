// SSE framing helpers for Session effects (D1).
// Pure formatters + effect → frame; HTTP chunk wrap is applied in _session_apply_effects.
package http

import "core:bytes"
import "core:strconv"
import "core:strings"

// Format one SSE field line: "field: value\n" (value may be empty → "field\n" is not used;
// we always emit "field: value\n" for data/event; comments use ": text\n").
@(private)
_sse_write_field :: proc(b: ^[dynamic]u8, field, value: string) {
	// field
	n := len(field) + 2 + len(value) + 1 // "field: " + value + "\n"  — actually "field: value\n"
	// "field: " is len(field)+2
	_ = n
	append(b, ..transmute([]u8)field)
	append(b, ':')
	append(b, ' ')
	append(b, ..transmute([]u8)value)
	append(b, '\n')
}

// Pure SSE frame for data-only event: each line of data → "data: line\n", ends with "\n".
// Multi-line data is split on '\n' (trailing empty line from split is skipped).
sse_format_data :: proc(data: string, b: ^[dynamic]u8) {
	if len(data) == 0 {
		append(b, ..transmute([]u8)string("data: \n\n"))
		return
	}
	start := 0
	for i in 0 ..= len(data) {
		at_end := i == len(data)
		if !at_end && data[i] != '\n' {
			continue
		}
		line := data[start:i]
		// Strip trailing CR from CRLF.
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		_sse_write_field(b, "data", line)
		if at_end {
			break
		}
		start = i + 1
	}
	append(b, '\n')
}

// event: name\ndata: ...\n\n
sse_format_event :: proc(name, data: string, b: ^[dynamic]u8) {
	if len(name) > 0 {
		_sse_write_field(b, "event", name)
	}
	sse_format_data(data, b)
}

// Comment frame: ": comment\n\n" (empty comment → ":\n\n").
sse_format_comment :: proc(comment: string, b: ^[dynamic]u8) {
	append(b, ':')
	if len(comment) > 0 {
		append(b, ' ')
		append(b, ..transmute([]u8)comment)
	}
	append(b, '\n')
	append(b, '\n')
}

// Format Effect into SSE bytes (no HTTP chunk framing).
@(private)
_sse_format_effect :: proc(b: ^[dynamic]u8, e: Effect) {
	switch e.kind {
	case .Sse_Data:
		sse_format_data(e.data, b)
	case .Sse_Event:
		sse_format_event(e.name, e.data, b)
	case .Sse_Comment:
		sse_format_comment(e.data, b)
	case .None, .Arm, .End, .Abort, .Ws_Text, .Ws_Binary, .Ws_Close:
		// not SSE frames
	}
}

// Pure helper: HTTP chunk framing around payload (mirrors _http_write_chunk for tests).
// Returns hex-size CRLF payload CRLF as a newly allocated string (caller deletes).
sse_http_chunk_string :: proc(payload: string, allocator := context.allocator) -> string {
	if len(payload) == 0 {
		return strings.clone("", allocator)
	}
	b: bytes.Buffer
	b.buf.allocator = allocator
	_http_write_chunk(&b, transmute([]u8)payload)
	// Transfer ownership of the buffer bytes as a string (no second copy).
	raw := bytes.buffer_to_bytes(&b)
	return string(raw)
}

// Hex size prefix used by chunked TE (for unit tests).
sse_chunk_size_hex :: proc(n: int, buf: []u8) -> string {
	if n < 0 || len(buf) == 0 {
		return ""
	}
	return string(strconv.write_int(buf, i64(n), 16))
}
