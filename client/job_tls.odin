// TLS mem-BIO drive for Client_Job.
// Ciphertext on the wire via proactr send/recv; SSL never owns the fd.
// Free SSL only from job_free_transport when ops_outstanding == 0.
package client

import "core:c"
import "core:mem"
import "core:net"
import "core:strings"

import od "../openssl_dynlib"
import proactr "../proactr"

// OpenSSL SSL_MODE bits (match tls_server / OpenSSL).
@(private)
_SSL_MODE_ENABLE_PARTIAL_WRITE :: c.long(0x00000001)
@(private)
_SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER :: c.long(0x00000002)

@(private)
_job_reset_tls :: proc(job: ^Client_Job) {
	job.use_tls = false
	job.ssl = nil
	job.insecure = false
	job.host_owned = ""
	job.req_method_owned = ""
	job.req_path_owned = ""
	job.req_port = 0
	job.want_version = .Auto
	job.negotiated = .Auto
	job.tls_stage = .None
	job.ct_send_inflight = false
	job.ct_recv_inflight = false
	job.app_tx_off = 0
	job.h2_started = false
	job.h2_sid = 0
	job.h2 = {}
}

// Free SSL (BIOs owned by SSL_set_bio), H2 session, and owned host/path strings.
// Caller must ensure ops_outstanding == 0 when ssl != nil (normative free law).
@(private)
_job_tls_free :: proc(job: ^Client_Job) {
	if job == nil do return
	if job.ssl != nil {
		assert(job.ops_outstanding == 0, "SSL_free with ops outstanding")
		if od.g_os.SSL_free != nil {
			od.g_os.SSL_free(job.ssl)
		}
		job.ssl = nil
	}
	if job.h2_started {
		h2_client_session_destroy(&job.h2)
		job.h2_started = false
		job.h2_sid = 0
	}
	if len(job.host_owned) > 0 {
		delete(job.host_owned, job.runtime.allocator if job.runtime != nil else job.allocator)
		job.host_owned = ""
	}
	if len(job.req_method_owned) > 0 {
		delete(job.req_method_owned, job.runtime.allocator if job.runtime != nil else job.allocator)
		job.req_method_owned = ""
	}
	if len(job.req_path_owned) > 0 {
		delete(job.req_path_owned, job.runtime.allocator if job.runtime != nil else job.allocator)
		job.req_path_owned = ""
	}
	job.use_tls = false
	job.tls_stage = .None
	job.ct_send_inflight = false
	job.ct_recv_inflight = false
	job.negotiated = .Auto
	job.want_version = .Auto
}

