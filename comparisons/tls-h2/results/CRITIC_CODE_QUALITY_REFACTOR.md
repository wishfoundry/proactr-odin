# Harsh critic — structural refactor re-review (code quality bar)

**Role:** adversarial structural / code-quality re-score after the dual-CT / file-split / ciphered-policy refactor.  
**Not a perf review.** Not a bastion re-rank.  
**Date:** 2026-08-09  

**Scope of prior blockers:**

| Blocker | Claim |
|---------|--------|
| **B1** files >1k | Host TLS/H2 godfiles past reviewable size |
| **B2** triple dual-CT seal engines | Oneshot / stream / H2 each owned SSL_write + ahead-seal physics |
| **B3** mark_hold soup on Connection | Flat `tls_ct_tx*` / hold fields as bag soup |
| **B4** `response_send_got_body` nested plain-split | ~60-line policy+exec bomb in send spine |
| **B5** pipe Seal_SM vs live dual-CT narrative lie | Comments/docs implied pure SM was the live path / serial-only wire |

**Files re-read (this pass):**

| Path | Lines (approx) | Focus |
|------|---------------:|--------|
| [`http/tls_dual_ct.odin`](../../../http/tls_dual_ct.odin) | 544 | `Dual_Ct`, `tls_seal_window*`, `tls_dual_ct_try_ahead`, submit/drain/promote |
| [`http/tls_host.odin`](../../../http/tls_host.odin) | 810 | accept/HS/recv/send-complete demux; no seal physics |
| [`http/tls_oneshot.odin`](../../../http/tls_oneshot.odin) | 205 | plain cursor + flush orchestration |
| [`http/tls_stream.odin`](../../../http/tls_stream.odin) | 216 | stream try_submit + hangup |
| [`http/h2_host.odin`](../../../http/h2_host.odin) | 803 | ALPN/slots/dispatch/send_response |
| [`http/h2_flush.odin`](../../../http/h2_flush.odin) | 309 | h2_out cursor + flush + send-complete |
| [`http/h2_goaway.odin`](../../../http/h2_goaway.odin) | 136 | GOAWAY hard/graceful |
| [`http/response.odin`](../../../http/response.odin) | 1922 | send spine; call-out residual |
| [`http/response_ciphered.odin`](../../../http/response_ciphered.odin) | 83 | plain-split policy + heading-body arm |
| [`http/response_materialize.odin`](../../../http/response_materialize.odin) | 209 | materialize helpers |
| [`http/server.odin`](../../../http/server.odin) | — | `Connection` fields (`dual_ct`) |
| [`http/pipe.odin`](../../../http/pipe.odin) | — | pure Seal_SM vs live dual_ct comments |
| [`http/conn_slab.odin`](../../../http/conn_slab.odin) | — | free-list `dual_ct = {}` |

---

## Verdict

**PASS**

The structural bar that blocked prior review is met:

1. **No triple live seal engines** — product SSL_write + wBIO CT drain for oneshot/stream/H2 lives only in `tls_dual_ct.odin` (`tls_seal_window_*` + shared `tls_dual_ct_try_ahead` / submit / drain / promote). Grep of `tls_server.write` / `bio_read_net` under `http/` hits that file only for seal physics.
2. **Dual-CT is modeled** — `Connection.dual_ct: Dual_Ct` replaces the flat `tls_ct_tx` / hold bag soup; lifecycle via `dual_ct_free_slabs` / `dual_ct_clear_meta`.
3. **Plain-split is not a nested bomb** — policy + arm live in `response_ciphered.odin`; send spine is a 4-line dispatch.
4. **Major TLS/H2 host files under ~900–1000** — `tls_host` ~810, `h2_host` ~803; seal/flush splits are in the claimed size band.
5. **`response.odin` still >1k** — called out below as residual debt with a clear next-split map (allowed under the bar).

This is a **structural** PASS. It is **not** a claim that flush orchestration is fully DRY, that docs honesty is fixed, or that stream CQE residual ordering is hardened beyond prior dual-CT critics.

---

## Checklist of prior blockers

