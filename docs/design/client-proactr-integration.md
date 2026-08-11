# Client × proactr integration

**Status:** plan — multi-critic **WOW** (performance, ergonomics, systems-compress, correctness r6)

**Critics:**
| Axis | Verdict |
|------|---------|
| Performance | WOW (r2) |
| Ergonomics | WOW (r3) |
| Systems-compress | WOW (r1) |
| Correctness | WOW (r6; Option B sync cancel terminal) |  
**Date:** 2026-08-11  
**Scope:** Run package `client` on the proactr completion model (and host reactor where product sockets live), keep a blocking facade for CLI, bind in-handler outbound work to the **inbound exchange** (`Stream_Slot`).  
**Non-scope:** H3 server host; public `http.resume`; streaming bodies v1; cross-worker pool.

---

## 1. Problem

Today `client/` is a solid multi-protocol toolkit on **blocking** TCP/TLS and H3 **sleep-poll**. Using it inside a server handler **stalls the worker**. There is no cancel-on-inbound-clean, no shared completion model with the host, and Darwin product I/O is **reactor kqueue**, not proactr socket ops.

---

## 2. Goals

1. Outbound client progress only on **completions** (CQE or reactor events)—never `time.sleep`, never nested `ring_wait` on the shared worker loop.  
2. **Blocking facade** for CLI/tests: private/thread-local runtime, reused across calls (not ring_init per `get`).  
3. **In-handler API is async-first** and **cannot omit** exchange binding.  
4. **Exchange unit = `Stream_Slot`** (H1 `conn.slot`, H2 `h2_slots[i]`), not bare `Connection`.  
5. Reuse H1/H2/H3 engines; change transport + scheduling only.  
6. TLS on async path: **mem-BIO only** (no blocking `SSL_connect` wall).  
7. Pool = worker/process group; jobs = exchange group.  
8. `.Auto` stays TCP ALPN; H3 via `.Http3` / `follow_alt_svc` / optional `prefer_h3`.

## 3. Non-goals

- Nested wait on worker ring.  
- Process-global client ring.  
- `http.resume`.  
- Happy Eyeballs / full browser conn manager.  
- Streaming bodies (v2).  
- Cross-worker connection reuse (v1).

---

## 4. Platform I/O ownership (performance — normative)

Product reality: **Linux** can use worker proactr ring for sockets; **Darwin** product path uses **reactor kqueue** for product sockets and proactr mainly for **soft_cq / timers**.

| Platform | Inbound product sockets | Outbound client sockets (v1) |
|----------|-------------------------|------------------------------|
| **Linux** | proactr `submit_recv/send` on worker ring | Same worker proactr ring; demux in harvest |
| **Darwin** | reactor kqueue (not proactr op_ids) | **Same reactor kq**, udata → client job cookie (or dual-wait design). **Not** proactr-only recv that never wakes `reactor_wait` |
| **Windows** | IOCP proactr | Same IOCP ring as worker |
| **CLI private runtime** | n/a | Private proactr ring only; pump until job done |

**Darwin law:** outbound TCP/UDP interest is registered on the **product reactor kq** used by `server_reactor_worker_loop`. Completions dispatch into `client_job_on_event` the same way inbound does. Soft proactr harvest alone is **not** the outbound wake path.

**Linux law:** outbound ops are proactr ops on the worker ring; one `ring_wait` harvests inbound + outbound.

**Forbidden:** assuming “same worker ring” always means co-batch on Darwin without reactor registration.

---

## 5. Architecture

### 5.1 Layers

```
CLI:  get / request  →  thread-local Client_Runtime (private ring)  →  pump
Handler: get_async(res, …)  →  worker Client_Runtime  →  CQE/reactor events

Client_Job SM (per outbound) + Stream_Slot job list (per exchange)
Transport: TCP | TLS mem-BIO | H3/QUIC
Engines: H1 | H2_Session | H3_Session (existing)
```

### 5.2 Client_Runtime

```odin
Client_Runtime :: struct {
	ring:      ^proactr.Ring,       // Linux/Windows worker or CLI private; Darwin: may be soft-only
	// Darwin: reactor handle / registration API for client fds (host-provided)
	reactor:   rawptr,              // nil on CLI; host sets for server workers
	pool:      ^Connection_Pool,    // worker-local preferred
	allocator: mem.Allocator,
	// In-flight demux: op_id or reactor_token → job (see §5.5)
	// NOT consulted on pure inbound Connection dispatch when user is known Connection*
	// Optional free-list of Client_Job shells only — not used for exchange_gone upgrade
}

// CLI / tests: process or thread-local singleton, created once, reused (PR1).
// Server: one Runtime per worker, installed at worker start (listen path).
```

