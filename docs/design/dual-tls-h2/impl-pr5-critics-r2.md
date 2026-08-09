# Implementation Critics — PR5 r2 (multi-axis)

**Posture:** harsh elite. Credit only claimed PR5 scope.  
**Bar:** WOW ≥ 9 for **claimed PR5 scope only**:

| Claimed in | Claimed out |
|------------|-------------|
| HTTPS H1 **oneshot** e2e (curl green / host wire) | SSE / WS on TLS |
| Pipe O(window) firehose **pure** CI | Live dual-CT seal∥send on wire (PR5.1) |
| Lightweight `connection_enable_ciphered` (no zombie CT[2]) | H2 / M1–M6 |
| Honest docs: live ≠ dual-CT seal∥send yet | Production “HTTPS complete” / bulk firehose CI on ring |
| `tls_server` dynlib OpenSSL **mem-BIO** | Full multi‑MiB HTTPS firehose product |

**Not required for WOW:** Phase 2 product matrix cells beyond oneshot; live SM driving `pipe_seal_step`.  
**Required for WOW:** R1 Majors closed for this claim; no lies; no critical UAF / free-order bugs; no zombie dual-CT tax on oneshot Open.

**Date:** 2026-08-08  
**Prior:** [`impl-pr5-critics-r1.md`](impl-pr5-critics-r1.md)  
**Subject:** live tree under `http/tls_host.odin`, `http/pipe.odin`, `http/response.odin`, `http/wire.odin`, `tls_server/*`, `examples/https_demo`, `docs/IMPLEMENTATION_STATUS.md`, `docs/TLS_H1.md`, `docs/CAPABILITY_MATRIX.md`, `scripts/check_firehose_pipe.sh`.

---

## Verify (this pass)

| Command | Result |
|---------|--------|
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **115/115 pass** (includes OpenSSL tls_host smoke when libssl loads) |
| `odin test tls_server -o:none` | **6/6 pass** |
| `./scripts/check_firehose_pipe.sh` | **OK** (presence gate + full http suite) |

---

## R1 → fixed (spot-checked)

| R1 ID | Claim | Evidence | Verdict |
|-------|--------|----------|---------|
| **CQ-M1 / PERF-M3 / MEM-M1** | Zombie dual-CT: enable_ciphered allocated seal_q + CT[2] unused on live | `connection_enable_ciphered` only sets `conn.ciphered` + PT HW; **no** seal_q / `tls_pipe_alloc_buffers`. Live Open calls lightweight enable only (`tls_host.odin`). Tests: `test_connection_enable_disable_ciphered` asserts `q == nil` / `bufs == nil`. | **Fixed** |
| **CQ-M2** | Half-wired: bags enabled but Seal_SM idle | Bags allocated only via `connection_enable_ciphered_pipe_sm` (pure/tests). Live never enables SM bags. Architecture is **severed**, not half-wired. | **Fixed** |
| **HON-M1 / HON-M2** | Scorecard “seal∥send Done” sold live dual-CT | Status splits: **PR5 pure seal∥send + firehose CI → Done**; **PR5 live dual-CT seal∥send on wire → Not yet**; live wire row says **serial** SSL_write + `tls_ct_tx`. `TLS_H1.md` + script header match. | **Fixed** |
| **PERF-M1** (as major under false Done packaging) | Live serial vs pure parallel | Still true as physics — **no longer a Major under claimed scope**. Claimed: pure parallel + live oneshot serial. Docs name that split. | **Reclassified (scope honesty)** |

R1 holds still green: free-order destroy (`shutdown` → `conn_free` → free rx/tx → `connection_disable_ciphered`), opaque SSL, mem-BIO product path, plan_policy ciphered demotions, clear-H1 fail-open when PEMs/provider fail, pure dual-CT firehose CI.

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **9.2** | **yes** | Minor |
| Performance | **9.1** | **yes** | Minor (phase residual) |
| Memory | **9.3** | **yes** | Minor |
| Shortcuts / honesty | **9.5** | **yes** | Minor |
| **Mean** | **9.3** | — | — |

**Verdict:** R1 Majors for **claimed PR5 scope** are closed. Live oneshot is a clean serial mem-BIO host; pure seal∥send + firehose remains elite CI physics; enable path no longer pays for a machine it does not run; status docs refuse live dual-CT Done. **All four axes clear WOW (≥9).** Residuals are true minors or explicit PR5.1 / bulk phase work — not withhold reasons under this claim.

