// Minimal TCP echo sketch for the proactr ring (Phase 1 scaffolding).
// Full accept/recv/send loop lands with the HTTP host (Phase 2).
// On non-Linux: ring_init returns Unsupported.
package main

import "core:fmt"
import "core:os"

import proactr "../../proactr"

main :: proc() {
	ring: proactr.Ring
	err := proactr.ring_init(&ring, proactr.DEFAULT_ENTRIES)
	defer proactr.ring_destroy(&ring)

	if err == .Unsupported {
		fmt.println("tcp_echo: proactr ring Unsupported on this platform")
		os.exit(0)
	}
	if err != .None {
		fmt.eprintf("ring_init failed: %v\n", err)
		os.exit(1)
	}

	// Phase 1: ring is live. A real echo needs listen socket + submit_accept /
	// submit_recv / submit_send / submit_close driven by complete_apply.
	// Use examples/ring_smoke for a NOP round-trip today.
	fmt.println("tcp_echo: ring active (listen/echo host deferred to Phase 2)")
	fmt.println("tcp_echo: see docs/PROACTR_RING.md for submit_* surface")
}
