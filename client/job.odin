package client

import "core:mem"
import "core:net"
import "core:time"

import http "../http"
import "../http3"
import proactr "../proactr"
import "../quic"

// Host demux: user pointer is tagged with CLIENT_USER_TAG (low bit).
// Connection* is always 8-byte aligned (LSB=0); client jobs use |1 so demux
// never deep-loads a Connection as Client_Job (no false-positive crash).
CLIENT_JOB_MAGIC :: u32(0xC1A37A0B)
CLIENT_USER_TAG  :: uintptr(1)

@(private)
_job_user :: #force_inline proc(job: ^Client_Job) -> rawptr {
	return rawptr(uintptr(job) | CLIENT_USER_TAG)
}

@(private)
_job_from_user :: #force_inline proc(user: rawptr) -> (^Client_Job, bool) {
	u := uintptr(user)
	if u & CLIENT_USER_TAG == 0 {
		return nil, false
	}
	return (^Client_Job)(u & ~CLIENT_USER_TAG), true
}

Client_Job_Phase :: enum u8 {
	Idle,
	Sending,
	Recving,
	Tls_Handshake,
	H3_Drive,
	Done,
	Cancelled,
}

// TLS application stage after handshake (H1/H2 over PT).
Client_Job_Tls_Stage :: enum u8 {
	None,
	Handshake,
	App_Write, // SSL_write request / H2 frames
	App_Read,  // SSL_read response
}

// H3 drive stage after dial residual (settings exchange → response).
Client_Job_H3_Stage :: enum u8 {
	None,
	Wait_Settings, // peer SETTINGS not yet received
	Wait_Response, // headers sent; awaiting take_response
}

// Client_Job is one outbound exchange on a Client_Runtime.
// Free only when ops==0 and not inside on_done (free_pending defers free across the callback).
Client_Job :: struct {
	magic:           u32, // CLIENT_JOB_MAGIC while live; 0 after free
	live:            bool, // false after job_free; cancel/on_cqe no-op
	in_callback:     bool, // true while on_done runs (blocks free)
	free_pending:    bool, // harvest wanted free during in_callback
	runtime:         ^Client_Runtime,
	phase:           Client_Job_Phase,
	ops_outstanding: int,
	done_fired:      bool,
	phase_cancel:    bool,
	exchange_gone:   bool,
	// Exchange bind (handler path / get_async)
	slot:            ^http.Stream_Slot,
	exchange_epoch:  u32,
	slot_next:       ^Client_Job, // intrusive list head = slot.client_jobs
	fd:              i32, // -1 if none
	result:          Response,
	err:             Http_Error,
	on_done:         proc(user: rawptr, res: Response, err: Http_Error),
	user:            rawptr,
	tx:              [dynamic]u8, // clear wire or TLS ciphertext (owned until Send CQE)
	rx:              [dynamic]u8, // clear wire or H1 plaintext after decrypt
	recv_buf:        []u8, // always allocated with runtime.allocator (CT or clear)
	tx_off:          int,
	max_body:        int,
	header_sep:      int, // -1 until headers complete
	content_length:  int, // -1 = until close; >=0 = fixed
	// Result ownership only (headers/body clones). Wire buffers use runtime.allocator.
	allocator:       mem.Allocator,
	// ---- TLS mem-BIO (use_tls) ----
	use_tls:           bool,
	ssl:               rawptr, // OpenSSL SSL*; BIOs owned via SSL_set_bio
	insecure:          bool,
	host_owned:        string, // SNI / Host; free in free_transport
	req_method_owned:  string,
	req_path_owned:    string,
	req_port:          int,
	want_version:      ProtocolVersion,
	negotiated:        ProtocolVersion,
	tls_stage:         Client_Job_Tls_Stage,
	ct_send_inflight:  bool,
	ct_recv_inflight:  bool,
	app_tx:            [dynamic]u8, // plaintext pending SSL_write
	app_tx_off:        int,
	h2:                H2_Session,
	h2_started:        bool,
	h2_sid:            u32,
	// ---- HTTP/3 / QUIC
	// Dial residual may sleep in quic.conn_connect; post-connect drive has no sleep.
	use_h3:              bool,
	quic:                ^quic.Conn,
	h3_sess:             H3_Session,
	h3_stream:           http3.Http3_Stream,
	h3_inited:           bool,
	h3_headers_sent:     bool, // stream id 0 is valid — do not use stream alone
	h3_stage:            Client_Job_H3_Stage,
	udp_recv_inflight:   bool,
	timer_id:            u32,
	timer_pending:       bool,
	h3_deadline:         time.Time,
}

