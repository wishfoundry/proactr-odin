// WASI demo: prove proactr soft_cq / timer / host-complete path,
// and that parked socket ops never complete without ring_wasi_complete.
package main

import "core:fmt"
import "core:os"

import proactr "../../proactr"

pass_n, fail_n: int

ok :: proc(name: string, cond: bool, detail: string = "") {
	if cond {
		pass_n += 1
		if detail != "" {
			fmt.printf("PASS  %s  (%s)\n", name, detail)
		} else {
			fmt.printf("PASS  %s\n", name)
		}
	} else {
		fail_n += 1
		if detail != "" {
			fmt.printf("FAIL  %s  (%s)\n", name, detail)
		} else {
			fmt.printf("FAIL  %s\n", name)
		}
	}
}

main :: proc() {
	fmt.println("=== proactr WASI demo ===")
	backend := proactr.ring_backend_name()
	fmt.printf("backend=%s\n", backend)
	ok("backend is wasi", backend == "wasi", backend)

	r: proactr.Ring
	err := proactr.ring_init(&r, 32)
	ok("ring_init", err == .None, fmt.tprintf("%v", err))
	if err != .None {
		fmt.println("abort: no ring")
		fmt.println("RESULT: FAILED")
		os.exit(2)
	}

	cq := make([]proactr.Completion, 16)

	{
		id, e := proactr.submit_nop(&r)
		ok("submit_nop", e == .None, fmt.tprintf("id=%v err=%v", id, e))
		n, we := proactr.ring_wait(&r, cq[:], 1, 0)
		ok("nop harvested on soft_cq", we == .None && n >= 1, fmt.tprintf("n=%v err=%v", n, we))
		if n >= 1 {
			op := proactr.complete_apply(&r, cq[0])
			ok("nop op completed", op != nil && op.status == .Completed && op.result == 0)
			proactr.operation_free(&r, cq[0].op_id)
		}
	}

	{
		_, e := proactr.submit_close(&r, 7)
		ok("submit_close", e == .None)
		n, _ := proactr.ring_wait(&r, cq[:], 1, 0)
		ok("close harvested", n >= 1)
		if n >= 1 {
			op := proactr.complete_apply(&r, cq[0])
			ok("close completed", op != nil && op.status == .Completed)
			proactr.operation_free(&r, cq[0].op_id)
		}
	}

	{
		_, e := proactr.submit_timeout(&r, 5_000_000) // 5ms
		ok("submit_timeout", e == .None)
		n, we := proactr.ring_wait(&r, cq[:], 1, 50)
		ok("timer harvested", we == .None && n >= 1, fmt.tprintf("n=%v err=%v", n, we))
		if n >= 1 {
			op := proactr.complete_apply(&r, cq[0])
			ok(
				"timer ETIME",
				op != nil && op.result == proactr.TIMEOUT_ETIME,
				fmt.tprintf("result=%v", op.result if op != nil else 0),
			)
			proactr.operation_free(&r, cq[0].op_id)
		}
	}

	{
		buf: [64]u8
		id, e := proactr.submit_recv(&r, 3, buf[:])
		ok("submit_recv parks (no real socket)", e == .None)
		n, _ := proactr.ring_wait(&r, cq[:], 1, 0)
		ok("recv not complete without host", n == 0, fmt.tprintf("n=%v (want 0)", n))
		proactr.ring_wasi_complete(&r, id, 11)
		n, _ = proactr.ring_wait(&r, cq[:], 1, 0)
		ok("recv complete after ring_wasi_complete", n >= 1)
		if n >= 1 {
			op := proactr.complete_apply(&r, cq[0])
			ok("recv result=11", op != nil && op.result == 11)
			proactr.operation_free(&r, cq[0].op_id)
		}
	}

	{
		id, e := proactr.submit_accept(&r, 1, continuous = false)
		ok("submit_accept parks only", e == .None)
		n, _ := proactr.ring_wait(&r, cq[:], 1, 20)
		ok(
			"CANNOT: accept never completes without host",
			n == 0,
			fmt.tprintf("n=%v", n),
		)
		proactr.ring_wasi_complete(&r, id, 99)
		n, _ = proactr.ring_wait(&r, cq[:], 1, 0)
		ok("accept completes only after host complete", n >= 1)
		if n >= 1 {
			op := proactr.complete_apply(&r, cq[0])
			ok("accept result is host-supplied fd", op != nil && op.result == 99)
			proactr.operation_free(&r, cq[0].op_id)
		}
	}

	{
		msg := transmute([]u8)string("hello")
		id, e := proactr.submit_send(&r, 4, msg)
		ok("submit_send parks", e == .None)
		n, _ := proactr.ring_wait(&r, cq[:], 1, 15)
		ok("CANNOT: send never completes without host", n == 0, fmt.tprintf("n=%v", n))
		proactr.ring_wasi_complete(&r, id, -1)
		n, _ = proactr.ring_wait(&r, cq[:], 1, 0)
		if n >= 1 {
			_ = proactr.complete_apply(&r, cq[0])
			proactr.operation_free(&r, cq[0].op_id)
		}
	}

	fmt.println("---")
	fmt.printf("summary: pass=%d fail=%d\n", pass_n, fail_n)
	delete(cq)
	proactr.ring_destroy(&r)

	if fail_n > 0 {
		fmt.println("RESULT: FAILED")
		os.exit(1)
	}
	fmt.println("RESULT: OK — soft_cq/timer/host-complete work; real sockets need wasi-sockets bridge")
}
