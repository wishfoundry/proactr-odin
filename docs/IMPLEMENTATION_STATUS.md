# Implementation status (Plan A R4)

Honest ship status for the dual-TLS/H2 track. This is **not** a capability calendar
(see [`CAPABILITY_MATRIX.md`](CAPABILITY_MATRIX.md) for author-facing ⏳/✅). Design
specs live under `docs/design/dual-tls-h2/` and are **not** product claims.

**Product H2 (PR9):** offline M1–M6 gates are green (concurrent unary, deferred
bodies + fair RR flush, duplex recv re-arm, peak on-wire O(window), multi-SSE +
RST → Client_Gone). Matrix TLS H2 oneshot / concurrent unary / SSE cells are ✅.
**Still not claimed:** WS-on-H2, full h2spec. Bastion tls-h2 peer matrix + live
dual-CT bulk: **Done** (`comparisons/tls-h2/results/`). Baseline:
[`design/dual-tls-h2/H2_PRODUCT_BASELINE.md`](design/dual-tls-h2/H2_PRODUCT_BASELINE.md).

TLS H1 covers **oneshot + long-lived SSE/WS** on the progressive ciphered stream
path with **live dual-CT** seal∥send (`http/tls_dual_ct.odin`). Pure-pipe firehose
CI remains the O(window) detector (not a substitute for bastion RPS).

Companion freeze gates: [`PHASE0_E0.md`](PHASE0_E0.md). Enforcement scripts:
`scripts/check_e0_bans.sh`, `scripts/check_app_contract_sample.sh`,
`scripts/check_firehose_pipe.sh` (PR5 O(window) pipe).

Implementer TLS notes (not app-facing): [`TLS_H1.md`](TLS_H1.md).  
Session / Effects (SSE first): [`SESSION_SSE.md`](SESSION_SSE.md).  
H2 engine sans-I/O (PR7) + product notes: [`H2_ENGINE.md`](H2_ENGINE.md).  
Production edges (PR10): [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md).

---

## Plan A R4 scorecard

