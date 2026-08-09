# Harsh critic — TLS/H2 peer matrix — R2

Role: adversarial correctness + honesty for **proactr vs ntex / drogon / go** under **TLS** and **HTTP/2**.

**Scope:** post–CRITIC_R1 fixes to harness + path_metrics hooks + four-peer bastion R1 numbers  
**Prior:** [`CRITIC_R1.md`](CRITIC_R1.md)  
**Do not** accept cleartext TFB numbers as TLS/H2 evidence.

---

## Verdict

**Verdict:** PASS  
**Date:** 2026-08-08  
**Built peers:** proactr, ntex, drogon, go  
**Ran peers (bastion R1 instrumented):** all four under current fail-closed TSV (`status`, `app_proto`, failed/errored/timeout)  

**Scoreboard of record:** [`BASTION_TLS_H2.md`](BASTION_TLS_H2.md) + [`bastion_summary.tsv`](bastion_summary.tsv) (fair INSTRUMENT=0 four-peer).  
**Instrumented companion:** [`BASTION_TLS_H2_R1_INSTRUMENTED.md`](BASTION_TLS_H2_R1_INSTRUMENTED.md) (PHASE+path_metrics first pass).

No **CRITICAL** honesty gaps remain. Residual items are tuning / polish only.

---

## R1 → R2 fix audit

| R1 IMPORTANT | Status in tree | Evidence |
|--------------|----------------|----------|
| Unparseable/empty h2load → INVALID | **Fixed** | `run_matrix.sh:231–241` — empty/`?`/non-numeric RPS → `status=fail`, `rps=INVALID` |
| H2 body len+prefix before load | **Fixed** | `verify_bodies` + `verify_one` h2 mode; ALPN gate via `h2load -n1` (`:140–163`) |
| INSTRUMENT=0 default (no PHASE) | **Fixed** | `build_proactr` only adds `HTTP_PHASE_STATS` when `INSTRUMENT=1` (`:260–268`) |
| Sanitized stats scrape | **Fixed** | `scrape_stats` `tr -cd '\11\12\15\40-\176'` (`:186–198`) |
| PT counted at SSL_write success | **Fixed** | `tls_host.odin:901–903` `path_metrics_note_ssl_write` before BIO pending; `h2_host.odin:771–773` `path_metrics_note_h2_flush` before BIO pending; CT only on drain |
| Stale bastion banner | **Fixed** | `BASTION_TLS_H2.md` PARTIAL/HISTORICAL header |
| Four-peer remeasure | **Done (R1 instrumented)** | All peers in TSV; drogon h2 = `N/A` / `no_h2` / `http/1.1` |

---

## Backend labels (required)

| Peer | I/O | TLS stack | H2 |
|------|-----|-----------|-----|
| proactr | io_uring | OpenSSL mem-BIO | ALPN h2 host |
| ntex | neon-uring | OpenSSL (bind_openssl) | ALPN h2\|http/1.1 |
| drogon | trantor **epoll** | OpenSSL | primarily H1; no_h2 → N/A |
| go | net/http epoll | crypto/tls | auto HTTP/2 |

Bastion R1 SUMMARY regenerates the same table; labels match wire paths.

---

## Fake-bench checklist

| # | Check | Result | Notes |
|---|--------|--------|-------|
| C1 | ntex TLS peer | PASS | Four-peer R1: h2 ok |
| C2 | drogon TLS peer | PASS | h1s ok; h2 N/A |
| C3 | go TLS H1+H2 | PASS | both ok |
| C4 | Same routes/bodies/certs/WORKERS | PASS | Unchanged contract |
| C5 | h2 requires Application protocol h2 else N/A | PASS | drogon cells `no_h2` / `N/A` |
| C6 | failed/errored/timeout → INVALID | PASS | Plus unparseable RPS → INVALID |
| C7 | Body content prefix | PASS | H1.s + H2 when ALPN h2 |
| C8 | Backend labels in SUMMARY | PASS | R1 instrumented file |
| C9 | No TFB numbers mixed in | PASS | |
| C10 | Instrumentation scrape after cells | PASS | Sanitize + scrape |
| C11 | drogon h2 not product win | PASS | WARN lines + N/A only |
| C12 | Worker model labels | PASS | GOMAXPROCS vs threads noted |

### CRITICAL findings

*None.*

### IMPORTANT residual (tuning / methodology — not ranking blockers)

1. **`parse_h2load_failed` still defaults to `0 0 0` on miss** (`run_matrix.sh:173`)  
   - Mitigated: invalid RPS already fails closed. Remaining edge is exotic (numeric RPS line without a matching `requests:` line).  
   - Optional: require `^requests:` present and optionally `succeeded > 0` when `status==ok`.

