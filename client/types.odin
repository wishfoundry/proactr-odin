package client

import "core:io"
import "core:mem"

import http "../http"
import "../http2"
import "../httpfield"
import "../qpack"

// Client wire vocabulary. Header is shared H2/H3 field type (httpfield).
// Status reuses package http status codes.

// Which protocol a request runs over.
// Auto = TLS ALPN h2|http/1.1 (client toolkit default). Http3 = QUIC (explicit).
// Optional client follow_alt_svc can upgrade Auto via cached Alt-Svc h3.
// Forced Http1/Http2 must match ALPN.
ProtocolVersion :: enum {
	Auto,
	Http1,
	Http2,
	Http3,
}

// One flat error for the client stack. Drivers map internal errors into this.
Http_Error :: enum {
	None,
	Invalid_Url,
	Resolve_Failed,
	Connect_Failed,
	Tls_Failed,
	Timeout,
	Closed,
	Protocol,
	Header_Compression,
	Unsupported_Version,
	// Buffered response body exceeded Options.max_response_body (or the package default).
	Body_Too_Large,
	// Inbound exchange died; do not respond on inbound res (async cancel).
	Exchange_Gone,
	// e.g. blocking get/request on server worker (http_worker_active).
	// Diagnostic string: INVALID_USE_DIAGNOSTIC (release builds / logs).
	Invalid_Use,
	// get_async without worker runtime installed.
	Not_Configured,
}

// Fixed diagnostic for .Invalid_Use (design §5.6).
INVALID_USE_DIAGNOSTIC :: "blocking client API on server worker; use get_async"

// Header field pair — QPACK/H3 native; H2 path converts to http2.Header (hpack).
Header :: qpack.Header

// Ordered list of header fields — insertion order preserved, duplicates allowed.
OrderedHeaders :: distinct [dynamic]Header

// HTTP status codes reuse the server package enum (numeric values only).
Status :: http.Status

// A parsed request target: the authority (+ default path) to dial.
Target :: struct {
	scheme:  string,
	host:    string,
	path:    string,
	port:    int,
	// Hint for the dialer's ALPN offer (.Auto = offer h2 + http/1.1).
	// After dial, Connection.version is always the *negotiated* protocol.
	version: ProtocolVersion,
	// Dial budget in ms (set by dial from Options.timeout). Built-in dialers
	// may honor it; custom Dial_Proc implementations may ignore it. 0 = unset.
	dial_timeout_ms: int,
}

// A client request — built, then sent. Body is a materialized slice.
Request :: struct {
	method:  string,
	target:  Target,
	headers: OrderedHeaders,
	body:    []u8,
}

// A client response — status + headers + fully-read body.
Response :: struct {
	status:  Status,
	headers: OrderedHeaders,
	body:    [dynamic]u8,
	version: ProtocolVersion,
}

// A live client connection. h1/h2 ride a byte stream; h3 owns its QUIC state.
// Reuse: call request() multiple times (h1 keep-alive, h2 mux, h3 streams).
// Redirect following (Options.max_redirects) is applied by request/get using
// dial options stored below so cross-origin hops can re-dial this Connection.
Connection :: struct {
	// Negotiated wire protocol (never a forced-but-wrong value).
	version:   ProtocolVersion,
	target:    Target,
	allocator: mem.Allocator,
	// From Options.timeout (ms); 0 = package defaults (dial + request).
	timeout_ms: int,
	// Resolved max buffered response body (never 0 after dial).
	max_response_body: int,
	// Resolved redirect budget: -1 = never follow; >=0 = max hops to follow.
	max_redirects: int,
	// Skip cert verify (copied from Options for Alt-Svc H3 redials).
	insecure: bool,
	// Alt-Svc cache this connection learns into (nil = none).
	alt_svc: ^Alt_Svc_Cache,

	// Dial knobs retained for redirect re-dials (same Options as initial dial).
	dialer:         Dialer,
	prefer_version: ProtocolVersion, // Options.version at dial
	follow_alt_svc: bool,
	prefer_h3:      bool, // Options.prefer_h3 at dial

	// Stream-family hop context (meta + fd). Source of truth after stream dial;
	// transport.stream is the byte pipe for request(). Zero hop.fd if unknown.
	hop: Hop,

	transport: union {
		io.Stream,    // h1, h2
		^Http3_State, // h3 (QUIC + H3_Session, see h3.odin / session_h3.odin)
	},

	// Persistent h2 mux: preface/SETTINGS once, then sequential requests on
	// stream ids 1, 3, 5, ... over the one TLS connection.
	h2:         http2.Http2_Connection,
	h2_started: bool,

	// H1 keep-alive: leftover bytes after a framed response.
	h1_rx:         [dynamic]u8,
	h1_alive:      bool, // false after peer close / framing error
	h1_keep_alive: bool, // request Connection: keep-alive (false → connection: close)

	// Resolved Options.accept_gzip (default true): offer gzip + gunzip responses.
	accept_gzip: bool,
}


