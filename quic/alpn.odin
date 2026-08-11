package quic

import "core:c"

// ALPN protocol identifiers for the zenoh QUIC transport, mirroring
// zenoh-rs's `zenoh-link-commons/src/quic/utils.rs`.
// Ordered by capability — the server is expected to pick the first one
// it supports from the client's list, so the client should advertise
// these in decreasing priority. zenoh-rs's compute_alpn_protocols does
// the same.
ALPN_MULTI_STREAM_MIXED_REL :: "zenoh-ms-mr" // multi-stream + per-priority reliability
ALPN_MULTI_STREAM           :: "zenoh-ms"    // multi-stream, uniform reliability
ALPN_MIXED_REL              :: "zenoh-mr"    // single bidi stream + per-frame reliability
ALPN_SINGLE_STREAM          :: "zenoh"       // single bidi stream
ALPN_LEGACY                 :: "hq-29"       // pre-zenoh, retained for fallback

// Append a length-prefixed ALPN entry to `buf` at offset `n` and return
// the new offset. The ALPN wire format is a sequence of (1-byte length,
// utf-8 bytes) entries (RFC 7301).
@(private)
_alpn_append :: proc(buf: ^[64]u8, n: int, proto: string) -> int {
	buf[n] = u8(len(proto))
	pos := n + 1
	for i in 0..<len(proto) {
		buf[pos + i] = proto[i]
	}
	return pos + len(proto)
}

// Build the ALPN wire list zenoh-odin offers, in decreasing preference.
// Multi-stream variants are listed first so they get picked when the
// peer supports them; the single-stream and legacy entries keep us
// interoperable with zenohd 1.8/1.9 and quinn-based zenoh-rs clients
// that haven't been bumped to multi-stream yet.
// `out` must be sized for the full list (~64 bytes is comfortable). The
// returned slice is a view into `out`.
build_zenoh_alpn_wire :: proc(out: ^[64]u8) -> []u8 {
	n := 0
	n = _alpn_append(out, n, ALPN_MULTI_STREAM_MIXED_REL)
	n = _alpn_append(out, n, ALPN_MULTI_STREAM)
	n = _alpn_append(out, n, ALPN_MIXED_REL)
	n = _alpn_append(out, n, ALPN_SINGLE_STREAM)
	n = _alpn_append(out, n, ALPN_LEGACY)
	return out[:n]
}

// True when the negotiated ALPN enables priority-mapped uni streams.
// Callers gate per-priority stream open on this.
conn_alpn_is_multi_stream :: proc(conn: ^Conn) -> bool {
	a := conn.alpn_negotiated[:conn.alpn_negotiated_len]
	return string(a) == ALPN_MULTI_STREAM || string(a) == ALPN_MULTI_STREAM_MIXED_REL
}

// True when the negotiated ALPN signals per-priority reliability — the
// peer can carry an unreliable best-effort stream alongside the reliable
// ones (we route those via DATAGRAM, but the negotiation also opts the
// peer in to mixed-rel framing).
conn_alpn_is_mixed_rel :: proc(conn: ^Conn) -> bool {
	a := conn.alpn_negotiated[:conn.alpn_negotiated_len]
	return string(a) == ALPN_MIXED_REL || string(a) == ALPN_MULTI_STREAM_MIXED_REL
}

// Read the protocol OpenSSL selected and stash it on the Conn so the
// rest of the stack can branch on it without redoing the SSL_get0
// dance. Safe to call once the TLS handshake has produced 1-RTT keys.
conn_capture_alpn :: proc(conn: ^Conn) {
	if !os_ensure() || conn == nil || conn.tls == nil {
		return
	}
	data: [^]u8
	length: c.uint
	g_os.SSL_get0_alpn_selected(conn.tls, &data, &length)
	if length == 0 || length > c.uint(len(conn.alpn_negotiated)) {
		conn.alpn_negotiated_len = 0
		return
	}
	for i in 0..<int(length) {
		conn.alpn_negotiated[i] = data[i]
	}
	conn.alpn_negotiated_len = int(length)
}
