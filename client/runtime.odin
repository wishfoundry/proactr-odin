package client

import "core:mem"
import "core:time"

import proactr "../proactr"

// Thread-local: set true for the entire server worker loop.
// Blocking facade (get/request) fails with .Invalid_Use when true.
@(thread_local)
http_worker_active: bool

// Client_Runtime owns (or borrows) a proactr ring for outbound jobs.
// CLI: thread-local owned ring. Server worker: bound non-owning ring.
Client_Runtime :: struct {
	ring:       ^proactr.Ring,
	owned_ring: proactr.Ring, // only valid when owns_ring
	owns_ring:  bool,
	allocator:  mem.Allocator,
	inited:     bool,
	// Sum of in-flight proactr ops across jobs (Darwin soft-harvest wake gate).
	pending_ops: int,
	// free-list of job shells (may retain buffer capacity)
	job_free:   [dynamic]^Client_Job,
}

// Thread-local CLI runtime (lazy, one per thread).
@(private)
@(thread_local)
_tls_runtime: Client_Runtime

// runtime_init creates an owned private ring. Returns false on ring_init failure.
// Safe to call again after failure (no Once burn-in).
runtime_init :: proc(rt: ^Client_Runtime, allocator := context.allocator, entries: u32 = 64) -> bool {
	if rt.inited {
		return true
	}
	rt^ = {}
	rt.allocator = allocator
	rt.job_free = make([dynamic]^Client_Job, 0, 8, allocator)
	err := proactr.ring_init(&rt.owned_ring, entries, allocator)
	if err != .None {
		delete(rt.job_free)
		rt^ = {}
		return false
	}
	rt.ring = &rt.owned_ring
	rt.owns_ring = true
	rt.inited = true
	return true
}

// runtime_bind_worker_ring installs a non-owning ring pointer (server worker path).
// Prefer runtime_destroy before rebinding over an owned runtime.
runtime_bind_worker_ring :: proc(rt: ^Client_Runtime, ring: ^proactr.Ring, allocator := context.allocator) {
	if rt.inited {
		runtime_destroy(rt)
	}
	if ring == nil {
		return
	}
	rt.job_free = make([dynamic]^Client_Job, 0, 8, allocator)
	rt.allocator = allocator
	rt.ring = ring
	rt.owns_ring = false
	rt.owned_ring = {}
	rt.inited = true
}

runtime_destroy :: proc(rt: ^Client_Runtime) {
	if rt == nil || !rt.inited {
		return
	}
	for j in rt.job_free {
		if j != nil {
			// Fully free shells (including any retained buffers).
			if j.recv_buf != nil {
				delete(j.recv_buf, rt.allocator)
			}
			delete(j.tx)
			delete(j.rx)
			delete(j.app_tx)
			// Defensive: transport should already have freed SSL/host/h2/h3.
			_job_tls_free(j)
			_job_h3_free(j)
			free(j, rt.allocator)
		}
	}
	delete(rt.job_free)
	if rt.owns_ring {
		proactr.ring_destroy(&rt.owned_ring)
	}
	rt^ = {}
}

// runtime_thread_local returns the process-thread private runtime.
// Retries init if a previous attempt failed (no sticky Once death).
runtime_thread_local :: proc() -> ^Client_Runtime {
	if _tls_runtime.inited {
		return &_tls_runtime
	}
	// Prefer a stable process allocator for thread-local lifetime.
	if !runtime_init(&_tls_runtime, context.allocator, 64) {
		return nil
	}
	return &_tls_runtime
}

// runtime_pump_until harvests CQEs and dispatches via Operation.user = job.
// timeout_ms: wall budget; 0 uses DEFAULT_REQUEST_TIMEOUT_MS.
runtime_pump_until :: proc(rt: ^Client_Runtime, done: ^bool, timeout_ms: int) -> Http_Error {
	if rt == nil || rt.ring == nil {
		return .Not_Configured
	}
	budget := timeout_ms
	if budget <= 0 {
		budget = DEFAULT_REQUEST_TIMEOUT_MS
	}
	deadline := time.time_add(time.now(), time.Duration(budget) * time.Millisecond)
	completions: [32]proactr.Completion

	for !done^ {
		now := time.now()
		remaining_ns := time.diff(now, deadline)
		if remaining_ns <= 0 {
			return .Timeout
		}
		wait_ms := i32(remaining_ns / time.Millisecond)
		if wait_ms < 1 {
			wait_ms = 1
		}
		n, werr := proactr.ring_wait(rt.ring, completions[:], 1, wait_ms)
		if werr != .None {
			return .Closed
		}
		if n == 0 {
			continue
		}
		for i in 0 ..< n {
			c := completions[i]
			op := proactr.complete_apply(rt.ring, c)
			if op == nil {
				continue
			}
			job, ok := _job_from_user(op.user)
			if !ok || job == nil || !job.live {
				if op.status != .Submitted {
					proactr.operation_free(rt.ring, c.op_id)
				}
				continue
			}
			job_on_cqe(job, c, op)
		}
	}
	return .None
}

// Drain CQEs after cancel/timeout. Default wait_ms=0 = non-blocking peeks only
// (no quiet-tax sleep). Pass wait_ms>0 only when close CQEs need a short block.
runtime_drain :: proc(rt: ^Client_Runtime, rounds := 32, wait_ms: i32 = 0) -> bool {
	if rt == nil || rt.ring == nil do return true
	completions: [16]proactr.Completion
	for _ in 0 ..< rounds {
		n, _ := proactr.ring_wait(rt.ring, completions[:], 0, wait_ms)
		if n == 0 {
			return true
		}
		for i in 0 ..< n {
			c := completions[i]
			op := proactr.complete_apply(rt.ring, c)
			if op == nil do continue
			job, ok := _job_from_user(op.user)
			if ok && job != nil && job.live {
				job_on_cqe(job, c, op)
			} else if op.status != .Submitted {
				proactr.operation_free(rt.ring, c.op_id)
			}
		}
	}
	return false
}
