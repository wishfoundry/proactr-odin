// HTTP/2 frame-layer types (RFC 9113). Owned here so the frame codec stays
// free of a dependency on package `http` (avoids circular deps with host).
package http2

import "../hpack"
import "../httpfield"

// Shared H2/H3 ordered field (httpfield); same type as hpack.Header / qpack.Header.
Header :: httpfield.Header

// Frame parse failures for length-prefixed frames off a buffer.
Frame_Error :: enum {
	None,
	Incomplete, // whole frame isn't buffered yet — need more bytes
	Malformed,  // structurally invalid (e.g. SETTINGS length not multiple of 6)
	Too_Large,  // advertised length exceeds the allowed maximum
}

// SETTINGS identifiers (§6.5.2).
SETTINGS_HEADER_TABLE_SIZE      :: u16(0x1)
SETTINGS_ENABLE_PUSH            :: u16(0x2)
SETTINGS_MAX_CONCURRENT_STREAMS :: u16(0x3)
SETTINGS_INITIAL_WINDOW_SIZE    :: u16(0x4)
SETTINGS_MAX_FRAME_SIZE         :: u16(0x5)
SETTINGS_MAX_HEADER_LIST_SIZE   :: u16(0x6)

// Peer/local SETTINGS values. Defaults match RFC 9113 unless noted.
Settings :: struct {
	header_table_size:      u32, // default 4096
	enable_push:            u32, // default 1 (we advertise 0 — no PUSH)
	max_concurrent_streams: u32, // default unlimited (0 = unset here)
	initial_window_size:    u32, // default 65535
	max_frame_size:         u32, // default 16384
	max_header_list_size:   u32, // default unlimited
}

default_settings :: proc() -> Settings {
	return Settings {
		header_table_size   = 4096,
		// Push stays OFF: we don't implement PUSH_PROMISE, and ignoring one
		// would desync the shared HPACK decoder table (its header block
		// mutates decoder state even if the pushed stream is unwanted).
		enable_push         = 0,
		initial_window_size = 65535,
		max_frame_size      = 16384,
	}
}