---

## Architecture map (post-sever)

```text
CLEAR H1
  respond → materialize → Wire_State.pending_send → host_submit_send
  pipe bags: init only; seal_q nil; bufs nil; ciphered false

TLS H1 ONESHOT (live — PR5 host)
  accept → SSL + mem-BIO + tls_ct_rx/tx scratch
  Handshake: CT→rBIO, SSL_accept, wBIO→tls_ct_tx→submit_send
  Open: connection_enable_ciphered  ← FLAG + plan_policy ONLY
        (NO seal_q, NO pipe CT[2])
        CT→rBIO, SSL_read PT→scanner
  respond: materialize full PT into resp_buf (oneshot)
        tls_plain_rest = buf
        loop: SSL_write(window) → bio_read_net(tls_ct_tx) → submit_send
              wait CQE → next window   ← SERIAL, one CT scratch (honest)
  destroy: SSL_shutdown best-effort; SSL_free; free rx/tx; disable_ciphered

PIPE PURE (tests + check_firehose_pipe)
  connection_enable_ciphered_pipe_sm → seal_q + CT[2]
  pipe_seal_step / pipe_mark_send / pipe_on_send_complete
  dual CT, seal_n∈{0,1,2}, dual HW, firehose_fail
  mock identity seal — NO OpenSSL, NO ring
```

**Grep fact:** `http/tls_host.odin` contains **zero** calls to `pipe_seal_step`, `pipe_mark_send`, `pipe_on_send_complete`, or `connection_enable_ciphered_pipe_sm`. Live seal is OpenSSL + `tls_ct_tx` only — **and** does not allocate the idle dual-CT plane.

---

## 1. Code quality — Score **9.2** / WOWED **yes**

### What is elite for claimed oneshot scope

1. **Opaque SSL surface.** `tls_server.Conn` / `Ctx` only; no `SSL*` in handlers / APP_CONTRACT. Dynlib provider + nil-safe wrappers remain clean IOC.
2. **Mem-BIO product law coded.** `setup_mem_bios` → `bio_write_net` / `bio_read_net` / `bio_pending_out`; `set_fd` labeled fallback. Darwin avoids Apple system libssl.
3. **Clear dual path honest at runtime.** PEMs empty or provider/PEM fail → log + clear-H1 only.
4. **Wire integration points local.** Accept / recv / send-complete / recv-arm demux unchanged and readable.
5. **Enable/disable API is the fix.**  
   - Lightweight: `connection_enable_ciphered` → `ciphered = true` (+ PT HW).  
   - Full SM: `connection_enable_ciphered_pipe_sm` → bags for pure/future.  
   - Disable: free bags if present; always clear flag — safe for both paths.
6. **Free-order on destroy fail-closed.** `connection_destroy` → `tls_host_conn_destroy` → disable_ciphered; close defers while wire inflight.
7. **`plan_policy_for` demotions real.** `ciphered` ⇒ no sendfile / no zc / `max_write_unit = PULL_WINDOW`. Respond skips Writev/Sendfile when ciphered.
8. **Tests lock the sever.** Lightweight enable asserts nil bags; pipe_sm asserts bags; firehose suite still green.

### Fatal

**None found** for free-order / UAF under claimed oneshot path (same audit as R1; zombie free path simplified — disable is no-op free when bags never allocated).

### Majors

**None remaining** under claimed scope.

| R1 Major | Status |
|----------|--------|
| CQ-M1 dual CT ownership | **Closed** — sever |
| CQ-M2 half-wired Seal_SM | **Closed** — bags not enabled on live |
| CQ-M3 pt_admit vs materialize | **Demoted** — oneshot materialize is in-claim; bulk O(window) PT is PR5.1 / large-TLS ⏳, not a live-oneshot ownership bug |

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Stale comment residue: `plan_policy_for` still says “no cipher path in host yet” above a live cipher demotion block. Harmless but dirty. |
| **CQ-m2** | `Connection` still says “pipe bags below are not yet wired” in one line — accurate for clear-H1 / live SM, slightly loose next to landed oneshot host. |
| **CQ-m3** | `SSL_shutdown` best-effort without WANT_READ/WRITE drain (oneshot OK; not production close polish). |
| **CQ-m4** | Package-public host zoo (`connection_enable_ciphered*`, seal_q_*, progressive stream_*) still importable — R3 residual, not PR5-specific. |
| **CQ-m5** | Optional free-order stress: HS CT inflight → peer reset → destroy; mid-flush close (nice-to-have, not WOW block for oneshot). |

