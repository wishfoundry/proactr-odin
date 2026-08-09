# Implementation Critics — PR5 r1 (multi-axis)

**Posture:** harsh elite. Credit only what the live wire or pure CI actually owns.  
**Bar:** WOW ≥ 9 for **claimed PR5 scope only**:

| Claimed in | Claimed out |
|------------|-------------|
| HTTPS H1 **oneshot** e2e (curl green) | SSE / WS on TLS |
| Pipe O(window) firehose **pure** CI | H2 / M1–M6 |
| `tls_server` dynlib OpenSSL **mem-BIO** | Full bulk multi‑MiB HTTPS firehose CI on ring |
| `connection_enable_ciphered` + `plan_policy` | Production “HTTPS complete” marketing |

**Not required for WOW:** Phase 2 product matrix cells beyond oneshot.  
**Required for WOW:** no lies, no critical UAF / free-order bugs, honest window / seal∥send physics for the claimed layer (oneshot live + pure pipe).

**Date:** 2026-08-08  
**Subject:** live tree under `http/tls_host.odin`, `http/pipe.odin`, `http/response.odin` ciphered branch, `http/wire.odin` send hooks, `tls_server/*`, `examples/https_demo`, `docs/IMPLEMENTATION_STATUS.md`, `docs/TLS_H1.md`, `docs/CAPABILITY_MATRIX.md`.

---

## Verify (this pass)

| Command | Result |
|---------|--------|
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **114/114 pass** (includes OpenSSL tls_host smoke when libssl loads) |
| `odin test tls_server -o:none` | **6/6 pass** |
| `./scripts/check_firehose_pipe.sh` | **OK** (presence gate + full http suite) |
| Manual: `examples/https_demo` + `curl -k --http1.1 https://127.0.0.1:18443/` | **200 / `OK`** |

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **7.9** | **no** | Major |
| Performance | **7.1** | **no** | Major |
| Memory | **7.4** | **no** | Major |
| Shortcuts / honesty | **8.4** | **no** | Minor→Major fringe |
| **Mean** | **7.7** | — | — |

**Verdict:** PR5 **oneshot HTTPS is real** (not paper). Pure pipe seal∥send + firehose detector is real. Status docs mostly refuse product overclaim. **WOW is withheld on all four axes** because the live ciphered send path is a **third architecture** (serial SSL_write → single `tls_ct_tx`) that **allocates but does not drive** the dual-CT `pipe_seal_step` machine the PR5 scorecard sells as “Done,” and live oneshot is **materialize-then-window** (O(body) PT residency) while pure firehose CI proves O(window) on a **mock** path only.

No critical UAF / SSL double-free found in the destroy path. That clears the “fatal free-order” bar but is not sufficient for WOW.

---

## Architecture map (what actually owns the socket)

```text
CLEAR H1
  respond → materialize → Wire_State.pending_send → host_submit_send
  pipe bags: init only; seal_q nil; ciphered false

TLS H1 ONESHOT (live — PR5 host)
  accept → SSL + mem-BIO + tls_ct_rx/tx scratch
  Handshake: CT→rBIO, SSL_accept, wBIO→tls_ct_tx→submit_send
  Open: enable_ciphered (alloc seal_q + CT[2] slabs — see Major)
        CT→rBIO, SSL_read PT→scanner (same parse)
  respond: materialize full PT into resp_buf
        tls_plain_rest = buf
        loop: SSL_write(window) → bio_read_net(tls_ct_tx) → submit_send
              wait CQE → next window   ← SERIAL, one CT scratch
  destroy: SSL_shutdown best-effort; SSL_free; free rx/tx; disable_ciphered

PIPE PURE (tests + check_firehose_pipe)
  pipe_seal_step / pipe_mark_send / pipe_on_send_complete
  dual CT, seal_n∈{0,1,2}, dual HW, firehose_fail
  mock identity seal — NO OpenSSL, NO ring
```

**Grep fact:** `http/tls_host.odin` contains **zero** calls to `pipe_seal_step`, `pipe_mark_send`, or `pipe_on_send_complete`. Live seal is OpenSSL + `tls_ct_tx` only.

