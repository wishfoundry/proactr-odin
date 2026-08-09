# Harsh critic — H2 bulk TLS P0: pending / h2_out cursor

Role: adversarial correctness + performance critic for the H2 outbound body flush cursor fix.

**Scope:** eliminate O(n) front-delete `memmove` on H2 stream `pending` and connection `h2_out` SSL_write path.  
**Out of scope (as stated):** H1 bulk serial seal.  
**Profile claim:** bastion H2 s1m ~72% `memmove` from `remove_range` in `_flush_stream_one_frame`.

**Files reviewed:**

| Path | Role |
|------|------|
| `http2/flow.odin` | `pending_off`, consume, one-frame flush, RR |
| `http2/connection.odin` | stream field, `stream_pending_len` / `clear`, reap |
| `http2/flow_test.odin` | cursor + residual `len(pending)` tests |
| `http/h2_host.odin` | `h2_out_off`, flush, oneshot_done |
| `http/server.odin` | `Connection.h2_out_off` |
| `http/session.odin` | H2 SSE backpressure + abort clear |
| `http/h2_m_gates_test.odin`, `http/h2_host_test.odin` | host tests |

**Date:** 2026-08-08

---

## Verdict

**FAIL**

Core engine flush math (window debit once per frame, END_STREAM only when unsent rem is empty, `frame_write` copies payload before consume, RR uses `stream_pending_len`) is sound for bulk oneshot. The change **does not** fully migrate the new invariant:

> unsent bytes ≡ `len(buf) - off` (via `stream_pending_len` / `h2_out_pending_len`), never raw `len(buf)`.

Production host code still uses raw `len(s.pending)` and `clear(&s.pending)` without resetting `pending_off`. That is a regression class introduced by this PR, not a pre-existing curiosity. Flagship cursor test does not actually pin cursor advancement.

Ship the engine after host call-sites + tests are fixed; do not claim P0 closed while unsent length is still misread on the H2 session path.

---

## Checklist (mandated)

| Risk | Result | Notes |
|------|--------|-------|
| Double-count window bytes | **OK** | `_flush_stream_one_frame` debits `s.send_window` / `c.send_window` once per emitted payload (`flow.odin:147–149`); consume does not re-debit. |
| END_STREAM early | **OK (engine)** | `last := n == rem` with `rem = stream_pending_len` (`flow.odin:128–135`); zero-body end only when rem==0 and `!end_sent` (`:154–158`). |
| Cursor after append while partial drain | **OK (engine)** | `conn_send_body` appends to end; `pending_off` stays; unsent = tail after off. Compact copies `[off:]` then resets off. |
| Reaped stream UAF | **OK** | `frame_write` `append(dst, ..payload)` copies into `dst` (`frame.odin:57–61`) before consume/reap can free `pending`. |
| clear without off reset | **FAIL (host)** | `session.odin:772` clears pending without `pending_off = 0`. |
| tests still use `len(pending)` incorrectly | **FAIL (partial)** | Engine tests 392/468/749; host oneshot_done uses `len`; flagship OR is vacuous. |
| RR fairness regression | **OK** | `_n_pending_streams` / RR eligibility use `stream_pending_len` (`flow.odin:60, 208`). |

---

## CRITICAL findings

*None on the bulk oneshot engine path.*

No proven double window debit, premature END_STREAM under normal consume, or UAF via payload aliasing after reap.

---

## IMPORTANT findings

### 1. H2 SSE backpressure still uses raw `len(s.pending)` — false BP after cursor

**File:** `http/session.odin:578`

```odin
pending_h2 = len(s.pending)
```

After partial DATA flush, dead prefix remains until compact (`pending_off >= 256 KiB`) or full drain clear. **Unsent** is `stream_pending_len(s)`, not `len(s.pending)`.

Default soft cap is **64 KiB** (`SESSION_MAX_STREAM_BUFFER_DEFAULT`, `session.odin:35`). Compact threshold is **256 KiB** (`PENDING_COMPACT_OFF`, `flow.odin:29`). Dead prefix therefore grows under long-lived H2 SSE **without ever compacting** before the 64 KiB cap fires.

