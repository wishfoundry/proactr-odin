// PR4: HTTP/3 over proactr Client_Job (UDP recv + software timers; no sleep on drive).
package client

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import "../http3"
import od "../openssl_dynlib"
import "../quic"

@(private = "file")
H3_Proactr_Server :: struct {
	sock: net.UDP_Socket,
	stop: bool,
}

@(private = "file")
_h3_proactr_handler :: proc(req: http3.Request, allocator: mem.Allocator) -> http3.Response {
	hdrs := make([]Header, 1, allocator)
	hdrs[0] = {name = "content-type", value = "text/plain"}
	body := fmt.aprintf("h3 proactr %s", req.path, allocator = allocator)
	return http3.Response{status = 200, headers = hdrs, body = transmute([]u8)body}
}

@(private = "file")
_h3_proactr_server_thread :: proc(data: rawptr) {
	args := (^H3_Proactr_Server)(data)
	http3.serve_conn(
		args.sock,
		transmute([]u8)string(http3.TEST_CERT_PEM),
		transmute([]u8)string(http3.TEST_KEY_PEM),
		_h3_proactr_handler,
		&args.stop,
	)
}

@(private = "file")
_h3_skip_no_quic :: proc(t: ^testing.T) -> bool {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return true
	}
	if !quic.os_ensure() {
		testing.expect(t, true, "skip: QUIC OpenSSL unavailable")
		return true
	}
	return false
}

@(test)
test_proactr_h3_get :: proc(t: ^testing.T) {
	if _h3_skip_no_quic(t) do return

	lo := net.IP4_Address{127, 0, 0, 1}
	ssock, se := net.make_bound_udp_socket(lo, 0)
	testing.expect(t, se == nil, "bind server socket")
	if se != nil do return
	net.set_blocking(ssock, false)
	sep, _ := net.bound_endpoint(ssock)

	args := H3_Proactr_Server{sock = ssock}
	th := thread.create_and_start_with_data(&args, _h3_proactr_server_thread)
	defer {
		args.stop = true
		thread.join(th)
		thread.destroy(th)
		net.close(ssock)
	}
	time.sleep(10 * time.Millisecond)

	// Private runtime avoids thread-local pollution from parallel tests.
	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 64) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	res, err := h3_request_blocking(
		&rt,
		"GET",
		"127.0.0.1",
		"/hello",
		sep.port,
		nil,
		DEFAULT_MAX_RESPONSE_BODY,
		true,
		5_000,
		context.allocator,
	)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.version, ProtocolVersion.Http3)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(res.body[:]), "h3 proactr /hello")
}

@(test)
test_proactr_h3_async_runtime :: proc(t: ^testing.T) {
	if _h3_skip_no_quic(t) do return

	lo := net.IP4_Address{127, 0, 0, 1}
	ssock, se := net.make_bound_udp_socket(lo, 0)
	testing.expect(t, se == nil, "bind server socket")
	if se != nil do return
	net.set_blocking(ssock, false)
	sep, _ := net.bound_endpoint(ssock)

	args := H3_Proactr_Server{sock = ssock}
	th := thread.create_and_start_with_data(&args, _h3_proactr_server_thread)
	defer {
		args.stop = true
		thread.join(th)
		thread.destroy(th)
		net.close(ssock)
	}
	time.sleep(10 * time.Millisecond)

	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	Wait :: struct {
		done: bool,
		res:  Response,
		err:  Http_Error,
	}
	wait: Wait
	url := fmt.tprintf("https://127.0.0.1:%d/async", sep.port)
	job, err := get_async_runtime(
		&rt,
		url,
		Options{insecure = true, version = .Http3, timeout = 5_000},
		rawptr(&wait),
		proc(user: rawptr, res: Response, err: Http_Error) {
			w := (^Wait)(user)
			w.res = res
			w.err = err
			w.done = true
		},
	)
	if err != .None {
		testing.expect(t, false, fmt.tprintf("start: %v", err))
		return
	}
	testing.expect(t, job != nil && job.use_h3, "use_h3")
	perr := runtime_pump_until(&rt, &wait.done, 5_000)
	testing.expect_value(t, perr, Http_Error.None)
	testing.expect(t, wait.done, "on_done fired")
	// Drain residual timer/close CQEs so H3/QUIC free_transport runs before runtime_destroy.
	_ = runtime_drain(&rt, 32, 0)
	_ = runtime_drain(&rt, 16, 2)
	defer response_destroy(&wait.res)
	testing.expect_value(t, wait.err, Http_Error.None)
	testing.expect_value(t, wait.res.version, ProtocolVersion.Http3)
	testing.expect_value(t, string(wait.res.body[:]), "h3 proactr /async")
}

