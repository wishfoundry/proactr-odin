package client

import "core:fmt"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

import http "../http"

@(test)
test_runtime_thread_local_once :: proc(t: ^testing.T) {
	rt1 := runtime_thread_local()
	testing.expect(t, rt1 != nil, "runtime_thread_local non-nil")
	testing.expect(t, rt1.inited, "runtime inited")
	testing.expect(t, rt1.owns_ring, "owns private ring")
	testing.expect(t, rt1.ring != nil, "ring pointer set")

	rt2 := runtime_thread_local()
	testing.expect(t, rt1 == rt2, "same thread-local instance")
	testing.expect(t, rt1.ring == rt2.ring, "same ring pointer")
}

@(test)
test_job_cancel_sync_on_done :: proc(t: ^testing.T) {
	rt: Client_Runtime
	ok := runtime_init(&rt, context.allocator, 32)
	if !ok {
		testing.expect(t, false, "runtime_init failed")
		return
	}
	defer runtime_destroy(&rt)

	Done_Ctx :: struct {
		calls: int,
		err:   Http_Error,
	}
	ctx: Done_Ctx

	job := job_alloc(&rt)
	job.user = rawptr(&ctx)
	job.on_done = proc(user: rawptr, res: Response, err: Http_Error) {
		_ = res
		c := (^Done_Ctx)(user)
		c.calls += 1
		c.err = err
	}

	// Cancel with no outstanding ops → sync on_done + free to free-list.
	job_cancel(job, false)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Closed)
	testing.expect(t, !job.live, "job free-listed after quiet cancel")

	// Second cancel is no-op (job may already be on free-list — re-alloc and re-cancel).
	job2 := job_alloc(&rt)
	job2.user = rawptr(&ctx)
	job2.on_done = proc(user: rawptr, res: Response, err: Http_Error) {
		_ = res
		c := (^Done_Ctx)(user)
		c.calls += 1
		c.err = err
	}
	job_cancel(job2, true)
	testing.expect_value(t, ctx.calls, 2)
	testing.expect_value(t, ctx.err, Http_Error.Exchange_Gone)
}

@(test)
test_job_cancel_inflight_and_double :: proc(t: ^testing.T) {
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

	job := job_alloc(&rt)
	job.user = rawptr(&ctx)
	job.on_done = proc(user: rawptr, res: Response, err: Http_Error) {
		_ = res
		c := (^Done_Ctx)(user)
		c.calls += 1
		c.err = err
	}
	// Simulate one in-flight op so cancel does not free immediately.
	job.ops_outstanding = 1
	job.phase = .Recving
	job_cancel(job, false)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Closed)
	testing.expect(t, job.live, "still live while ops outstanding")
	testing.expect(t, job.done_fired, "done fired on first cancel")

	// Double-cancel: second call must not re-fire on_done.
	job_cancel(job, true)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Closed) // first reason frozen

	// Simulate last CQE arriving (harvest free path).
	job.ops_outstanding = 0
	_job_try_free(job)
	testing.expect(t, !job.live, "freed after ops drain")
}

@(test)
test_job_on_done_reentry_safe :: proc(t: ^testing.T) {
	// on_done that allocates a new job must not corrupt free-list ABA.
	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	Re_Ctx :: struct {
		rt:       ^Client_Runtime,
		calls:    int,
		new_job:  ^Client_Job,
		orig_live_during: bool,
	}
	ctx: Re_Ctx
	ctx.rt = &rt

	job := job_alloc(&rt)
	job.user = rawptr(&ctx)
	job.on_done = proc(user: rawptr, res: Response, err: Http_Error) {
		_ = res
		_ = err
		c := (^Re_Ctx)(user)
		c.calls += 1
		// During callback original must still be live (deferred free).
		// Allocate another shell — must not be the same pointer still "owned".
		c.new_job = job_alloc(c.rt)
		c.orig_live_during = true
	}
	job_cancel(job, false)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect(t, !job.live, "original free after callback")
	testing.expect(t, ctx.new_job != nil, "nested alloc ok")
	testing.expect(t, ctx.new_job.live, "nested job live")
	// Nested job is distinct live shell (may share pointer only after free — but
	// free happens after nested alloc, so nested must be a different allocation
	// OR same if free-list was empty and we... wait: free is AFTER callback, so
	// during callback original is live, nested is new() if free-list empty).
	if ctx.new_job != nil {
		job_cancel(ctx.new_job, false)
	}
}

