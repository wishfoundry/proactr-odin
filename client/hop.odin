// Hop — dial result with meta and optional FD.
// hop_dial_stream: Connection path (TLS-complete stream + ALPN OK).
package client

import "core:io"
import "core:mem"
import "core:net"
import "../quic"

Hop_Kind :: enum {
	Stream, // duplex bytes; may also set fd
	Quic,   // ^quic.Conn (+ optional UDP fd for wait)
}

Hop_Meta :: struct {
	scheme, host:  string,
	port:          int,
	local, remote: net.Endpoint, // zero if unknown
	negotiated:    ProtocolVersion,
	nonblocking:   bool,
	alpn:          string, // "" if none
	insecure:      bool,
	// If true, scheme/host/alpn were cloned into hop.allocator and hop_close deletes them.
	strings_owned: bool,
}

Hop :: struct {
	kind:        Hop_Kind,
	meta:        Hop_Meta,
	stream:      io.Stream,
	fd:          i32, // -1 if none
	quic:        ^quic.Conn,
	owns_fd:     bool,
	owns_quic:   bool,
	owns_stream: bool, // io.close on hop_close
	allocator:   mem.Allocator,
	// Internal: stream was created by hop helpers (for close semantics).
}

// hop_close is idempotent. Only closes resources still owned by the hop.
hop_close :: proc(h: ^Hop) {
	if h == nil do return
	if h.owns_stream {
		if h.stream.procedure != nil {
			io.close(h.stream)
		}
		h.owns_stream = false
		h.stream = {}
		// TCP/TLS stream close already closed fd if it owned the sock.
		if h.owns_fd {
			h.owns_fd = false
			h.fd = -1
		}
	} else if h.owns_fd && h.fd >= 0 {
		net.close(net.TCP_Socket(h.fd))
		h.owns_fd = false
		h.fd = -1
	}
	if h.owns_quic && h.quic != nil {
		quic.conn_udp_close(h.quic)
		quic.conn_free(h.quic)
		h.quic = nil
		h.owns_quic = false
	}
	if h.meta.strings_owned {
		alloc := h.allocator
		if len(h.meta.scheme) > 0 do delete(h.meta.scheme, alloc)
		if len(h.meta.host) > 0 do delete(h.meta.host, alloc)
		if len(h.meta.alpn) > 0 do delete(h.meta.alpn, alloc)
		h.meta.scheme = ""
		h.meta.host = ""
		h.meta.alpn = ""
		h.meta.strings_owned = false
	}
	h.fd = -1 if h.fd >= 0 && !h.owns_fd else h.fd
	h.kind = .Stream
	h.meta.negotiated = .Auto
	h.meta.nonblocking = false
	h.quic = nil
}

// hop_take_fd transfers FD ownership to the caller (job). hop will not close fd.
hop_take_fd :: proc(h: ^Hop) -> i32 {
	if h == nil || h.fd < 0 do return -1
	fd := h.fd
	h.owns_fd = false
	// Stream still may close sock on io.close — clear owns_stream if stream wraps same fd.
	if h.stream.procedure == _tcp_stream_proc {
		h.owns_stream = false
		h.stream = {}
	} else if h.stream.procedure == _tls_stream_proc {
		// TLS stream owns SSL+sock; taking fd is unsafe for dual close.
		// Leave owns_stream true only if we did not take for proactr clear path.
		// clear_fd path never has TLS stream.
	}
	h.fd = -1
	return fd
}

// hop_from_v1_dialer runs a legacy Dial_Proc and packs a Stream hop.
// Extracts fd for known TCP/TLS stream layouts when possible.
hop_from_v1_dialer :: proc(
	dialer: Dialer,
	target: Target,
	allocator: mem.Allocator,
) -> (Hop, Http_Error) {
	if dialer.procedure == nil {
		return {}, .Not_Configured
	}
	stream, negotiated, err := dialer.procedure(dialer.data, target, allocator)
	if err != .None {
		return {}, err
	}
	if negotiated == .Auto {
		negotiated = .Http1
	}
	h := hop_from_stream(stream, target, negotiated, allocator, owns_stream = true)
	return h, .None
}