| Item | Status |
|------|--------|
| E0.1–E0.3 docs | **Done** — `APP_CONTRACT.md`, `MIDDLEWARE_CONTRACT.md`, `CAPABILITY_MATRIX.md` |
| E0.4 same-handler CI | **Done (clear H1)** — sample = `examples/empty_ok`; TLS H1 same-handler CI not yet wired |
| E0.5–E0.7 example bans | **Done** — enforced by `scripts/check_e0_bans.sh` |
| E0.8 plan tables | **Done** — `http/plan_test` E0.8 section |
| PR1 Plan_Context 4-field | **Done** — public `Plan_Context` four fields + host meters separate; tests |
| PR2 Stream_Slot | **Done (N=1)** — `Response` + session + progressive stream on `Stream_Slot`; `Loop` is `req` only; clear-H1 wire still `Connection.wire` |
| PR4 pipe POD | **Done** — types + pure tests; `Wire_Conn_State` thin (`q` nil on clear-H1); **not** on clear-H1 hot path |
| **PR5 pure seal∥send + firehose CI** | **Done** — pure `pipe_seal_step` / mock seal∥send / dual CT; firehose detector + 4 MiB windowed bulk sim; CI gate `scripts/check_firehose_pipe.sh` |
| **PR5 tls_server (dynlib mem-BIO)** | **Done** — OpenSSL via `core:dynlib`, product path `setup_mem_bios` + BIO net R/W; set_fd fallback only |
| **PR5 host ciphered + plan_policy** | **Done** — `Connection.ciphered`, lightweight `connection_enable_ciphered` (no seal_q/CT[2]), `plan_policy_for` no sendfile / pull-window unit; full SM bags via `connection_enable_ciphered_pipe_sm` (pure/tests) |
| **PR5 TLS host wire (handshake + ciphered send)** | **Done (HTTPS H1 oneshot)** — mem-BIO accept/handshake/Open; CT recv → SSL_read → scanner; response → dual-CT seal∥send (`dual_ct` + `tls_seal_window`); ALPN http/1.1; bastion tls-h2 matrix + `examples/https_demo` |
| **PR5 live dual-CT seal∥send on wire** | **Done** — `http/tls_dual_ct.odin`; oneshot/stream/H2 share seal engine; pure `connection_enable_ciphered_pipe_sm` remains test-only |
| **PR6 TLS H1 SSE / WS wire** | **Done** — same App Contract (`sse_start` / `ws_start` / Effects); progressive ciphered stream via `_stream_try_submit` → `tls_host_stream_try_submit`; hangup CT recv single-flight (`tls_ct_recv_inflight`; re-arm only after CQE); close defers on CT recv like wire send; fail-closed CT drain after `SSL_write`; session tests ciphered attach + hangup gate + inflight arm; mid-session CT complete does **not** oneshot-clean |
| PR5/PR6 bulk on live TLS wire | **Partial** — bastion large-body matrix green (dual-CT + 256 KiB seals); pure firehose CI remains O(window) only |
| **PR7 H2 engine sans-I/O** | **Done** (engine unit surface) — packages `http2/` (`conn_feed` / flow-aware `conn_send_*`), `hpack/`, `huffman/`; offline unit tests (frame + connection + flow + strict subset). Residuals: inbound FC is 1:1 auto-credit (not recv windows); HPACK encoder is static/literal only; not full h2spec. See [`H2_ENGINE.md`](H2_ENGINE.md) |
| **PR8 eng unary H2 host** | **Done** (superseded as product by PR9) — ALPN prefer `h2` / fallback `http/1.1`; after TLS Open, `h2` → `h2_host_*`; lazy multi-slot; GOAWAY on feed fail; oneshot via `server.handler` / `respond`. Serial remains opt-in (`h2_serial_dispatch=true`) for eng/debug |
| **PR9 H2 product / M1–M6 / SSE-on-H2** | **Done (offline product bar)** — default concurrent unary (`h2_serial_dispatch=false`); multi-slot dispatch; fair RR flush (`Http2_Connection.flush_rr` / `_flush_pending_rr`); duplex CT recv re-arm; multi-SSE + RST → Client_Gone; gates `http/h2_m_gates_test.odin` M1–M6. Baseline: [`H2_PRODUCT_BASELINE.md`](design/dual-tls-h2/H2_PRODUCT_BASELINE.md). **Not** WS-on-H2; **not** bastion RPS peer matrix; **not** full h2spec |
| **PR10 multi-worker / production edges** | **Done** — [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md). Shared SSL_CTX once per Server + REUSEPORT workers; session caps (`max_sessions_per_worker`) + soft 503 / H2 `RST_STREAM(REFUSED_STREAM)` on admission; graceful GOAWAY drain on `Server.closing`; optional `h2_weight_interactive` / `h2_weight_bulk` (default 2/1). **Not claimed:** kTLS, WS-H2, bastion peer RPS; soft 503 on stream-pool bytes admission remains optional polish |

---

## What “landed” means (honesty notes)

### Phase 0 (E0.*)

- Docs and plan-policy tests are real merge artifacts.
- E0.5–E0.7 fail the tree if examples/README reintroduce duals (`check_e0_bans.sh`).
- E0.4 is **sample designated + scripted check** for clear H1; multi-protocol same-handler
  CI for TLS H1 is still a host/repo choice.

### PR2 (exchange Response on slot)

`Stream_Slot` owns **`res: Response`**, session attach/pad/gen, and progressive stream
markers. `Loop` is **`req` + conn only**. Clear-H1 byte schedule still uses
`Connection.wire` (`Wire_State`).

### PR4 (POD) → PR5 (seal∥send physics)

**Pure** seal∥send physics (dual CT, seal_n, mock seal driver, dual high-water, firehose
fail detector) are **Done** and CI-gated. `Seal_Queue` + pipe CT[2] are heap-allocated
only via `connection_enable_ciphered_pipe_sm` (or explicit `wire_conn_enable_seal_q` /
`tls_pipe_alloc_buffers`); clear-H1 and live oneshot/session keep `q == nil` / `bufs == nil`.

**Live** HTTPS is **dual-CT** seal∥send (`Connection.dual_ct` primary+hold slabs,
`tls_seal_window` / `tls_dual_ct_try_ahead`). Pure-pipe `Seal_Queue` + mock SM remain
test-only (`connection_enable_ciphered_pipe_sm`); do not confuse pure CI with live path.

### PR5 (TLS host wire — HTTPS H1 oneshot)