// SSL_new + mem-BIO + SNI/ALPN/verify (same semantics as client/tls.odin dialer).
// Does not dial; job.fd must already be connected O_NONBLOCK.
@(private)
_job_tls_setup :: proc(
	job: ^Client_Job,
	host: string,
	insecure: bool,
	want: ProtocolVersion,
) -> Http_Error {
	if !od.os_ensure_ssl() {
		return .Tls_Failed
	}
	_client_ssl_ctx_ensure()
	if !_client_ssl.ok || _client_ssl.ctx == nil {
		return .Tls_Failed
	}
	if !insecure && !_client_ssl.roots_ok {
		return .Tls_Failed
	}

	ssl := od.g_os.SSL_new(_client_ssl.ctx)
	if ssl == nil {
		return .Tls_Failed
	}

	rbio := od.g_os.BIO_new(od.g_os.BIO_s_mem())
	wbio := od.g_os.BIO_new(od.g_os.BIO_s_mem())
	if rbio == nil || wbio == nil {
		if rbio != nil do od.g_os.BIO_free(rbio)
		if wbio != nil do od.g_os.BIO_free(wbio)
		od.g_os.SSL_free(ssl)
		return .Tls_Failed
	}
	// SSL takes ownership of both BIOs.
	od.g_os.SSL_set_bio(ssl, rbio, wbio)
	od.g_os.SSL_set_connect_state(ssl)

	if od.g_os.SSL_set_mode != nil {
		_ = od.g_os.SSL_set_mode(
			ssl,
			_SSL_MODE_ENABLE_PARTIAL_WRITE | _SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER,
		)
	}

	alloc := job.runtime.allocator if job.runtime != nil else job.allocator
	job.host_owned = strings.clone(host, alloc)
	is_hostname := net.parse_address(host) == nil
	if is_hostname {
		host_c := strings.clone_to_cstring(host, context.temp_allocator)
		if od.SSL_set_tlsext_host_name(ssl, host_c) != 1 {
			od.g_os.SSL_free(ssl)
			job.ssl = nil
			delete(job.host_owned, alloc)
			job.host_owned = ""
			return .Tls_Failed
		}
	}

	job.insecure = insecure
	if insecure {
		od.g_os.SSL_set_verify(ssl, od.SSL_VERIFY_NONE, nil)
	} else {
		od.g_os.SSL_set_verify(ssl, od.SSL_VERIFY_PEER, nil)
		if is_hostname {
			host_c := strings.clone_to_cstring(host, context.temp_allocator)
			if od.g_os.SSL_set1_host(ssl, host_c) != 1 {
				od.g_os.SSL_free(ssl)
				job.ssl = nil
				delete(job.host_owned, alloc)
				job.host_owned = ""
				return .Tls_Failed
			}
		}
	}

	alpn := ALPN_H2_H1
	offer := alpn[:]
	#partial switch want {
	case .Http2:
		offer = alpn[:3]
	case .Http1:
		offer = alpn[3:]
	}
	if od.g_os.SSL_set_alpn_protos(ssl, raw_data(offer), c.uint(len(offer))) != 0 {
		od.g_os.SSL_free(ssl)
		job.ssl = nil
		delete(job.host_owned, alloc)
		job.host_owned = ""
		return .Tls_Failed
	}

	job.ssl = ssl
	job.use_tls = true
	job.want_version = want
	job.negotiated = .Auto
	job.tls_stage = .Handshake
	job.phase = .Tls_Handshake
	job.ct_send_inflight = false
	job.ct_recv_inflight = false
	return .None
}

// Copy wBIO pending ciphertext into job.tx and submit_send if not inflight.
// CT buffer is owned until Send CQE (do not reset wBIO via peek alone).
@(private)
_job_tls_flush_wbio :: proc(job: ^Client_Job) -> Http_Error {
	if job.ssl == nil {
		return .Tls_Failed
	}
	// Finish any unsent CT first (at most one CT send in flight).
	if job.ct_send_inflight {
		return .None
	}
	if job.tx_off < len(job.tx) {
		return _job_tls_submit_send(job)
	}

	wbio := od.g_os.SSL_get_wbio(job.ssl)
	if wbio == nil {
		return .Tls_Failed
	}
	pending := int(od.g_os.BIO_ctrl_pending(wbio))
	if pending <= 0 {
		return .None
	}

	clear(&job.tx)
	reserve(&job.tx, pending)
	resize(&job.tx, pending)
	n := od.g_os.BIO_read(wbio, raw_data(job.tx), c.int(pending))
	if n <= 0 {
		clear(&job.tx)
		return .None
	}
	resize(&job.tx, int(n))
	job.tx_off = 0
	return _job_tls_submit_send(job)
}

@(private)
_job_tls_submit_send :: proc(job: ^Client_Job) -> Http_Error {
	if job.ct_send_inflight {
		return .None
	}
	if job.tx_off >= len(job.tx) {
		return .None
	}
	rt := job.runtime
	if rt == nil || rt.ring == nil || job.fd < 0 {
		return .Closed
	}
	buf := job.tx[job.tx_off:]
	id, err := proactr.submit_send(rt.ring, job.fd, buf, _job_user(job))
	if err != .None {
		return .Closed
	}
	job.ops_outstanding += 1
	rt.pending_ops += 1
	job.ct_send_inflight = true
	job.phase = .Sending if job.tls_stage != .Handshake else .Tls_Handshake
	_ = id
	return .None
}

