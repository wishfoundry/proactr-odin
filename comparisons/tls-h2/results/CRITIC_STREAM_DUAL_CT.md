# Harsh critic — progressive TLS stream dual-CT ahead-seal

Role: adversarial correctness review of **progressive stream / SSE / WS** live dual-CT seal∥send  
(per-slab `tls_ct_*_plain_n`, `tls_host_stream_plain_off`, ahead-seal while CT send inflight).

**Intent:** while one stream CT sock send is in flight, seal the next plain window into the free CT slab; advance `stream_sent` only after the CT for that plain is fully delivered; never double-encrypt the same plain.

**Prior dual-CT context:** [`CRITIC_DUAL_CT.md`](CRITIC_DUAL_CT.md), [`CRITIC_DUAL_CT_R2.md`](CRITIC_DUAL_CT_R2.md) (oneshot/H2/HS; stream was still serial at R2).

**Date:** 2026-08-08

**Files reviewed:**

| Path | Role |
|------|------|
| [`http/tls_host.odin`](../../../http/tls_host.odin) | `tls_host_stream_plain_off`, `tls_host_seal_stream_window`, `tls_host_try_seal_hold_stream`, `tls_host_stream_try_submit`, long-lived branch of `tls_host_on_send_complete` |
| [`http/server.odin`](../../../http/server.odin) | `tls_ct_tx_plain_n` / `tls_ct_hold_plain_n` / `tls_stream_plain_n` |
| [`http/tls_host_test.odin`](../../../http/tls_host_test.odin) | stream dual-CT / plain_n unit tests |
| [`http/response.odin`](../../../http/response.odin) | `_stream_try_submit` ciphered branch; `_stream_compact_delivered`; `_stream_finish` |
| [`http/wire.odin`](../../../http/wire.odin) | CT CQE → `tls_host_on_send_complete` (`.Send`); clear stream compact path |
| [`http/pipe.odin`](../../../http/pipe.odin) | `TLS_SEAL_WINDOW_DEFAULT` (256 KiB), `TLS_CT_SLAB_DEFAULT` (272 KiB) |

**PASS bar (mandated):** no **CRITICAL** double-encrypt of the same plain, and no **CRITICAL** wrong `stream_sent` advance under dual-CT ahead-seal.

---

## Verdict

**PASS**

No **CRITICAL** double-encrypt and no **CRITICAL** wrong `stream_sent` on the reachable progressive dual-CT ahead-seal machine.

Happy-path seal∥send is correctly wired:

1. Next `SSL_write` plain starts at `tls_host_stream_plain_off` = `stream_sent + tls_stream_plain_n + tls_ct_tx_plain_n + tls_ct_hold_plain_n` (not bare `stream_sent`).
2. Per-slab `plain_n` is set on the slab that owns the CT; CQE advances `stream_sent` by the completed slab’s plain (plus deferred residual), then promotes the ahead-seal slab.
3. `seal_dst_for_ahead` refuses the sending slab; ready_n gates free; idle submit goes through `tls_host_submit_ct`.
4. Stream try-submit promotes ready CT **before** residual wBIO / new seal (R2 C2 class, now present on the stream entry).
5. Finish / hangup “more work” gates see slab plain fields (and hangup also sees ready_n).

Residual multi-chunk and metrics/tests remain **IMPORTANT** debt. Under current constants (`TLS_SEAL_WINDOW_DEFAULT` 256 KiB, CT slab = seal + 16 KiB), a single progressive seal’s CT fits one slab, so multi-chunk residual reorder/misattribute paths are **latent**, not demonstrated happy-path killers.

Do **not** read this as “stream dual-CT is fully hardened.” Read it as: the double-encrypt / `stream_sent` cursor contract holds for depth-2 ahead-seal as implemented.

---

## Architecture (what landed)

```text
Cursor (delivered plain):
  stream_sent          — advanced on full CT CQE for that seal (normal path)
  tls_ct_tx_plain_n    — plain sealed into primary slab, not yet CQE-advanced
  tls_ct_hold_plain_n  — plain sealed into hold slab (ahead-seal), not yet CQE-advanced
  tls_stream_plain_n   — deferred plain when multi-record residual CT of a seal is still out

plain_off = stream_sent + tls_stream_plain_n + tls_ct_tx_plain_n + tls_ct_hold_plain_n
          → next SSL_write; prevents re-encrypt of in-flight / ahead-sealed plain

seal_stream_window(dst):
  plain = resp_buf[plain_off:][:min(unsent, SEAL_WINDOW)]
  SSL_write → bio_read once into dst → (n_ct, plain_n)

try_submit (idle):
  promote ready (hold first) → residual wBIO drain → seal into primary → submit_ct
  → try_seal_hold_stream (ahead)

try_submit / CQE (inflight):
  residual drain into free slab (stash) → try_seal_hold_stream if free

on_send_complete (long-lived):
  was_hold → take/clear slab plain_n
  1) bio_pending → defer plain, drain residual
  2) other ready with plain_n==0 → residual of same seal: defer, promote (no advance yet)
  3) advance stream_sent by slab_plain + deferred
  4) promote ahead-seal (plain_n > 0)
  5) compact (only if no promote return)
  6–9) session / reflush / finish / hangup arm
```

