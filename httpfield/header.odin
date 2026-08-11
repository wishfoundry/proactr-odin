// Shared ordered header field for HPACK (H2) and QPACK (H3).
// One wire-facing type: name/value + ownership flags for safe destroy.
//
// Not the same as package http's map-based Headers (H1 request/response access).
package httpfield

import "core:strings"

// Header is a name/value pair with explicit ownership.
// Named compound literals (`Header{name = "a", value = "b"}`) zero the owned
// flags → borrowed; safe for test/call-site literals and static-table views.
// Decoded / cloned strings must set the corresponding flag so headers_destroy
// can free without pointer-identity heuristics.
// Prefer named form; Odin positional literals require all fields.
Header :: struct {
	name, value: string,
	name_owned:  bool, // free name in headers_destroy / table eviction
	value_owned: bool,
}

// Borrowed name/value (flags false). Convenience for encode tests and builders.
header :: proc(name, value: string) -> Header {
	return Header{name = name, value = value}
}

// Owned clones of name and value (both flags true).
header_owned :: proc(name, value: string, allocator := context.allocator) -> Header {
	return Header {
		name        = strings.clone(name, allocator),
		value       = strings.clone(value, allocator),
		name_owned  = true,
		value_owned = true,
	}
}

// Free owned strings only (not the backing array). Safe on mixed borrowed/owned lists.
headers_destroy :: proc(headers: []Header, allocator := context.allocator) {
	for h in headers {
		if h.name_owned do delete(h.name, allocator)
		if h.value_owned do delete(h.value, allocator)
	}
}

