package client

import "base:runtime"
import "core:mem"

import http "../http"
import proactr "../proactr"

// Thread-local worker Client_Runtime (non-owning ring bound to host worker).
@(thread_local)
_worker_rt: Client_Runtime

@(thread_local)
_worker_rt_installed: bool

// worker_runtime returns the installed worker runtime, or nil if not on a server worker.
worker_runtime :: proc() -> ^Client_Runtime {
	if !_worker_rt_installed || !_worker_rt.inited {
		return nil
	}
	return &_worker_rt
}

// worker_install binds the host worker ring (non-owning). Sets http_worker_active.
worker_install :: proc(ring: ^proactr.Ring, allocator: mem.Allocator) {
	if ring == nil {
		return
	}
	// Rebind if already installed (defensive).
	if _worker_rt_installed {
		runtime_destroy(&_worker_rt)
	}
	runtime_bind_worker_ring(&_worker_rt, ring, allocator)
	_worker_rt_installed = _worker_rt.inited
	http_worker_active = true
}

// worker_uninstall tears down free-list shells and clears worker flags.
// Does not destroy the host ring.
worker_uninstall :: proc() {
	if _worker_rt_installed {
		runtime_destroy(&_worker_rt)
	}
	_worker_rt_installed = false
	http_worker_active = false
}


// job_link_slot binds job to exchange; snapshots exchange_epoch.
job_link_slot :: proc(job: ^Client_Job, slot: ^http.Stream_Slot) {
	if job == nil || slot == nil do return
	job.slot = slot
	job.exchange_epoch = slot.exchange_epoch
	job.slot_next = (^Client_Job)(slot.client_jobs)
	slot.client_jobs = rawptr(job)
}

// job_unlink_slot removes job from slot list. Safe if already unlinked.
job_unlink_slot :: proc(job: ^Client_Job) {
	if job == nil || job.slot == nil do return
	slot := job.slot
	prev: ^Client_Job = nil
	cur := (^Client_Job)(slot.client_jobs)
	for cur != nil {
		if cur == job {
			if prev == nil {
				slot.client_jobs = rawptr(job.slot_next)
			} else {
				prev.slot_next = job.slot_next
			}
			job.slot_next = nil
			job.slot = nil
			return
		}
		prev = cur
		cur = cur.slot_next
	}
	// Not found — clear local fields only.
	job.slot_next = nil
	job.slot = nil
}

// client_jobs_cancel_slot — walk slot list, unlink, cancel each.
// O(jobs on that slot). Host calls with exchange_gone=true on clean/destroy.
client_jobs_cancel_slot :: proc(slot: ^http.Stream_Slot, exchange_gone := true) {
	if slot == nil do return
	j := (^Client_Job)(slot.client_jobs)
	slot.client_jobs = nil
	for j != nil {
		next := j.slot_next
		j.slot_next = nil
		j.slot = nil
		if j.live && !j.done_fired {
			job_cancel(j, exchange_gone)
		}
		j = next
	}
}

// client_jobs_cancel_conn — H1 slot + all H2 slots.
client_jobs_cancel_conn :: proc(conn: ^http.Connection, exchange_gone := true) {
	if conn == nil do return
	client_jobs_cancel_slot(&conn.slot, exchange_gone)
	if conn.h2_slots != nil {
		for i in 0 ..< http.H2_SLOT_CAP {
			client_jobs_cancel_slot(&conn.h2_slots[i], exchange_gone)
		}
	}
}

// Bridge: host CQE demux. Tag bit first — never deep-load untagged user as Client_Job.
// Once tagged, always claim (return true): never fall through to host Connection cast.
@(private)
_bridge_on_cqe :: proc(ring: rawptr, c: proactr.Completion, op: ^proactr.Operation) -> bool {
	if op == nil || op.user == nil {
		return false
	}
	job, ok := _job_from_user(op.user)
	if !ok {
		return false // inbound Connection* (aligned, untagged)
	}
	// Tagged → ours. Free op if job dead/stale; do not host_dispatch.
	if job.magic != CLIENT_JOB_MAGIC || !job.live {
		if op.status != .Submitted {
			proactr.operation_free((^proactr.Ring)(ring), c.op_id)
		}
		return true
	}
	if job.runtime == nil || job.runtime.ring == nil || rawptr(job.runtime.ring) != ring {
		if op.status != .Submitted {
			proactr.operation_free((^proactr.Ring)(ring), c.op_id)
		}
		// Drop pending_ops if we cannot route (avoid stuck dual-wait).
		if job.runtime != nil && job.runtime.pending_ops > 0 {
			job.runtime.pending_ops -= 1
		}
		return true
	}
	// Stale exchange: cancel if not already terminal (epoch ABA).
	if job.slot != nil && job.exchange_epoch != job.slot.exchange_epoch {
		if !job.done_fired && !job.phase_cancel {
			job.slot_next = nil
			job.slot = nil
			job_cancel(job, true)
		}
	}
	job_on_cqe(job, c, op)
	return true
}

@(private)
_bridge_has_work :: proc() -> bool {
	if !_worker_rt_installed || !_worker_rt.inited {
		return false
	}
	return _worker_rt.pending_ops > 0
}

@(private)
_bridge_on_worker_enter :: proc(ring: rawptr, allocator: mem.Allocator) {
	worker_install((^proactr.Ring)(ring), allocator)
}

@(private)
_bridge_on_worker_leave :: proc() {
	worker_uninstall()
}

@(private)
_bridge_cancel_slot :: proc(slot: rawptr, exchange_gone: bool) {
	client_jobs_cancel_slot((^http.Stream_Slot)(slot), exchange_gone)
}

@(private)
_bridge_cancel_conn :: proc(conn: rawptr, exchange_gone: bool) {
	client_jobs_cancel_conn((^http.Connection)(conn), exchange_gone)
}

@(init)
_client_register_http_bridge :: proc "contextless" () {
	context = runtime.default_context()
	http.register_client_bridge(
		http.Client_Bridge {
			on_worker_enter = _bridge_on_worker_enter,
			on_worker_leave = _bridge_on_worker_leave,
			on_cqe          = _bridge_on_cqe,
			has_work        = _bridge_has_work,
			cancel_slot     = _bridge_cancel_slot,
			cancel_conn     = _bridge_cancel_conn,
		},
	)
}