@(private)
_job_tls_submit_recv :: proc(job: ^Client_Job) -> Http_Error {
	if job.ct_recv_inflight {
		return .None
	}
	rt := job.runtime
	if rt == nil || rt.ring == nil || job.fd < 0 {
		return .Closed
	}
	if job.recv_buf == nil {
		job.recv_buf = make([]u8, 4096, rt.allocator)
	}
	id, err := proactr.submit_recv(rt.ring, job.fd, job.recv_buf, _job_user(job))
	if err != .None {
		return .Closed
	}
	job.ops_outstanding += 1
	rt.pending_ops += 1
	job.ct_recv_inflight = true
	if job.tls_stage == .Handshake {
		job.phase = .Tls_Handshake
	} else {
		job.phase = .Recving
	}
	_ = id
	return .None
}

@(private)
_job_tls_on_send :: proc(job: ^Client_Job, result: i32) {
	job.ct_send_inflight = false
	if result < 0 {
		_job_fail(job, .Closed)
		return
	}
	job.tx_off += int(result)
	if job.tx_off < len(job.tx) {
		if e := _job_tls_submit_send(job); e != .None {
			_job_fail(job, e)
		}
		return
	}
	// Full CT buffer sent — drop ownership; more may be in wBIO.
	clear(&job.tx)
	job.tx_off = 0
	_job_tls_drive(job)
}

@(private)
_job_tls_on_recv :: proc(job: ^Client_Job, result: i32) {
	job.ct_recv_inflight = false
	if result < 0 {
		if job.tls_stage == .App_Read && job.negotiated == .Http1 {
			if job.header_sep >= 0 && _job_body_complete(job) {
				_job_finish_success(job)
				return
			}
		}
		_job_fail(job, .Closed)
		return
	}
	if result == 0 {
		// TCP EOF.
		if job.tls_stage == .App_Read && job.negotiated == .Http1 {
			if job.header_sep < 0 {
				_job_fail(job, .Closed)
				return
			}
			if job.content_length >= 0 && !_job_body_complete(job) {
				_job_fail(job, .Closed)
				return
			}
			_job_finish_success(job)
			return
		}
		if job.tls_stage == .App_Read && job.negotiated == .Http2 {
			// Try complete from already-fed data; else closed.
			if job.h2_started {
				if res, ok := h2_client_session_take_response(&job.h2, job.h2_sid, job.allocator); ok {
					if len(res.body) > job.max_body {
						response_destroy(&res, job.allocator)
						_job_fail(job, .Body_Too_Large)
						return
					}
					job.result = res
					job.phase = .Done
					out := job.result
					job.result = {}
					if job.fd >= 0 {
						net.close(net.TCP_Socket(job.fd))
						job.fd = -1
					}
					_job_fire_done(job, out, .None)
					return
				}
			}
		}
		_job_fail(job, .Closed)
		return
	}

	n := int(result)
	if n > len(job.recv_buf) {
		n = len(job.recv_buf)
	}
	rbio := od.g_os.SSL_get_rbio(job.ssl)
	if rbio == nil {
		_job_fail(job, .Tls_Failed)
		return
	}
	w := od.g_os.BIO_write(rbio, raw_data(job.recv_buf), c.int(n))
	// Mem-BIO should accept full write; short write would drop CT.
	if w < 0 || int(w) != n {
		_job_fail(job, .Tls_Failed)
		return
	}
	_job_tls_drive(job)
}

// WANT_WRITE: flush wBIO CT. If send in flight, yield. If wBIO empty after flush,
// arm CT recv once (never busy-spin). Returns true if caller must stop the drive loop.
@(private)
_job_tls_on_want_write :: proc(job: ^Client_Job) -> (yield: bool) {
	if e := _job_tls_flush_wbio(job); e != .None {
		_job_fail(job, e)
		return true
	}
	if job.ct_send_inflight {
		return true
	}
	// Pathological empty WANT_WRITE with mem-BIO: arm recv once, do not spin.
	if e := _job_tls_submit_recv(job); e != .None {
		_job_fail(job, e)
	}
	return true
}