job_alloc :: proc(rt: ^Client_Runtime) -> ^Client_Job {
	job: ^Client_Job
	if len(rt.job_free) > 0 {
		job = pop(&rt.job_free)
		// Keep tx/rx/recv_buf/app_tx capacity; reset scalars.
		clear(&job.tx)
		clear(&job.rx)
		clear(&job.app_tx)
		job.magic = CLIENT_JOB_MAGIC
		job.runtime = rt
		job.allocator = rt.allocator
		job.fd = -1
		job.header_sep = -1
		job.content_length = -1
		job.phase = .Idle
		job.ops_outstanding = 0
		job.done_fired = false
		job.phase_cancel = false
		job.exchange_gone = false
		job.in_callback = false
		job.free_pending = false
		job.slot = nil
		job.exchange_epoch = 0
		job.slot_next = nil
		job.tx_off = 0
		job.err = .None
		job.on_done = nil
		job.user = nil
		job.result = {}
		job.result.headers.allocator = rt.allocator
		job.result.body.allocator = rt.allocator
		_job_reset_tls(job)
		_job_reset_h3(job)
		job.live = true
		return job
	}
	job = new(Client_Job, rt.allocator)
	job^ = {}
	job.magic = CLIENT_JOB_MAGIC
	job.live = true
	job.runtime = rt
	job.allocator = rt.allocator
	job.fd = -1
	job.header_sep = -1
	job.content_length = -1
	job.phase = .Idle
	job.tx.allocator = rt.allocator
	job.rx.allocator = rt.allocator
	job.app_tx.allocator = rt.allocator
	job.result.headers.allocator = rt.allocator
	job.result.body.allocator = rt.allocator
	_job_reset_tls(job)
	_job_reset_h3(job)
	return job
}

// job_free returns the shell to the free-list. Idempotent if !live.
job_free :: proc(rt: ^Client_Runtime, job: ^Client_Job) {
	if job == nil || !job.live do return
	assert(job.ops_outstanding == 0, "job_free with ops outstanding")
	job_unlink_slot(job)
	job.live = false
	job.magic = 0
	job.in_callback = false
	job.free_pending = false
	// Retain buffer capacity for reuse.
	clear(&job.tx)
	clear(&job.rx)
	// Keep recv_buf slice for next use (runtime.allocator-owned).
	job.on_done = nil
	job.user = nil
	job.runtime = rt
	append(&rt.job_free, job)
}

// Close job.fd with the correct socket type (TCP clear/TLS vs UDP H3).
@(private)
_job_close_fd :: proc(job: ^Client_Job) {
	if job == nil || job.fd < 0 do return
	if job.use_h3 || job.quic != nil {
		net.close(net.UDP_Socket(job.fd))
		if job.quic != nil {
			job.quic.socket_owned = false
		}
	} else {
		net.close(net.TCP_Socket(job.fd))
	}
	job.fd = -1
}

// job_free_transport clears result ownership, TLS/H3, and closes fd.
// Only call when ops_outstanding == 0 and not mid-callback (use _job_try_free).
// Free SSL/BIOs and QUIC/H3 only here (ops==0 law §5.7 / §5.14).
job_free_transport :: proc(job: ^Client_Job) {
	if job == nil do return
	response_destroy(&job.result, job.allocator)
	job.result = {}
	_job_tls_free(job)
	_job_h3_free(job)
	_job_close_fd(job)
	job.tx_off = 0
	job.header_sep = -1
	job.content_length = -1
	clear(&job.app_tx)
	job.app_tx_off = 0
}

// Free when quiet and not inside on_done. Safe after callback re-entry (ABA).
@(private)
_job_try_free :: proc(job: ^Client_Job) {
	if job == nil || !job.live do return
	if job.ops_outstanding != 0 do return
	if job.in_callback {
		job.free_pending = true
		return
	}
	rt := job.runtime
	job_free_transport(job)
	if rt != nil {
		job_free(rt, job)
	}
}

