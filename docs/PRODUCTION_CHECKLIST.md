# Production edges checklist (PR10)

Honest multi-worker / admission / shutdown checklist for operators and
implementers. This is **not** a product capability flip (see
[`CAPABILITY_MATRIX.md`](CAPABILITY_MATRIX.md)) and **not** an app-API change
(soft admission is host behavior — see [`APP_CONTRACT.md`](APP_CONTRACT.md)).

Companion ship status: [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).  
H2 product bar (M1–M6 offline): [`design/dual-tls-h2/H2_PRODUCT_BASELINE.md`](design/dual-tls-h2/H2_PRODUCT_BASELINE.md).

---

## Checklist

| Item | Status / how |
|------|----------------|
| Soft 503 / H2 REFUSED on admission | **Done** — over `max_sessions_per_worker × thread_count`, `sse_start` / `ws_start` soft-reject with **503 Service Unavailable** (`Retry-After: 1` when unset), return `Session{}` (`id == 0`), metric `session_metrics_admission_reject` (no assert). H2 multi-slot full → `RST_STREAM(REFUSED_STREAM)` via `conn_refuse_stream`, connection stays open. Engine concurrent refuse at SETTINGS max is separate (`http2` REFUSED_STREAM after HPACK decode). Soft 503 is not a new `Session_Event_Kind`. |
| GOAWAY drain on shutdown | **Done** — feed / `fail_code` path: **GOAWAY → flush once → close** (`h2_host_emit_goaway_and_close`). Server shutdown: `Server.closing` → graceful `GOAWAY(NO_ERROR)` once (`h2_host_maybe_goaway_from_closing` / `h2_host_on_server_closing`); refuse new streams `> last_sid`; drain existing (incl. SSE) then close when idle (`h2_host_maybe_close_after_goaway_drain`). |
| Shared SSL_CTX multi-worker | **Current host model** — `server_tls_init` once per `Server` in `listen` when PEMs set; `Server.tls_provider` + `Server.tls_ctx` shared by all workers; each accept does `SSL_new` from that ctx (`tls_host_on_accept`). Freed once in serve teardown via `server_tls_destroy`. Fail → honest clear-H1 only (PEMs cleared). |
| REUSEPORT workers | **Existing host model** — `Server_Opts.thread_count` workers; each owns a `proactr.Ring` + SO_REUSEPORT listen (`server_linux` / `server_posix`). No shared accept ring. |
| Session caps | **Present** — `Server_Opts.max_sessions_per_worker` (0 → `SESSION_MAX_PER_WORKER_DEFAULT` = 4096); global live gauge vs `max_sess * thread_count`. Overflow → soft 503 (above). Related: `max_stream_buffer`, `max_stream_bytes_total`, stream pool admission. |
| H2 slot cap | **Present** — `H2_SLOT_CAP` = 8; lazy `^[H2_SLOT_CAP]Stream_Slot` only on ALPN-h2 open (clear/TLS H1 leave `h2_slots` nil). Default concurrent (`h2_serial_dispatch=false`); serial opt-in for eng/debug. Slot full → REFUSED_STREAM (above). |
| Fairness weights | **Done** — engine weighted RR (`flush_rr` / `_flush_pending_rr`); `Server_Opts.h2_weight_interactive` / `h2_weight_bulk` (defaults 2 / 1); `sse_start` marks stream interactive for RR quanta. Pipe `rr_cursor` for seal_q unchanged. |
| Firehose / M1–M6 offline gates | **CI / scripts + tests** — `scripts/check_firehose_pipe.sh` (PR5 pure seal∥send O(window)); `odin test http` includes `h2_m_gates_test` M1–M6; `odin test http2` / `hpack` / `huffman`; E0 bans via `scripts/check_e0_bans.sh` + `check_app_contract_sample.sh`. |
| **Not claimed** | **kTLS** (research only; never silent `sendfile_ok` under Ciphered). **WS-on-H2** (matrix ⏳). Full h2spec. Soft 503 on **stream pool** bytes / temp-slot admission (session-cap path is Done). Live dual-CT + bastion tls-h2 peer matrix: **Done** (see `comparisons/tls-h2/results/`). |

---

## Multi-worker TLS sketch (as built)

```text
listen(Server, PEMs…)
  └─ server_tls_init once → shared SSL_CTX + ALPN h2|http/1.1
serve(Server, handler)
  └─ for each worker 0..thread_count-1
       ├─ SO_REUSEPORT listen fd
       ├─ proactr.Ring
       └─ accept → SSL_new(shared ctx) → Handshake → Open
            ├─ ALPN http/1.1 → TLS H1 host
            └─ ALPN h2 → h2_host_* (lazy multi-slot)
shutdown / SIGINT
  └─ Server.closing → close listen
       └─ H2 conns: GOAWAY(NO_ERROR) once → drain in-flight → close when idle
```

---

## Operator notes

1. **Workers:** set `Server_Opts.thread_count` (or env `WORKERS` in harnesses). Compare peers at the same worker count ([`BENCHMARKS.md`](BENCHMARKS.md)).
2. **TLS:** PEMs on listen only (`tls_cert_pem` / `tls_key_pem` or `listen_and_serve_tls`). No handler `#if`. Missing OpenSSL dynlib or bad PEMs → clear-H1 with log.
3. **Session load:** exceeding `max_sessions_per_worker × thread_count` soft-rejects with 503 + `Session{id=0}` (metric `session_metrics_admission_reject`). Handlers must check `session_status` / `id != 0` before Effects.
4. **H2 concurrency:** at most `H2_SLOT_CAP` concurrent exchanges per connection; engine SETTINGS max concurrent is independent. Extra streams get `RST_STREAM(REFUSED_STREAM)`; connection stays open.
5. **Fairness:** optional `h2_weight_interactive` / `h2_weight_bulk` (0 → defaults 2/1) for mixed SSE + bulk under tight windows.
6. **Claims:** do not publish “production HTTPS/H2 ready” for bulk large-body or bastion H2 RPS from this checklist alone. Matrix ✅ cells remain offline-bar + eng curl for H2.

---

## Quick verify (same as status doc)

```bash
./scripts/check_e0_bans.sh
./scripts/check_app_contract_sample.sh
./scripts/check_firehose_pipe.sh
odin test http -define:ODIN_TEST_THREADS=1 -o:none   # incl. M1–M6 + PR10 soft admit / REFUSED
odin test http2 hpack huffman -o:none               # incl. weighted RR + GOAWAY refuse
```

---

## Residuals (explicit)

| Residual | Track |
|----------|--------|
| Soft 503 on stream pool / temp-slot admission (session cap is Done) | optional polish |
| kTLS / WS-H2 / bastion peer RPS / live dual-CT firehose / full h2spec | not claimed |
