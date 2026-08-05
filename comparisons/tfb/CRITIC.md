# Harsh critic — five-profile peer matrix (PROFILE_MATRIX.md)

Role: adversarial correctness + honesty reviewer for **proactr-mat / proactr-opt** vs **laytan / ntex / drogon**.

**Date:** 2026-08-05  
**Scope:** profile routes + harness (`run_profile_matrix.sh`, `run_bench.sh`)  
**Verdict:** **FAIL** (not wow-ready)

---

## Verdict: FAIL

Not shippable as a fair peer matrix until remaining IMPORTANT gaps are closed or explicitly waived in published numbers. CRITICAL harness/peer body-contract issues found this pass were patched in-tree (see “Fixes landed”); residual gaps still block PASS.

---

## Backend labels

| Peer | I/O | Assembled mechanism | File mechanism | SSE |
|------|-----|---------------------|----------------|-----|
| proactr-mat | proactr / io_uring (Linux) | `preconcat_blob` (g_assembled + respond_plain) | `file_read_full` (`respond_file`) | `sse_oneshot` **chunked TE** stream API |
| proactr-opt | same | `multi_send` (prefer_gather + 8× body_static) — **NOT** kernel writev | `file_chunked` (body_file + prefer_sendfile → pread chunks) — **NOT** kernel sendfile | same as mat |
| laytan | nbio / io_uring (Linux) | `preconcat_blob` | `file_read_full` (respond_file) | `sse_oneshot` CL body |
| ntex | neon-uring (Linux) | `preconcat_blob` (must stay labeled) | `file_read_full` (std::fs::read) | `sse_oneshot` CL body |
| drogon | trantor **epoll** | `preconcat_blob` (must stay labeled) | `file_read_full` (ifstream) | `sse_oneshot` CL body |

---

## Fake-bench findings

### CRITICAL (fixed this pass)

| # | Finding | Evidence | Fix landed |
|---|---------|----------|------------|
| C1 | **Body-check was length-only** | `tiny` and `gen` are both 13 B; a peer mapping `/gen/ok` → `Hello, World!` would pass. Assembled first-byte `'A'+i` never checked. `/file/1m` could be any 1 MiB blob. | `run_bench.sh` `verify_peer_bodies`: exact bytes for tiny/gen/sse; assembled 8× first-byte; blob pattern prefix; **file body `cmp` to `$PLAN_FILE_PATH`**; SSE `Content-Type` contains `event-stream`. |
| C2 | **proactr `/file/1m` in-memory fallback** | `on_file` served `P_1M` if path empty — forbidden “in-memory labeled as file”. | Removed fallback; 500 if path unset; mat uses `respond_file`, opt uses open fd + `body_file`. |
| C3 | **proactr SSE missing Content-Type** | `on_sse` set cache-control only; PROFILE requires `text/event-stream`. Peers set it. | Set `headers_set_content_type(..., "text/event-stream")` before `response_begin_stream`. |
| C4 | **FORCE_REBUILD=1 ignored by profile matrix** | `run_profile_matrix.sh` exported `FORCE_REBUILD=1` then `exec run_bench.sh`, which never rebuilds. Stale binaries after route edits. | Profile matrix rebuilds proactr-mat/opt/laytan/ntex/drogon when `FORCE_REBUILD=1`. `run_peer_matrix.sh` also rebuilds `proactr-mat`/`proactr-opt`. |
| C5 | **PLAN_FILE_PATH not explicit on peer starts** | ntex/laytan/drogon only inherited env; easy to desync custom path vs harness-written file. | `run_bench.sh` exports + passes `PLAN_FILE_PATH` into ntex/laytan/drogon/proactr starts. |

### IMPORTANT (open — still FAIL)

| # | Finding | Why it matters | Concrete fix |
|---|---------|----------------|--------------|
| I1 | **No body re-check under load** | PROFILE forbidden #5: “Skipping body-check under load”. Pre-start exact check + oha Size/request 10% WARN is not fail-closed. | After each `run_load`, re-run content verify (or sample 1 req) and **FAIL** peer on mismatch; for drogon only, document known oha size anomaly. |
| I2 | **SSE wire framing unequal** | proactr: stream API → **chunked TE** oneshot. Peers: single `setBody` / `respond` with **Content-Length**. Same decoded 42 B, different framing cost/path. Meta now notes chunked vs CL; RPS still not pure apples-to-apples. | Either (a) publish as “stream API vs CL oneshot” with dual labels always, or (b) add peer stream-API path where available, or (c) add proactr CL oneshot mode for fair RPS and keep stream path as separate test. |
| I3 | **Assembled multi-fragment only on proactr-opt** | ntex/drogon/laytan/proactr-mat are honest `preconcat_blob`. Matrix “multi-fragment intent” is **proactr-opt-only**. Comparing opt multi_send RPS to peer preconcat is a mechanism gap, not peer failure. | Rank tables **must** split columns: `assembled_preconcat` vs `assembled_multi_send`. Never claim peers “lose” multi-send. |
| I4 | **gen “build-in-handler” is uneven** | proactr: `body_reserve` + copy + commit. Peers: static `GEN_BODY` const / string. Contract bytes fair; work measured is not. | Peers: stack buffer fill of `generated:ok\n` per request (or shared sprintf into thread-local) so gen is not free static. |
| I5 | **Framework counters still say “writev”** | `http/plan.odin` `plan_wire_writev_total` increments on multi-buffer sequential send. Summaries that scrape this will re-lie. | Rename counter to `plan_wire_multi_send_total` (or dual-name + deprecate writev); harness/meta must never print “writev” for proactr-opt. |
| I6 | **proactr profile peer still requires SQLite init** | `fortunes_init` + DB open even when TESTS are profile-only. Extra start dependency / failure mode peers may not share for this matrix. | Lazy fortunes or `PROFILE_ONLY=1` skip DB when fortunes not in TESTS. |
| I7 | **wait_up only hits /api/tiny or /plaintext** | Ready if tiny works; profile routes relied solely on later body-check (now stronger). | Optional: wait_up also HEAD/GET gen+assembled once. Low risk if body-check always runs. |
| I8 | **blob vs file work asymmetry unmeasured** | Peers re-read 1 MiB from disk every file request (good). Blob is static. No harness proof of open/read syscalls under load. | Optional: `/proc` or peer log “file_ops”; or `lsof`/strace spot-check on bastion. |