// Fire on_done once; free after callback if quiet (or honor free_pending).
@(private)
_job_fire_done :: proc(job: ^Client_Job, res: Response, err: Http_Error) {
	if job.done_fired do return
	job.done_fired = true
	job.err = err
	cb := job.on_done
	user := job.user
	job.in_callback = true
	if cb != nil {
		cb(user, res, err)
	} else {
		owned := res
		response_destroy(&owned, job.allocator)
	}
	job.in_callback = false
	if job.free_pending || job.ops_outstanding == 0 {
		job.free_pending = false
		_job_try_free(job)
	}
}

// job_cancel — sync terminal on_done on first cancel.
// Unlinks from slot list before on_done (destroy never walks unlinked jobs).
job_cancel :: proc(job: ^Client_Job, exchange_gone := false) {
	if job == nil || !job.live do return
	if job.done_fired do return
	if job.phase_cancel do return

	job.phase_cancel = true
	job.exchange_gone = exchange_gone
	job.phase = .Cancelled
	job_unlink_slot(job)

	rt := job.runtime
	// H3: cancel software timer first (CQE still harvested; never free Submitted).
	if job.use_h3 && job.timer_pending && rt != nil && rt.ring != nil {
		_ = proactr.cancel_timeout(rt.ring, job.timer_id)
		job.timer_pending = false
	}

	if job.fd >= 0 {
		if rt != nil && rt.ring != nil {
			id, err := proactr.submit_close(rt.ring, job.fd, _job_user(job))
			if err == .None {
				job.ops_outstanding += 1
				rt.pending_ops += 1
				// QUIC owns the same fd — mark closed so free_transport does not double-close.
				if job.quic != nil {
					job.quic.socket_owned = false
				}
				job.fd = -1
				_ = id
			} else {
				_job_close_fd(job)
			}
		} else {
			_job_close_fd(job)
		}
	}

	err: Http_Error = .Exchange_Gone if job.exchange_gone else .Closed
	_job_fire_done(job, {}, err)
}

// job_on_cqe — op already complete_apply'd; free when not Submitted.
// Pass op from pump (user demux). Never free Submitted.
job_on_cqe :: proc(job: ^Client_Job, c: proactr.Completion, op: ^proactr.Operation) {
	if job == nil || !job.live || job.runtime == nil || job.runtime.ring == nil {
		return
	}
	rt := job.runtime
	ring := rt.ring

	kind := proactr.Operation_Kind.Nop
	result: i32 = c.result
	if op != nil {
		kind = op.kind
		result = op.result
		if op.status != .Submitted {
			proactr.operation_free(ring, c.op_id)
		}
	}

	if job.ops_outstanding <= 0 {
		// Extra CQE after accounting error — do not drive SM or free again.
		return
	}
	job.ops_outstanding -= 1
	if rt.pending_ops > 0 {
		rt.pending_ops -= 1
	}

	// Terminal path: cancel, close, or fail/success that left ops in flight.
	// Never re-enter send/recv after done_fired.
	if job.done_fired || job.phase_cancel || job.phase == .Done || job.phase == .Cancelled {
		if job.ops_outstanding == 0 {
			_job_try_free(job)
		}
		return
	}

	if kind == .Close {
		// Unexpected close while still active — treat as failure.
		_job_fail(job, .Closed)
		return
	}

	// TLS mem-BIO path: CT send/recv → drive SM (clear H1 unchanged below).
	if job.use_tls {
		#partial switch kind {
		case .Send:
			_job_tls_on_send(job, result)
		case .Recv:
			_job_tls_on_recv(job, result)
		case:
			_job_fail(job, .Closed)
		}
		return
	}

	// H3/QUIC: UDP Recv + software Timeout (PTO / request deadline). No Send op —
	// pump_quic_send is nonblocking on the CQE path.
	if job.use_h3 {
		#partial switch kind {
		case .Recv:
			_job_h3_on_recv(job, result)
		case .Timeout:
			_job_h3_on_timeout(job, result)
		case:
			_job_fail(job, .Closed)
		}
		return
	}

	#partial switch job.phase {
	case .Sending:
		_job_on_send(job, result)
	case .Recving:
		_job_on_recv(job, result)
	case:
		_job_fail(job, .Closed)
	}
}