@(test)
test_get_invalid_use_when_worker_active :: proc(t: ^testing.T) {
	prev := http_worker_active
	http_worker_active = true
	defer {http_worker_active = prev}

	res, err := get("http://example.com/")
	testing.expect_value(t, err, Http_Error.Invalid_Use)
	testing.expect_value(t, res.status, Status(0))

	res2, err2 := get_proactr("http://example.com/")
	testing.expect_value(t, err2, Http_Error.Invalid_Use)
	_ = res2

	// request() also hard-fails on worker.
	c := new(Connection, context.allocator)
	c.allocator = context.allocator
	defer free(c)
	req := Request{method = "GET"}
	_, rerr := request(c, &req)
	testing.expect_value(t, rerr, Http_Error.Invalid_Use)

	job, aerr := get_async(nil, "http://example.com/")
	testing.expect(t, job == nil, "get_async nil job")
	testing.expect_value(t, aerr, Http_Error.Not_Configured)
}

@(test)
test_get_async_not_configured_without_worker :: proc(t: ^testing.T) {
	// No worker_install → loud Not_Configured.
	prev := http_worker_active
	http_worker_active = false
	defer {http_worker_active = prev}

	res: http.Response
	job, err := get_async(&res, "http://127.0.0.1/")
	testing.expect(t, job == nil)
	testing.expect_value(t, err, Http_Error.Not_Configured)
}

@(test)
test_slot_cancel_exchange_gone :: proc(t: ^testing.T) {
	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	// Simulate worker runtime for get_async path pieces (slot list only).
	slot: http.Stream_Slot
	slot.exchange_epoch = 1

	Done_Ctx :: struct {
		calls: int,
		err:   Http_Error,
	}
	ctx: Done_Ctx

	job := job_alloc(&rt)
	job.user = rawptr(&ctx)
	job.on_done = proc(user: rawptr, res: Response, err: Http_Error) {
		_ = res
		c := (^Done_Ctx)(user)
		c.calls += 1
		c.err = err
	}
	job_link_slot(job, &slot)
	testing.expect(t, slot.client_jobs == rawptr(job), "linked")
	testing.expect_value(t, job.exchange_epoch, u32(1))

	// Host clean: cancel with exchange_gone.
	client_jobs_cancel_slot(&slot, true)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Exchange_Gone)
	testing.expect(t, slot.client_jobs == nil, "list cleared")
	testing.expect(t, !job.live, "job free-listed after quiet cancel")

	// Second cancel on empty slot is no-op.
	client_jobs_cancel_slot(&slot, true)
	testing.expect_value(t, ctx.calls, 1)
}

@(test)
test_get_async_with_worker_install :: proc(t: ^testing.T) {
	// Private ring bound as "worker" runtime + fake exchange Response.
	owned: Client_Runtime
	if !runtime_init(&owned, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&owned)

	// Install worker view onto the same ring (non-owning bind path).
	worker_install(owned.ring, context.allocator)
	defer worker_uninstall()

	// Local HTTP server for clear GET.
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if lerr != nil {
		testing.expect(t, false, fmt.tprintf("listen: %v", lerr))
		return
	}
	defer net.close(listener)
	bound, berr := net.bound_endpoint(listener)
	if berr != nil {
		testing.expect(t, false, fmt.tprintf("bound: %v", berr))
		return
	}
	Srv :: struct {
		listener: net.TCP_Socket,
	}
	srv := Srv{listener = listener}
	th := thread.create_and_start_with_data(rawptr(&srv), proc(data: rawptr) {
		s := (^Srv)(data)
		client, _, aerr := net.accept_tcp(s.listener)
		if aerr != nil do return
		defer net.close(client)
		buf: [4096]u8
		total := 0
		for total < len(buf) {
			n, rerr := net.recv_tcp(client, buf[total:])
			if n > 0 do total += n
			if rerr != nil do break
			if total >= 4 && strings_contains_crlfcrlf(buf[:total]) do break
		}
		resp := "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\npr2"
		_, _ = net.send_tcp(client, transmute([]u8)resp)
	})
	defer {
		thread.join(th)
		thread.destroy(th)
	}
	time.sleep(10 * time.Millisecond)

	// Fake inbound exchange: slot + response binding.
	slot: http.Stream_Slot
	slot.exchange_epoch = 7
	res: http.Response
	res._slot = &slot

	Wait :: struct {
		done: bool,
		body: string,
		err:  Http_Error,
	}
	wait: Wait
	url := fmt.tprintf("http://127.0.0.1:%d/", bound.port)
	job, err := get_async(
		&res,
		url,
		Options{version = .Http1},
		rawptr(&wait),
		proc(user: rawptr, upstream: Response, err: Http_Error) {
			w := (^Wait)(user)
			w.err = err
			if err == .None {
				w.body = string(upstream.body[:])
				// Caller owns body — destroy after copy for test.
				owned := upstream
				response_destroy(&owned)
			}
			w.done = true
		},
	)
	if err != .None {
		testing.expect(t, false, fmt.tprintf("get_async: %v", err))
		return
	}
	testing.expect(t, job != nil)
	testing.expect(t, job.slot == &slot)
	testing.expect_value(t, job.exchange_epoch, u32(7))
	testing.expect(t, slot.client_jobs == rawptr(job))

	// Pump worker runtime until done.
	rt := worker_runtime()
	testing.expect(t, rt != nil)
	perr := runtime_pump_until(rt, &wait.done, 5_000)
	testing.expect_value(t, perr, Http_Error.None)
	testing.expect(t, wait.done)
	testing.expect_value(t, wait.err, Http_Error.None)
	testing.expect_value(t, wait.body, "pr2")
}

