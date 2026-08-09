# Harsh critic — live dual-CT seal∥send (PR5.1)

Role: adversarial correctness review of live dual-CT seal∥send on the TLS bulk path.  
**Intent:** while one CT sock send is in flight, seal the next plain window into the free CT slab so CQE can submit without serial encrypt-then-wait.  
**Claimed scope:** Connection dual slabs + oneshot flush/promote + H2 flush/promote + pure unit + 160 http tests.

**Date:** 2026-08-08

**Files reviewed:**

| Path | Role |
|------|------|
| [`http/tls_host.odin`](../../../http/tls_host.odin) | `submit_ct` / `seal_dst_for_ahead` / `try_drain_out` / `promote_hold` / oneshot flush + send-complete |
| [`http/h2_host.odin`](../../../http/h2_host.odin) | `h2_host_try_seal_hold` / `h2_host_flush_out` / `h2_host_on_send_complete` / drained |
| [`http/server.odin`](../../../http/server.odin) | `tls_ct_hold`, ready_n, `tls_send_is_hold` |
| [`http/wire.odin`](../../../http/wire.odin) | partial send; full buffer → `tls_host_on_send_complete` |
| [`http/tls_host_test.odin`](../../../http/tls_host_test.odin) | `test_tls_dual_ct_seal_dst_for_ahead` |
| [`http/conn_slab.odin`](../../../http/conn_slab.odin) | free-list TLS field reset |
| [`http/response.odin`](../../../http/response.odin) | materialize → flush; `clean_request_loop` |
| [`http/path_metrics.odin`](../../../http/path_metrics.odin) | seal / ct_send counters |
| Prior bulk context | [`BULK_TLS_PROFILE.md`](BULK_TLS_PROFILE.md), [`CRITIC_H2_CURSOR_R2.md`](CRITIC_H2_CURSOR_R2.md) |

---

## Verdict

**FAIL**

The oneshot / H2 **happy path** correctly implements depth-2 seal∥send (do not seal into the sending slab; promote hold-first after full CT CQE; partial send does not promote early; H2 still arms recv on flush and send-complete). That is real craft toward the bulk P1 ceiling.

It is **not shippable** as a correctness-complete dual-CT machine: PR5.1 taught `tls_host_try_drain_out` to **stash** CT into the second slab while a send is inflight, but **handshake and progressive stream never promote that stash**. That is a lost-CT / reorder class introduced by this PR, not a pre-existing curiosity. Tests only pin destination selection; they do not exercise promote, residual-before-promote order, or HS concurrent drain.

Do not claim live dual-CT Done until every consumer of `try_drain_out` either promotes ready slabs or cannot stash.

---

## Architecture (what landed)

```text
Connection
  tls_ct_tx      primary CT slab (TLS_CT_TX_DEFAULT = CT_SLAB_SIZE = 64 KiB)
  tls_ct_hold    second CT slab (same size)
  tls_ct_tx_ready_n / tls_ct_hold_n   sealed-not-submitted lengths
  tls_send_is_hold                    pending_send aliases hold?

seal_dst_for_ahead (only when wire.kind != None):
  send_is_hold → free primary if tx_ready_n==0
  else         → free hold if hold_n==0

try_drain_out:
  !inflight → bio_read into free slab → submit_ct immediately
  inflight  → bio_read into free slab → set ready_n only (stash)

promote_hold (CQE / idle flush):
  hold_n first, then tx_ready_n → submit_ct (hs forced false)

Oneshot: flush_response + on_send_complete promote → try_seal_hold_oneshot
H2:      flush_out      + on_send_complete promote → try_seal_hold
Stream:  still serial; inflight → flush_pending only (no ahead seal)
HS:      try_drain_out(hs=true); CQE → drive_handshake (no promote)
```

Alloc both slabs on `tls_host_on_accept`; free both on `tls_host_conn_destroy`. Good.

---

## Checklist (mandated)