2. **Scrape still contaminates proactr path_metrics**  
   - Post-cell `GET /_matrix/stats` over H1.s: bastion excerpt shows `ssl_write_ok=1` / `materialize=1` on **h2** cells (scrape, not load).  
   - Fine for coarse ratios at millions of seals; subtract ~1 or exclude scrape path for precise accounting.

3. **`reqs` remains seal-cycle completion, not HTTP requests**  
   - e.g. h2 s64k: `reqs=90989` vs `seal_calls=181777` (multi-seal bodies). Compare to h2load RPS carefully.

4. **SUMMARY fairness text lags H2 body verify** (`run_matrix.sh:411`)  
   - Still says only “TLS HTTP/1.1 before load”; code also verifies H2 when ALPN works. Doc-only.

5. **Cipher suite policies still differ** (ntex mozilla_intermediate vs go/proactr/drogon defaults)  
   - Methodology label if rankings are tight; not fake-bench.

6. **Fair re-run without PHASE**  
   - Default harness is `INSTRUMENT=0` (no PHASE). R1 file name says “INSTRUMENTED” (path_metrics scrapes present; no PHASE lines in SUMMARY excerpt).  
   - If any bastion binary was built with `INSTRUMENT=1`, re-rank only after a confirmed fair rebuild. Operator notes fair re-run may still be in progress — treat R1 numbers as honest under path_metrics-always-on; confirm PHASE off before absolute peak claims.

7. **`bastion_instrumentation_r1.txt` may still be noisy/binary on disk**  
   - Harness now sanitizes; re-fetch after next run. SUMMARY excerpt of proactr stats is clean and usable.

### NIT

- h1s cells do not assert `app_proto == http/1.1` (low risk with `h2load --h1`).  
- go build not `-ldflags` optimized vs ntex LTO / proactr `-o:speed`.  
- `path_metrics_note_seal` still unused (hosts open-code seal_calls).

---

## Bastion R1 numbers — honesty read

From `bastion_summary_r1.tsv` (WORKERS=8, BENCH_C=100, BENCH_Z=15, WARMUP_Z=3):

| Check | Observation |
|-------|-------------|
| Fail-closed columns | Present; all timed cells `failed=errored=timeout=0` or drogon h2 `N/A` |
| drogon h2 | Four cells `status=no_h2`, `app_proto=http/1.1`, `rps=N/A` — correct, not a product win |
| proactr/ntex/go h2 | `app_proto=h2`, `status=ok` |
| No INVALID silent scores | No cell with numeric RPS and fail status |
| No TFB mix | Separate tree; not cited |

**Performance (context only, not critic pass/fail):**  
proactr leads small H2 oneshots (plaintext/s4k); ntex/go lead larger H2 bodies (s64k/s1m variously); drogon strong on H1.s large bodies. That split is **plausible product behavior**, not a harness lie — path_metrics show multi-seal on large H2 (`seal_calls ≫ reqs` for s64k/s1m).

---

## Instrumentation adequacy (post PT fix)

| Peer | Scrape | Adequacy |
|------|--------|----------|
| proactr | seal_calls, ssl_write_ok, pt/ct, ct_pt_ratio, h2_flush, h2_pt_bytes, ct_sends, materialize | **Usable for tuning.** PT-at-write fixed. Bastion h2.plaintext: `h2_flush≈reqs`, `ct_pt_ratio≈1.33` (small-record overhead); large bodies → ratio→1.0, multi-seal visible. |
| ntex/go/drogon | reqs + bytes + io/tls labels | Matrix minimum; no seal/CT split |

**Tuning next steps (not honesty blockers):**  
1. Drive down multi-seal cost on H2 large bodies (`seal_calls/reqs`, `ct_sends`).  
2. Ignore scrape’s +1 `ssl_write_ok`/`materialize` on h2 cells.  
3. Optional PHASE only under `INSTRUMENT=1` separate from ranking.  
4. After fair no-PHASE confirm, re-compare s64k/s1m H2 vs ntex/go.

---

## Top residual fixes (truthfulness → insight)

1. Optional: require `requests:` line + `succeeded>0` for `status=ok` (belt-and-suspenders on C6).  
2. Update SUMMARY fairness bullet to mention H2 body verify.  
3. Exclude `/_matrix/*` from path_metrics or document scrape delta for tuning purity.

---

## Always-do compliance

1. Wire paths read (harness + hosts + bastion TSV).  
2. Peer dirs non-empty.  
3. CRITICAL / IMPORTANT residual / NIT above.  
4. No cleartext TFB used as TLS/H2 evidence.

**Bottom line:** R1 IMPORTANT honesty gaps are closed in code and reflected in a clean four-peer bastion matrix. **PASS.** Further work is performance tuning and minor fail-closed/doc polish, not fake-bench remediation.
