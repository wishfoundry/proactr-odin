// HTTP/3 on Client_Job via proactr completions + software timers (design §5.14 / PR4).
//
// Residual (documented): dial may call quic.conn_connect, which still sleep-polls
// during the QUIC handshake. After connect, drive uses only:
//   - nonblocking http3.pump_quic_send
//   - proactr.submit_recv on the connected UDP fd
//   - proactr.submit_timeout for request deadline / PTO
// No time.sleep on this path.
//
// Free law: free H3_Session + quic.conn only when ops_outstanding == 0
// (job_free_transport). Cancel Option B: cancel timer, close UDP, free when quiet.
package client

import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

import "../http3"
import proactr "../proactr"
import "../quic"

// UDP datagram max for recv_buf (QUIC max_udp_payload_size is typically ≤1472).
@(private)
_H3_RECV_BUF :: 2048

// Cap nonblocking SETTINGS drain after dial residual (no sleep).
@(private)
_H3_SETTINGS_SPIN :: 32

@(private)
_job_reset_h3 :: proc(job: ^Client_Job) {
	job.use_h3 = false
	job.quic = nil
	job.h3_sess = {}
	job.h3_stream = http3.Http3_Stream(0)
	job.h3_inited = false
	job.h3_headers_sent = false
	job.h3_stage = .None
	job.udp_recv_inflight = false
	job.timer_id = 0
	job.timer_pending = false
	job.h3_deadline = {}
}

// Free H3 session + QUIC conn. Caller must ensure ops_outstanding == 0.
// Does not free host/method/path if still owned by TLS path; H3 uses the same
// host_owned / req_*_owned strings and clears them here when use_h3.
@(private)
_job_h3_free :: proc(job: ^Client_Job) {
	if job == nil do return
	if !job.use_h3 && job.quic == nil && !job.h3_inited {
		return
	}
	assert(job.ops_outstanding == 0 || !job.use_h3, "H3 free with ops outstanding")
	if job.h3_inited {
		h3_client_session_destroy(&job.h3_sess)
		job.h3_inited = false
	}
	if job.quic != nil {
		if job.fd >= 0 {
			quic.conn_udp_close(job.quic)
			job.fd = -1
		} else {
			// Already closed (cancel / fail / success path).
			job.quic.socket_owned = false
		}
		quic.conn_free(job.quic)
		job.quic = nil
	}
	// Owned request strings (shared field names with TLS path).
	alloc := job.runtime.allocator if job.runtime != nil else job.allocator
	if len(job.host_owned) > 0 {
		delete(job.host_owned, alloc)
		job.host_owned = ""
	}
	if len(job.req_method_owned) > 0 {
		delete(job.req_method_owned, alloc)
		job.req_method_owned = ""
	}
	if len(job.req_path_owned) > 0 {
		delete(job.req_path_owned, alloc)
		job.req_path_owned = ""
	}
	job.use_h3 = false
	job.h3_headers_sent = false
	job.h3_stage = .None
	job.udp_recv_inflight = false
	job.timer_pending = false
	job.timer_id = 0
	job.h3_stream = http3.Http3_Stream(0)
	job.insecure = false
	job.req_port = 0
	job.h3_deadline = {}
}

// Nonblocking QUIC flush. Prefer udp_send_raw so connected sockets use send()
// (http3.pump_quic_send always uses sendto + remote, which can fail after
// conn_udp_connect on some platforms).
@(private)
_job_h3_pump_send :: proc(conn: ^quic.Conn) {
	if conn == nil do return
	emit :: proc(packet: []u8, user: rawptr) {
		c := (^quic.Conn)(user)
		_ = quic.udp_send_raw(c, packet)
	}
	quic.conn_poll_send(conn, emit, conn)
}