**Blocking `get`:** use thread-local runtime; **never** `ring_init`/`ring_destroy` per call. Cold bar separate from warm bar.

### 5.3 Client_Job

```odin
Client_Job :: struct {
	// Exchange bind (required for handler path)
	slot:         rawptr,           // ^Stream_Slot
	exchange_epoch: u32,            // snapshot at start; see §6.2
	parent_conn:  rawptr,           // ^Connection for host helpers; demux only

	runtime:      ^Client_Runtime,
	phase:        Job_Phase,
	opts:         Options,          // owned copies of strings needed after handler returns
	// ... method, target, headers, body: **copied into job at start** (default)

	// Outstanding I/O (proactr or reactor tokens)
	ops_outstanding: int,           // Recv/Send/UDP still Submitted
	// timer ops use cancel_timeout + count

	// Buffers: live until corresponding CQE applied
	rx, tx:       []u8,

	// TLS: SSL* + mem BIOs; free only when ops_outstanding==0
	// H3: quic state; same free rule

	result:       Response,         // body job-owned until on_done consumes/destroys
	err:          Http_Error,
	done_fired:   bool,
	phase_cancel: bool,             // Cancelled

	on_done:      proc(user: rawptr, res: Response, err: Http_Error),
	// user: NOT request-temp. Copy small ctx into job or use conn/runtime allocator.
	// Arena user is forbidden (cancel may fire after conn_temp_reset).
	user:         rawptr,
	exchange_gone: bool,            // set by host cancel on teardown; maps to .Exchange_Gone
	// Pool
	pooled:       ^Connection,      // outbound client conn if from pool
	pool_checkin: bool,             // false → close on finish (dirty)
}
```

### 5.4 Public API (ergonomics — frozen names)

```odin
// CLI — unchanged signature; private/thread-local runtime pump
get :: proc(url: string, opts := Options{}, allocator := context.allocator) -> (Response, Http_Error)

// Handler — ONLY happy-path async entry (cannot omit exchange)
// Binds runtime, slot, epoch from res (Response has _conn / slot access via host helper).
get_async :: proc(
	res: ^http.Response,           // inbound response → exchange
	url: string,
	opts: Options = {},
	user: rawptr = nil,
	on_done: proc(user: rawptr, upstream: Response, err: Http_Error),
) -> (job: ^Client_Job, err: Http_Error)

request_async :: proc(res: ^http.Response, req: ^Request, opts: Options = {}, user: rawptr = nil, on_done: ...) -> ...

job_cancel :: proc(job: ^Client_Job)  // usually host-only; marks cancel
```

**No** `client_runtime_for_conn` as happy path. Host installs worker runtime at boot; `get_async` fails with **loud** `.Not_Configured` if missing (`"outbound client runtime not installed on worker"`).

**Naming:** `get_async` / `request_async` only (not `client_get_async`).

### 5.5 Demux (performance + correctness)

| Path | Demux |
|------|--------|
| Inbound Recv/Send with `user = ^Connection` | Existing dispatch — **zero** client map lookup |
| Outbound proactr op | `user = job` **or** runtime side table op_id→job filled on submit, **cleared only on harvest apply** |
| Darwin reactor | udata carries job or (kind,job) cookie |

**Forbidden:** map lookup on every inbound CQE “just in case.”

### 5.6 Blocking facade

```odin
get(...) {
	rt := thread_local_or_process_runtime()  // create once
	// async job with parent=nil, on_done stores result
	// pump rt.ring only until done
	// do NOT destroy runtime
}
```

**Server worker detection:** thread-local `http_worker_active` (set for entire worker loop).
If true, **all** blocking facade entry points (`get`, `request`, pool blocking helpers) return
`.Invalid_Use` with a fixed string in release builds (debug may assert). Tests required.

### 5.7 TLS drive law (async path only)

Normative sequence (mirror server product mem-BIO):

1. TCP connected (see §5.8).  
2. `SSL_new(shared_client_ctx)`; **mem-BIO** `SSL_set_bio` (not long-lived blocking `SSL_set_fd` drive).  
3. PT/CT split:  
   - Net ciphertext in → `BIO_write(rbio)` then `SSL_read` / `SSL_do_handshake`  
   - `SSL_write` / handshake → peek/read wBIO → **copy** ciphertext into send buffer owned until Send CQE (residual stash if peek invalidates—same law as server residual)  
