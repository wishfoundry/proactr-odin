# Harsh critic — H2 bulk TLS P0 cursor — R2

Role: re-score after R1 IMPORTANT call-site fixes.  
**Prior:** [`CRITIC_H2_CURSOR.md`](CRITIC_H2_CURSOR.md)  
**Scope:** `pending_off` / `h2_out_off` O(1) consume; unsent ≡ `len − off` across engine + host + session.

**Date:** 2026-08-08

---

## Verdict

**PASS**

No remaining **IMPORTANT** correctness gaps on the cursor invariant for production engine / host / session paths. R1 blockers are fixed and verified in-tree. Bastion smoke is consistent with killing the per-frame front-delete tax on large H2 bodies (not a peer ranking claim).

---

## R1 → R2 fix audit

| R1 IMPORTANT | Status | Evidence |
|--------------|--------|----------|
| SSE backpressure `len(s.pending)` | **Fixed** | `http/session.odin:579` → `http2.stream_pending_len(s)` |
| Abort `clear(&s.pending)` without off | **Fixed** | `http/session.odin:773` → `http2.stream_pending_clear(s)` |
| `h2_host_stream_oneshot_done` raw len | **Fixed** | `http/h2_host.odin:907` → `http2.stream_pending_len(s) > 0` |
| Vacuous cursor test OR | **Fixed** | `http2/flow_test.odin:896–897` strict `pending_off == 32*1024` and `len(pending) == len(body)` |
| Residual flow_test `len(pending)` unsent checks | **Fixed** | `:392`, `:468`, `:749` use `stream_pending_len` |

### Production grep (post-fix)

| Pattern | `http/` production | Notes |
|---------|-------------------|--------|
| `len(s.pending)` / bare `clear(&s.pending)` | **0 hits** | Only engine consume path clears with `pending_off = 0` |
| Unsent reads | `stream_pending_len` | session BP, oneshot_done, gates tests, engine |
| Clears | `stream_pending_clear` or consume full-drain | RST/GOAWAY/refuse/session abort |

---

## Correctness checklist (cursor invariant)

| Risk | Result | Notes |
|------|--------|-------|
| Double-count window | **OK** | One debit per DATA payload in `_flush_stream_one_frame` |
| END_STREAM early | **OK** | Gated on `stream_pending_len` rem |
| Append after partial drain | **OK** | Append to end; off unchanged |
| Reaped UAF | **OK** | `frame_write` copies payload before consume/reap |
| clear without off reset | **OK (prod)** | All production clears pair with off=0 or `stream_pending_clear` |
| Host/session unsent misuse | **OK** | R1 sites fixed; no remaining prod `len(pending)` for unsent |
| RR fairness | **OK** | Eligibility uses `stream_pending_len` |

---

## CRITICAL findings

*None.*

---

## IMPORTANT findings

*None.*

---

## NIT residual

1. **Test harness `clear(&conn.h2_out)` without `h2_out_off = 0`** (`h2_host_test.odin:713, 1190, …`). Production open/consume always resets off; tests rely on defensive clamp in `h2_out_pending_len` (`h2_host.odin:697–698`). Prefer a `h2_out_clear` helper or explicit off=0 in tests.

2. **`stream_pending_len` has no stale-off clamp** (unlike `h2_out_pending_len`). Acceptable while every clear goes through `stream_pending_clear` / full-drain consume; not a live bug.

3. **Coverage gaps (non-blocking):** no unit test for (a) multi-chunk append after partial drain, (b) compact at `PENDING_COMPACT_OFF`, (c) partial SSL_write advancing `h2_out_off`. Engine large-body test now pins cursor; host path is integration/smoke only.

4. **Compact still O(remaining)** at 256 KiB dead prefix — intentional bound for SSE; not per-frame quadratic.

---

## Bastion smoke (stated; not re-run here)

Fair `-o:speed`, WORKERS=8, c=100, 10s:

| Cell | RPS (smoke) | Prior fair matrix (approx) | Read |
|------|-------------|----------------------------|------|
| h2 s64k | 6228 | ~5852 | modest lift |
| h2 s1m | 1897 | ~976 | **~2×** — matches “kill O(n²) front-delete on large body” |
| h1s s64k | 10637 | same class | control unchanged (cursor not on H1 path) |

**Honesty bounds:** single smoke, not a full four-peer fair matrix. Do not re-rank ntex/go from this alone. Directional confirmation that P0 landed where profile said memmove lived.

---

## Top remaining bulk RPS risks (post-cursor)

1. **Multi-copy H2 path** — body → `pending` → framed `h2_out` → SSL_write (cursor only removed per-frame tail memmove).
2. **Serial seal ∥ send** — seal waits send CQE; still primary live-path ceiling (`BULK_TLS_PROFILE` P1).
3. **64 KiB pull / mem-BIO CT drain** — many CQEs and BIO copies on bulk.
4. **H1 bulk materialize** — out of scope for this PR; h1s control stable as expected.

---

## Scoreboard

| Claim | R2 |
|-------|-----|
| Engine O(1) pending consume | **PASS** |
| h2_out O(1) SSL_write consume | **PASS** |
| Unsent invariant host/session | **PASS** (R1 fixed) |
| Tests pin cursor | **PASS** (strict off + dead-prefix len) |
| No IMPORTANT correctness left | **PASS** |
| Bulk RPS closed vs peers | **No** — P0 only; ~2× s1m smoke, next ceiling is seal/send + copies |

**Bottom line:** R1 FAIL conditions are closed. Cursor fix is correct across engine + host + session for unsent accounting. Ship P0; next bulk work is not more front-delete fixes.