Lifecycle zero of all three plain fields: `tls_host_conn_destroy`, connection close path (`server.odin`).

---

## Checklist (mandated CRITICAL risks)

| # | Risk | Result | Notes |
|---|------|--------|-------|
| 1 | Double-encrypt same plain (plain_off / stream_sent lag under ahead-seal) | **OK** | Seal always uses `tls_host_stream_plain_off`. Ahead-seal charges `tls_ct_hold_plain_n` (or `tls_stream_plain_n` if `n_ct<=0`) so the next write cannot restart at bare `stream_sent`. |
| 2 | Wrong plain_n on CQE advances `stream_sent` too far / short | **OK (happy path)** | CQE captures `was_hold` before promote; clears the completing slab’s plain only; residual-of-same-seal uses `other_plain==0` + defer; independent ahead-seal keeps its own `plain_n` until its CQE. |
| 3 | Clobber in-flight CT slab | **OK** | `seal_dst_for_ahead` only when inflight; never returns sending slab; ready_n>0 blocks re-seal into that slab. Idle path seals primary only after promote-or-empty ready. |
| 4 | END / `_stream_finish` with pending plain on slabs | **OK (plain fields)** | Finish requires `stream_sent >= len` **and** all three plain fields zero. Sealed-not-CQE plain keeps finish closed. Hangup “more” also sees ready_n / hold_n. |
| 5 | Promote ordering vs residual | **OK (prod entry + normal dual-CT)** | `tls_host_stream_try_submit` promotes before residual/new seal. CQE promotes residual (`plain_n==0` ready) before advance; promotes ahead-seal after advance. See I2 for latent multi-chunk residual hole. |

---

## CRITICAL findings

*None under the mandated double-encrypt / wrong `stream_sent` bar.*

---

## IMPORTANT findings

### I1 — Tests pin arithmetic, not the state machine

| Test | What it actually proves |
|------|-------------------------|
| `test_tls_stream_plain_n_cursor` | `plain_off` sum; long-lived gate |
| `test_tls_stream_dual_ct_plain_n_bookkeeping` | **Hand-copied** CQE arithmetic (primary then hold; residual defer) — does **not** call `tls_host_on_send_complete` |
| `test_tls_stream_plain_n_cqe_advance_semantics` | Same: pure `+=` model |
| `test_tls_host_on_send_complete_mid_session_no_clean` | Real OpenSSL mem-BIO, **single** slab plain, no ahead-seal, no residual, no promote |
| `test_tls_dual_ct_seal_dst_for_ahead` | Destination selection only |

Missing pure (or OpenSSL) tests that would kill regressions:

- Ahead-seal: `tx_plain=N1`, `hold_plain=N2` → two CQEs → `stream_sent` and `plain_off` monotone, no re-seal of `[0,N1+N2)`
- Residual ready (`hold_n>0`, `hold_plain==0`) before advance
- Finish blocked while `hold_plain>0` / `tx_plain>0` even if `unsent==0` at plain_off
- `try_submit` promote-before-residual when both ready and `bio_pending`
- Compact after advance with hold ahead-seal still charged (buffer rewrite + plain_n still consistent)

Without these, the cursor design is **audited**, not **locked**.

### I2 — Residual multi-chunk ordering is still structurally wrong (sized out)

**Constants:** one seal ≤ 256 KiB plain; CT slab = 272 KiB. TLS 1.3 app-data expansion for one seal is ≪ 16 KiB slack → **one bio_read drains one seal**. Multi-chunk residual of a **single** progressive seal is effectively unreachable today.

**Code still wrong if residual ever spans hold + wBIO:**

On long-lived CQE, **step 1 drains `bio_pending` into the free primary and may submit** before **step 2** promotes an older residual already stashed on hold (`plain_n==0`). That reorders TLS records (newer residual chunk before older hold chunk).

Related: after successful `submit_ct`, `try_seal_hold_stream` does **not** drain residual before a new `SSL_write`. If residual were present, `bio_read` into hold would bind **old residual CT** to **new `plain_n`** (wrong plain_n → wrong later `stream_sent`). Inflight re-entry drains first; the post-submit ahead path does not — safe only because residual after a full-slab-fit seal is ~0.

**Fix shape (defense-in-depth, not required for today’s PASS bar):**

- Never ahead-seal while `bio_pending_out > 0`.
- On CQE: if any ready slab has `plain_n==0` (residual), promote it **before** further wBIO drain.
- Or: single ordered CT queue instead of free-slab stash.

### I3 — `n_ct<=0` early / co-advance violates the stated `stream_sent` invariant

Comments and fields say: advance `stream_sent` only after full CT for that seal is delivered.

Two exceptions:

1. **Idle** `try_submit` when `plain_n>0` and `n_ct<=0`: `stream_sent += plain_n` immediately.
2. **Ahead** `try_seal_hold_stream` when `n_ct<=0`: `tls_stream_plain_n += plain_n`; a later CQE for an **earlier** slab does `adv = slab_plain + tls_stream_plain_n` and can co-advance the buffered plain before its CT hits the wire.