### NIT

| # | Finding | Fix |
|---|---------|-----|
| N1 | PROFILE_MATRIX pattern text said “64-char” over a 32-char literal | Corrected to full 64-byte block matching peers. |
| N2 | Meta previously said `preconcat_or_mat` (weasel) | Now `preconcat_blob`. |
| N3 | `check_load_size` python print path is dead/weird | Clean error message to include peer+test. |
| N4 | laytan fortunes still 501 | Out of profile matrix scope; keep skip. |

---

## Focus checklist (requested)

| Focus | Status |
|-------|--------|
| 1. Assembled first-byte contract across peers | **Code OK** on all five peers (construct `'A'+i`). **Harness now verifies**. |
| 2. File truly from disk for all peers | ntex/drogon/laytan re-read path. proactr-mat `respond_file`; opt held fd. **In-memory fallback removed**. **Harness `cmp` to disk**. |
| 3. gen is fair (no DB) | All peers fixed `generated:ok\n`, no DB. **Work fairness still uneven** (I4). |
| 4. proactr-opt labeled multi_send not writev | Meta + comments OK. **Counter name still writev** (I5). |
| 5. SSE body length exactly 42 | Bytes correct; **exact content + CT checked**. proactr was missing CT (fixed). |
| 6. wait_up / body-check covering new routes | path_for_test + expected_body_len cover all six. body-check now content-level. wait_up still tiny-only (I7). |
| 7. ntex/drogon preconcat for assembled | Confirmed; labeled `preconcat_blob` in peer logs + meta. Must stay labeled. |

---

## Performance findings (vs ntex / drogon / laytan)

- Do **not** rank “assembled” across peers without mechanism split (I3).
- proactr SSE chunked TE vs peer CL will bias SSE RPS (I2).
- drogon remains epoll; always label when next to uring peers.
- gen RPS: proactr pays reserve/commit; peers static — do not claim gen ceiling without I4.
- file: peers full read every request; proactr-opt chunked pread path is the only non-full-materialize candidate — prove with counters (`plan_wire_copy_into_total`), not docs.

---

## Correctness findings

- Content-Length vs chunked: proactr SSE is TE-chunked; body decode still 42 B (curl/oha decoded). Dual CL+TE avoided in `response_begin_stream`.
- File fd lifetime: proactr-opt holds process-lifetime fd for `body_file` — OK if send completes before process exit; document for multi-CQE.
- Body contracts now fail-closed on start for exact profile rules.

---

## Fixes landed this pass (commit target)

1. `run_bench.sh` — exact content body-check + assembled first-byte + file=disk + SSE CT; export/pass `PLAN_FILE_PATH`.
2. `run_profile_matrix.sh` — FORCE_REBUILD for mat/opt peers; honest meta (multi_send / preconcat_blob / chunked vs CL).
3. `proactr/main.odin` — no P_1M file lie; SSE Content-Type; comments on multi_send / disk file.
4. `run_peer_matrix.sh` — rebuild proactr-mat/opt under FORCE_REBUILD.
5. `PROFILE_MATRIX.md` — pattern length text fix.

---

## Top 3 fixes remaining (ordered by impact)

1. **I1** — fail-closed body re-check after load (kill SIZE_WARN soft pass for profile matrix).
2. **I3 + I2** — published tables split by mechanism (assembled preconcat vs multi_send; SSE chunked stream vs CL oneshot). No mixed ranking.
3. **I5 + I4** — rename writev counter; make peer gen do real per-request fill.

---

## Always-do checklist (standing)

1. Read wire paths, not docs claims.
2. Same routes, WORKERS, c, z, host.
3. Label I/O backends (uring vs epoll).
4. Call shortcuts by name with file:line.
5. Prefer CRITICAL / IMPORTANT / NIT.

**Return: FAIL until I1–I3 closed or results are published with mechanism-split tables and no soft size passes.**