// Dial residual: conn_connect (may sleep) + conn_udp_connect + session init.
// Returns connected job.quic with nonblocking UDP; peer SETTINGS may still be pending.
@(private)
_job_h3_dial_residual :: proc(
	job: ^Client_Job,
	host: string,
	port: int,
	insecure: bool,
	dial_timeout_ms: int,
) -> Http_Error {
	p := port
	if p == 0 do p = 443
	endpoint := format_dial_endpoint(host, p)

	alpn := [3]u8{2, 'h', '3'}
	conn, cerr := quic.conn_new(host, alpn[:], _h3_transport_params())
	if cerr != .None {
		return .Tls_Failed
	}
	if insecure do quic.conn_disable_verify(conn)

	// Residual: conn_connect still sleep-polls the handshake (documented).
	dial_to := time.Duration(_resolve_dial_timeout_ms(dial_timeout_ms)) * time.Millisecond
	#partial switch quic.conn_connect(conn, endpoint, dial_to) {
	case .None:
	case .Timeout:
		quic.conn_udp_close(conn)
		quic.conn_free(conn)
		return .Timeout
	case .Resolve_Failed:
		quic.conn_udp_close(conn)
		quic.conn_free(conn)
		return .Resolve_Failed
	case:
		quic.conn_udp_close(conn)
		quic.conn_free(conn)
		return .Connect_Failed
	}

	// Connected UDP so kqueue/proactr recv only wakes on peer datagrams.
	if !quic.conn_udp_connect(conn) {
		quic.conn_udp_close(conn)
		quic.conn_free(conn)
		return .Connect_Failed
	}
	_ = net.set_blocking(conn.socket, false)

	if h3_client_session_init(&job.h3_sess, conn, http3.DEFAULT_SETTINGS, job.runtime.allocator) !=
	   .None {
		quic.conn_udp_close(conn)
		quic.conn_free(conn)
		return .Protocol
	}
	job.h3_inited = true
	job.quic = conn
	job.fd = i32(conn.socket)
	job.use_h3 = true

	// Flush local SETTINGS; nonblocking peer SETTINGS drain (no sleep).
	_job_h3_pump_send(conn)
	for _ in 0 ..< _H3_SETTINGS_SPIN {
		n_recv := http3.pump_quic_recv(conn)
		_ = h3_client_session_process(&job.h3_sess)
		if h3_client_session_peer_settings_ready(&job.h3_sess) {
			_job_h3_pump_send(conn)
			return .None
		}
		_job_h3_pump_send(conn)
		if n_recv == 0 do break
	}
	return .None
}

@(private)
_job_h3_send_request_headers :: proc(job: ^Client_Job) -> Http_Error {
	if job.h3_headers_sent do return .None
	if !h3_client_session_peer_settings_ready(&job.h3_sess) {
		return .None // still waiting
	}

	method := job.req_method_owned if len(job.req_method_owned) > 0 else "GET"
	path := job.req_path_owned if len(job.req_path_owned) > 0 else "/"
	host := job.host_owned
	port := job.req_port
	authority := format_authority("https", host, port)

	headers: [dynamic]Header
	headers.allocator = context.temp_allocator
	append(&headers, Header{name = ":method", value = method})
	append(&headers, Header{name = ":scheme", value = "https"})
	append(&headers, Header{name = ":authority", value = authority})
	append(&headers, Header{name = ":path", value = path})
	// Match legacy _h3_do defaults.
	append(&headers, Header{name = "user-agent", value = DEFAULT_USER_AGENT})

	rs, e := h3_client_session_send_headers(&job.h3_sess, headers[:], nil)
	if e != .None {
		return .Protocol
	}
	job.h3_stream = rs
	job.h3_headers_sent = true
	job.h3_stage = .Wait_Response
	_job_h3_pump_send(job.quic)
	return .None
}

// Arm one UDP recv if not already in flight.
@(private)
_job_h3_arm_recv :: proc(job: ^Client_Job) -> Http_Error {
	if job.udp_recv_inflight do return .None
	if job.done_fired || job.phase_cancel do return .None
	rt := job.runtime
	if rt == nil || rt.ring == nil || job.fd < 0 {
		return .Closed
	}
	if job.recv_buf == nil || len(job.recv_buf) < _H3_RECV_BUF {
		if job.recv_buf != nil {
			delete(job.recv_buf, rt.allocator)
		}
		job.recv_buf = make([]u8, _H3_RECV_BUF, rt.allocator)
	}
	id, err := proactr.submit_recv(rt.ring, job.fd, job.recv_buf, _job_user(job))
	if err != .None {
		return .Closed
	}
	job.ops_outstanding += 1
	rt.pending_ops += 1
	job.udp_recv_inflight = true
	job.phase = .H3_Drive
	_ = id
	return .None
}

// Arm software timer for min(remaining deadline, PTO). One timer at a time.
@(private)
_job_h3_arm_timer :: proc(job: ^Client_Job) -> Http_Error {
	if job.timer_pending do return .None
	if job.done_fired || job.phase_cancel do return .None
	rt := job.runtime
	if rt == nil || rt.ring == nil {
		return .Closed
	}

	now := time.now()
	remain := time.diff(now, job.h3_deadline)
	if remain <= 0 {
		return .Timeout
	}

	// PTO from congestion control (pre-sample falls back to 2·INITIAL_RTT).
	pto := quic.pto_duration(&job.quic.cc, 0)
	if pto <= 0 {
		pto = 250 * time.Millisecond
	}
	// Cap wait to remaining request budget.
	wait := remain if remain < pto else pto
	// Floor 1ms so we never submit a zero-duration busy timer.
	if wait < time.Millisecond {
		wait = time.Millisecond
	}

	id, err := proactr.submit_timeout(rt.ring, i64(wait), _job_user(job))
	if err != .None {
		return .Closed
	}
	job.ops_outstanding += 1
	rt.pending_ops += 1
	job.timer_id = id
	job.timer_pending = true
	job.phase = .H3_Drive
	return .None
}

