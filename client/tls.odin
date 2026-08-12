// The TLS dialer — h1/h2 auto-negotiation over OpenSSL dynlib (openssl_dynlib).
// Offers ALPN ["h2", "http/1.1"]; negotiated version drives the request path.
package client

import "core:c"
import "core:io"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import od "../openssl_dynlib"

// Built-in TLS dialer. `dial` picks it for https targets.
tls_dialer :: Dialer{procedure = _tls_dial}

// Certificate verification OFF (non-nil data flag).
tls_dialer_insecure :: Dialer{procedure = _tls_dial, data = rawptr(uintptr(1))}

@(private)
_suppress_sigpipe :: proc(sock: net.TCP_Socket) {
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD {
		SO_NOSIGPIPE :: 0x1022
		one: c.int = 1
		_ = posix.setsockopt(posix.FD(sock), posix.SOL_SOCKET, posix.Sock_Option(SO_NOSIGPIPE), &one, size_of(one))
	}
}

@(private, rodata)
ALPN_H2_H1 := [12]u8{2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1'}

// Shared client SSL_CTX: roots once; VERIFY_NONE on CTX; PEER only on SSL when secure.
@(private)
_client_ssl: struct {
	once:     sync.Once,
	ctx:      rawptr,
	roots_ok: bool,
	ok:       bool, // CTX created
}

// Debug/test: how many times roots were loaded (must stay 1 after multi-dial).
client_roots_load_count: int

@(private)
Tls_State :: struct {
	ssl:       rawptr,
	sock:      net.TCP_Socket,
	allocator: mem.Allocator,
}

@(private)
_client_ssl_ctx_ensure :: proc() {
	sync.once_do(&_client_ssl.once, proc() {
		if !od.os_ensure_ssl() do return
		ctx := od.g_os.SSL_CTX_new(od.g_os.TLS_client_method())
		if ctx == nil do return
		_ = od.SSL_CTX_set_min_proto_version(ctx, c.int(od.TLS1_2_VERSION))
		_ = od.SSL_CTX_set_max_proto_version(ctx, c.int(od.TLS1_3_VERSION))
		if od.g_os.SSL_CTX_set_verify != nil {
			od.g_os.SSL_CTX_set_verify(ctx, od.SSL_VERIFY_NONE, nil)
		}
		if od.load_system_roots(ctx) {
			_client_ssl.roots_ok = true
			client_roots_load_count += 1
		}
		_client_ssl.ctx = ctx
		_client_ssl.ok = true
	})
}

@(private)
_tls_dial :: proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (stream: io.Stream, negotiated: ProtocolVersion, err: Http_Error) {
	if !od.os_ensure_ssl() {
		return {}, .Http1, .Tls_Failed
	}
	_client_ssl_ctx_ensure()
	if !_client_ssl.ok || _client_ssl.ctx == nil {
		return {}, .Http1, .Tls_Failed
	}

	insecure := data != nil
	if !insecure && !_client_ssl.roots_ok {
		return {}, .Http1, .Tls_Failed
	}

	ep4, ep6, rerr := net.resolve(target.host)
	if rerr != nil do return {}, .Http1, .Resolve_Failed
	ep := ep4 if ep4.address != nil else ep6
	ep.port = target.port

	sock, derr := net.dial_tcp(ep)
	if derr != nil do return {}, .Http1, .Connect_Failed
	_suppress_sigpipe(sock)

	dial_to := time.Duration(_resolve_dial_timeout_ms(target.dial_timeout_ms)) * time.Millisecond
	_set_sock_timeouts(sock, dial_to)

	ssl := od.g_os.SSL_new(_client_ssl.ctx)
	if ssl == nil {
		net.close(sock)
		return {}, .Http1, .Tls_Failed
	}

	fail :: proc(ssl: rawptr, sock: net.TCP_Socket) {
		od.g_os.SSL_free(ssl)
		net.close(sock)
	}

	if od.g_os.SSL_set_fd(ssl, c.int(sock)) != 1 {
		fail(ssl, sock)
		return {}, .Http1, .Tls_Failed
	}

	is_hostname := net.parse_address(target.host) == nil
	if is_hostname {
		host_c := strings.clone_to_cstring(target.host, context.temp_allocator)
		if od.SSL_set_tlsext_host_name(ssl, host_c) != 1 {
			fail(ssl, sock)
			return {}, .Http1, .Tls_Failed
		}
	}

	if insecure {
		od.g_os.SSL_set_verify(ssl, od.SSL_VERIFY_NONE, nil)
	} else {
		od.g_os.SSL_set_verify(ssl, od.SSL_VERIFY_PEER, nil)
		if is_hostname {
			host_c := strings.clone_to_cstring(target.host, context.temp_allocator)
			if od.g_os.SSL_set1_host(ssl, host_c) != 1 {
				fail(ssl, sock)
				return {}, .Http1, .Tls_Failed
			}
		}
	}

	alpn := ALPN_H2_H1
	offer := alpn[:]
	#partial switch target.version {
	case .Http2: offer = alpn[:3]
	case .Http1: offer = alpn[3:]
	}
	if od.g_os.SSL_set_alpn_protos(ssl, raw_data(offer), c.uint(len(offer))) != 0 {
		fail(ssl, sock)
		return {}, .Http1, .Tls_Failed
	}

	if ret := od.g_os.SSL_connect(ssl); ret != 1 {
		ferr := Http_Error.Tls_Failed
		if od.g_os.SSL_get_error(ssl, ret) == od.SSL_ERROR_SYSCALL {
			ferr = .Timeout
		}
		fail(ssl, sock)
		return {}, .Http1, ferr
	}

	proto: [^]u8
	proto_len: c.uint
	od.g_os.SSL_get0_alpn_selected(ssl, &proto, &proto_len)
	negotiated = .Http1
	if proto_len == 2 && proto[0] == 'h' && proto[1] == '2' {
		negotiated = .Http2
	} else if proto_len == 8 &&
		proto[0] == 'h' &&
		proto[1] == 't' &&
		proto[2] == 't' &&
		proto[3] == 'p' {
		negotiated = .Http1
	} else if proto_len == 0 {
		negotiated = .Http1
	} else {
		// Unknown ALPN — fail closed.
		fail(ssl, sock)
		return {}, .Http1, .Unsupported_Version
	}

	st := new(Tls_State, allocator)
	st^ = {ssl = ssl, sock = sock, allocator = allocator}
	return io.Stream{data = st, procedure = _tls_stream_proc}, negotiated, .None
}

@(private)
_tls_stream_proc :: proc(
	stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	st := (^Tls_State)(stream_data)
	#partial switch mode {
	case .Query:
		return io.query_utility(io.Stream_Mode_Set{.Query, .Read, .Write, .Close})
	case .Read:
		ret := od.g_os.SSL_read(st.ssl, raw_data(p), c.int(len(p)))
		if ret > 0 do return i64(ret), .None
		if od.g_os.SSL_get_error(st.ssl, ret) == od.SSL_ERROR_ZERO_RETURN do return 0, .EOF
		return 0, .Unexpected_EOF
	case .Write:
		ret := od.g_os.SSL_write(st.ssl, raw_data(p), c.int(len(p)))
		if ret <= 0 do return 0, .Short_Write
		return i64(ret), .None
	case .Close:
		_ = od.g_os.SSL_shutdown(st.ssl)
		od.g_os.SSL_free(st.ssl)
		net.close(st.sock)
		free(st, st.allocator)
		return 0, .None
	}
	return 0, .Empty
}
