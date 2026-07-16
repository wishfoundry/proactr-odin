// Phase 1 smoke: init ring; on Linux submit NOP and wait for CQE.
// On non-Linux, ring_init returns Unsupported (expected).
package main

import "core:fmt"
import "core:os"

import proactr "../../proactr"

main :: proc() {
	ring: proactr.Ring
	err := proactr.ring_init(&ring, 32)
	defer proactr.ring_destroy(&ring)

	if err == .Unsupported {
		fmt.println("ring_smoke: Unsupported (non-Linux or no io_uring) — OK for Phase 1")
		os.exit(0)
	}
	if err != .None {
		fmt.eprintf("ring_init failed: %v\n", err)
		os.exit(1)
	}

	id, serr := proactr.submit_nop(&ring)
	if serr != .None {
		fmt.eprintf("submit_nop failed: %v\n", serr)
		os.exit(1)
	}

	if serr = proactr.ring_submit(&ring); serr != .None {
		fmt.eprintf("ring_submit failed: %v\n", serr)
		os.exit(1)
	}

	completions: [8]proactr.Completion
	n, werr := proactr.ring_wait(&ring, completions[:], 1, 1000)
	if werr != .None {
		fmt.eprintf("ring_wait failed: %v\n", werr)
		os.exit(1)
	}
	if n < 1 {
		fmt.eprintf("ring_wait: expected >= 1 CQE, got %d\n", n)
		os.exit(1)
	}

	c := completions[0]
	op := proactr.complete_apply(&ring, c)
	if op == nil || c.op_id != id {
		fmt.eprintf("bad completion: op_id=%v expected=%v op=%v\n", c.op_id, id, op)
		os.exit(1)
	}
	if c.result < 0 {
		fmt.eprintf("NOP completed with error res=%d\n", c.result)
		os.exit(1)
	}

	proactr.op_free(&ring, id)
	fmt.printf("ring_smoke: OK (nop id=%v res=%d)\n", id, c.result)
}