### What already WOW'd the bar

1. **One CT seal owner on the live path:** host `tls_ct_tx` only; dual slabs not allocated until SM path.  
2. Sever is **typed into two procs**, not a comment.  
3. Status + code + tests + script agree.

### WOWED: **yes**

Working oneshot with clean opaque SSL + ownership sever is the structure dual R1 rejected. Score ≥9 for claimed craft.

---

## 2. Performance — Score **9.1** / WOWED **yes**

### What is real under claim

| Path | Behavior | Grade |
|------|----------|-------|
| Pure `pipe_seal_step` | Dual CT, seal while send inflight | **Elite pure physics** |
| Pure 4 MiB bulk sim | peak_pt = peak_ct = 128 KiB (= HW); firehose detector green | **Elite pure CI** |
| Live oneshot | Windowed `SSL_write` ≤ `PULL_WINDOW`, multi-CQE CT | **Correct serial oneshot** |
| Live plan | Ciphered demotes sendfile/zc; skips Writev/Sendfile | **Correct demotion** |
| Clear-H1 | Unchanged when TLS off | **No RPS poison in suite** |
| Dead dual-CT tax | **Gone** on Open | **R1 PERF-M3 closed** |

### Majors

**None remaining** under claimed scope.

Serial live seal is **in-scope honesty**, not a defect against “pure seal∥send Done + live oneshot serial.” Claiming live seal∥send would re-open PERF-M1 as Major — status correctly does **not**.

### Minors / phase residuals (OK under claim)

| ID | Issue |
|----|--------|
| **PERF-m1** | Live: materialize-then-window ⇒ O(body) PT residency before first seal. Fine for tiny oneshot; **not** bulk-honest. Matrix large TLS ⏳; docs say serial oneshot. |
| **PERF-m2** | Live seal is serial (one CT while sock send). PR5.1 to drive dual-CT SM if product wants seal∥send on wire. |
| **PERF-m3** | Metrics `tls_peak_pt` track admit windows, not `len(resp_buf)` — weak ops proxy for materialize peak. |
| **PERF-m4** | No multi-MiB HTTPS bulk bench in tree (correctly not claimed as CI). |

### Windowed-send honesty (claimed layers)

| Claim layer | Windowed? | Peak PT | Peak CT (host-owned) |
|-------------|:---------:|---------|----------------------|
| Pure pipe firehose CI | **yes** | ≤128 KiB HW | ≤128 KiB HW |
| Live HTTPS oneshot | CT **yes** / PT materialize | **O(body)** in `resp_buf` | ~one slab + OpenSSL BIO |
| Live dual-CT seal∥send | **Not claimed** | — | — |

**Honesty:** pure O(window) proven; live oneshot CT windowed; PT materialize disclosed via status + large-cell ⏳.

### WOWED: **yes**

For claimed scope, pure firehose is WOW-grade; live serial oneshot is the **named** product slice. R1 withheld because packaging sold dual algorithms as one Done — packaging fixed; physics for each claim holds.

---

## 3. Memory — Score **9.3** / WOWED **yes**

### What is solid

1. **Clear-H1 idle:** `q == nil`, no CT slabs, `ciphered == false` (R2/R3 win held).
2. **Live Open tax (host CT-ish):** `tls_ct_rx` (~16 KiB) + `tls_ct_tx` (64 KiB) only — **no** unused pipe CT[2] (128 KiB) + seal_q (~1.3 KiB). R1 ~210 KiB zombie stack **gone**.
3. **Destroy frees engine + host CT + optional SM bags** — 115 tests under mem tracking green.
4. **Idempotent destroy** (`test_tls_host_conn_destroy_idempotent`).
5. **Partial alloc rollback** on accept; BIO ownership via `SSL_set_bio` / `SSL_free`.
6. **SM bags only on pure path** via `connection_enable_ciphered_pipe_sm` — density law matches use.

### Majors

**None remaining** under claimed scope.