| Risk | Result | Notes |
|------|--------|-------|
| Clobber in-flight buffer | **OK (oneshot/H2 happy)** | `seal_dst_for_ahead` never returns the sending slab; ready_n gates free. Stream bypasses `submit_ct` and always writes `tls_ct_tx` — safe only while dual-CT state is empty. |
| Double-submit | **OK** | Promote / flush idle paths gate on `!_conn_wire_in_flight`; partial resubmit stays single-flight. `host_submit_send` itself does not re-check inflight (callers must). |
| Lost CT | **FAIL (CRITICAL)** | HS (and stream) can stash via `try_drain_out` and never promote. Oneshot clean checks `hold_n` but **not** `tx_ready_n`. H2 `h2_host_conn_drained` ignores both ready_n. |
| Promote order bugs | **FAIL (CRITICAL / latent)** | Idle `try_drain_out` prefers primary for **new** wBIO while `hold_n>0` still holds **older** CT → wire reorder if residual drain runs before promote. Flush does residual **before** promote. Oneshot CQE promotes first (mitigates main path); HS/session flush entry points do not. |
| H2 duplex broken | **OK** | `h2_host_flush_out` and `h2_host_on_send_complete` still `tls_host_arm_recv` while Open; inflight send does not block arm. |
| Incomplete dual depth | **IMPORTANT** | Depth 2 only (correct). Progressive stream remains serial. Residual multi-chunk beyond free slab stalls (OK). Not pure `Seal_SM` / `pipe_seal_step` — third live architecture again. |
| Race on hold_n | **OK (single-thread)** | Worker is single-threaded; hold_n is POD, not atomic. No concurrent CQE vs seal on same conn. |
| Metrics double-count | **IMPORTANT** | `path_metrics_note_ct_send` fires at **bio drain**, including stash-before-submit. Residual `try_drain_out` also `tls_metrics_inc_seal`. `path_metrics_note_req` can fire when last plain is sealed, before last CT CQE. |

---

## CRITICAL findings

### C1 — Handshake can stash CT into hold and never promote (lost / reorder)

**Mechanism**

1. `tls_host_try_drain_out` now, when `_conn_wire_in_flight`, `bio_read`s into the free slab and sets `tls_ct_hold_n` / `tls_ct_tx_ready_n` without submit (`tls_host.odin` ~572–578).
2. Handshake drives that helper with `hs=true` from `tls_host_drive_handshake` and from CT-recv during `.Handshake`.
3. HS send CQE path (`tls_host_on_send_complete` with `tls_hs_send` / `.Handshake`) only calls `tls_host_drive_handshake` — **never** `tls_host_promote_hold`.
4. `drive_handshake` only looks at `bio_pending_out`. Stashed CT is **out of wBIO**, so it is invisible.
5. Later idle drain prefers free **primary** for any *new* BIO bytes while `hold_n > 0` still holds older records → submit newer first → **reorder**, or leave hold forever → **lost HS flight**.

**Reachability:** multi-message TLS 1.3 server flight (ServerHello + Certificate chain + …) where first CT chunk is still on the wire when more outbound HS CT is produced (recv continues accept, or WANT_WRITE loops under async I/O). Cert chains make multi-slab / multi-turn HS realistic.

**Why this is PR5.1’s bug:** dual-CT stash is a global change to `try_drain_out`. HS was not updated to the promote contract. Pre-dual-CT single-buffer drain could not safely invent a second ready buffer the HS path never recycles.

**Fix shape (normative)**

- On every HS send complete: `promote_hold` **before** `drive_handshake`, with `hs` preserved for promoted HS CT; **or**
- Forbid stash during Handshake (`try_drain_out` returns false without reading when inflight && HS); **or**
- `drive_handshake` always: if `hold_n|tx_ready_n` and !inflight → promote before accept/drain.

---

### C2 — Idle drain-before-promote can reorder CT (structural)

Both `tls_host_flush_response` and `h2_host_flush_out` when **not** inflight:

1. If `bio_pending_out` → `try_drain_out` (may **submit new residual via primary**).
2. **Then** promote `hold_n` / `tx_ready_n`.