---

## 1. Code quality — Score **7.9** / WOWED **no**

### What is elite for claimed oneshot scope

1. **Opaque SSL surface.** `tls_server.Conn` / `Ctx` only; no `SSL*` in handlers / APP_CONTRACT. Dynlib provider + nil-safe wrappers are clean IOC.
2. **Mem-BIO product law is coded, not slogan.** `setup_mem_bios` → `bio_write_net` / `bio_read_net` / `bio_pending_out`; `set_fd` labeled fallback. Darwin deliberately avoids Apple system libssl (abort trap).
3. **Clear dual path is honest at runtime.** PEMs empty or provider/PEM fail → log + clear-H1 only (`server_tls_init` false). Clear accept path unchanged.
4. **Wire integration points are local and readable.**  
   - Accept: `server_tls_live` → `tls_host_on_accept` + arm CT recv.  
   - Recv: `tls_ssl != nil` → `tls_host_on_recv`.  
   - Send complete: `_host_on_wire_send` → `tls_host_on_send_complete` before clear finish.  
   - Recv arm: Open prefers `SSL_read` then CT arm.
5. **Free-order on destroy is fail-closed for engine + host CT.**  
   `connection_destroy` → `tls_host_conn_destroy`: `shutdown` → `conn_free` → delete `tls_ct_rx`/`tls_ct_tx` → `connection_disable_ciphered` (seal_q + pipe CT slabs).  
   Close defers while `_conn_wire_in_flight` (`close_on_io`) — same law as clear gather/sendfile.
6. **`plan_policy_for` ciphered demotions are real.** `ciphered` ⇒ `sendfile_ok=false`, `zero_copy_send=false`, `max_write_unit = PULL_WINDOW`. Respond skips Writev/Sendfile when `conn.ciphered`. Plan tests lock File+Ciphered → materialize.
7. **Partial-write modes set** (`SSL_MODE_ENABLE_PARTIAL_WRITE | ACCEPT_MOVING_WRITE_BUFFER`) — correct for windowed `SSL_write` cursor.

### Fatal

**None found** for free-order / UAF under claimed oneshot path:

| Check | Evidence |
|-------|----------|
| SSL free once | `conn_free` after optional shutdown; BIOs owned by SSL via `SSL_set_bio` |
| CT scratch free | delete rx/tx with conn_allocator |
| seal_q / pipe CT free | `connection_disable_ciphered` |
| Inflight send before free | `connection_close` defers on wire.kind |
| `tls_plain_rest` lifetime | view into `resp_buf` until flush empties; `clean_request_loop` only after full drain |

### Majors

| ID | Issue | Why Major under PR5 claim |
|----|--------|---------------------------|
| **CQ-M1** | **Dual CT ownership — dead pipe vs live host** | `connection_enable_ciphered` allocates `Seal_Queue` + `Tls_Pipe` CT[2] slabs. Live flush never touches `pipe.bufs` / `seal_n` / Seal_SM. A second CT plane (`tls_ct_tx`) owns every product seal. Two truth systems for “ciphertext ready to send.” |
| **CQ-M2** | **Law S1 still dual: `Wire_State` sole submit; `Tls_Pipe` Seal_SM idle on live** | Acceptable as interim **if** documented as temporary. Today the host both enables pipe bags **and** ignores them for seal, which is worse than “not wired yet” — it is **wired halfway**. |
| **CQ-M3** | **PT admission vs materialize truth** | `tls_host_flush_response` calls `pt_admit` / `pt_release` around each SSL_write window, but the full PT body already lives in `resp_buf`. Meters and dual-HW language pretend windowed admission while the real PT peak is materialize size. |

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Stale comments: `plan_policy_for` still says “no cipher path in host yet”; `Connection` still says pipe bags “not yet wired” while TLS host enables them. |
| **CQ-m2** | `SSL_shutdown` best-effort without WANT_READ/WRITE drain loop (acceptable oneshot; not production close polish). |
| **CQ-m3** | Host_dispatch Closing: clear exec and drop CQE without `tls_host_on_send_complete` — safe if destroy follows; residual plain_rest / pt.admitted cleaned only on destroy path. |
| **CQ-m4** | Scanner full free_n≤0 under Open arms CT again — oneshot-safe; long-lived / large request needs real compact/grow discipline. |
| **CQ-m5** | Package-public host zoo (`connection_enable_ciphered`, seal_q_*, progressive stream_*) still importable — R3 residual, not PR5-specific. |