| Blocker | Status | Evidence |
|---------|--------|----------|
| **B1** files >1k (tls/h2 host) | **Fixed** | `tls_host` ~810, `h2_host` ~803, `h2_flush` ~309, `h2_goaway` ~136, `tls_oneshot` ~205, `tls_stream` ~216, `tls_dual_ct` ~544. All major host/seal modules under the ~900–1000 bar. |
| **B2** triple dual-CT seal engines | **Fixed** | Single seal engine entry: `tls_seal_window(conn, dst, Tls_Seal_Plain)` dispatches `.Oneshot` / `.Stream` / `.H2_Out`. Shared `tls_host_submit_ct`, `tls_host_seal_dst_for_ahead`, `tls_host_try_drain_out`, `tls_host_promote_hold`, `tls_dual_ct_try_ahead`. Call sites only pass plain enum + orchestrate promote order. |
| **B3** mark_hold soup on Connection | **Fixed** | Flat CT fields gone from `Connection`; bag is `dual_ct: Dual_Ct { tx, hold, tx_ready_n, hold_n, send_is_hold, tx_plain_n, hold_plain_n }`. `mark_hold` is a **local** parameter into `dual_ct_set_ready` / `dual_ct_set_slab_plain`, not a Connection field soup. |
| **B4** nested plain-split in send spine | **Fixed** | `response_send_got_body` (~1747–1752): `ciphered_oneshot_plan` → `response_send_ciphered_heading_body`. Policy, 8 KiB constant, and heading/body arm are in `response_ciphered.odin` (~83 lines). |
| **B5** Seal_SM vs live dual-CT narrative lie (code) | **Fixed** | `tls_host.odin` header: live path = dual_ct engine; pure `Seal_SM` formal. `pipe.odin` `connection_enable_ciphered` / `_pipe_sm` comments: live uses `dual_ct` + `tls_seal_window`, not `Seal_Queue`. `Connection` comment block matches. |
| **B5b** product docs still say serial / dual-CT “Not yet” | **Open (docs, not code)** | `docs/TLS_H1.md`, `docs/IMPLEMENTATION_STATUS.md`, `docs/CAPABILITY_MATRIX.md` still claim live dual-CT **Not yet** / serial `tls_ct_tx`. Code comments fixed; **published implementer docs still lie**. Score as residual honesty debt, not a re-open of the code-comment blocker. |

### Partial nuances (do not flip Fixed → Open)

| Item | Note |
|------|------|
| **B2 residual** | Three **flush orchestration** loops remain (oneshot / stream / H2): promote → residual drain → seal → submit → try_ahead. Physics unified; **control-flow still triple-copied**. Not “triple seal engines.” |
| **B3 residual** | Naming asymmetry inside the model: `tx_ready_n` vs `hold_n` (not `hold_ready_n`). `tls_stream_plain_n` remains a sibling Connection field (deferred residual plain), not nested under `Dual_Ct`. Modeled enough for the bar; not perfect. |
| **B1 residual** | `response.odin` ~1922 still over 1k — **allowed** only as residual with next split (below). |

---

## Remaining IMPORTANT structural issues

### I1 — Triple flush orchestration (copy-paste control flow)

`tls_host_flush_response`, `tls_host_stream_try_submit`, and `h2_host_flush_out` still share the same skeleton:

```text
if inflight: drain residual → try_ahead → return
if dual_ct_has_ready: promote → try_ahead → return
if bio_pending: try_drain → maybe try_ahead → return
seal_window(tx) → submit_ct → try_ahead
```

Seal **physics** is shared; **policy differences** (done → clean, stream plain bookkeeping, h2 arm_recv, error → close vs Client_Gone) still justify some split. A single `tls_dual_ct_flush_step(conn, plain, hooks)` would cut ~3× maintain surface. **IMPORTANT**, not a structural FAIL.

### I2 — Stream CQE machine still a large special case in `tls_host`

`tls_host_on_send_complete` long-lived branch (~627–720) still owns residual multi-chunk / promote / advance ordering inline. Seal engine extraction did not pull this into `tls_dual_ct.odin` (correct: promote-before-residual stays at call sites per file header). Residual risk remains the same class as `CRITIC_STREAM_DUAL_CT` I2 (latent multi-chunk), not re-litigated here.

### I3 — `response.odin` residual megafile (~1922)

Materialize and ciphered-split are out; the spine still carries Response API, hooks, writev/sendfile, stream, clean_request_loop, close policy. **Next clear splits** (optional judo):

| Chunk | Approx home |
|-------|-------------|
| `response_send_got_body` + wire assembly arm | `response_send.odin` |
| `clean_request_loop` + keep-alive reset | `response_clean.odin` or `conn_clean.odin` |
| writev / sendfile send helpers | already partly nearby; finish extract if still nested |
| stream progressive clear/ciphered | already partially in stream/tls_stream |

Bar allows this residual **only** because it is named and has a next cut.