// After process/send: check body limit / take_response; rearm ops if still waiting.
@(private)
_job_h3_progress :: proc(job: ^Client_Job) {
	if job == nil || !job.live || job.done_fired || job.phase_cancel {
		return
	}
	if job.quic == nil || !job.h3_inited {
		_job_fail(job, .Protocol)
		return
	}

	// Always process + flush after any input or timer tick.
	_ = h3_client_session_process(&job.h3_sess)
	_job_h3_pump_send(job.quic)

	// SETTINGS → send headers once.
	if !job.h3_headers_sent {
		if e := _job_h3_send_request_headers(job); e != .None {
			_job_fail(job, e)
			return
		}
		if !job.h3_headers_sent {
			job.h3_stage = .Wait_Settings
		}
	}

	// Response complete?
	if job.h3_headers_sent {
		_, body, done := h3_client_session_response(&job.h3_sess, job.h3_stream)
		if len(body) > job.max_body {
			_job_fail(job, .Body_Too_Large)
			return
		}
		if done {
			res, ok := h3_client_session_take_response(
				&job.h3_sess,
				job.h3_stream,
				job.allocator,
			)
			_job_h3_pump_send(job.quic)
			if !ok {
				_job_fail(job, .Protocol)
				return
			}
			if len(res.body) > job.max_body {
				response_destroy(&res, job.allocator)
				_job_fail(job, .Body_Too_Large)
				return
			}
			// Terminal success: cancel timer, close UDP, fire on_done.
			job.phase = .Done
			if job.timer_pending {
				rt := job.runtime
				if rt != nil && rt.ring != nil {
					_ = proactr.cancel_timeout(rt.ring, job.timer_id)
				}
				job.timer_pending = false
			}
			_job_close_fd(job)
			_job_fire_done(job, res, .None)
			return
		}
	}

	// Work-conserving: if stream data still owed, pump again (no sleep).
	if quic.conn_has_unsent_stream_data(job.quic) {
		_job_h3_pump_send(job.quic)
	}

	if e := _job_h3_arm_recv(job); e != .None {
		_job_fail(job, e)
		return
	}
	if e := _job_h3_arm_timer(job); e != .None {
		if e == .Timeout {
			_job_fail(job, .Timeout)
		} else {
			_job_fail(job, e)
		}
		return
	}
}

@(private)
_job_h3_on_recv :: proc(job: ^Client_Job, result: i32) {
	job.udp_recv_inflight = false
	if job.done_fired || job.phase_cancel {
		return
	}
	if result < 0 {
		_job_fail(job, .Closed)
		return
	}
	if result == 0 {
		// Connected UDP rarely returns 0; treat as peer silence / error.
		_job_fail(job, .Closed)
		return
	}
	if job.quic == nil {
		_job_fail(job, .Closed)
		return
	}
	n := int(result)
	if n > len(job.recv_buf) {
		n = len(job.recv_buf)
	}
	_ = quic.conn_on_udp_recv(job.quic, job.recv_buf[:n])
	// Drain any further datagrams already queued (nonblocking).
	_ = http3.pump_quic_recv(job.quic)
	_job_h3_progress(job)
}

@(private)
_job_h3_on_timeout :: proc(job: ^Client_Job, result: i32) {
	job.timer_pending = false
	if job.done_fired || job.phase_cancel {
		return
	}
	// cancel_timeout posts TIMEOUT_CANCELED — accounting only.
	if result == proactr.TIMEOUT_CANCELED {
		return
	}
	// Wall deadline?
	if time.diff(time.now(), job.h3_deadline) <= 0 {
		_job_fail(job, .Timeout)
		return
	}
	// PTO tick: retransmit + flush.
	if job.quic != nil {
		_ = quic.conn_pto_check(job.quic)
		_job_h3_pump_send(job.quic)
	}
	_job_h3_progress(job)
}