### What would WOW (≥9)

1. **One CT seal owner on the live path:** either drive `pipe_seal_step` with a real `Cipher_Seal_Fn` wrapping SSL_write+wBIO drain into `CT[i]`, **or** delete/disable dual-slab alloc until that land — no zombie CT[2].
2. Single “can I submit_send?” helper that both clear and TLS use (Law S1 story).
3. Free-order unit that exercises: HS CT inflight → peer reset → destroy (no free under CQE); Open multi-window respond → close mid-flush.
4. Kill stale “not yet wired / no cipher path” comments the same PR that wires ciphered.

### WOWED: **no**

Working oneshot with clean opaque SSL is strong craft. Parallel dead dual-CT + live single-buffer seal is a structure dual that R4 already rejected on other bags. Score holds below 8.5.

---

## 2. Performance — Score **7.1** / WOWED **no**

### What is real

| Path | Behavior | Grade |
|------|----------|-------|
| Pure `pipe_seal_step` | Dual CT, seal while send inflight (`test_pipe_seal_send_parallel_two_slots`) | **Real pure physics** |
| Pure 4 MiB bulk sim | peak_pt = peak_ct = 128 KiB (= HW); firehose detector green | **Real pure CI** |
| Live oneshot | Windowed `SSL_write` ≤ `PULL_WINDOW` (64 KiB), multi-CQE CT | **Not one giant SSL_write** |
| Live plan | Ciphered demotes sendfile/zc; skips optimize Writev/Sendfile | **Correct demotion** |
| Clear-H1 | Unchanged when TLS off | **No RPS poison observed in suite** |

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **PERF-M1** | **seal∥send on live wire is serial, not parallel** | After each CT `host_submit_send`, host waits CQE (`tls_host_on_send_complete` → next `tls_host_flush_response`). Never seals CT[1] while CT[0] is in sock send. Dual-CT pure tests do **not** describe live HTTPS. |
| **PERF-M2** | **Materialize-then-window (O(body) PT before any seal)** | `respond`: always `_response_materialize_cmds` for ciphered (and default clear). Then `tls_plain_rest = full buf`. Plan A product write pipeline is “windowed PT → seal → CT”; live PR5 is “full PT → windowed seal.” For tiny “OK” oneshot this is fine; as **PR5 exit physics** it is not bulk-honest. |
| **PERF-M3** | **Dead dual-CT tax every Open conn** | `tls_pipe_alloc_buffers` = 2 × 64 KiB CT slabs + `Seal_Queue` (~1.3 KiB) allocated on handshake Open, then idle for the entire connection lifetime. Live CT uses separate `tls_ct_tx` (another 64 KiB). Seal∥send “Done” costs RSS without throughput. |

### Minors

| ID | Issue |
|----|--------|
| **PERF-m1** | Single `tls_ct_tx` drain per SSL_write; residual wBIO > slab size drains on next loop (correct but not overlapped with next seal). |
| **PERF-m2** | Metrics `tls_peak_pt` track `pt.admitted` (window fiction), not `len(resp_buf)` — useless as live firehose RSS proxy. |
| **PERF-m3** | No multi-MiB HTTPS bulk bench in tree (correctly not claimed as CI). |

### Honesty of “windowed send”

| Claim layer | Windowed? | Peak PT | Peak CT (host-owned) |
|-------------|:---------:|---------|----------------------|
| Pure pipe firehose CI | **yes** | ≤128 KiB HW | ≤128 KiB HW |
| Live HTTPS oneshot | CT yes / PT **no** | **O(body)** in `resp_buf` | ~one slab + OpenSSL internal BIO |
| Live HTTPS multi‑MiB (not CI) | same pattern | **O(body)** materialize | serial slabs |