4. At most one in-flight CT recv and one CT send unless full-duplex explicitly documented.  
5. `SSL_MODE_ENABLE_PARTIAL_WRITE` as needed for PT.  
6. Free SSL/BIOs only when `ops_outstanding == 0`.  
7. Verify/SNI/ALPN same semantics as current blocking dialer; PEER on SSL after new.

**CLI blocking path** may keep simpler set_fd+connect **only** on private ring thread (not shared worker).

### 5.8 Connect + DNS

| Step | CLI private ring | Server worker |
|------|------------------|---------------|
| DNS | Blocking resolve OK on private pump thread | **v1:** require IP or pre-resolved host in opts, **or** resolve on blocking helper thread and only then start job; **not** sync DNS on ring thread |
| TCP connect | Blocking connect OK on private pump, or nonblock | **Nonblocking connect**; completion via **writable**/`SO_ERROR` (reactor POLLOUT or platform equivalent)—**not** `submit_recv` readiness |

Proactr has no `submit_connect` today: Darwin uses reactor POLLOUT; Linux may use io_uring connect if available or poll-out equivalent documented per OS in PR1.

### 5.9 Cancel / outstanding ops (correctness — normative)

**Illegal:** `operation_free` while status is Submitted.

**ops_outstanding** counts **every** completable unit that can produce a CQE/event:
Recv, Send, UDP, **Timeout** (soft cancel still delivers a CQE — same class as session
`timer_pending_cqes`), reactor tokens. `finish_cancel` / free SSL / free job **only when
ops_outstanding == 0**.

```
// Law: SYNC terminal on_done on first cancel (r4 Option B).
// First cancel reason freezes while exchange liveness still matches that call.
// Harvest only frees SSL/buffers/job — never invents a second on_done.

client_job_cancel(job, exchange_gone := false):
  if done_fired: return
  if phase_cancel: return          // already terminal-notified; ignore re-entry
  phase_cancel = true
  job.exchange_gone = exchange_gone
  pool_checkin = false
  unlink_from_slot_list(job)
  job.slot = nil
  cancel_timeout(each timer)       // still counted until soft CQE
  close_fd_or_quic(job)            // force I/O CQEs; do NOT free Submitted ops
  // SYNC terminal — before return, while inbound res may still be valid if !exchange_gone
  done_fired = true
  err := .Exchange_Gone if job.exchange_gone else .Closed
  on_done(user, {}, err)           // must run before free; user may live in job shell
  if ops_outstanding == 0:
    free_transport_and_job(job)    // SSL/quic/buffers/job shell
  // else: free_transport_and_job from harvest when count hits 0

client_job_on_cqe(job, cqe):
  ops_outstanding -= 1
  clear demux entry for this op
  if phase_cancel:
    // Free only after cancel already fired on_done (done_fired)
    if ops_outstanding == 0 and done_fired: free_transport_and_job(job)
    return                         // never second on_done
  // normal phase SM …
  ...

finish_success(job):
  if phase_cancel: return          // cancel already terminal
  if done_fired: return
  done_fired = true
  on_done(user, result, .None)
  unlink if still linked
  free_transport_and_job after on_done returns (or when ops==0 if any linger)
```

**Exactly-once `on_done`:** always for `get_async` / `request_async`; **fires in cancel before return**
(or in success path). Harvest never calls `on_done` for cancelled jobs.

**Add `Http_Error.Exchange_Gone`** in PR2.

**Re-entrancy:** after first cancel, `done_fired` / `phase_cancel` → further cancel is no-op
(no sticky upgrade — first reason freezes while exchange liveness is known).

**List ownership:** unlink slot in cancel before return. Destroy never walks a job already
unlinked. Free job shell only at `ops_outstanding == 0` after terminal `on_done`.

**Cancel errors (author law):**

| Cause | `err` to `on_done` | Handler must |
|-------|-------------------|--------------|
| Inbound clean / slot free / Client_Gone / pipe destroy | **`.Exchange_Gone`** | **Not** call `respond_*` on inbound `res` |
| Outbound timeout / explicit `job_cancel` while exchange live | **`.Closed`** | May `respond_*` (e.g. Bad Gateway) |

Host passes `exchange_gone` on first cancel only; no dual-reason upgrade required.

**user pointer law (normative — Option A):**