Not double-encrypt (`plain_off` still moves). Risk is **early finish / early compact** if OpenSSL accepted plain with no outbound CT yet and the stream ends. Rare on mem-BIO app writes; still a contract hole. Prefer: keep all accepted-but-no-CT plain in `tls_stream_plain_n` until a CT CQE (or explicit flush) and never co-mingle with another seal’s completion without a generation tag.

### I4 — Continuous dual-CT can skip `_stream_compact_delivered`

Clear progressive path compacts on **every** full stream CQE (`wire.odin`).

TLS long-lived path:

```text
advance → promote success → try_seal_hold → return
         ^^^^^^^^ compact only on the fall-through after promote fails
```

Steady SSE with always-another-window ahead-sealed: every CQE promotes → **compact never runs** → `resp_buf` retains full session history. Correctness of plain_n/plain_off survives compact (lengths, not absolute offsets), but long-lived TLS SSE RSS is worse than clear. Compact **before** promote (after advance), or compact whenever `stream_sent > 0` and wire idle even if a ready slab exists (ready CT is in CT slabs, not `resp_buf` prefix).

### I5 — Finish / idle gates ignore ready_n (mitigated by promote-first)

`_stream_finish` triggers when plains are zero and `stream_sent >= len`, without checking `tls_ct_hold_n` / `tls_ct_tx_ready_n`.

Normal CQE path promotes ready before the finish check, so residual/ahead CT is submitted first. A promote failure after clearing wire state, or a future entry that zeros plain without promote, could finish with CT still on a ready slab. Defense: finish iff plains **and** ready_n **and** `bio_pending` are all clear (mirror oneshot / `h2_host_conn_drained` after R2 C4).

### I6 — Metrics: stream undercounts PT; seal/CT inflated on residual

| Hook | Stream `seal_stream_window` | Oneshot `seal_oneshot_window` |
|------|----------------------------|-------------------------------|
| `path_metrics_note_ssl_write` (PT / ssl_write_ok) | **Missing** | Present |
| `path_metrics_note_ct_send` | On bio_read (including first drain) | Same |
| `tls_metrics_inc_seal` | On bio_read | Same |

So progressive TLS H1 SSE/WS **does not** move `path_pt_bytes` / `path_ssl_write_ok`. Matrix scrapes that assume PT≈SSL_write will **under-report** stream load and mis-attribute bulk vs stream.

Also: every residual `try_drain_out` chunk increments seal + ct_send again (stash and submit paths). `path_ct_sends` means “BIO drained,” not “sock CQE,” including ahead-stash. Same dual-CT metric honesty issue as R2 I6 — now on the stream path too.

### I7 — `bio_read` fail-closed drops consumed plain from cursor

If `SSL_write` succeeds and `bio_pending>0` but `bio_read_net` returns `n<=0`, `seal_stream_window` returns `(0, 0, false)`. OpenSSL has the plain; `plain_off` does not. Caller `session_client_gone` / fail — connection should die. Not double-encrypt on a healthy conn; if any path ever ignored `ok==false` and continued, that would be CRITICAL. Keep fail-closed absolute.

---

## What is solid (credit)

- **plain_off** is the right primitive; dual-CT without it is automatic double-encrypt.
- Per-slab plain_n matches dual-CT ownership better than a single `tls_stream_plain_n`.
- Stream entry finally promote-before-residual (was R2 I4).
- Long-lived CQE never `clean_request_loop`; mid-session OpenSSL test pins that.
- Ciphered `_stream_try_submit` never takes stream_pool slabs / plain-send bypass.
- Destroy/close zeros all three plain fields (no free-list plain_n leak on that path).

---

## Top findings (summary)

1. **PASS** on CRITICAL double-encrypt / wrong `stream_sent` for depth-2 progressive ahead-seal as coded + sized.
2. **I1** — Tests are bookkeeping mirrors; they will not catch a broken `on_send_complete` step order.
3. **I2** — Residual multi-chunk promote/drain order is still wrong in structure; constants make it latent.
4. **I4** — Dual-CT promote-every-CQE skips compact → long TLS SSE buffer growth.
5. **I6** — Stream seals omit `path_metrics_note_ssl_write`; residual inflates seal/ct_send.

---

## Recommended lock-in (not done in this pass)

1. Pure test: dual-CT ahead bookkeeping **by calling** the real CQE branch helpers (or a extracted pure `stream_ct_cqe_step`) with `bio_pending` mocked false — assert `stream_sent` and `plain_off` after CQE1/CQE2.
2. Pure test: residual `other_plain==0` defers advance.
3. Drain-before-ahead invariant: `try_seal_hold_stream` returns early if `bio_pending_out > 0` (force residual into free slab first).
4. Compact after advance even when promote succeeds.
5. `path_metrics_note_ssl_write(u64(consumed))` in `tls_host_seal_stream_window` on successful `SSL_write`.

---

## Verdict line

**Verdict: PASS** — no CRITICAL double-encrypt / wrong `stream_sent` on progressive dual-CT ahead-seal; residual ordering, compact-skip, metrics, and thin tests are IMPORTANT follow-ups.
)