**Windowed send honesty score for live path: partial.** CT is windowed; PT residency is not.

### What would WOW

1. Live path: produce/seal unit ≤ `PULL_WINDOW` **without** holding full body in `resp_buf` for multi‑MiB (or explicitly mark large-body ⏳ and keep oneshot materialize only for small — matrix already ⏳ for large TLS; **code comments and scorecard must match**).
2. Live seal∥send: seal into free CT while sock send inflight **or** rename PR5 scorecard line to “serial windowed SSL_write (dual-CT pure only).”
3. Stop allocating dual CT until the SM drives them.
4. Optional: oneshot microbench (handshake + small body) recorded — not required for WOW if honesty is clean.

### WOWED: **no**

For claimed scope, pure firehose is WOW-grade physics; **live host is a different algorithm**. Performance WOW for “PR5 seal∥send + oneshot” cannot pass while those are split.

---

## 3. Memory — Score **7.4** / WOWED **no**

### What is solid

1. **Clear-H1 idle path still thin on seal storage** until Open: `q == nil`, no CT slabs, `ciphered == false` (R2/R3 win held for non-TLS conns).
2. **Destroy frees engine + host CT + pipe enable set** — suite runs under mem tracking green (114 tests).
3. **Idempotent destroy** (`test_tls_host_conn_destroy_idempotent`).
4. **Partial alloc rollback** on `tls_host_on_accept` (rx fail → free ssl; tx fail → free rx + ssl).
5. **BIO ownership:** `SSL_set_bio` takes both; `SSL_free` releases — no host BIO_free double path.

### Majors

| ID | Issue | Approx cost / TLS Open conn |
|----|--------|-----------------------------|
| **MEM-M1** | **Triple CT reservation** | `tls_ct_rx` (~16 KiB default) + `tls_ct_tx` (64 KiB) + **unused** pipe CT[2] (128 KiB) + seal_q (~1.3 KiB) ≈ **~210 KiB** host CT-ish tax before any app body. Pipe dual slabs earn **zero** live work. |
| **MEM-M2** | **Oneshot PT peak = materialize size** | Full headers+body in `resp_buf` for entire multi-CQE seal. Pure firehose “O(window)” does **not** bound live HTTPS PT. Matrix marks large TLS ⏳ — good — but enable_ciphered + pt_admit choreography **suggests** dual-HW control that does not bound `resp_buf`. |
| **MEM-M3** | **Metrics vs reality** | Server atomics `tls_peak_pt` / `tls_peak_ct` / `tls_seal_units` measure admit windows and CT submit sizes — **not** dual-slab occupancy or materialize high-water. Using them as firehose proof would be a lie. |

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | `SSL_shutdown` may leave session tickets / error queue; not a host slab leak. |
| **MEM-m2** | Provider process-global `g_default` never unloaded — intentional dynlib lifetime. |
| **MEM-m3** | `resp_buf` capacity retained across keep-alive (clear-H1 same) — fine for oneshot demo; multi‑MiB growth sticky until clear. |
| **MEM-m4** | Handshake and response share one `tls_ct_tx` — good density; conflicts only if concurrent HS+response (not oneshot). |

### Free-order audit (destroy)

```text
connection_destroy
  stream_slot_reset_exchange   // pad free-before-zero (R2 fixed)
  tls_host_conn_destroy
    SSL_shutdown (best effort)
    conn_free                  // SSL + owned BIOs
    delete tls_ct_rx, tls_ct_tx
    connection_disable_ciphered
      free seal_q
      free pipe CT slabs + Tls_Pipe_Buffers
  pt_ring_init / wire_conn_init / tls_pipe_init
```

**No Fatal free-order bug found** for this order under single-threaded CQE model + `close_on_io`.

### What would WOW