| R1 Major | Status |
|----------|--------|
| MEM-M1 triple CT / zombie dual slabs | **Closed** |
| MEM-M2 oneshot PT = materialize | **Demoted** — in-claim for oneshot; bulk bound is phase residual |
| MEM-M3 metrics ≠ dual-slab occupancy | **Minor** — dual-slab not live; meters still not materialize HWM |

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | Oneshot PT peak = materialize size for multi-CQE flush duration (OK for demo; large stays ⏳). |
| **MEM-m2** | `SSL_shutdown` / provider process-global lifetime — intentional. |
| **MEM-m3** | `resp_buf` capacity sticky across keep-alive (clear-H1 same). |
| **MEM-m4** | Optional: N concurrent HTTPS oneshot destroy leak stress in CI. |

### Free-order audit (destroy)

```text
connection_destroy
  stream_slot_reset_exchange
  tls_host_conn_destroy
    SSL_shutdown (best effort)
    conn_free                  // SSL + owned BIOs
    delete tls_ct_rx, tls_ct_tx
    connection_disable_ciphered
      free seal_q if any
      free pipe CT slabs if any
      ciphered = false
  pt_ring_init / wire_conn_init / tls_pipe_init
```

**No Fatal free-order bug found** under single-threaded CQE model + `close_on_io`. Lightweight path skips bag free work harmlessly.

### WOWED: **yes**

Free-on-destroy competent; **not paying for dual-CT seal∥send you do not run** restores the density win R1 said was reintroduced. Memory WOW clear for claim.

---

## 4. Shortcuts / honesty — Score **9.5** / WOWED **yes**

### What matches the tree

| Surface | Claim | Match |
|---------|-------|-------|
| `IMPLEMENTATION_STATUS.md` | Pure seal∥send + firehose **Done**; live dual-CT seal∥send **Not yet**; host wire **Done (oneshot)** serial | **Match** |
| Same | Lightweight enable (no seal_q/CT[2]); full SM via `*_pipe_sm` | **Match** |
| `TLS_H1.md` | Same split; oneshot serial; pure CI gate | **Match** |
| `CAPABILITY_MATRIX.md` | TLS H1 oneshot ✅; large / SSE / WS ⏳ | **Match** |
| Explicit non-claims | Not full TLS product; not H2; not M1–M6 | **Match** |
| Fail-open to clear-H1 | Provider/PEM fail logs and serves clear | **Match** |
| `check_firehose_pipe.sh` | Pure path + http tests; **not** HTTPS e2e; header names serial live | **Match** (R1 HON-m1 fixed) |
| Demo | Self-signed; manual curl | **Match** |

### Majors

**None remaining.**

| R1 Major | Status |
|----------|--------|
| HON-M1 scorecard conflation pure/live | **Closed** — split rows |
| HON-M2 third seal path + zombie bags | **Closed** — sever + honest serial wording |

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | In-code comment “no cipher path in host yet” in `plan_policy_for` (CQ-m1 twin) — one-line doc fix. |
| **HON-m2** | No CI job for HTTPS oneshot (manual only) — **honestly** not claimed as CI; residual E0.4 TLS same-handler CI not wired. |
| **HON-m3** | Matrix “Phase 2” vs eng “PR5” naming — navigable with status as canonical. |

### PR5 exit checklist vs claim

| Claim signal | R2 reality | Grade |
|--------------|------------|-------|
| TLS H1 oneshot host wire | Live serial mem-BIO + windowed CT | **Met** |
| mem-BIO / dynlib | Live + tests | **Met** |
| Pure seal∥send + firehose CI | Dual CT SM + 4 MiB sim + script | **Met** |
| Lightweight enable (no zombie CT[2]) | Code + tests | **Met** |
| Docs: live ≠ dual-CT seal∥send | Status / TLS_H1 / script | **Met** |
| Live dual-CT seal∥send | Explicit **Not yet** | **Honest non-claim** |
| SSE/WS on TLS | Out of claim | N/A |

### WOWED: **yes**

Honesty is the strongest axis. Scorecard packaging now **tracks** the two architectures instead of selling them as one Done. That was the R1 withhold; it is closed.

---

## Cross-cutting residual table (priority)

