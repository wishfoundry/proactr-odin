# TLS H1 — implementer notes (PR5 + PR6)

**Not a full app tutorial.** Authors use the same handler API; TLS is a listen option
(PEMs on `Server_Opts` or `listen_and_serve_tls`). Linked from
[`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md). Matrix TLS H1 **oneshot +
SSE/WS** are ✅ when OpenSSL dynlib is available; large-body bulk remains ⏳.
TLS H2 concurrent + multi-SSE are ✅ offline (PR9 M1–M6); WS-on-H2 still ⏳.

Session Effects surface: [`SESSION_SSE.md`](SESSION_SSE.md).

---

## Status snapshot

| Piece | State |
|-------|--------|
| **Pure** seal∥send + firehose CI | **Done** (`http/pipe.odin`, `http/pipe_test.odin`, `scripts/check_firehose_pipe.sh`) |
| `tls_server` dynlib + mem-BIO | Done |
| `conn.ciphered` + `plan_policy_for` | **Done** — lightweight `connection_enable_ciphered` (no seal_q/CT[2]) |
| Full SM bags (`connection_enable_ciphered_pipe_sm`) | Pure/tests only; not live host wire |
| Host wire handshake + CT send (oneshot) | **Done** — dual-CT seal∥send (`Connection.dual_ct`, `tls_seal_window` / `tls_dual_ct_try_ahead` in `http/tls_dual_ct.odin`) |
| HTTPS oneshot e2e | **Done** (manual curl; `examples/https_demo` `/`; bastion tls-h2 matrix) |
| Progressive stream / SSE / WS on TLS (PR6) | **Done** — dual-CT stream path + hangup CT recv |
| Live dual-CT seal∥send on wire | **Done** (PR5.1) — primary+hold CT slabs; pure `pipe` Seal_SM remains test-only |
| Bulk multi-MiB firehose on live TLS wire | **Partial** — bastion large-body matrix green; pure firehose CI still O(window) detector only |
| H2 / M1–M6 | **PR9 Done offline** — concurrent + multi-SSE; see `H2_PRODUCT_BASELINE.md` |

---

## Mem-BIO path (product I/O law)

Product path owns ciphertext on the wire; SSL only encrypts/decrypts:

1. `setup_mem_bios(provider, conn)` — attach memory BIOs (do **not** `set_fd` after this).
2. Inbound CT from the socket → `bio_write_net`.
3. Drive `accept` / `read` / `write` on the plaintext side.
4. Outbound CT → `bio_pending_out` + `bio_read_net` → host `submit_send`.

`set_fd` may exist on the provider as a blocking/demo fallback; it is **not** the
proactr product path. See `tls_server/provider.odin` and `tls_server/config.odin`.

Compile-time defaults:

```text
-define:HTTP_TLS_BACKEND=dynlib        # only PR5 default
-define:HTTP_TLS_DYNLIB_PATH=...       # optional explicit libssl path
```

---

## How to set PEMs

In-memory PEM slices (not paths). Empty = TLS off.

```odin
opts := http.Default_Server_Opts
opts.tls_cert_pem = cert_pem
opts.tls_key_pem  = key_pem
http.listen_and_serve(&s, handler, endpoint, opts)

// or convenience:
http.listen_and_serve_tls(&s, handler, endpoint, cert_pem, key_pem, opts)
```

On `listen`: if PEMs set, host loads `default_provider()` → `ctx_new` → `ctx_load_pem`
→ ALPN select `http/1.1`. If provider/PEM load fails: **log error, clear PEMs, serve
clear-H1 only** (honest).

Per accept: `conn_new` → `setup_mem_bios` → Handshake; on Open →
lightweight `connection_enable_ciphered` (ciphered flag + plan demotes sendfile;
**no** seal_q / pipe CT[2] — those are pure SM via `connection_enable_ciphered_pipe_sm`).

Self-signed unit material: `tls_server` / `http/tls_host_test` PEMs — not for production.
When OpenSSL dynlib is missing, tests skip (do not fail CI).

---

## Progressive stream / session path (PR6)

Long-lived SSE/WS use the **same** entry as clear H1 progressive Stream:

```text
sse_start / ws_start / stream_* effects
  → plain frames into resp_buf
  → _stream_try_submit
       if conn.ciphered || tls_ssl:
         tls_host_stream_try_submit   // encrypt path; no stream_pool slabs
       else:
         clear Wire_Kind.Stream pool path
```

| Concern | Behavior |
|---------|----------|
| Plain framing | Effects still write SSE/WS frames into `resp_buf` (gen / apply identical to clear) |
| Seal window | `resp_buf[stream_sent:]` capped at `PULL_WINDOW` → `SSL_write` |
| CT drain | wBIO → `tls_ct_tx` → `submit_send` (`.Send`); CQE advances `stream_sent` by `tls_stream_plain_n` |
| Mid-session | `tls_host_stream_long_lived` gates CT complete — **no** oneshot `clean_request_loop` |
| Hangup | `_session_arm_hangup_watch` → CT recv when Open+ssl+long-lived; single-flight `tls_ct_recv_inflight` (no double-arm / kqueue orphan); peer FIN / close_notify / unexpected app data → `.Client_Gone`; close waits for CT CQE via `close_on_io` |
| No SSL yet | `ciphered` without `tls_ssl`: mark `stream_flush_pending`, do not take clear pool |

**Honesty:** live path is **dual-CT** seal∥send (not pure-pipe `Seal_Queue` SM). Pure firehose CI
does not prove multi-MiB live TLS bulk.

Key files: `http/tls_host.odin` (`tls_host_stream_try_submit`, `tls_host_on_send_complete`,
`tls_host_stream_ct_recv`), `http/response.odin` (`_stream_try_submit` ciphered branch),
`http/session.odin` / `session_ws.odin` (hangup arm on attach).

---

## Manual HTTPS demo

```bash
odin build examples/https_demo -out:examples/https_demo/https_demo.bin -o:none
./examples/https_demo/https_demo.bin
# other terminal:
curl -k --http1.1 https://127.0.0.1:18443/
# expect: OK

curl -kN --http1.1 -H 'Accept: text/event-stream' https://127.0.0.1:18443/sse
# expect: a few event-stream frames then close (PR6 progressive CT path)
```

Requires system OpenSSL (dynlib). On Darwin, Homebrew OpenSSL@3 is probed first
(Apple system libssl is intentionally not used).

---

## Firehose CI gate (O(window) pipe)

**Pure** PR5 gate — seal∥send + firehose detector; bulk produce must stay O(window), not O(body):

```bash
./scripts/check_firehose_pipe.sh
```

**Pure** seal∥send + firehose CI: **Done**. Live dual-CT bulk is product-proven on the
bastion tls-h2 matrix; pure firehose detector remains the O(window) CI gate.

---

## Host wire (landed)

### Oneshot (PR5)

| Stage | Behavior |
|-------|----------|
| Accept | If `server_tls_live`: SSL + mem-BIO; arm CT recv; **no** clear parse yet |
| Handshake | CT → rBIO; `SSL_accept`; WANT_WRITE drains wBIO → `submit_send`; Open → lightweight `connection_enable_ciphered` |
| Recv Open | CT → rBIO; burst `SSL_read` PT into scanner (same parse path as clear) |
| Send Open | Dual-CT: window plain ≤ `TLS_SEAL_WINDOW` → `SSL_write` → CT slab; while send inflight, seal next into hold; promote on CQE (`tls_dual_ct.odin`) |
| Destroy | `SSL_shutdown` best-effort; `conn_free`; free CT scratch; `connection_disable_ciphered` |

### Progressive / session (PR6)

| Stage | Behavior |
|-------|----------|
| Stream submit | Ciphered branch of `_stream_try_submit` → `tls_host_stream_try_submit` |
| CT complete | Advance plain cursor; reflush or mid-idle arm CT hangup watch |
| Peer close | CT recv / `SSL_read` 0 / close_notify → `tls_host_session_client_gone` → `.Client_Gone` |
| End | `stream_ending` drains remaining plain then `_stream_finish` (no mid-session clean) |

Clear-H1 path is unchanged when TLS is off. No `SSL*` in app API / `APP_CONTRACT`.

---

## Tests

```bash
odin test http -define:ODIN_TEST_THREADS=1 -o:none
# PR6 gates in package http:
#   session_test — ciphered attach (SSE/WS plain apply), hangup CT gate
#   tls_host_test — long-lived stream, no-clean mid-session, ciphered-no-ssl pending
```