- `user` **must not** be request-temp arena.  
- Copy small handler ctx into job at `get_async` (job free-list / runtime allocator), or pass
  conn_allocator / static / process memory.  
- Deferred `on_done` after harvest is then always safe relative to `conn_temp_reset`.

### 5.10 Pool vs cancel

| Finish reason | Pooled conn |
|---------------|-------------|
| Success, protocol idle | checkin |
| Cancel mid-request | **close**, never checkin |
| Protocol error / partial H1 request | **close** |
| H2 stream error if conn still healthy | implementation may reset stream and checkin only if proven idle; v1: **close** if uncertain |

### 5.11 Exchange epoch (ABA) + teardown coverage

Host oneshot `slot.gen` today does **not** bump every clean. Plan:

**Add `Stream_Slot.exchange_epoch: u32`** (or bump gen on every oneshot exchange start **and** clean).
H2: bump/check on that stream slot’s alloc/free paths too.

At `get_async` start: `job.exchange_epoch = slot.exchange_epoch`.  
On every CQE: if `job.exchange_epoch != slot.exchange_epoch` → treat as cancel/stale
(ignore payload, still account outstanding).

H2: bind job to **that stream’s slot**, not conn-wide list only.

**Every path that ends an exchange or destroys the pipe MUST call
`client_jobs_cancel_slot(slot, exchange_gone=true)` (or walk all used slots on the conn)
BEFORE `stream_slot_reset_exchange` / slot free / `connection_destroy`:**

| Path | When |
|------|------|
| H1 oneshot finish | `clean_request_loop` step 2 |
| H2 stream finish | `h2_host_exchange_done_slot` before slot reset |
| Peer RST / Client_Gone | same slot cancel before pad free |
| Pipe close / `connection_close` → destroy | cancel all slots’ jobs before destroy |
| Worker shutdown / conn recycle | same |

### 5.12 clean_request_loop insert order

```
1. complete hooks (arena live)
2. client_jobs_cancel_slot(slot, exchange_gone=true)
   // SYNC on_done(.Exchange_Gone) per job; user still valid (not request-temp)
   // ops may still drain after this step
3. wire clear / tls plain clear
4. conn_temp_reset
```

**Normative:** `Client_Job` storage from **runtime free-list**, never request temp arena.  
**`user` is not request-temp** (§5.9 Option A).

### 5.13 Response / request ownership (ergonomics)

| Item | Rule |
|------|------|
| URL, method, headers, body into job | **Copied** at `get_async` start (safe after handler returns) |
| `upstream` in `on_done` | Owned by callback; **must** `response_destroy` before return |
| `.Closed` / empty Response | **destroy-safe** (nil body, no double-free) |
| Valid after `on_done` returns | **No** |

### 5.14 H3

- No sleep-poll; UDP + timeouts + poll_send on platform wait owner (§4).  
- `.Auto` TCP; `prefer_h3` opt-in; `follow_alt_svc` unchanged.  
- Multi-op outstanding count for UDP recv/send/timers.

### 5.15 Redirects

Async v1: **same redirect policy as blocking** `max_redirects` (follow with new job or SM phase). Document if temporarily unsupported → hard error, not silent single-hop.

---

## 6. Performance contracts (testable)

| Bar | Test / gate |
|-----|-------------|
| Warm blocking `get` localhost | p50 ≤ 1.5× **baseline blocking client after shared TLS warm**; **exclude** first-ever ring_init; CI optional microbench in PR notes, hard fail if >2× unexplained |
| Thread-local runtime reuse | Assert ring_init count == 1 across N gets in process |
| No sleep on async path | Debug counter / forbid `time.sleep` in client job code under `CLIENT_ASYNC` |
| Darwin wake | Integration: outbound progress without relying on soft_cq-only empty poll |
| Linux co-batch | Harvest includes client op completions with inbound |
| Cancel cost | O(jobs on that **slot**), unit test |
| Inbound demux | Zero client map lookup when user is Connection* |

---

## 7. Systems-compress (unchanged intent)

| Plural | Structure |
|--------|-----------|
| Idle outbound | worker `Connection_Pool` |
| In-flight per exchange | slot job list |
| CQEs / events | batch harvest / reactor batch |
| Workers | one Runtime + pool each |

No per-request private ring on server. No process-global job registry. Job free-list at ≥2 hot call sites.

---

## 8. PR plan (re-ordered for correctness)

### PR1 — Runtime + Job SM + clear TCP + cancel skeleton + blocking facade