| Layer | Reality |
|-------|---------|
| `tls_server` | Dynlib OpenSSL + mem-BIO API; unit smoke (skips if no libssl) |
| Host cipher flag | Lightweight `connection_enable_ciphered` → `conn.ciphered` + plan_policy + TLS PT high-water |
| Host wire | **Live dual-CT** — accept → SSL mem-BIO → Handshake→Open → seal window + hold while send inflight |
| Pure seal∥send | **Done** (tests + `check_firehose_pipe.sh`); not wired to product send |
| Manual e2e | `curl -k --http1.1 https://127.0.0.1:18443/` → `200` / `OK` (`examples/https_demo`) |
| Clear H1 | Unchanged when PEMs empty or provider load fails (honest log + clear-H1 only) |

### PR6 (TLS H1 progressive stream / session)

| Layer | Reality |
|-------|---------|
| Entry | `_stream_try_submit`: if `conn.ciphered` or `tls_ssl` → `tls_host_stream_try_submit` (no clear pool slabs; no plain-send bypass) |
| Seal | Window plain from `resp_buf[stream_sent:]` ≤ `PULL_WINDOW` → `SSL_write` → drain wBIO → `tls_ct_tx` → `submit_send` |
| CQE | Advance `stream_sent` by `tls_stream_plain_n`; mid-session **does not** `clean_request_loop` |
| Hangup | Session attach / mid-idle arms **CT recv** when Open+ssl; peer FIN / close_notify / unexpected PT → `.Client_Gone` |
| App Contract | Same `sse_start` / `ws_start` / Effects as clear H1; listen PEMs only (no handler `#if`) |
| Tests | `odin test http` — ciphered attach (SSE/WS effects → plain `resp_buf`), hangup CT gate, stream long-lived / no-clean mid-session |
| Manual | `examples/https_demo` `/` oneshot + `/sse` long-lived (`curl -kN … /sse`) |
| Not yet | Pure-pipe multi-MiB firehose as *live* CI job, CI same-handler TLS job |

See [`TLS_H1.md`](TLS_H1.md) for PEM knobs, progressive path, and demo commands.

### PR7 (H2 engine sans-I/O)

| Layer | Reality |
|-------|---------|
| Packages | `http2/` frames + **`conn_feed` / flow-aware `conn_send_*` / flow**; `hpack/` full decoder + simple encoder; `huffman/` Appendix B |
| Sans-I/O connection | **Done** — `Http2_Connection`, `conn_feed`, `conn_send_headers`/`body`/`request`/`response` (all window-aware), `conn_take_request`, loopback + strict unit tests |
| Frame size | Local `SETTINGS_MAX_FRAME_SIZE` on decode; peer max on outbound DATA flush |
| Concurrent refuse | HPACK-decode then `RST_STREAM(REFUSED_STREAM)` (table stays in sync) |
| Memory defaults | Server `conn_init`: `max_body_bytes=1MiB`, `max_header_bytes=64KiB` (0 after init = unbounded); client + server reap closed+delivered/failed streams |
| Tests | `odin test http2` / `hpack` / `huffman` offline — **strict unit subset, not full h2spec** |
| Residual limits | Inbound FC = 1:1 auto WINDOW_UPDATE (not peer-throttle recv windows); HPACK encoder does not dynamic-index; no full h2spec suite |

### PR8 (H2 host foundation) → **PR9 (product concurrent + SSE)**

| Layer | Reality |
|-------|---------|
| ALPN | Prefer `h2`, fallback `http/1.1` (`alpn_select_h2_or_http11`); after Open, `alpn_is_h2` → `h2_host_on_open` else H1 |
| Host | `http/h2_host.odin` — `conn_feed` / `conn_send_response` / windowed `SSL_write` of `h2_out`; lazy multi-slot `^[H2_SLOT_CAP]Stream_Slot` on open |
| Dispatch | **Default concurrent** (`h2_serial_dispatch=false`); opt-in serial for eng/debug |
| Fairness | Engine `flush_rr` + `_flush_pending_rr` on conn WINDOW_UPDATE / SETTINGS window growth |
| Errors | Feed error / `fail_code` → `goaway_write(last_peer_sid, code)` → flush once → close |
| Duplex | Re-arm CT recv after H2 send complete; flush does not unarm recv (M4) |
| Request | Pseudos → `Request` (version **1.1** for handler compat); body via `_pre_body` |
| Response | `respond` → if `h2_active`: HPACK `:status` + headers + body DATA (not H1 wire) |
| SSE | Multi-slot `sse_start` / Effects; peer RST → `.Client_Gone` once (M6) |
| Tests | `odin test http` — `h2_host_test` + **`h2_m_gates_test` M1–M6**; `odin test http2` RR/flow |
| Baseline | [`design/dual-tls-h2/H2_PRODUCT_BASELINE.md`](design/dual-tls-h2/H2_PRODUCT_BASELINE.md) |
| Explicit non-claims | **Not** WS-on-H2; **not** bastion multi-stream RPS peer matrix; **not** full h2spec; large-body live bulk still ⏳ |