// hop_from_stream builds a Hop around an existing stream.
// owns_stream: if true, hop_close will io.close the stream.
hop_from_stream :: proc(
	stream: io.Stream,
	target: Target,
	negotiated: ProtocolVersion,
	allocator: mem.Allocator,
	owns_stream := true,
) -> Hop {
	h: Hop
	h.kind = .Stream
	h.stream = stream
	h.owns_stream = owns_stream
	h.fd = -1
	h.allocator = allocator
	h.meta.scheme = target.scheme
	h.meta.host = target.host
	h.meta.port = target.port
	h.meta.negotiated = negotiated
	h.meta.strings_owned = false // borrow target strings
	// Extract fd from known layouts.
	if stream.procedure == _tcp_stream_proc {
		h.fd = i32(uintptr(stream.data))
		h.owns_fd = false // stream Close owns sock
		h.meta.nonblocking = false // unknown; caller may set
	} else if stream.procedure == _tls_stream_proc {
		st := (^Tls_State)(stream.data)
		if st != nil {
			h.fd = i32(st.sock)
			h.owns_fd = false
			h.meta.insecure = false // unknown from stream alone
		}
	}
	return h
}

// hop_dial_stream — legacy Connection path (https → TLS dialer by default).
hop_dial_stream :: proc(
	target: Target,
	opts: Options,
	allocator := context.allocator,
) -> (Hop, Http_Error) {
	t := target
	t.version = opts.version
	t.dial_timeout_ms = _resolve_dial_timeout_ms(opts.timeout)

	dialer := opts.dialer
	if dialer.procedure == nil {
		switch {
		case t.scheme != "https": dialer = tcp_dialer
		case opts.insecure:       dialer = tls_dialer_insecure
		case:                     dialer = tls_dialer
		}
	}
	h, err := hop_from_v1_dialer(dialer, t, allocator)
	if err != .None do return {}, err

	// Fill remote when TCP/TLS known.
	if h.fd >= 0 {
		// Best-effort: remote from resolve (dial already connected).
		ep4, ep6, rerr := net.resolve(t.host)
		if rerr == nil {
			ep := ep4 if ep4.address != nil else ep6
			ep.port = t.port
			h.meta.remote = ep
		}
	}
	if opts.version != .Auto && h.meta.negotiated != opts.version {
		hop_close(&h)
		return {}, .Unsupported_Version
	}
	return h, .None
}

// hop_dial_clear_fd — proactr path: nonblocking clear TCP only (no SSL).
// Custom dialer must not return a finished TLS stream.
hop_dial_clear_fd :: proc(
	target: Target,
	opts: Options,
	allocator := context.allocator,
) -> (Hop, Http_Error) {
	t := target
	t.version = .Http1
	t.dial_timeout_ms = _resolve_dial_timeout_ms(opts.timeout)

	if opts.dialer.procedure != nil {
		h, err := hop_from_v1_dialer(opts.dialer, t, allocator)
		if err != .None do return {}, err
		// Reject TLS-complete streams for proactr mem-BIO path.
		if h.stream.procedure == _tls_stream_proc {
			hop_close(&h)
			return {}, .Unsupported_Version
		}
		if h.fd < 0 {
			hop_close(&h)
			return {}, .Not_Configured
		}
		// Ensure nonblocking for proactr.
		_ = net.set_blocking(net.TCP_Socket(h.fd), false)
		h.meta.nonblocking = true
		// Transfer: job path will take fd; keep stream closed carefully.
		// For clear TCP stream, take ownership of fd and drop stream close of sock.
		if h.stream.procedure == _tcp_stream_proc {
			h.owns_stream = false
			h.stream = {}
			h.owns_fd = true
		}
		return h, .None
	}

	// Default clear TCP.
	ep4, ep6, rerr := net.resolve(t.host)
	if rerr != nil do return {}, .Resolve_Failed
	ep := ep4 if ep4.address != nil else ep6
	ep.port = t.port

	sock, derr := net.dial_tcp(ep)
	if derr != nil do return {}, .Connect_Failed
	if berr := net.set_blocking(sock, false); berr != nil {
		net.close(sock)
		return {}, .Connect_Failed
	}

	h: Hop
	h.kind = .Stream
	h.fd = i32(sock)
	h.owns_fd = true
	h.owns_stream = false
	h.allocator = allocator
	h.meta.scheme = t.scheme
	h.meta.host = t.host
	h.meta.port = t.port
	h.meta.remote = ep
	h.meta.negotiated = .Http1
	h.meta.nonblocking = true
	h.meta.insecure = opts.insecure
	h.meta.strings_owned = false
	return h, .None
}