**Effect:** soft backpressure (`session_metrics_backpressure`, drop payload) triggers while true unsent may be far below `max_buf`. This is a **product regression** relative to pre-cursor semantics (where `remove_range` kept `len == unsent`).

**Fix:** `pending_h2 = http2.stream_pending_len(s)`.

---

### 2. Session abort clears pending without resetting `pending_off`

**File:** `http/session.odin:769–773`

```odin
s.failed = true
s.error_code = http2.H2_CANCEL
clear(&s.pending)
s.end_pending = false
```

Engine paths use `stream_pending_clear` (`connection.odin:661–664`) which zeros `pending_off`. Abort does not.

If `pending_off > 0` at abort and any later path `append`s to the same stream object before free/reap:

- `stream_pending_len` can report **0** while bytes sit in `pending` (`len - off < 0` → clamped to 0)
- subsequent `end_stream` can emit empty END_STREAM while body is orphaned in the buffer

Even if today’s abort always destroys the session next, this is an invariant break next to a public engine helper that already does the right thing.

**Fix:** `http2.stream_pending_clear(s)` (and ideally the same fail/close path as RST handlers).

---

### 3. `h2_host_stream_oneshot_done` uses `len(s.pending)`

**File:** `http/h2_host.odin:907–910`

```odin
if len(s.pending) > 0 {
    return false
}
return s.end_sent
```

Today full drain always `clear`s in `_stream_pending_consume` when `rem == 0` (`flow.odin:98–102`), so oneshot bulk **coincidentally** matches `stream_pending_len == 0`. That coupling is load-bearing and undocumented. Any future “keep capacity / skip clear” optimization silently freezes slot free.

**Fix:** `http2.stream_pending_len(s) > 0`.

---

### 4. Flagship cursor test does not assert the cursor

**File:** `http2/flow_test.odin:893–896`

```odin
testing.expect_value(t, stream_pending_len(s), len(body) - 32*1024)
// ...
testing.expect(t, s.pending_off == 32*1024 || stream_pending_len(s) == len(body)-32*1024)
```

The second clause of the `||` is already proven on the previous line, so the expect is **vacuous**: it never fails if `pending_off` is wrong (e.g. still 0 with a buggy clear/rebuild that still reports the same rem).

Also missing:

- assertion that payload bytes match `body[off:off+n]` across partial + WINDOW_UPDATE drain
- multi-chunk append after partial drain (`pending_off > 0` then more `conn_send_body`)
- compact path (`pending_off >= PENDING_COMPACT_OFF` with rem > 0)
- `h2_out_off` partial SSL_write consume (no unit coverage found for cursor semantics; only production path)

---

### 5. Residual engine tests still key off `len(pending)` for “has pending”

**Files:**

- `http2/flow_test.odin:392` — `len(srv.streams[1].pending) == 40` (OK only because window was 0 → nothing flushed)
- `http2/flow_test.odin:468` — `len(s1.pending) > 0 && len(s3.pending) > 0` (s1 may have dead prefix; still “> 0” but wrong helper)
- `http2/flow_test.odin:749` — same class

These will not catch a regression that keeps `len(pending)` correct while `stream_pending_len` / off desync.

---

## NIT findings

### N1. Asymmetric defensive clamp

`h2_out_pending_len` clamps a stale `h2_out_off` (`h2_host.odin:697–698`). `stream_pending_len` does not (`connection.odin:654–657`). Host tests `clear(&conn.h2_out)` without resetting off (`h2_host_test.odin:713, 1190, 1200, …`) rely on the clamp. Prefer a single clear helper that always zeros off, and avoid mutable getters.

### N2. `h2_out_pending_len` mutates on read

Clamping inside a “len” helper is surprising and can hide bugs (stale off → silent reset). Prefer assert/log in debug or fix all clear sites (`clear + off = 0`).

### N3. Compact still O(remaining) memmove