### PR10 (multi-worker + production edges)

| Layer | Reality |
|-------|---------|
| Checklist | **Done** — [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md) |
| Shared SSL_CTX | **Done** — `server_tls_init` once in `listen`; all workers share `Server.tls_ctx`; per-conn `SSL_new`; free on serve teardown |
| REUSEPORT | **Done** — existing `thread_count` workers, each SO_REUSEPORT listen + own ring |
| Session / H2 caps | **Present** — `max_sessions_per_worker` (default 4096); `H2_SLOT_CAP=8` lazy multi-slot |
| Fairness weights | **Done** — engine weighted RR (`flush_rr`); `Server_Opts.h2_weight_interactive` / `h2_weight_bulk` (default 2/1); `sse_start` marks stream interactive; seal `rr_cursor` unchanged |
| Soft 503 / H2 REFUSED admission | **Done** — session overflow → 503 + `Session{id=0}` + `session_metrics_admission_reject` (no assert); H2 multi-slot full → `RST_STREAM(REFUSED_STREAM)`, conn stays open (engine SETTINGS refuse still separate) |
| GOAWAY on feed fail | **Done** (PR8/PR9) — `goaway_write` → flush → close |
| GOAWAY drain on shutdown | **Done** — `Server.closing` → graceful `GOAWAY(NO_ERROR)` once + refuse new streams + drain-idle close (`h2_host_maybe_goaway_from_closing` / `h2_host_on_server_closing`) |
| Offline gates | Firehose + M1–M6 scripts/tests green (PR5/PR9); PR10 soft-admit / REFUSED / weighted RR unit coverage in `http` + `http2` tests |
| Explicit non-claims | kTLS; WS-on-H2; bastion multi-stream peer RPS; soft 503 on stream-pool bytes / temp-slot admission (optional) |

### Product surface today

- Clear HTTP/1.1 host path (scaffold / greenfield quality — see root README).
- **HTTPS H1 oneshot + long-lived SSE/WS** when OpenSSL dynlib loads and PEMs are set
  (`Server_Opts.tls_*_pem` or `listen_and_serve_tls`). Same handler API as clear H1.
- **TLS H2** (ALPN `h2`): concurrent unary + multi-SSE offline product bar (M1–M6).
  Same handler API; stream ids stay host-private. WS-on-H2 and live RPS matrix still ⏳.
- Large-body TLS bulk / dual-CT: **product-proven** on bastion tls-h2 matrix; residual mem-BIO multi-copy / kTLS later.
- Multi-worker TLS is the existing REUSEPORT + shared SSL_CTX host model. Soft session
  admission, H2 slot REFUSED, GOAWAY drain on shutdown, and optional fairness weights are
  landed host/operator edges (not matrix cells) — see [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md).

---

## Quick verify

```bash
./scripts/check_e0_bans.sh
./scripts/check_app_contract_sample.sh
./scripts/check_firehose_pipe.sh   # PR5: firehose tests present + odin test http
odin test http -define:ODIN_TEST_THREADS=1 -o:none
# ↑ covers PR6 session TLS + PR9 h2_host + M1–M6 gates
odin test tls_server -o:none   # skips if no system libssl

# PR7 H2 engine offline (+ PR9 fair RR / peak window tests):
odin test http2   -o:none
odin test hpack   -o:none
odin test huffman -o:none

# Manual HTTPS oneshot + SSE + H2 probe (OpenSSL present; not RPS matrix):
odin build examples/https_demo -out:examples/https_demo/https_demo.bin -o:none
./examples/https_demo/https_demo.bin &
curl -k --http1.1 https://127.0.0.1:18443/
curl -kN --http1.1 -H 'Accept: text/event-stream' https://127.0.0.1:18443/sse
curl -k --http2 https://127.0.0.1:18443/
```