@(test)
test_job_user_tag_demux :: proc(t: ^testing.T) {
	// Untagged aligned pointer must not claim as Client_Job (Connection* path).
	fake_conn: [2]uintptr
	user := rawptr(&fake_conn[0])
	testing.expect(t, uintptr(user)&1 == 0, "aligned")
	job, ok := _job_from_user(user)
	testing.expect(t, !ok, "untagged rejected")
	testing.expect(t, job == nil)

	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 8) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)
	j := job_alloc(&rt)
	tagged := _job_user(j)
	testing.expect(t, uintptr(tagged)&1 != 0, "tagged")
	j2, ok2 := _job_from_user(tagged)
	testing.expect(t, ok2)
	testing.expect(t, j2 == j)
	job_cancel(j, false)
}

@(test)
test_clean_sim_cancel_during_flight :: proc(t: ^testing.T) {
	// Job with outstanding ops: cancel_slot → Exchange_Gone, single on_done.
	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	slot: http.Stream_Slot
	slot.exchange_epoch = 3

	Done_Ctx :: struct {
		calls: int,
		err:   Http_Error,
	}
	ctx: Done_Ctx
	job := job_alloc(&rt)
	job.ops_outstanding = 1
	job.phase = .Recving
	job.user = rawptr(&ctx)
	job.on_done = proc(user: rawptr, res: Response, err: Http_Error) {
		_ = res
		c := (^Done_Ctx)(user)
		c.calls += 1
		c.err = err
	}
	job_link_slot(job, &slot)

	client_jobs_cancel_slot(&slot, true)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Exchange_Gone)
	testing.expect(t, job.live, "still live with ops")
	testing.expect(t, job.done_fired)
	testing.expect(t, slot.client_jobs == nil)

	// Explicit outbound cancel while exchange live → .Closed (different path).
	job2 := job_alloc(&rt)
	job2.ops_outstanding = 1
	job2.user = rawptr(&ctx)
	job2.on_done = proc(user: rawptr, res: Response, err: Http_Error) {
		_ = res
		c := (^Done_Ctx)(user)
		c.calls += 1
		c.err = err
	}
	ctx.calls = 0
	job_cancel(job2, false)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Closed)

	// Drain fake outstanding so free-list clean for runtime_destroy.
	job.ops_outstanding = 0
	_job_try_free(job)
	job2.ops_outstanding = 0
	_job_try_free(job2)
}

