# Harsh critic — TLS/H2 peer matrix — R1

Role: adversarial correctness + honesty for **proactr vs ntex / drogon / go** under **TLS** and **HTTP/2**.

**Scope:** `comparisons/tls-h2/` harness + peers + instrumentation  
**Do not** accept cleartext TFB numbers as TLS/H2 evidence.

---

## Verdict

**Verdict:** PASS  
**Date:** 2026-08-08  
**Built peers:** proactr, ntex, drogon, go (source + build scripts present; not empty dirs)  
**Ran peers (smoke, ranch-bastion — operator-confirmed):**  
- proactr, ntex, go → Application protocol **h2**  
- drogon → Application protocol **http/1.1** only (h2 cells must be **N/A**)  
- All four serve `/plaintext` (13B) + `/_matrix/stats`  

**Published numbers caveat:** `results/BASTION_TLS_H2.md` + `bastion_summary.tsv` are a **partial older run** (proactr+go only, no `status`/`app_proto`/fail columns, BENCH_Z=10). They are **not** full four-peer evidence under the current fail-closed harness. Do not rank ntex/drogon from that file. Do not mix with `comparisons/tfb`.

---

## Backend labels (required)

| Peer | I/O | TLS stack | H2 |
|------|-----|-----------|-----|
| proactr | io_uring | OpenSSL mem-BIO | ALPN h2 host |
| ntex | neon-uring (Linux) | OpenSSL (`bind_openssl`) | ALPN h2\|http/1.1 |
| drogon | trantor **epoll** | OpenSSL | primarily H1; no_h2 → N/A |
| go | net/http epoll | crypto/tls | auto HTTP/2 |

Wire-path confirmation (not README-only):

| Peer | Evidence |
|------|----------|
| proactr | `proactr/main.odin` `listen_and_serve_tls`, `opts.thread_count=WORKERS`, path_metrics scrape |
| ntex | `ntex/src/main.rs` `HttpServer…bind_openssl`, `Cargo.toml` `neon-uring`+`openssl` on Linux |
| drogon | `drogon/main.cc` `addListener(..., true, cert, key)`, `setThreadNum`, stats `h2=limited_or_none` |
| go | `go/main.go` `ListenAndServeTLS`, `GOMAXPROCS=WORKERS`, no worker-thread claim |

Harness SUMMARY regenerates the same label table (`run_matrix.sh` ~346–352).

---

## Fake-bench checklist

| # | Check | Result | Notes |
|---|--------|--------|-------|
| C1 | ntex peer exists, builds, runs under TLS | PASS | `ntex/src/main.rs`, release binary `ntex-tls-h2` → `server.bin`; smoke h2 |
| C2 | drogon peer exists, builds, runs under TLS | PASS | `drogon/main.cc` + `build.sh`; smoke H1.s |
| C3 | go peer under TLS H1 + H2 | PASS | smoke h2 + h1s |
| C4 | Same routes, body lens, certs, WORKERS, host | PASS | `/plaintext` 13B, `/s/{4k,64k,1m}` same 64-char pattern, shared `certs/`, `WORKERS`, `0.0.0.0:$PORT` |
| C5 | h2 cell requires Application protocol h2 else N/A | PASS | `run_matrix.sh:199–204` → `status=no_h2`, `rps=N/A` |
| C6 | failed/errored/timeout → INVALID not silent RPS | PASS* | `run_matrix.sh:206–210` sets `INVALID`; *gap: empty/malformed h2load → `rps=?` can stay `status=ok` (see IMPORTANT) |
| C7 | Body content prefix (not length-only) | PASS* | `verify_bodies` len+prefix over **H1.s only**; H2 body not pre-checked (IMPORTANT) |
| C8 | Backend labels in SUMMARY | PASS | Generated table + fairness notes (GOMAXPROCS vs threads, drogon epoll) |
| C9 | Clear TFB numbers never mixed into this table | PASS | README + SUMMARY exclude TFB; drogon only **reuses Drogon install** from tfb path, not numbers |
| C10 | Instrumentation scrape after cells | PASS | `scrape_stats` after each cell → `instrumentation.txt` |
| C11 | drogon h2 not claimed as product win if no_h2 | PASS | Labels + startup `h2=not_product_claimed`; cells N/A via C5 |
| C12 | Worker model labels (GOMAXPROCS vs threads) | PASS | SUMMARY fairness notes; go sets `GOMAXPROCS` only |

### CRITICAL findings

*(none that break matrix honesty for ranking under the current harness + smoke)*

Smoke + wire paths support: real TLS peers, drogon h2 not sold as a win, fail-closed on nonzero failed/errored/timeout, shared certs/routes/loadgen.

### IMPORTANT findings