1. Live CT slabs: **either** use pipe CT[2] for product seal **or** do not allocate them on enable.
2. Bound or document live PT: materialize only under copy budget; large ciphered bodies deferred into PT ring (Plan A PT1) before claiming bulk memory laws.
3. Peak meters that include `len(resp_buf)` / true host CT high-water if exposed for ops.
4. Stress: N concurrent HTTPS oneshots → destroy all; leak tracker zero (optional CI).

### WOWED: **no**

Free-on-destroy is competent. **Paying for dual-CT seal∥send you do not run** is a density miss identical in spirit to the R1 embedded `Seal_Queue` on every Connection — already fixed once for clear-H1, reintroduced as Open-only zombie.

---

## 4. Shortcuts / honesty — Score **8.4** / WOWED **no**

### What is genuinely honest (credit)

| Surface | Claim | Match to tree |
|---------|-------|---------------|
| `IMPLEMENTATION_STATUS.md` | HTTPS H1 oneshot Done; SSE/WS/bulk live firehose **Not yet** | **Match** (curl green this pass) |
| `TLS_H1.md` | Same; pure firehose CI; not full product | **Match** |
| `CAPABILITY_MATRIX.md` | TLS H1 oneshot ✅; large / SSE / WS ⏳ | **Match** |
| Explicit non-claims | Not full TLS product; not H2; not M1–M6 | **Match** |
| Fail-open to clear-H1 | Provider/PEM fail logs and serves clear | **Match** |
| `check_firehose_pipe` | Pure path + http tests; **not** HTTPS e2e | Presence gate is real; odin test green |
| Demo | Self-signed; not E0 sample; manual | **Match** |

This is **much better** than early dual-tls drafts that papered H2. PR5 status writing largely refuses marketing theater.

### Majors (honesty fringe — not product lies, but PR5 scorecard risk)

| ID | Issue | Risk |
|----|--------|------|
| **HON-M1** | Scorecard line **“PR5 pipe seal∥send + firehose \| Done”** is **pure-path true**, **live-wire false** | Readers (and future README) conflate dual-CT parallel seal with HTTPS host. Detail rows partially save it; the bold Done does not. |
| **HON-M2** | Live host **implements a third seal path** while still enabling the pure path’s bags | Looks like seal∥send product landed when it is **serial SSL_write + unused dual CT**. |

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | `scripts/check_firehose_pipe.sh` header still says “host wire is still **Partial**” while `TLS_H1.md` / status say host wire **Done (oneshot)**. Stale script vs docs. |
| **HON-m2** | No CI job for HTTPS oneshot (manual only) — **honestly** not claimed as CI; residual E0.4 “TLS same-handler CI not yet wired.” |
| **HON-m3** | Stale in-code comments (“no cipher path in host yet”) contradict landed host. |
| **HON-m4** | Matrix “Phase 2” label for oneshot vs eng “PR5” naming — navigable if status is canonical. |

### PR5 exit checklist vs Plan A Phase 2 (oneshot slice)

| Plan A Phase 2 signal | PR5 r1 reality | Grade |
|----------------------|----------------|-------|
| TLS H1 oneshot curl | Green (manual) | **Met** |
| mem-BIO host | Live | **Met** |
| Pipe seal∥send physics | Pure + tests; **not** live SM | **Partial** |
| Firehose peak ≤~4× HW CI | Pure mock 4 MiB | **Partial** (pure only) |
| Conn_Pt_Ring must-alias seal input | Live seal reads `tls_plain_rest` ⊂ `resp_buf`, not PT ring | **Not met** on live |
| SSE/WS on TLS | Out of claim | N/A |

### What would WOW

1. Split scorecard rows:  
   - `PR5 pure seal∥send + firehose CI` → Done  
   - `PR5 live host seal` → “serial windowed SSL_write (dual-CT SM not on wire)” or Done only after SM drives CT.  
2. Fix `check_firehose_pipe.sh` Partial stale line.  
3. Optional: one CI-optional HTTPS oneshot smoke (skip without libssl) so “curl green” is not tribal knowledge.  
4. No claim that live PT is O(window) until materialize policy changes or large stays ⏳ with code comments matching.