// Main TLS SM: handshake → ALPN → H1/H2 app write/read.
// Called after setup and after each CT send/recv CQE.
@(private)
_job_tls_drive :: proc(job: ^Client_Job) {
	if job == nil || !job.live || job.done_fired || job.phase_cancel {
		return
	}
	if job.ssl == nil {
		_job_fail(job, .Tls_Failed)
		return
	}

	// Prefer draining outbound CT before further SSL ops.
	if e := _job_tls_flush_wbio(job); e != .None {
		_job_fail(job, e)
		return
	}
	if job.ct_send_inflight {
		return
	}

	#partial switch job.tls_stage {
	case .Handshake:
		_job_tls_drive_handshake(job)
	case .App_Write:
		_job_tls_drive_app_write(job)
	case .App_Read:
		_job_tls_drive_app_read(job)
	case:
		_job_fail(job, .Protocol)
	}
}

@(private)
_job_tls_drive_handshake :: proc(job: ^Client_Job) {
	for {
		if job.done_fired || job.phase_cancel {
			return
		}
		if e := _job_tls_flush_wbio(job); e != .None {
			_job_fail(job, e)
			return
		}
		if job.ct_send_inflight {
			return
		}

		ret := od.g_os.SSL_do_handshake(job.ssl)
		if ret == 1 {
			// Final HS records.
			if e := _job_tls_flush_wbio(job); e != .None {
				_job_fail(job, e)
				return
			}
			if job.ct_send_inflight {
				// Complete after CT send CQE re-enters drive.
				return
			}
			if e := _job_tls_on_handshake_complete(job); e != .None {
				_job_fail(job, e)
				return
			}
			_job_tls_drive(job)
			return
		}

		ge := od.g_os.SSL_get_error(job.ssl, ret)
		if ge == od.SSL_ERROR_WANT_WRITE {
			_ = _job_tls_on_want_write(job)
			return
		}
		if ge == od.SSL_ERROR_WANT_READ {
			if e := _job_tls_flush_wbio(job); e != .None {
				_job_fail(job, e)
				return
			}
			if job.ct_send_inflight {
				return
			}
			if e := _job_tls_submit_recv(job); e != .None {
				_job_fail(job, e)
			}
			return
		}
		// SSL_ERROR_SSL / SYSCALL / other.
		_job_fail(job, .Tls_Failed)
		return
	}
}

@(private)
_job_tls_on_handshake_complete :: proc(job: ^Client_Job) -> Http_Error {
	proto: [^]u8
	proto_len: c.uint
	od.g_os.SSL_get0_alpn_selected(job.ssl, &proto, &proto_len)
	negotiated := ProtocolVersion.Http1
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
		return .Unsupported_Version
	}

	if job.want_version != .Auto && negotiated != job.want_version {
		return .Unsupported_Version
	}
	job.negotiated = negotiated

	clear(&job.app_tx)
	job.app_tx_off = 0

	if negotiated == .Http2 {
		return _job_tls_start_h2(job)
	}
	return _job_tls_start_h1(job)
}

@(private)
_job_tls_start_h1 :: proc(job: ^Client_Job) -> Http_Error {
	method := job.req_method_owned if len(job.req_method_owned) > 0 else "GET"
	path := job.req_path_owned if len(job.req_path_owned) > 0 else "/"
	host := job.host_owned
	port := job.req_port
	_job_build_h1_request(&job.app_tx, method, host, path, port, nil, "https")
	job.app_tx_off = 0
	job.tls_stage = .App_Write
	job.phase = .Sending
	job.header_sep = -1
	job.content_length = -1
	clear(&job.rx)
	return .None
}