@(private)
_job_submit_send :: proc(job: ^Client_Job) -> Http_Error {
	rt := job.runtime
	if rt == nil || rt.ring == nil || job.fd < 0 {
		return .Closed
	}
	if job.tx_off >= len(job.tx) {
		return .None
	}
	buf := job.tx[job.tx_off:]
	id, err := proactr.submit_send(rt.ring, job.fd, buf, _job_user(job))
	if err != .None {
		return .Closed
	}
	job.ops_outstanding += 1
	rt.pending_ops += 1
	_ = id
	return .None
}

@(private)
_job_submit_recv :: proc(job: ^Client_Job) -> Http_Error {
	rt := job.runtime
	if rt == nil || rt.ring == nil || job.fd < 0 {
		return .Closed
	}
	// Always runtime.allocator so free-list / runtime_destroy match.
	if job.recv_buf == nil {
		job.recv_buf = make([]u8, 4096, rt.allocator)
	}
	id, err := proactr.submit_recv(rt.ring, job.fd, job.recv_buf, _job_user(job))
	if err != .None {
		return .Closed
	}
	job.ops_outstanding += 1
	rt.pending_ops += 1
	_ = id
	return .None
}

@(private)
_job_on_send :: proc(job: ^Client_Job, result: i32) {
	if result < 0 {
		_job_fail(job, .Closed)
		return
	}
	job.tx_off += int(result)
	if job.tx_off < len(job.tx) {
		if e := _job_submit_send(job); e != .None {
			_job_fail(job, e)
		}
		return
	}
	job.phase = .Recving
	if e := _job_submit_recv(job); e != .None {
		_job_fail(job, e)
	}
}

@(private)
_job_on_recv :: proc(job: ^Client_Job, result: i32) {
	if result < 0 {
		if job.header_sep >= 0 && _job_body_complete(job) {
			_job_finish_success(job)
			return
		}
		_job_fail(job, .Closed)
		return
	}
	if result == 0 {
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

	n := int(result)
	if n > len(job.recv_buf) {
		n = len(job.recv_buf)
	}
	// Search only near the join for header end (O(chunk) not O(total)).
	prev_len := len(job.rx)
	append(&job.rx, ..job.recv_buf[:n])

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

	if e := _job_submit_recv(job); e != .None {
		_job_fail(job, e)
	}
}

@(private)
_job_body_complete :: proc(job: ^Client_Job) -> bool {
	if job.header_sep < 0 do return false
	body_start := job.header_sep + 4
	have := len(job.rx) - body_start
	if have < 0 do return false
	if job.content_length < 0 {
		return false
	}
	return have >= job.content_length
}

@(private)
_job_fail :: proc(job: ^Client_Job, err: Http_Error) {
	if !job.live || job.done_fired || job.phase_cancel {
		return
	}
	job.phase = .Done
	// Cancel H3 timer (CQE still harvested).
	if job.use_h3 && job.timer_pending {
		rt := job.runtime
		if rt != nil && rt.ring != nil {
			_ = proactr.cancel_timeout(rt.ring, job.timer_id)
		}
		job.timer_pending = false
	}
	// Drop fd so in-flight ops complete with error; harvest frees when ops hit 0.
	_job_close_fd(job)
	_job_fire_done(job, {}, err)
}

@(private)
_job_finish_success :: proc(job: ^Client_Job) {
	if !job.live || job.done_fired || job.phase_cancel {
		return
	}
	if e := _job_materialize_body(job); e != .None {
		_job_fail(job, e)
		return
	}
	job.phase = .Done
	res := job.result
	job.result = {}
	if job.use_h3 && job.timer_pending {
		rt := job.runtime
		if rt != nil && rt.ring != nil {
			_ = proactr.cancel_timeout(rt.ring, job.timer_id)
		}
		job.timer_pending = false
	}
	_job_close_fd(job)
	_job_fire_done(job, res, .None)
}