- Thread-local runtime for CLI `get` (http clear)  
- `ops_outstanding` cancel law  
- **No `parent` / no `get_async` yet** OR parent allowed only with full cancel+list  
- Nonblocking connect story per OS (or CLI-only blocking connect documented)  

### PR2 — `get_async(res,…)` + slot list + epoch + clean_request_loop hook

- Loud Not_Configured  
- Worker runtime install in listen/worker boot  
- Hard-fail blocking `get` on worker  
- Cancel + on_done(.Closed) tests  
- Handler example in docs  

### PR3 — TLS mem-BIO + H1/H2 on job

- Full §5.7 law  
- https parity tests  

### PR4 — H3 on platform wait (no sleep)

### PR5 — prefer_h3 optional + polish

---

## 9. Key decisions

1. Handler entry is **`get_async(res, …)`** only — exchange implicit.  
2. **`on_done` exactly once**; cancel fires **sync** with **`.Exchange_Gone` or `.Closed`**.  
3. **Job storage = runtime free-list; user must not be request-temp** (Option A).  
4. **Cancel never frees Submitted ops**; drain via close; harvest only frees transport.  
5. **Exchange = Stream_Slot + epoch**.  
6. **Darwin outbound on reactor kq**; Linux on proactr ring.  
7. **Thread-local runtime** for blocking get.  
8. **Hard-fail all blocking facade on worker**.  
9. **Request inputs copied** into job.  
10. **`.Auto` TCP**; H3 opt-in.  
11. Inbound demux unchanged (no map tax).  
12. Pool: cancel mid-flight → **close**.  
13. **First cancel freezes terminal reason** (no dual-reason upgrade).

---

## 10. Success definition

1. CLI `get` works (clear + TLS) via thread-local pump.  
2. Handler `get_async` + `on_done` → respond; cancel on inbound clean.  
3. No sleep-poll H3; no blocking SSL_connect on worker async path.  
4. Darwin/Linux harvest laws documented and tested.  
5. Docs: two APIs; ownership paragraph; APP/MIDDLEWARE outbound note.  
6. Multi-critic WOW.

---

## 11. Author quick start (frozen sketch)

```odin
// CLI
res, err := client.get("https://example.com")
defer client.response_destroy(&res)

// Handler — user must NOT be request-temp (conn_allocator / job-copied ctx)
ctx := new(Proxy_Ctx, conn_allocator)
ctx.res = res
get_async(res, "https://upstream/api", {}, ctx, proc(user: rawptr, up: client.Response, err: client.Http_Error) {
	ctx := (^Proxy_Ctx)(user)
	defer client.response_destroy(&up) // .Closed / empty is destroy-safe
	if err == .Exchange_Gone {
		return // inbound dying — do not respond
	}
	if err != .None { // .Closed = outbound cancel/timeout while exchange live
		http.respond_status(ctx.res, .Bad_Gateway)
		return
	}
	http.respond_bytes(ctx.res, up.body[:])
})
```

---

## 12. Checklist

- [x] PR1 clear TCP + thread-local + cancel skeleton  
  - `Client_Runtime` / `Client_Job` SM; demux via `Operation.user` (no op_jobs map)  
  - free-list retains buffer capacity; `live` + `in_callback`/`free_pending` (no free-list ABA)  
  - Option B sync cancel; `recv_buf` always `runtime.allocator`; result clones use caller allocator  
  - `get`/`get_proactr` thread-local pump; `use_proactr_io`; hard-fail when `http_worker_active`  
  - `get_async` shell → `.Not_Configured` until PR2; clear H1 only (no TLS/H2/H3 on proactr path)  
  - **Critics (impl r2):** code quality **WOW**, performance **WOW**  
  - Residual (documented, not PR1 blockers): body dual-buffer; blocking DNS/dial; no pool on clear path; dial timeout not applied; pool helpers lack worker Invalid_Use
- [x] PR2 get_async + slot epoch + clean hook + hard-fail get  
  - `get_async(^http.Response, …)` binds `Stream_Slot` + `exchange_epoch`; slot job list  
  - `http.Client_Bridge` (no import cycle): worker enter/leave, tagged-user CQE demux, cancel_slot/conn  
  - `clean_request_loop` / `h2_host_exchange_done_slot` / `connection_destroy` → cancel `.Exchange_Gone`  
  - Worker install on ring_init; `CLIENT_USER_TAG` demux (zero map on inbound); O_NONBLOCK after dial  
  - Darwin dual-wait when `pending_ops>0`: `ring_wait(min_complete=1)` then nonblock reactor  
  - Hard-fail blocking facade already PR1; tests: slot cancel, worker get_async, Not_Configured, tag demux  
  - **Critics (impl r3):** code quality **WOW**, performance **WOW**  
  - Residual: blocking DNS/dial on worker; dual-wait product lag vs full reactor registration; clear H1 only  