@(private)
_job_tls_start_h2 :: proc(job: ^Client_Job) -> Http_Error {
	alloc := job.runtime.allocator if job.runtime != nil else job.allocator
	h2_client_session_init(&job.h2, alloc)
	job.h2_started = true

	// Preface + SETTINGS into app_tx.
	if len(job.h2.out) > 0 {
		append(&job.app_tx, ..job.h2.out[:])
		clear(&job.h2.out)
	}

	method := job.req_method_owned if len(job.req_method_owned) > 0 else "GET"
	path := job.req_path_owned if len(job.req_path_owned) > 0 else "/"
	hdrs: [dynamic]Header
	hdrs.allocator = context.temp_allocator
	append(&hdrs, Header{name = ":method", value = method})
	append(&hdrs, Header{name = ":scheme", value = "https"})
	append(
		&hdrs,
		Header {
			name  = ":authority",
			value = format_authority("https", job.host_owned, job.req_port),
		},
	)
	append(&hdrs, Header{name = ":path", value = path})
	append(&hdrs, Header{name = "user-agent", value = DEFAULT_USER_AGENT})
	job.h2_sid = h2_client_session_send_headers(&job.h2, hdrs[:], nil)
	if len(job.h2.out) > 0 {
		append(&job.app_tx, ..job.h2.out[:])
		clear(&job.h2.out)
	}

	job.app_tx_off = 0
	job.tls_stage = .App_Write
	job.phase = .Sending
	return .None
}

@(private)
_job_tls_drive_app_write :: proc(job: ^Client_Job) {
	for {
		if job.done_fired || job.phase_cancel {
			return
		}
		if e := _job_tls_flush_wbio(job); e != .None {
			_job_fail(job, e)
			return
		}
		if job.ct_send_inflight {
			return
		}

		if job.app_tx_off >= len(job.app_tx) {
			// PT request fully encrypted.
			clear(&job.app_tx)
			job.app_tx_off = 0
			job.tls_stage = .App_Read
			job.phase = .Recving
			_job_tls_drive_app_read(job)
			return
		}

		remain := job.app_tx[job.app_tx_off:]
		ret := od.g_os.SSL_write(job.ssl, raw_data(remain), c.int(len(remain)))
		if ret > 0 {
			job.app_tx_off += int(ret)
			if e := _job_tls_flush_wbio(job); e != .None {
				_job_fail(job, e)
				return
			}
			if job.ct_send_inflight {
				return
			}
			continue
		}

		ge := od.g_os.SSL_get_error(job.ssl, ret)
		if ge == od.SSL_ERROR_WANT_WRITE {
			_ = _job_tls_on_want_write(job)
			return
		}
		if ge == od.SSL_ERROR_WANT_READ {
			if e := _job_tls_flush_wbio(job); e != .None {
				_job_fail(job, e)
				return
			}
			if job.ct_send_inflight {
				return
			}
			if e := _job_tls_submit_recv(job); e != .None {
				_job_fail(job, e)
			}
			return
		}
		_job_fail(job, .Tls_Failed)
		return
	}
}

@(private)
_job_tls_drive_app_read :: proc(job: ^Client_Job) {
	if job.negotiated == .Http2 {
		_job_tls_drive_h2_read(job)
		return
	}
	_job_tls_drive_h1_read(job)
}