// Start H3 GET (or method) on a fresh QUIC dial. Takes ownership of the UDP fd.
// Caller pumps runtime until on_done. Dial residual may sleep; drive does not.
// timeout_ms: request pump budget (0 → DEFAULT_REQUEST_TIMEOUT_MS).
// dial_timeout_ms: optional dial residual budget (0 → _resolve_dial_timeout_ms(timeout_ms)).
// prefer_h3 probes pass a short dial_timeout_ms so fallback is not a multi-10s sleep tax.
h3_request_start :: proc(
	rt: ^Client_Runtime,
	method, host, path: string,
	port: int,
	body: []u8,
	max_body: int,
	insecure: bool,
	timeout_ms: int,
	user: rawptr,
	on_done: proc(user: rawptr, res: Response, err: Http_Error),
	allocator: mem.Allocator,
	dial_timeout_ms: int = 0,
) -> (^Client_Job, Http_Error) {
	if rt == nil || !rt.inited || rt.ring == nil {
		return nil, .Not_Configured
	}
	// v1: no request body on proactr H3 path (same as TLS GET-only residual).
	if len(body) > 0 {
		return nil, .Unsupported_Version
	}

	job := job_alloc(rt)
	job.max_body = max_body if max_body > 0 else DEFAULT_MAX_RESPONSE_BODY
	job.allocator = allocator
	job.result.headers.allocator = allocator
	job.result.body.allocator = allocator
	job.user = user
	job.on_done = on_done
	job.req_port = port if port != 0 else 443
	job.insecure = insecure
	job.use_h3 = true
	job.phase = .H3_Drive
	job.h3_stage = .Wait_Settings
	job.h3_deadline = time.time_add(
		time.now(),
		time.Duration(_resolve_request_timeout_ms(timeout_ms)) * time.Millisecond,
	)

	alloc := rt.allocator
	job.host_owned = strings.clone(host, alloc)
	job.req_method_owned = strings.clone(method if len(method) > 0 else "GET", alloc)
	job.req_path_owned = strings.clone(path if len(path) > 0 else "/", alloc)

	dial_to := dial_timeout_ms
	if dial_to <= 0 {
		dial_to = _resolve_dial_timeout_ms(timeout_ms)
	}
	if e := _job_h3_dial_residual(job, host, job.req_port, insecure, dial_to); e != .None {
		job.on_done = nil
		// Dial failed before any proactr ops — free shell immediately.
		job.use_h3 = true // ensure _job_h3_free cleans partial state
		job_free_transport(job)
		job_free(rt, job)
		return nil, e
	}

	// Extend deadline after dial residual so request budget is post-handshake.
	job.h3_deadline = time.time_add(
		time.now(),
		time.Duration(_resolve_request_timeout_ms(timeout_ms)) * time.Millisecond,
	)

	// Try to send headers immediately if SETTINGS already ready.
	if e := _job_h3_send_request_headers(job); e != .None {
		job.on_done = nil
		job_free_transport(job)
		job_free(rt, job)
		return nil, e
	}

	// Kick drive: may complete synchronously if response already buffered
	// (unlikely); otherwise arms recv + timer.
	_job_h3_progress(job)
	if job.done_fired {
		return job, .None
	}
	if job.ops_outstanding == 0 && !job.done_fired {
		_job_fail(job, .Protocol)
	}
	return job, .None
}

// Blocking H3 GET over thread-local / explicit runtime pump.
h3_request_blocking :: proc(
	rt: ^Client_Runtime,
	method, host, path: string,
	port: int,
	body: []u8,
	max_body: int,
	insecure: bool,
	timeout_ms: int,
	allocator: mem.Allocator,
) -> (Response, Http_Error) {
	if rt == nil || !rt.inited || rt.ring == nil {
		return {}, .Not_Configured
	}

	Wait :: struct {
		done: bool,
		res:  Response,
		err:  Http_Error,
	}
	wait: Wait

	job, err := h3_request_start(
		rt,
		method,
		host,
		path,
		port,
		body,
		max_body,
		insecure,
		timeout_ms,
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

	budget := _resolve_request_timeout_ms(timeout_ms)
	// Include dial residual time already spent: pump budget is request-side.
	perr := runtime_pump_until(rt, &wait.done, budget)
	if !wait.done {
		if job.live && !job.done_fired {
			job_cancel(job, false)
		}
		if wait.err == .None {
			wait.err = perr if perr != .None else .Timeout
		}
	}
	// Harvest timer-cancel / post-close recv CQEs so free_transport runs (ops==0 law).
	// Prefer nonblocking peeks first; short wait only if still noisy.
	_ = runtime_drain(rt, 32, 0)
	if job != nil && job.live {
		_ = runtime_drain(rt, 16, 2)
	}
	return wait.res, wait.err
}