### I4 — Product docs narrative lag (honesty)

Code says dual-CT is live. Docs still say:

- `docs/TLS_H1.md`: “serial windowed … (**not** dual-CT)”, “Live dual-CT … **Not yet**”
- `docs/IMPLEMENTATION_STATUS.md`: PR5.1 dual-CT **Not yet**
- `docs/CAPABILITY_MATRIX.md`: serial `tls_ct_tx`

This is the **same class of narrative lie as B5**, moved from code comments to docs. Flip docs with an accurate stream/oneshot/H2 dual-CT note (and residual multi-chunk caveats). Not a structural code FAIL.

### I5 — Parallel pure-pipe vs live dual_ct architectures remain

Intentional: pure `Seal_SM` / `Seal_Queue` / `connection_enable_ciphered_pipe_sm` for firehose CI; live `Dual_Ct` for HTTPS. Comments now tell the truth. Long-term compression (live path speaking `Seal_SM` vocabulary, or pure path deleted) is optional product judo — not required for this bar.

### I6 — `Dual_Ct` field naming / meta hygiene

- `tx_ready_n` / `hold_n` asymmetry invites misread (“is hold always ready-only?”).
- `send_is_hold` is clear.
- Per-slab plain fields correctly stream-only; oneshot/H2 cursors live elsewhere (`tls_plain_*`, `h2_out_off`) — good cut, but the dual-CT model is CT-centric, not a full seal session object.

### I7 — Tests pin structure lightly

`tls_host_test` covers `seal_dst_for_ahead` and plain_n bookkeeping; flush promote-before-residual and shared-engine identity are not pure-tested as a machine. Prior dual-CT critics already said this; refactor did not worsen it.

---

## Must-fix before approve

**None** for the structural bar stated in this review.

Do **not** block merge on I1–I7. Optional docs flip (I4) is the highest-value non-code fix before anyone quotes IMPLEMENTATION_STATUS as ground truth.

---

## Optional next judo moves

1. **`tls_dual_ct_flush_step`** — parameterize residual hooks (`on_done`, `on_fail`, `post_submit`) so oneshot/stream/H2 share one promote/drain/seal loop; leave stream CQE machine separate until multi-chunk is product-proven.
2. **Split `response_send_got_body` / clean** out of `response.odin` → drop below ~1k without touching handler API.
3. **Docs honesty pass** — one table row each in `TLS_H1.md` + `IMPLEMENTATION_STATUS.md`: live dual-CT Done (oneshot + stream + H2); pure Seal_SM = CI; residual multi-chunk IMPORTANT.
4. **Rename** `hold_n` → `hold_ready_n` (or both `*_ready_n`) inside `Dual_Ct` for mirror symmetry.
5. **Fold** `tls_stream_plain_n` into `Dual_Ct` as `deferred_plain_n` if stream residual accounting is considered dual-CT state (optional; keeps Connection thinner).
6. **Pure tests** for: promote order hold→tx; flush promote-before-residual; oneshot done gate with ready_n only (carry-forward from `CRITIC_DUAL_CT_R2`).

---

## Size scoreboard (post-refactor)

| Module | ~LOC | Role | Bar |
|--------|-----:|------|-----|
| `tls_dual_ct.odin` | 544 | seal∥send engine + Dual_Ct | OK |
| `tls_host.odin` | 810 | HS / recv / CQE demux | OK (<900–1000) |
| `tls_oneshot.odin` | 205 | H1 oneshot cursor + flush | OK |
| `tls_stream.odin` | 216 | progressive stream flush | OK |
| `h2_host.odin` | 803 | H2 host product | OK |
| `h2_flush.odin` | 309 | H2 flush / exchange | OK |
| `h2_goaway.odin` | 136 | GOAWAY | OK |
| `response_ciphered.odin` | 83 | plain-split policy | OK |
| `response_materialize.odin` | 209 | materialize | OK |
| `response.odin` | **1922** | Response API + send spine | **Residual** (allowed with next split) |

---

## Bottom line

| Question | Answer |
|----------|--------|
| Triple seal engines gone? | **Yes** — one engine file, three plain sources |
| Dual_Ct modeled (not flat soup)? | **Yes** |
| Plain-split out of send spine? | **Yes** |
| Host files under ~1k? | **Yes** (response residual named) |
| Code narrative dual-CT live? | **Yes** |
| Docs narrative dual-CT live? | **No** — I4 residual |
| Must-fix for structural approve? | **None** |

**Verdict: PASS**
)