@(private)
_job_tls_drive_h1_read :: proc(job: ^Client_Job) {
	pt: [4096]u8
	for {
		if job.done_fired || job.phase_cancel {
			return
		}
		// Drain any control CT first.
		if e := _job_tls_flush_wbio(job); e != .None {
			_job_fail(job, e)
			return
		}
		if job.ct_send_inflight {
			return
		}

		ret := od.g_os.SSL_read(job.ssl, raw_data(pt[:]), c.int(len(pt)))
		if ret > 0 {
			n := int(ret)
			prev_len := len(job.rx)
			append(&job.rx, ..pt[:n])

			if job.header_sep < 0 {
				scan_from := prev_len - 3
				if scan_from < 0 do scan_from = 0
				if sep := _find_header_end(job.rx[scan_from:]); sep >= 0 {
					job.header_sep = scan_from + sep
					if e := _job_parse_headers(job); e != .None {
						_job_fail(job, e)
						return
					}
				} else if len(job.rx) > 1024 * 1024 {
					_job_fail(job, .Protocol)
					return
				}
			}

			if job.header_sep >= 0 {
				body_len := len(job.rx) - (job.header_sep + 4)
				if body_len < 0 do body_len = 0
				if body_len > job.max_body {
					_job_fail(job, .Body_Too_Large)
					return
				}
				if _job_body_complete(job) {
					_job_finish_success(job)
					return
				}
			}
			// Burst more PT if available.
			continue
		}

		ge := od.g_os.SSL_get_error(job.ssl, ret)
		if ge == od.SSL_ERROR_WANT_READ {
			if e := _job_tls_submit_recv(job); e != .None {
				_job_fail(job, e)
			}
			return
		}
		if ge == od.SSL_ERROR_WANT_WRITE {
			_ = _job_tls_on_want_write(job)
			return
		}
		if ge == od.SSL_ERROR_ZERO_RETURN {
			// clean close_notify
			if job.header_sep < 0 {
				_job_fail(job, .Closed)
				return
			}
			if job.content_length >= 0 && !_job_body_complete(job) {
				_job_fail(job, .Closed)
				return
			}
			_job_finish_success(job)
			return
		}
		// If we already have a complete CL body, tolerate SSL errors at end.
		if job.header_sep >= 0 && _job_body_complete(job) {
			_job_finish_success(job)
			return
		}
		_job_fail(job, .Closed)
		return
	}
}

@(private)
_job_tls_drive_h2_read :: proc(job: ^Client_Job) {
	pt: [4096]u8
	for {
		if job.done_fired || job.phase_cancel {
			return
		}
		// Flush any pending control frames encrypted earlier.
		if e := _job_tls_flush_wbio(job); e != .None {
			_job_fail(job, e)
			return
		}
		if job.ct_send_inflight {
			return
		}
		// Encrypt any H2 out (ACKs / WINDOW_UPDATE) queued from prior feed.
		if len(job.h2.out) > 0 {
			append(&job.app_tx, ..job.h2.out[:])
			clear(&job.h2.out)
		}
		if job.app_tx_off < len(job.app_tx) {
			// Need SSL_write before more read.
			job.tls_stage = .App_Write
			_job_tls_drive_app_write(job)
			return
		}
		clear(&job.app_tx)
		job.app_tx_off = 0

		// Already complete?
		if res, ok := h2_client_session_take_response(&job.h2, job.h2_sid, job.allocator); ok {
			if len(res.body) > job.max_body {
				response_destroy(&res, job.allocator)
				_job_fail(job, .Body_Too_Large)
				return
			}
			job.phase = .Done
			if job.fd >= 0 {
				net.close(net.TCP_Socket(job.fd))
				job.fd = -1
			}
			_job_fire_done(job, res, .None)
			return
		}
		if _, failed := h2_client_session_stream_failed(&job.h2, job.h2_sid); failed {
			_job_fail(job, .Closed)
			return
		}

		ret := od.g_os.SSL_read(job.ssl, raw_data(pt[:]), c.int(len(pt)))
		if ret > 0 {
			if h2_client_session_feed(&job.h2, pt[:int(ret)]) != .None {
				_job_fail(job, .Protocol)
				return
			}
			// Early body growth check.
			if s, ok := job.h2.h2.streams[job.h2_sid]; ok && len(s.body) > job.max_body {
				_job_fail(job, .Body_Too_Large)
				return
			}
			// Encrypt control replies then continue burst.
			if len(job.h2.out) > 0 {
				append(&job.app_tx, ..job.h2.out[:])
				clear(&job.h2.out)
				job.app_tx_off = 0
				job.tls_stage = .App_Write
				_job_tls_drive_app_write(job)
				return
			}
			continue
		}

		ge := od.g_os.SSL_get_error(job.ssl, ret)
		if ge == od.SSL_ERROR_WANT_READ {
			if e := _job_tls_submit_recv(job); e != .None {
				_job_fail(job, e)
			}
			return
		}
		if ge == od.SSL_ERROR_WANT_WRITE {
			_ = _job_tls_on_want_write(job)
			return
		}
		if ge == od.SSL_ERROR_ZERO_RETURN {
			if res, ok := h2_client_session_take_response(&job.h2, job.h2_sid, job.allocator); ok {
				if len(res.body) > job.max_body {
					response_destroy(&res, job.allocator)
					_job_fail(job, .Body_Too_Large)
					return
				}
				job.phase = .Done
				if job.fd >= 0 {
					net.close(net.TCP_Socket(job.fd))
					job.fd = -1
				}
				_job_fire_done(job, res, .None)
				return
			}
			_job_fail(job, .Closed)
			return
		}
		_job_fail(job, .Closed)
		return
	}
}

