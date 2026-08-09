# Harsh critic — ciphered H1 oneshot: no full-body materialize for single Static/Bytes

Role: adversarial correctness review of the ciphered H1 oneshot **heading + borrowed body** plain cursor (split PT), replacing full O(body) materialize for single Static/Bytes.

**Intent:** format heading only into `resp_buf`; seal `tls_plain_rest` then borrowed `tls_plain_body` through existing windowed SSL_write / dual-CT path.

**Claimed non-goals:** metrics path behavior, multi-cmd still materializes, H2 path unchanged.

**Date:** 2026-08-08

**Files reviewed:**

| Path | Role |
|------|------|
| [`http/response.odin`](../../../http/response.odin) | `response_send_got_body` ciphered single-cmd borrow arm; materialize / HEAD / clean |
| [`http/tls_host.odin`](../../../http/tls_host.odin) | `tls_plain_*`, `tls_host_seal_oneshot_window`, `tls_host_flush_response`, send-complete continue |
| [`http/server.odin`](../../../http/server.odin) | `tls_plain_rest` / `tls_plain_body` / `tls_plain_body_off` |
| [`http/tls_host_test.odin`](../../../http/tls_host_test.odin) | rest-only + rest→body + cross-part advance unit tests |
| [`http/conn_slab.odin`](../../../http/conn_slab.odin) | free-list / destroy plain clear + temp reset order |
| [`http/plan.odin`](../../../http/plan.odin) | Static/Bytes cmd constructors / flags |
| Bench harness | [`comparisons/tls-h2/proactr/main.odin`](../proactr/main.odin) process-static payloads |

---

## Verdict

**FAIL**

Cursor math, Content-Length pairing, HEAD exclusion, multi-cmd / H2 fall-through, and happy-path `clean_request_loop` ordering are **sound**. Cross-part `tls_plain_advance` is correct and unit-tested.

The change is **not** lifetime-safe relative to the pre-existing **single** `body_set` / materialize contract on ciphered H1:

> Before: every ciphered oneshot Static/Bytes **copied** body into permanent `resp_buf` inside `respond` (handler-return-safe).  
> After: single Static/Bytes **aliases** handler bytes until **CT complete** (`clean_request_loop`), while `body_set_bytes` still documents materialize copy.

That is a silent UAF class for stack buffers and any heap freed after `respond` returns — the default exclusive body API on TLS. Process-static and request-temp bodies remain OK only because of careful clean order, not because the host pins or copies.

Do not ship as a pure perf win until the public body contract is honest (and preferably `.Owned` / non-static Bytes still materialize or are rejected).

---

## Architecture (what landed)

```text
response_send_got_body (ciphered H1, !HEAD, !stream, !h2, cmd_count==1, Static|Bytes):
  format heading → resp_buf[:hlen]          // permanent conn_allocator
  tls_plain_rest  = heading view
  tls_plain_body  = c.bytes                 // BORROW — no memcpy
  tls_plain_body_off = 0
  tls_host_flush_response → windowed SSL_write / dual-CT (unchanged engine)

else (multi-cmd, File, HEAD, stream, clear H1, etc.):
  _response_materialize_cmds  (or writev/sendfile on clear optimize)
  tls_plain_rest = full buf; tls_plain_body = nil

tls_plain_window:
  contiguous view of rest OR body tail — never spans part boundary
tls_plain_advance(n):
  consume rest first, then body_off
seal_oneshot_window:
  SSL_write(window) → advance(consumed) with consumed ≤ |window|
```

Multi-CQE: remaining plain stays in `tls_plain_*`; hold seal while CT inflight reuses same cursor.

---

## Checklist (mandated)

| Risk | Result | Notes |
|------|--------|-------|
| 1. Body lifetime until seal/CT complete | **FAIL (CRITICAL)** | Host holds `tls_plain_body` until `clean_request_loop` (after last CT CQE), not merely until first `SSL_write`. Handler returns from `respond` after first flush arm. **Process-static OK. Request-temp OK** (`tls_plain_clear` before `conn_temp_reset` in clean). **Stack / free-after-respond UAF** — regression vs prior always-materialize ciphered path. |
| 2. Content-Length matches body | **OK** | `body_len := len(c.bytes)` → `_response_format_heading(r, body_len, …)`; seal consumes exactly that slice (or nil if `body_len==0`). Same CL helper as materialize. |
| 3. HEAD does not leak body | **OK** | Borrow arm gated on `!_response_is_head(conn)`. HEAD falls through to materialize (headers + CL, no body copy). |
| 4. Cross-part SSL_write advance | **OK** | Window stops at part boundary; `consumed` clamped to `win`; advance rest-then-body. Unit: `test_tls_plain_rest_then_body_cursor`, `test_tls_plain_advance_across_parts`. |
| 5. clean / destroy clears body view | **OK (happy)** / **IMPORTANT (destroy order)** | `clean_request_loop` → `tls_plain_clear` **before** temp reset. Free-list zero + `tls_host_conn_destroy` clear. **Destroy:** `connection_destroy` calls `conn_temp_reset` **before** `tls_host_conn_destroy`/`tls_plain_clear` — dangling alias window (no further seal after `close_on_io`, but pointer hygiene is wrong). |
| Multi-cmd still materializes | **OK** | Requires `r._cmd_count == 1`. |
| H2 path unchanged | **OK** | H2 returns at top of `response_send_got_body` before H1 wire assembly. |
| Metrics / plan_wire materialize count | **IMPORTANT** | Borrow arm intentionally skips `plan_wire_inc_materialize`. `path_metrics_note_req` still fires when last plain is sealed (may precede final CT CQE) — pre-existing dual-CT timing. |