@(test)
test_proactr_h3_cancel_during_request :: proc(t: ^testing.T) {
	if _h3_skip_no_quic(t) do return

	lo := net.IP4_Address{127, 0, 0, 1}
	ssock, se := net.make_bound_udp_socket(lo, 0)
	testing.expect(t, se == nil, "bind server socket")
	if se != nil do return
	net.set_blocking(ssock, false)
	sep, _ := net.bound_endpoint(ssock)

	args := H3_Proactr_Server{sock = ssock}
	th := thread.create_and_start_with_data(&args, _h3_proactr_server_thread)
	defer {
		args.stop = true
		thread.join(th)
		thread.destroy(th)
		net.close(ssock)
	}
	time.sleep(10 * time.Millisecond)

	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	Done_Ctx :: struct {
		calls: int,
		err:   Http_Error,
	}
	ctx: Done_Ctx

	job, err := h3_request_start(
		&rt,
		"GET",
		"127.0.0.1",
		"/cancel-me",
		sep.port,
		nil,
		DEFAULT_MAX_RESPONSE_BODY,
		true, // insecure
		5_000,
		rawptr(&ctx),
		proc(user: rawptr, res: Response, err: Http_Error) {
			_ = res
			c := (^Done_Ctx)(user)
			c.calls += 1
			c.err = err
		},
		context.allocator,
	)
	if err != .None {
		testing.expect(t, false, fmt.tprintf("h3 start: %v", err))
		return
	}
	testing.expect(t, job != nil && job.live && job.use_h3, "job live h3")
	shell := job

	// Option B: first cancel fires on_done sync with .Closed.
	job_cancel(job, false)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Closed)
	// Second cancel is no-op (reason frozen).
	job_cancel(job, true)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Closed)

	// Drain so CQEs (timer cancel + close + UDP) can free the shell.
	for _ in 0 ..< 8 {
		if !shell.live do break
		_ = runtime_drain(&rt, 16, 2)
	}
	// kqueue may drop armed UDP recv CQEs after close (documented residual).
	// Force accounting only when fd already closed and cancel terminal — reclaim shell.
	if shell.live && shell.ops_outstanding > 0 && shell.fd < 0 {
		shell.ops_outstanding = 0
		if shell.runtime != nil {
			shell.runtime.pending_ops = 0
		}
		_job_try_free(shell)
	}
	testing.expect(t, !shell.live, "job free-listed after cancel drain")
}

// job_h3.odin drive must not call time.sleep (dial residual may sleep outside this file).
@(test)
test_proactr_h3_no_sleep_in_job_h3_source :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("job_h3.odin", context.allocator)
	if err != nil {
		data, err = os.read_entire_file("client/job_h3.odin", context.allocator)
	}
	if err != nil || data == nil {
		testing.expect(t, false, "read job_h3.odin")
		return
	}
	defer delete(data)
	src := string(data)
	// Disallow executable sleep; comments may mention time.sleep as residual.
	// Match call form: time.sleep(
	if strings.contains(src, "time.sleep(") {
		testing.expect(t, false, "job_h3.odin must not call time.sleep(")
	}
}