If `hold_n > 0` (older sealed CT) and wBIO has newer residual and socket is free, step 1 sends newer first. Oneshot/H2 **CQE** paths promote first (good), but many **H2 flush call-sites** (`session.odin`, open, GOAWAY, dispatch) enter `h2_host_flush_out` directly. Any path that leaves ready_n set while !inflight hits this order.

**Fix:** promote-ready **before** any idle bio drain/submit; `try_drain_out` idle must refuse to fill a slab while the other has ready older CT (or always promote first).

---

### C3 — Progressive stream ignores dual-CT ready state

`tls_host_stream_try_submit`:

- On inflight: sets `stream_flush_pending` and returns (no ahead seal — incomplete dual depth).
- On idle: drains/seals only through **primary** `tls_ct_tx`, bypassing `tls_host_submit_ct` (does not set `tls_send_is_hold` / clear ready_n).
- Stream branch of `tls_host_on_send_complete` **never** calls `promote_hold`.

If any prior path left `hold_n` / `tx_ready_n` (or HS stash survived into Open), stream can clobber `tls_ct_tx` or leave hold CT unsent. Even if keep-alive usually empties dual state, the contract is incomplete: **every** Open send path must own promote.

---

### C4 — “Fully done” / drained ignore `tls_ct_tx_ready_n`

Oneshot complete continue gate (`tls_host.odin` ~1205–1207):

```text
plain_rest > 0 || hold_n > 0 || bio_pending
```

**Omits `tls_ct_tx_ready_n`.** Promote usually submits it first; if promote cannot (`len(tx)==0` edge) or a future path sets ready without promote, clean runs with CT still ready → **lost ciphertext** and early `clean_request_loop`.

`h2_host_conn_drained` checks out pending, wire inflight, wBIO only — **not** ready_n. Slot free / GOAWAY close can declare drained while a sealed CT slab is still waiting.

---

## IMPORTANT findings

### I1 — Dual depth incomplete vs bulk claim

- Oneshot + H2 oneshot flush: ahead seal yes.
- SSE/WS progressive: still serial (explicit early-return on inflight).
- Live path is still a **third architecture** (not `pipe_seal_step` / pure `Seal_SM`). Pure firehose CI does not prove this wire machine.
- Residual wBIO after a full-slab `bio_read` is handled only if a later drain/promote runs; ahead seal does not drain residual **before** the next `SSL_write` (TLS byte order usually preserved inside wBIO, but mixes “window N residual” into the next slab — complicates reasoning and metrics).

### I2 — Unit test is destination selection only

`test_tls_dual_ct_seal_dst_for_ahead` checks:

- no ahead when !inflight
- primary sending → hold
- hold ready → nil
- hold sending → primary

“Promote prefers hold” is **not** tested (assert only that both ready_n stay set). No test for:

- promote order hold then primary
- residual drain vs ready reorder
- HS stash + CQE
- partial send + hold intact
- `h2_host_conn_drained` with ready_n
- clean with `tx_ready_n` only

“160 tests pass” does not cover dual-CT failure modes.

### I3 — Metrics / profile signal drift

| Counter | Behavior after PR5.1 |
|---------|----------------------|
| `path_ct_sends` | Incremented on wBIO drain (incl. stash), not on `submit_send` |
| `tls_metrics` seal units | Incremented on residual drain as well as SSL_write path |
| `path_reqs` | May tick when last plain window seals, before last CT CQE |

Bastion “seal_calls ≈ ct_sends ≈ windows” narrative weakens; dual-CT success should show **encrypt overlapping send** (lower end-to-end latency / higher RPS), not necessarily fewer seal_calls (still ~body/64KiB SSL_writes).

### I4 — Lifecycle hygiene gaps