---

## CRITICAL findings

### C1 — Single-cmd ciphered borrow breaks prior materialize safety for `body_set`

**Mechanism**

1. Pre-change ciphered path always hit `_response_materialize_cmds` (comment still says “Ciphered: materialize only” at `response.odin` ~1918, then the new arm contradicts it).
2. Materialize copied Static/Bytes into permanent `resp_buf` **before** `respond` returned → stack/local/`free` after `respond` was safe.
3. New arm (`response.odin` ~1944–1985) sets `conn.tls_plain_body = c.bytes` and returns after `tls_host_flush_response`, which typically leaves remaining plain for later CQEs (large bodies; dual-CT).
4. Public API still claims copy-at-send:

```odin
// body_set_bytes — response.odin:407
// Borrowed for response lifetime; materialize copies into resp_buf at send.
```

```odin
// body_set_str — response.odin:415
// Safe: materialize copies; we do not mutate the string bytes.
```

5. Clear-H1 single Static still materializes (`n_mem >= 2` required for writev). **Ciphered exclusive `body_set` is the first default path that borrows a single body without copy.**

**UAF shapes**

| Source | Valid until CT complete? |
|--------|---------------------------|
| `#load` / string literal / process-static (bench `g_p4k` / `g_p1m`) | Yes |
| `context.temp_allocator` / request scrap (`respond_file`, `/_matrix/stats`) | Yes — clean clears plain before `conn_temp_reset` |
| Stack buffer / function-local array | **No** — dead after handler returns |
| Heap freed by handler after `respond` | **No** |
| `body_bytes(..., owned=true)` if caller frees after respond (flag implies free-after-send; host never frees, previously copy saved them) | **No** |

**Why CRITICAL (not doc nit):** silent change of the primary oneshot body API on TLS; dual-CT guarantees seal continues after the handler stack is gone.

**Fix shape (normative — pick one)**

1. **Honest + safe default:** borrow only when `Static` **or** `.Borrowed` with an explicit “live until clean” contract; **materialize** `.Owned` Bytes and anything not marked static; update `body_set_*` comments to match writev LIFETIME (`response.odin` ~1382–1387).  
2. **Or** keep always-copy for Bytes; borrow only process-static Static.  
3. **Or** pin/copy into resp_buf when `len(body)` is small and borrow only above a threshold (document threshold).

Until then, treat ciphered single `body_set` of non-static data as **unsafe**.

---

## IMPORTANT findings

### I1 — Stale “Ciphered: materialize only” comment

`response.odin` ~1918 still documents ciphered as materialize-only immediately above the new non-materialize arm. Misleading for the next reader / critic.

### I2 — `connection_destroy` resets request arena before clearing plain views

```odin
// conn_slab.odin connection_destroy
conn_temp_reset(c)          // first — invalidates temp-backed body bytes
...
tls_host_conn_destroy(c)    // tls_plain_clear last
```

Happy path (`clean_request_loop`) orders clear → temp reset correctly. Destroy path leaves a dangling `tls_plain_body` alias until clear. Today `close_on_io` aborts further seal, so this is hygiene / ASAN noise, not a proven mid-seal UAF — still invert the order.

### I3 — No integration test that SSL_write consumes rest then body

Unit tests cover cursor arithmetic without OpenSSL. Missing: seal_oneshot_window / flush with split plain (heading PT + body PT, partial SSL_write, dual-CT hold sealing body while heading CT inflight). Cursor tests are necessary but not sufficient for BIO/record edge cases.

### I4 — Metrics / counters

- Borrow path does **not** increment `plan_wire_materialize_total` (intentional; comment “do not count full-body materialize”).
- `path_metrics_note_ssl_write` still counts PT at successful SSL_write (including body windows).
- `path_metrics_note_req` can tick when plain is exhausted while last CT is still on the wire (pre-existing dual-CT).

### I5 — Multi-cmd / File / streaming / H2

As required: multi-cmd and File fall through to materialize; streaming excluded; H2 early-return unchanged. No finding.

---

## Non-findings (checked OK)

- **CL vs body length:** single source `len(c.bytes)` for heading and borrowed slice.
- **HEAD:** excluded from borrow; materialize strips body.
- **Empty body:** `body_len==0` → `tls_plain_body=nil`, heading-only seal.
- **Part boundary:** SSL_write never fed a straddling window; advance clamps and rest-then-body.
- **Materialize path reset:** full-buffer ciphered path nils `tls_plain_body` before setting `tls_plain_rest = buf`.
- **Keep-alive reuse:** free-list zeros plain fields; clean clears before next request.

---

## Test coverage snapshot

| Test | Pins |
|------|------|
| `test_tls_host_ciphered_plan_and_flush_cursor` | rest-only window/advance/clear |
| `test_tls_plain_rest_then_body_cursor` | heading then body; partial body; over-advance; clear |
| `test_tls_plain_advance_across_parts` | single advance straddling rest→body |

**Gaps:** live SSL_write split; CT complete before temp reset; regression that stack body is unsafe (or a materialize-for-Owned test).

---

## Bottom line

| Item | Status |
|------|--------|
| Cursor / CL / HEAD / multi-cmd / H2 | Sound |
| Host clean order (happy path) | Sound for static + request-temp |
| Lifetime vs prior ciphered single `body_set` | **CRITICAL regression** |
| Ship? | **No** until contract + Owned/stack policy fixed |

**Verdict: FAIL** — CRITICAL lifetime contract bug (C1). No CRITICAL Content-Length or HEAD leak found.