| Pri | ID | Axis | Action |
|----:|----|------|--------|
| 1 | **PERF-m1 / MEM-m1** | P+M | Keep large TLS ⏳; when bulk ships, produce/seal ≤ window without full-body `resp_buf` residency (PT ring / progressive). |
| 2 | **PR5.1** | P+Q | Optional product: drive `pipe_seal_step` with real `Cipher_Seal_Fn` (SSL_write+wBIO → CT[i]) **or** leave serial forever with scorecard staying honest. |
| 3 | **CQ-m1 / HON-m1** | Q+H | One-line fix: drop “no cipher path in host yet” in `plan_policy_for`. |
| 4 | Free-order stress | Q | Mid-flush close + HS CQE after destroy-defer (optional). |
| 5 | E0.4 TLS CI | H | Optional HTTPS oneshot smoke in CI when libssl present. |

None of these re-open Majors under **claimed** PR5 scope.

---

## What is **not** a ding under claimed scope

- No SSE/WS on TLS  
- No H2 / ALPN h2  
- No automated multi‑MiB HTTPS firehose on ring  
- No live dual-CT seal∥send on wire (explicit Not yet)  
- No peer RPS floors / TFB HTTPS  
- Dynlib skip when OpenSSL absent  
- Self-signed demo PEMs  
- Serial live SSL_write (named architecture for oneshot)

---

## One-line summary

**PR5 oneshot HTTPS is real; pure dual-CT firehose CI is real; zombie CT[2] on Open is gone; docs split pure Done from live serial oneshot — R1 Majors closed; all four axes WOW for claimed scope.**

| | |
|--|--|
| **Ship oneshot?** | Yes, with OpenSSL dynlib + PEMs |
| **Ship dual-CT seal∥send product on wire?** | **No** — pure only (honest Not yet) |
| **WOW any axis?** | **Yes — all four** |
| **Mean** | **9.3** |

---

## Appendix A — key file anchors

| File | Role |
|------|------|
| `/Users/bngreer/Projects/proactr-odin/http/tls_host.odin` | Live mem-BIO HS + Open decrypt + serial windowed flush; lightweight enable only |
| `/Users/bngreer/Projects/proactr-odin/http/pipe.odin` | Pure seal∥send SM; `connection_enable_ciphered` vs `_pipe_sm` sever |
| `/Users/bngreer/Projects/proactr-odin/http/pipe_test.odin` | Lightweight nil-bags + pipe_sm bags + firehose bulk |
| `/Users/bngreer/Projects/proactr-odin/http/response.odin` | `plan_policy_for` ciphered; respond → `tls_plain_rest` |
| `/Users/bngreer/Projects/proactr-odin/http/wire.odin` | `_host_on_wire_send` → `tls_host_on_send_complete` |
| `/Users/bngreer/Projects/proactr-odin/tls_server/provider_openssl_dynlib.odin` | Dynlib + mem-BIO product path |
| `/Users/bngreer/Projects/proactr-odin/examples/https_demo/main.odin` | Manual oneshot |
| `/Users/bngreer/Projects/proactr-odin/scripts/check_firehose_pipe.sh` | Pure firehose gate (honest header) |
| `/Users/bngreer/Projects/proactr-odin/docs/IMPLEMENTATION_STATUS.md` | Ship honesty scorecard (split pure / live) |
| `/Users/bngreer/Projects/proactr-odin/docs/TLS_H1.md` | Implementer TLS notes |

## Appendix B — live vs pure (post-sever)

| Property | Pure pipe CI | Live HTTPS oneshot |
|----------|--------------|--------------------|
| OpenSSL | no | yes (dynlib) |
| Ring / CQE | no (sim complete) | yes |
| CT slots used | 2 | 1 (`tls_ct_tx`) |
| Seal while send | yes (test) | **no** (serial — claimed) |
| PT source | staging ≤ HW | full `resp_buf` (oneshot) |
| Peak PT claim | ≤128 KiB | O(body) materialize |
| Firehose CI | yes | **no** |
| Enables seal_q+CT[2] | yes (`*_pipe_sm`) | **no** (lightweight only) |

## Appendix C — score delta vs r1

| Axis | r1 | r2 | Driver |
|------|---:|---:|--------|
| Code quality | 7.9 | **9.2** | Sever dual-CT ownership; half-wire gone |
| Performance | 7.1 | **9.1** | Dead dual-CT tax gone; serial in-claim; pure still elite |
| Memory | 7.4 | **9.3** | ~128 KiB+ zombie slabs removed per Open conn |
| Honesty | 8.4 | **9.5** | Scorecard split pure Done / live Not yet |
| **Mean** | **7.7** | **9.3** | R1 Majors closed for claim |
