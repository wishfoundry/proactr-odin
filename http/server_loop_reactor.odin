#+build darwin
package http

// Darwin worker loop: native kqueue reactor wait ownership (Plan R2 P5).
// Product sockets: reactor kqueue only. Timers: proactr soft_cq (D5).
// Dual-wait merge: skip empty soft wait when no timer is due; single reactor
// kevent holds the blocking wait with timer-aware timeout (drogon one-poll shape).

import "core:log"
import "core:sync"
import "core:time"

import proactr "../proactr"

@(private)
server_reactor_dispatch_soft :: proc(s: ^Server, completions: []proactr.Completion) {
	n_soft, werr := proactr.ring_wait(&td.ring, completions[:], 0, 0)
	if werr != .None {
		log.errorf("ring_wait(soft) error: %v", werr)
		return
	}
	for i in 0 ..< n_soft {
		c := completions[i]
		op := proactr.complete_apply(&td.ring, c)
		if op == nil {
			continue
		}
		if client_bridge.on_cqe != nil &&
		   client_bridge.on_cqe(rawptr(&td.ring), c, op) {
			continue
		}
		host_dispatch(s, op, c)
		if op.status != .Submitted {
			proactr.op_free(&td.ring, c.op_id)
		}
	}
}

// server_reactor_worker_loop: replaces façade ring_wait as the primary wait.
@(private)
server_reactor_worker_loop :: proc(s: ^Server) {
	if !reactor_host_init(s.conn_allocator) {
		log.error("reactor_host_init failed")
		return
	}
	defer reactor_host_destroy()

	server_date_refresh()

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

		loop_wait := wait_ms
		if sync.atomic_load(&td.mail_pending) > 0 {
			loop_wait = 0
		}

		tms, has_timer := proactr.ring_next_timer_ms(&td.ring)
		if has_timer {
			if tms < loop_wait || loop_wait < 0 {
				loop_wait = tms
			}
		}

		// Outbound client ops arm proactr kq (not product reactor). When pending,
		// dual-wait: block on proactr (min_complete=1) for client readiness, then
		// nonblock product. Full reactor registration of client fds is later polish.
		// Pre-I/O soft harvest when timer due now.
		if has_timer && tms == 0 {
			server_reactor_dispatch_soft(s, completions)
		}
		// Re-sample after soft harvest (may have submitted more outbound).
		client_work := client_bridge.has_work != nil && client_bridge.has_work()

		if client_work {
			n_soft, werr := proactr.ring_wait(&td.ring, completions[:], 1, loop_wait)
			if werr != .None {
				log.errorf("ring_wait(client dual) error: %v", werr)
			} else {
				for i in 0 ..< n_soft {
					c := completions[i]
					op := proactr.complete_apply(&td.ring, c)
					if op == nil {
						continue
					}
					if client_bridge.on_cqe != nil &&
					   client_bridge.on_cqe(rawptr(&td.ring), c, op) {
						continue
					}
					host_dispatch(s, op, c)
					if op.status != .Submitted {
						proactr.op_free(&td.ring, c.op_id)
					}
				}
			}
			_ = reactor_wait(s, 0)
		} else {
			// One blocking wait: product sockets + timer deadline in kevent timeout.
			_ = reactor_wait(s, loop_wait)
		}

		// Post-I/O soft harvest: timers or remaining client work (nonblocking peek).
		_, has_timer_post := proactr.ring_next_timer_ms(&td.ring)
		client_work_post := client_bridge.has_work != nil && client_bridge.has_work()
		if has_timer_post || client_work_post {
			server_reactor_dispatch_soft(s, completions)
		}
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
