#+build darwin
package http

// Darwin worker loop: native kqueue reactor wait ownership (Plan R2 P5).
// Product sockets: reactor kqueue only. Timers: proactr soft_cq (ring_wait peek).
// APP_CONTRACT unchanged.

import "core:log"
import "core:sync"
import "core:time"

import proactr "../proactr"

// server_reactor_worker_loop: replaces façade ring_wait as the primary wait.
// Call after ring_init, listen, and optional fixed-file install (same setup as
// _server_thread_main prologue). Does not ring_init/destroy — caller owns that.
@(private)
server_reactor_worker_loop :: proc(s: ^Server) {
	if !reactor_host_init(s.conn_allocator) {
		log.error("reactor_host_init failed")
		return
	}
	defer reactor_host_destroy()

	server_date_refresh()

	// Prime accept on reactor kqueue (not proactr).
	if !reactor_host_submit_accept(s) {
		log.error("initial reactor accept arm failed; will retry")
		td.needs_accept_rearm = true
	}

	cqe_n := max(1, s.opts.cqe_batch)
	completions := make([]proactr.Completion, cqe_n, s.conn_allocator)
	defer delete(completions)
	wait_ms := i32(s.opts.wait_timeout_ms)
	td.state = .Running

	for {
		closing := server_reap_if_closing(s)

		if td.needs_accept_rearm {
			if atomic_load(&s.closing) || td.state >= .Closing || atomic_load(&s.listen_closed) {
				td.needs_accept_rearm = false
			} else if td.accept_pending {
				td.needs_accept_rearm = false
			} else if !reactor_host_submit_accept(s) {
				td.needs_accept_rearm = true
			} else {
				td.needs_accept_rearm = false
			}
		}

		if time.diff(td.date_updated, time.now()) >= time.Second {
			server_date_refresh()
		}

		if closing && len(td.conns) == 0 && !td.accept_pending {
			break
		}

		// Mailbox wake: non-blocking I/O wait.
		loop_wait := wait_ms
		if sync.atomic_load(&td.mail_pending) > 0 {
			loop_wait = 0
		}

		// Timer budget: wake early for due software timers (D5 merge wait).
		if tms, has := proactr.ring_next_timer_ms(&td.ring); has {
			if tms < loop_wait || loop_wait < 0 {
				loop_wait = tms
			}
		}

		// 1) Fire due timers + drain soft_cq only (no socket arms on proactr kq).
		n_soft, werr := proactr.ring_wait(&td.ring, completions[:], 0, 0)
		if werr != .None {
			log.errorf("ring_wait(soft) error: %v", werr)
			if !atomic_load(&s.closing) {
				break
			}
		}
		for i in 0 ..< n_soft {
			c := completions[i]
			op := proactr.complete_apply(&td.ring, c)
			if op == nil {
				continue
			}
			// Expect Timeout / Nop only; never Accept/Recv/Send on Darwin P5.
			host_dispatch(s, op, c)
			if op.status != .Submitted {
				proactr.op_free(&td.ring, c.op_id)
			}
		}

		// 2) Product socket wait on reactor kqueue (drains deferred clean inside).
		_ = reactor_wait(s, loop_wait)
		// Soft_cq path may also have finished oneshot via timer-driven work; drain again.
		reactor_drain_deferred_clean()

		closing = server_reap_if_closing(s)

		if td.needs_accept_rearm {
			if !atomic_load(&s.closing) && td.state < .Closing && !atomic_load(&s.listen_closed) &&
			   !td.accept_pending {
				if !reactor_host_submit_accept(s) {
					td.needs_accept_rearm = true
				} else {
					td.needs_accept_rearm = false
				}
			} else {
				td.needs_accept_rearm = false
			}
		}

		session_mailbox_drain()
		if s.opts.on_worker_tick != nil {
			s.opts.on_worker_tick(s.opts.worker_tick_user)
		}

		if closing && len(td.conns) == 0 && !td.accept_pending {
			break
		}
	}

	td.state = .Cleaning
	log.debug("worker reactor loop end")
}