### WOWED: **no**

Honesty is the strongest axis (~8.4). Withheld from 9 because **seal∥send “Done” packaging outruns the live host**, and the zombie dual-CT alloc makes that packaging load-bearing rather than pedantic.

---

## Cross-cutting defect table (priority)

| Pri | ID | Axis | Action |
|----:|----|------|--------|
| 1 | **CQ-M1 / PERF-M1 / MEM-M1** | Q+P+M | **Unify or sever:** drive `pipe_seal_step` on live **or** stop allocating CT[2]/seal_q on enable until SM is live. Prefer one CT plane. |
| 2 | **PERF-M2 / MEM-M2** | P+M | Document live oneshot as materialize-then-window; keep large TLS ⏳; do not let `pt_admit` cosplay O(window) PT. |
| 3 | **HON-M1** | H | Split IMPLEMENTATION_STATUS Done lines (pure vs live seal). |
| 4 | **HON-m1 / CQ-m1** | H+Q | Refresh script header + stale comments in same cleanup PR. |
| 5 | CQ free-order stress | Q | Mid-flush close + HS CQE after destroy-defer tests. |

---

## What is **not** a ding under claimed scope

- No SSE/WS on TLS  
- No H2 / ALPN h2  
- No automated multi‑MiB HTTPS firehose on ring  
- No peer RPS floors / TFB HTTPS  
- Dynlib skip when OpenSSL absent (tests skip, not fail)  
- Self-signed demo PEMs  

These are correctly non-claims in status docs.

---

## One-line summary

**PR5 oneshot HTTPS works (curl 200); pure dual-CT firehose CI works; live seal is a serial SSL_write sidecar that allocates the parallel machine it does not run — competent ship of the thin claim, not WOW-grade physics or ownership unification.**

| | |
|--|--|
| **Ship oneshot?** | Yes, with OpenSSL dynlib + PEMs |
| **Ship dual-CT seal∥send product?** | **No** — pure only |
| **WOW any axis?** | **No** |
| **Mean** | **7.7** |

---

## Appendix A — key file anchors

| File | Role |
|------|------|
| `/Users/bngreer/Projects/proactr-odin/http/tls_host.odin` | Live mem-BIO HS + Open decrypt + serial windowed flush |
| `/Users/bngreer/Projects/proactr-odin/http/pipe.odin` | Pure seal∥send SM, dual CT, firehose_fail, enable_ciphered alloc |
| `/Users/bngreer/Projects/proactr-odin/http/response.odin` | `plan_policy_for` ciphered; respond → `tls_plain_rest` |
| `/Users/bngreer/Projects/proactr-odin/http/wire.odin` | `_host_on_wire_send` → `tls_host_on_send_complete` |
| `/Users/bngreer/Projects/proactr-odin/tls_server/provider_openssl_dynlib.odin` | Dynlib + mem-BIO product path |
| `/Users/bngreer/Projects/proactr-odin/examples/https_demo/main.odin` | Manual oneshot |
| `/Users/bngreer/Projects/proactr-odin/scripts/check_firehose_pipe.sh` | Pure firehose gate (stale Partial comment) |
| `/Users/bngreer/Projects/proactr-odin/docs/IMPLEMENTATION_STATUS.md` | Ship honesty scorecard |
| `/Users/bngreer/Projects/proactr-odin/docs/TLS_H1.md` | Implementer TLS notes |

## Appendix B — live vs pure (one table)

| Property | Pure pipe CI | Live HTTPS oneshot |
|----------|--------------|--------------------|
| OpenSSL | no | yes (dynlib) |
| Ring / CQE | no (sim complete) | yes |
| CT slots used | 2 | 1 (`tls_ct_tx`) |
| Seal while send | yes (test) | **no** |
| PT source | staging ≤ HW | full `resp_buf` |
| Peak PT claim | ≤128 KiB | O(body) |
| Firehose CI | yes | **no** |
| Enables seal_q+CT[2] | tests | **yes, unused** |