At `PENDING_COMPACT_OFF` (256 KiB), consume does `copy` + `resize` (`flow.odin:105–108`, `h2_host.odin:718–721`). Correct and rare vs per-frame `remove_range`; still a cliff for long-lived streams that sit just under full drain. Acceptable for P0; not a free lunch for SSE firehose.

### N4. Engine still materializes full body into `pending` before flush

`conn_send_body` still `append`s the entire chunk, then frames into `h2_out`, then SSL_writes. Cursor kills quadratic front-delete; it does **not** remove the extra full-body buffer copy. Expected for this PR; next bulk ceiling is elsewhere (see risks).

---

## What the engine got right

1. **Unsent accounting in flush** — `_flush_stream_one_frame` / `_n_pending_streams` / `_flush_pending_rr` / `conn_send_body` return value all use `stream_pending_len`.
2. **Full drain frees buffer** — bulk oneshot does not retain dead capacity after rem==0 (`flow.odin:98–102`).
3. **Window debit order** — debit then consume; no second debit on cursor advance.
4. **END_STREAM gating** — tied to unsent rem, not raw `len(pending)`.
5. **`stream_pending_clear` API** — correct; RST / GOAWAY / refuse paths in `connection.odin` use it.
6. **`frame_write` copy** — eliminates pending-slice lifetime coupling.
7. **h2_out mirror** — same consume/clear/compact shape; partial SSL_write advances off only by `ret` bytes.

---

## Top remaining risks for bulk RPS (after this P0)

1. **Still ≥2 full-body copies on H2 path** — handler body → `stream.pending` → framed `h2_out` → SSL_write. Cursor removes per-frame memmove of the tail; peak bandwidth still pays materialize + frame gather. Expect memmove/copy share to drop sharply but not to ntex/go levels alone.
2. **Serial seal ∥ send (P1 in `BULK_TLS_PROFILE.md`)** — `seal_calls ≈ body/64KiB`; SSL_write waits on send CQE. Dominates once buffer churn is gone.
3. **Pull window / CT drain** — 64 KiB PT window and mem-BIO CT copies (P3/P4) remain.
4. **H1 bulk materialize** — out of scope here; still the H1s bulk tax.
5. **Host invariant drift** — any remaining `len(s.pending)` / bare `clear(&pending)` will mis-measure backpressure or desync off under load; treat as merge blockers for follow-ups.

---

## Required fixes before PASS

| # | Change | File |
|---|--------|------|
| 1 | Backpressure uses `stream_pending_len` | `http/session.odin:578` |
| 2 | Abort uses `stream_pending_clear` | `http/session.odin:772` |
| 3 | Oneshot done uses `stream_pending_len` | `http/h2_host.odin:907` |
| 4 | Assert `pending_off == 32*1024` (no vacuous OR); add append-after-partial + optional compact test | `http2/flow_test.odin` |
| 5 | RR/pending expects → `stream_pending_len` | `http2/flow_test.odin:392,468,749` |

Optional: reset `h2_out_off` on every test `clear(&conn.h2_out)`; or provide `h2_out_clear` helper.

---

## Scoreboard (honest)

| Claim | Assessment |
|-------|------------|
| Kill O(n) `remove_range` on stream DATA flush | **Engine: yes** — no remaining `remove_range` on `pending` / `h2_out` in tree |
| Same class of fix for SSL_write path | **Yes** — `h2_out_off` + consume |
| Defensive clamp if h2_out cleared without off | **Present** — mutates on read; tests depend on it |
| Tests updated / new large-body test | **Partial** — helpers updated in many places; cursor test weak; host/session not fully migrated |
| 34 http2 + 159 http tests pass | **Believed as stated; not re-run in this review** — does not prove unsent invariant |

**Bottom line:** engine cursor design for bulk oneshot is correct and is the right P0. **FAIL** until host `len(s.pending)` / bare-clear call sites and non-vacuous tests land. Without those, long-lived H2 and any failed-stream edge can violate the invariant the engine just introduced.