1. **Fail-closed gap when h2load output is empty/unparseable** — `comparisons/tls-h2/run_matrix.sh:194–211`  
   - Empty RPS → `rps="?"` but `status` can remain `ok` (especially **h1s**, where appproto is not forced).  
   - `parse_h2load_failed` defaults to `0 0 0` on miss (`:144`), so a format mismatch fails **open**.  
   - **Truthfulness:** silent `?` cells look completed.  
   - **Patch (harness only):** after parsing, if `rps` empty/`?` **or** no `finished in` / no `requests:` line → `status=fail`, `rps=INVALID`. Prefer parsing `succeeded` and requiring `succeeded > 0` when status would be `ok`.

2. **H2 response body not verified before load** — `run_matrix.sh:106–134`  
   - Prefix+len only via `curl --http1.1`. An H2-only handler bug could still produce RPS.  
   - C7 is partially satisfied (H1.s).  
   - **Patch:** for each test, also `curl -sk --http2` (or one-shot `h2load -n1`) and re-check len+prefix when peer is expected to speak h2.

3. **Stale / partial published bastion results** — `results/BASTION_TLS_H2.md`, `bastion_summary.tsv`  
   - Only proactr+go; no status/app_proto/failed columns; older BENCH_Z=10.  
   - **Truthfulness:** easy to mis-cite as the four-peer matrix.  
   - **Patch (docs):** banner at top of `BASTION_TLS_H2.md`:  
     `> PARTIAL (proactr+go only; pre-fail-closed TSV). Not four-peer evidence. Re-run with current run_matrix.sh.`  
   - Re-run full `SERVERS="proactr ntex drogon go"` under current harness before any ranking claim.

4. **proactr alone built with `HTTP_PHASE_STATS=true`** — `run_matrix.sh:219`  
   - Cycle counters on the hot path (`http/phase_stats.odin`); peers do not pay this.  
   - Biases **against** proactr (not a fake win), but impure for “fair RPS”.  
   - **Patch:** fair matrix build without PHASE; optional `TUNING=1` rebuild with PHASE + path_metrics scrape emphasis.

5. **path_metrics PT undercount when wBIO has no pending CT after `SSL_write`** — `http/tls_host.odin:904–923`, `http/h2_host.odin:772–788`  
   - Metrics only recorded when CT is drained (`path_metrics_note_ssl_write` / `path_metrics_note_h2_flush` + `ct_send`). OpenSSL record buffering can drop PT from counters while still advancing plain.  
   - **Impact:** `ct_pt_ratio`, `pt_bytes`, `h2_pt_bytes` less trustworthy for tuning (not RPS table honesty).  
   - **Fix (product, not harness):** count PT at successful `SSL_write` regardless of immediate BIO pending; keep CT on drain.

6. **`reqs` ≈ seal-cycle completion, not HTTP requests** — `path_metrics.odin:9`, hooks at `tls_host.odin:932–933`, `h2_host.odin:797–798`  
   - Incremented when plain/h2_out empties after a seal unit. Multi-frame / batching can skew vs h2load RPS. Documented as approx; peers count handler invocations.  
   - **Tuning:** compare proactr `reqs` to h2load carefully; prefer seal/ct/h2_flush ratios over req equality.

7. **Cipher policy not aligned across peers** — methodology, not fake-bench  
   - ntex: `SslAcceptor::mozilla_intermediate` (`ntex/src/main.rs:97`)  
   - go: `MinVersion: TLS12` + crypto/tls defaults  
   - proactr/drogon: OpenSSL stack defaults via each server  
   - **Label** in SUMMARY if rankings are tight; optional shared cipher list later.

### NIT findings

1. **proactr `/_matrix/stats` scrape walks the TLS seal path** → slightly contaminates path_metrics after the timed cell (peers’ stats handlers do not increment reqs/bytes). Prefer scrape-only counter exclusion or accept ±1 seal.  
2. **`path_metrics_note_seal` unused**; hosts open-code `atomic_add(&path_seal_calls)` (`tls_host.odin:931`, `h2_host.odin:796`) — fine, slightly inconsistent API.  
3. **drogon `CMakeLists.txt:7`** `../tfb/drogon/install` resolves under `tls-h2/tfb/…` (wrong); rescued by `PROACTR_ROOT/comparisons/tfb/...` and `build.sh`.  
4. **Server header** set by go/drogon only — header-byte differences only; body contract matches.  
5. **go build** unoptimized vs ntex LTO / proactr `-o:speed` / drogon Release — label if comparing absolute peaks.  
6. **h1s cells** do not assert Application protocol is `http/1.1` (only h2 is gated). Low risk with `h2load --h1`.

---

## Instrumentation adequacy (performance tuning next steps)