- `conn_alloc` free-list reset clears `tls_ct_tx` / `tls_ct_rx` but **not** `tls_ct_hold`, ready_n, or `tls_send_is_hold` (destroy usually cleans; asymmetric).
- `clean_request_loop` does not zero dual-CT ready flags / `tls_plain_rest` (relies on flush completion).
- Docs still say live dual-CT **Not yet** (`docs/TLS_H1.md`, `docs/IMPLEMENTATION_STATUS.md`) while code runs dual-CT — honesty lag after land.

### I5 — `promote_hold` always `hs=false`

Any HS CT promoted through the shared helper would demux as response CT on the next complete. Combined with C1, HS must either never stash or promote with correct `hs`.

---

## What is actually good

1. **Slab ownership model is clear** on the oneshot/H2 happy path: sending vs ready vs free; `tls_send_is_hold` + raw_data compare in `submit_ct`.
2. **Partial send** re-arms the same buffer and does not promote hold early (`wire.odin` ~728–742).
3. **H2 duplex law held** — flush/send-complete still arm CT recv; dual-CT does not serialize recv behind send.
4. **Accept alloc** pays for second slab only on TLS accept; destroy frees both; lightweight `connection_enable_ciphered` still does not zombie pure `seal_q` CT[2].
5. **Intent matches bulk profile P1** — seal next window while `wire.kind == .Send` is the right lever after the H2 cursor fix (~1897 rps s1m smoke).

---

## Scoreboard (correctness only)

| Axis | Score | Note |
|------|------:|------|
| Oneshot happy-path seal∥send | 7.5 | Works if HS already Open and no stale ready |
| H2 happy-path seal∥send + duplex | 7.0 | Promote on CQE OK; flush entry / drained gaps |
| Cross-path promote contract | **3.0** | HS + stream + drained + residual order |
| Tests | **2.5** | Selection only |
| Docs honesty | 5.0 | Code ahead of status rows |
| **Ship as PR5.1 Done?** | **No** | FAIL until C1–C4 closed |

---

## Top residual bulk risks (post dual-CT, even after fixes)

1. **Still ~17 SSL_write / MiB** at 64 KiB pull — dual-CT overlaps encrypt with send; it does not reduce seal count. Larger windows / record batching remain P1b.
2. **Multi-copy H2 path** — body → stream pending → framed `h2_out` → SSL_write → BIO → CT slab → kernel (cursor removed front-delete only).
3. **Mem-BIO copies** — every drain is still `BIO_read` → slab memmove class cost (`BULK_TLS_PROFILE` P3).
4. **H1 full materialize** — oneshot still O(body) PT in `resp_buf` before windowed seal (firehose pure O(window) not on live oneshot).
5. **Depth-2 only** — deep wBIO backlog cannot seal a third window; stall until CQE (correct, but limits overlap under slow TCP).
6. **Progressive TLS still serial** — SSE/WS bulk-ish streams do not get seal∥send.
7. **No live multi-MiB dual-CT firehose CI on ring** — unit + offline gates ≠ bastion proof; re-measure h2/h1s s1m after C1–C4.

---

## Required fixes before PASS (ordered)

1. **HS promote contract** — promote ready CT on every HS send complete (with `hs=true`) or disable stash during Handshake.
2. **Global promote-before-idle-drain** — `try_drain_out` / flush must never submit newer wBIO ahead of ready older slabs.
3. **drained + clean gates** — include `tls_ct_hold_n` and `tls_ct_tx_ready_n` everywhere “outbound empty” is decided.
4. **Stream path** — either dual-CT + promote, or hard-assert ready_n==0 and only use `submit_ct`.
5. **Tests** — promote order; HS concurrent drain+CQE; residual+ready reorder guard; drained with ready_n; partial send + hold.
6. **Docs** — flip PR5.1 row only after (1)–(5); keep pure vs live distinction accurate.

---

## One-line summary

**FAIL:** dual-CT seal∥send is real on oneshot/H2 happy path, but stash-without-promote on handshake (and incomplete stream/drained contracts) are CRITICAL lost-CT / reorder bugs; residual-before-promote is a structural reorder hazard; tests do not pin the machine.