// Start https job on connected nonblocking fd. Takes ownership of fd.
// Caller pumps runtime until on_done. H3 not supported.
tls_request_start :: proc(
	rt: ^Client_Runtime,
	fd: i32,
	method, host, path: string,
	port: int,
	body: []u8,
	max_body: int,
	insecure: bool,
	want: ProtocolVersion,
	user: rawptr,
	on_done: proc(user: rawptr, res: Response, err: Http_Error),
	allocator: mem.Allocator,
) -> (^Client_Job, Http_Error) {
	if rt == nil || !rt.inited || rt.ring == nil {
		return nil, .Not_Configured
	}
	// v1: no request body on proactr TLS path (loud fail; match H3).
	if len(body) > 0 {
		return nil, .Unsupported_Version
	}
	if fd < 0 {
		return nil, .Connect_Failed
	}
	if want == .Http3 {
		return nil, .Unsupported_Version
	}

	job := job_alloc(rt)
	job.fd = fd
	job.max_body = max_body if max_body > 0 else DEFAULT_MAX_RESPONSE_BODY
	job.allocator = allocator
	job.result.headers.allocator = allocator
	job.result.body.allocator = allocator
	job.user = user
	job.on_done = on_done
	job.req_port = port

	alloc := rt.allocator
	job.req_method_owned = strings.clone(method if len(method) > 0 else "GET", alloc)
	job.req_path_owned = strings.clone(path if len(path) > 0 else "/", alloc)

	if e := _job_tls_setup(job, host, insecure, want); e != .None {
		job.on_done = nil
		// SSL may be nil; free owned strings via free_transport path.
		job_free_transport(job)
		job_free(rt, job)
		return nil, e
	}

	// Kick handshake (ClientHello → wBIO → send).
	_job_tls_drive(job)
	if job.done_fired {
		// Immediate failure already notified.
		return job, .None
	}
	// Must have at least one op or done; if neither, fail.
	if job.ops_outstanding == 0 && !job.done_fired {
		// Drive stalled without I/O — treat as TLS failure.
		_job_fail(job, .Tls_Failed)
	}
	return job, .None
}

// Blocking https GET over thread-local runtime pump.
tls_request_blocking :: proc(
	rt: ^Client_Runtime,
	fd: i32,
	method, host, path: string,
	port: int,
	body: []u8,
	max_body: int,
	insecure: bool,
	want: ProtocolVersion,
	timeout_ms: int,
	allocator: mem.Allocator,
) -> (Response, Http_Error) {
	if rt == nil || !rt.inited || rt.ring == nil {
		return {}, .Not_Configured
	}
	if fd < 0 {
		return {}, .Connect_Failed
	}

	Wait :: struct {
		done: bool,
		res:  Response,
		err:  Http_Error,
	}
	wait: Wait

	job, err := tls_request_start(
		rt,
		fd,
		method,
		host,
		path,
		port,
		body,
		max_body,
		insecure,
		want,
		rawptr(&wait),
		proc(user: rawptr, res: Response, err: Http_Error) {
			w := (^Wait)(user)
			w.res = res
			w.err = err
			w.done = true
		},
		allocator,
	)
	if err != .None {
		return {}, err
	}
	_ = job

	perr := runtime_pump_until(rt, &wait.done, timeout_ms)
	if !wait.done {
		if job != nil && job.live && !job.done_fired {
			job_cancel(job, false)
		}
		_ = runtime_drain(rt, 32, 0)
		if wait.err == .None {
			wait.err = perr if perr != .None else .Timeout
		}
	}
	return wait.res, wait.err
}