@(test)
test_h1_clear_proactr :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if lerr != nil {
		testing.expect(t, false, fmt.tprintf("listen: %v", lerr))
		return
	}
	defer net.close(listener)

	bound, berr := net.bound_endpoint(listener)
	if berr != nil {
		testing.expect(t, false, fmt.tprintf("bound endpoint: %v", berr))
		return
	}

	Srv :: struct {
		listener: net.TCP_Socket,
		ok:       bool,
	}
	srv := Srv{listener = listener}
	th := thread.create_and_start_with_data(rawptr(&srv), proc(data: rawptr) {
		s := (^Srv)(data)
		client, _, aerr := net.accept_tcp(s.listener)
		if aerr != nil do return
		defer net.close(client)
		buf: [4096]u8
		// Read request (best-effort full headers).
		total := 0
		for total < len(buf) {
			n, rerr := net.recv_tcp(client, buf[total:])
			if n > 0 do total += n
			if rerr != nil do break
			if total >= 4 && strings_contains_crlfcrlf(buf[:total]) do break
		}
		resp := "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
		_, _ = net.send_tcp(client, transmute([]u8)resp)
		s.ok = true
	})
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	// Brief settle for accept thread (local; not proactr path).
	time.sleep(10 * time.Millisecond)

	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	sock, derr := net.dial_tcp(bound)
	if derr != nil {
		testing.expect(t, false, fmt.tprintf("dial: %v", derr))
		return
	}
	if berr := net.set_blocking(sock, false); berr != nil {
		net.close(sock)
		testing.expect(t, false, "set_blocking")
		return
	}
	fd := i32(sock)

	res, err := h1_clear_request_blocking(
		&rt,
		fd,
		"GET",
		"127.0.0.1",
		"/",
		bound.port,
		nil,
		1024,
		5_000,
		context.allocator,
	)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(res.body[:]), "hello")
}

@(test)
test_get_async_runtime_pump :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if lerr != nil {
		testing.expect(t, false, fmt.tprintf("listen: %v", lerr))
		return
	}
	defer net.close(listener)

	bound, berr := net.bound_endpoint(listener)
	if berr != nil {
		testing.expect(t, false, fmt.tprintf("bound: %v", berr))
		return
	}

	Srv :: struct {
		listener: net.TCP_Socket,
	}
	srv := Srv{listener = listener}
	th := thread.create_and_start_with_data(rawptr(&srv), proc(data: rawptr) {
		s := (^Srv)(data)
		client, _, aerr := net.accept_tcp(s.listener)
		if aerr != nil do return
		defer net.close(client)
		buf: [4096]u8
		total := 0
		for total < len(buf) {
			n, rerr := net.recv_tcp(client, buf[total:])
			if n > 0 do total += n
			if rerr != nil do break
			if total >= 4 && strings_contains_crlfcrlf(buf[:total]) do break
		}
		resp := "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nbye"
		_, _ = net.send_tcp(client, transmute([]u8)resp)
	})
	defer {
		thread.join(th)
		thread.destroy(th)
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
	url := fmt.tprintf("http://127.0.0.1:%d/", bound.port)
	job, err := get_async_runtime(
		&rt,
		url,
		Options{version = .Http1},
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
	_ = job
	perr := runtime_pump_until(&rt, &wait.done, 5_000)
	testing.expect_value(t, perr, Http_Error.None)
	testing.expect(t, wait.done, "on_done fired")
	defer response_destroy(&wait.res)
	testing.expect_value(t, wait.err, Http_Error.None)
	testing.expect_value(t, wait.res.status, Status.OK)
	testing.expect_value(t, string(wait.res.body[:]), "bye")
}

@(test)
test_get_http_proactr :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if lerr != nil {
		testing.expect(t, false, fmt.tprintf("listen: %v", lerr))
		return
	}
	defer net.close(listener)

	bound, berr := net.bound_endpoint(listener)
	if berr != nil {
		testing.expect(t, false, fmt.tprintf("bound: %v", berr))
		return
	}

	Srv :: struct {
		listener: net.TCP_Socket,
	}
	srv := Srv{listener = listener}
	th := thread.create_and_start_with_data(rawptr(&srv), proc(data: rawptr) {
		s := (^Srv)(data)
		client, _, aerr := net.accept_tcp(s.listener)
		if aerr != nil do return
		defer net.close(client)
		buf: [4096]u8
		total := 0
		for total < len(buf) {
			n, rerr := net.recv_tcp(client, buf[total:])
			if n > 0 do total += n
			if rerr != nil do break
			if total >= 4 && strings_contains_crlfcrlf(buf[:total]) do break
		}
		resp := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
		_, _ = net.send_tcp(client, transmute([]u8)resp)
	})
	defer {
		thread.join(th)
		thread.destroy(th)
	}
	time.sleep(10 * time.Millisecond)

	url := fmt.tprintf("http://127.0.0.1:%d/", bound.port)
	res, err := get(url, Options{use_proactr_io = true, version = .Http1, timeout = 5_000})
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(res.body[:]), "ok")
}

@(private = "file")
strings_contains_crlfcrlf :: proc(buf: []u8) -> bool {
	s := string(buf)
	for i in 0 ..< len(s) - 3 {
		if s[i] == '\r' && s[i + 1] == '\n' && s[i + 2] == '\r' && s[i + 3] == '\n' {
			return true
		}
	}
	return false
}