- [x] PR3 TLS mem-BIO + H1/H2  
  - `Client_Job` TLS fields; `client/job_tls.odin` mem-BIO drive (SSL_set_bio + connect_state)  
  - CT send/recv at most one each; wBIO copy into job.tx until Send CQE; free SSL only ops==0  
  - ALPN → H1 clear-style parse / H2_Session feed+take_response  
  - Empty WANT_WRITE: flush + arm recv (no busy-spin); BIO_write full-chunk or fail  
  - `get_async_runtime` / `get_proactr` / `use_proactr_io` accept https H1/H2 (reject H3)  
  - SNI/ALPN/verify same as `client/tls.odin`; PEER on SSL when secure  
  - Tests: proactr https H1, H2, async_runtime H2, cancel Option B during handshake  
  - **Critics (impl r2):** code quality **WOW**, performance **WOW**  
  - Residual: kqueue close may drop armed recv CQEs; blocking DNS/dial; GET-only body on TLS path

- [x] PR4 H3 on platform wait (no sleep)  
  - `Client_Job` H3 fields; `client/job_h3.odin` drive via `submit_recv` + `submit_timeout`  
  - Dial residual: `quic.conn_connect` may sleep during handshake; post-connect drive has **no** `time.sleep`  
  - `conn_udp_connect` for kqueue/proactr UDP readability; pump via `udp_send_raw` on connected socket  
  - Multi-op outstanding: UDP recv + software timer (PTO / request deadline); free QUIC only ops==0  
  - Unified `_job_close_fd` (TCP vs UDP); cancel Option B; body non-empty → loud `.Unsupported_Version`  
  - `get_async_runtime` / `get_proactr` / `use_proactr_io` accept `opts.version == .Http3` (https)  
  - Tests: real UDP `serve_conn`, private runtime H3, cancel free-list reclaim, source `time.sleep(` ban  
  - **Critics (impl r2):** code quality **WOW**, performance **WOW**  
  - Residual: dial sleep in `conn_connect`; GET-only; kqueue may drop armed UDP recv CQEs after close  
- [x] PR5 prefer_h3 optional + polish  
  - `Options.prefer_h3`: Auto+https try H3 first; fall through **only** if dial/start fails (no mid-exchange double GET)  
  - Short dial probe `PREFER_H3_PROBE_MS` (1.5s) via `h3_request_start(dial_timeout_ms)` / `_h3_dial`  
  - After prefer fail, skip Alt-Svc H3 same bind; `Connection.prefer_h3` survives redial  
  - `.Http3` still force-only; `follow_alt_svc` still cache-gated  
  - TLS body non-empty → loud `.Unsupported_Version`; pool worker → `.Invalid_Use` + `INVALID_USE_DIAGNOSTIC`  
  - README protocol table; async ignores redirects (v1)  
  - Tests: prefer_h3 success, TCP fallback, pool Invalid_Use, TLS body reject, predicate  
  - **Critics (impl r2):** code quality **WOW**, performance **WOW**  
- [x] API reuse F1–F3 (Hop + dialer seams + H1 Exchange)  
  - `Hop` / `Hop_Meta`: dial result with scheme/host/port/remote/negotiated/fd  
  - **Two dial seams:** `hop_dial_stream` (legacy Connection; TLS-complete OK) vs `hop_dial_clear_fd` (proactr nonblocking clear TCP only)  
  - `get_proactr` / `get_async` / `get_async_hop` use clear-FD hop + `hop_take_fd` (custom dialer honored when clear)  
  - `Connection.hop` retained; close prefers `hop_close`  
  - `Exchange` H1: `exchange_start` / `wait_headers` / `read_body` / `cancel` / `collect` / `finish`  
  - README tier diagram + residual honesty (async full-body; no chunked Exchange; H3 not Dialer-shaped)  
  - Tests: hop clear fd / take_fd / mock stream / proactr dialer count; exchange headers+body / collect / cancel / H2 reject  
- [ ] Platform harvest tests  
- [x] Docs (handler example + prefer_h3 + Hop/Exchange tiers in `client/README.md`)  