| Peer | Scrape | Adequacy |
|------|--------|----------|
| proactr | `/_matrix/stats` → seal_calls, ssl_write_ok, pt/ct, ct_pt_ratio, h2_flush, h2_pt_bytes, ct_sends, materialize (+ PHASE log if enabled) | **Good skeleton** for ciphered-path bottleneck hunting; fix PT-on-write undercount before trusting ratios. Hook sites: `tls_host.odin:928–933`, `h2_host.odin:793–798`, `plan.odin:138`. |
| ntex | reqs + bytes + tls/io labels | Meets matrix minimum; no seal/CT split — cannot explain OpenSSL vs app gap. |
| go | reqs + body Write bytes + labels | Meets minimum; body-only (not header/CT). |
| drogon | reqs + bytes + `h2=limited_or_none` | Meets minimum; labels honesty correctly. |

**Harness:** `reset_stats` before warmup and before timed cell; scrape after each cell; final scrape; optional PHASE lines from server log (`run_matrix.sh:291–296`).  

**Recommended tuning sequence (proactr):**  
1. Fix PT accounting at `SSL_write` success (IMPORTANT #5).  
2. Fair RPS run **without** `HTTP_PHASE_STATS`; separate tuning run with PHASE + path_metrics.  
3. Per cell, interpret: `h2_flush` vs RPS (frames/req), `ct_sends` vs `seal_calls` (batching), `ct_pt_ratio` (record overhead), `materialize` (plan path).  
4. Large-body H2: watch `h2_pt_bytes` vs expected `RPS × body` once PT accounting is fixed.  
5. Full four-peer bastion run under current harness before claiming relative standing on s64k/s1m (old bastion shows large H2 s64k gap proactr vs go — needs status-clean remeasure + instrumentation).

---

## Top remaining fixes (by truthfulness impact)

*(Verdict is PASS; these are the highest-value follow-ups, not blockers for “harness is not a fake-bench”.)*

1. **Harness fail-closed on missing/partial h2load parse** (`run_matrix.sh` bench_one) — reject `rps=?`, missing `requests:` / `finished in`, and optionally `succeeded==0`.  
2. **Re-run full four-peer matrix; quarantine stale `BASTION_TLS_H2.md`** — add PARTIAL banner; produce SUMMARY with status/app_proto/failed columns for proactr, ntex, drogon, go.  
3. **H2 pre-bench body len+prefix** + **fair proactr build flag** (no PHASE for ranking; PT metrics fix for tuning).

---

## Exact patches (harness/docs only — not applied)

### A. Fail-closed empty parse (`run_matrix.sh` inside `bench_one`, after parse)

```bash
# After appproto/rps/failed_line parse:
if [[ "$rps" == "?" || -z "$rps" ]] || ! grep -qE 'finished in' "$out" 2>/dev/null; then
  status="fail"
  rps="INVALID"
  echo "FAIL $peer $proto $test unparseable/empty h2load" | tee -a "$LOGDIR/errors.txt"
fi
# Optional: parse succeeded and require >0 when status would stay ok
```

### B. Banner on stale bastion results (`results/BASTION_TLS_H2.md` top)

```markdown
> **PARTIAL / HISTORICAL:** proactr+go only; pre-status TSV; not four-peer TLS/H2 evidence.
> Re-run: `./comparisons/tls-h2/run_on_bastion.sh` with current `run_matrix.sh`.
```

### C. Fair proactr build (`run_matrix.sh` `build_proactr`)

```bash
# Ranking default:
odin build . -out:server.bin -o:speed
# Tuning optional:
# odin build . -out:server.bin -o:speed -define:HTTP_PHASE_STATS=true
```

### D. H2 body check (sketch in `verify_bodies` or sibling)

```bash
# After H1.s checks, if peer is not drogon (or always attempt):
code=$(curl -sk -o "$body" -w "%{http_code}" --http2 "https://127.0.0.1:${PORT}${path}" || echo 000)
# same len+prefix asserts; on curl http2 failure for drogon, skip without failing peer
```

---

## Always-do compliance

1. Read wire paths, not README claims — done (peers + hosts + harness).  
2. Empty peer dirs = FAIL — **not empty**.  
3. CRITICAL / IMPORTANT / NIT — above.  
4. Top fixes ordered by truthfulness then RPS insight — above.  
5. Cleartext TFB numbers **not** used as TLS/H2 evidence.

---

## Summary for operators

Harness and peers are **honest enough to PASS**: shared workload, labeled I/O/TLS/H2, drogon h2 → N/A, nonzero loadgen failures → INVALID, instrumentation scrape present.  

Do **not** treat current `results/BASTION_*` as the four-peer scoreboard. Close the empty-parse fail-open gap before publishing; remeasure all four under the current script; use path_metrics/PHASE only with the accounting caveats above for proactr tuning.
