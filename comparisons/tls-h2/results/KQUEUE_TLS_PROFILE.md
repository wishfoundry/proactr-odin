# Where proactr TLS time goes (Darwin / kqueue)

**When:** 2026-08-09  
**Host:** Mac14,9 · M2 Pro 12-core · Darwin 25.5.0 · OpenSSL 3.6.3 (Homebrew dynlib)  
**Binary:** `server.instr.bin` (`-o:speed -define:HTTP_PHASE_STATS=true`) for counters  
**Stacks:** `server.prof.bin` (`-o:speed -debug` + same define) under `/usr/bin/sample` 10s @ 1ms  
**Load:** h2load `-c 100 -D 12|15 -t 4` · WORKERS=8 · same matrix certs  
**Artifacts:** `results/kqueue_profile/*` · raw under `/tmp/proactr-kqueue-profile/`

This explains the **kqueue matrix rank gap** (`KQUEUE_TLS_H2.md`): proactr is correct but trails ntex/go on small H2 and drogon/go on bulk H1.s.

---

## Instrumentation added

| Signal | Source | Build |
|--------|--------|-------|
| seal / pt / ct / h2_flush / ct_sends / materialize | `path_metrics` (always on) | any |
| `seals_per_req`, `ct_pt_ratio` | scrape | any |
| `ssl_write_cyc`, `bio_read_cyc`, `seal_cyc`, shares | cycle timers in `tls_seal_window_*` | `HTTP_PHASE_STATS` |
| `ahead_seals`, `promote` | dual-CT try_ahead / promote_hold | `HTTP_PHASE_STATS` |
| `phase_parse/handle/build/reset` | existing request phases | `HTTP_PHASE_STATS` |
| Stack samples | macOS `sample` | `-debug` symbols |

Scrape: `GET /_matrix/stats` · reset: `POST /_matrix/reset` (also clears phase buckets when PHASE enabled).

**Caveats**

1. **Apple `read_cycle_counter` is timebase-ish**, not GHz core clocks. Use **shares and rankings**, not “X GHz cycles.”
2. **`path_reqs` undercounts multi-chunk H2/H1 bulk** (`note_req` fires when `h2_out` empties on first flush path / oneshot complete). Prefer **h2load request counts** for seals/req. Example: h2 s1m h2load 20 930 reqs vs scrape `reqs=201`.
3. **H2 does not tick `phase_n` per request** the same way H1 does (`phase_n≈1` on H2 cells). H2 CPU story comes from **sample stacks**, not PHASE.
4. Instrumented RPS is a few % below fair-matrix (timer tax). Relative structure is the signal.

---

## Counter matrix (instr binary, 12s cells)

| Cell | h2load RPS | seals (scrape) | seals/req† | ahead% | seal share SSL_write | seal share BIO_read | notes |
|------|----------:|---------------:|-----------:|-------:|---------------------:|--------------------:|-------|
| h2 plaintext | 57 324 | 688k | **1.0** | ~0% | **96%** | 4% | tiny records |
| h2 s4k | 60 373 | 725k | **1.0** | ~0% | 87% | 13% | |
| h2 s64k | 22 231 | 267k | **1.0** | ~0% | 91% | 9% | one window |
| h2 s1m | 1 744 | 105k | **~5.0†** | **80%** | 89% | 11% | dual-CT live |
| h1s plaintext | 108 200 | 1.30M | **1.0** | 0% | 96% | 4% | materialize=reqs |
| h1s s64k | 28 087 | 674k | **~2.0†** | **50%** | 91% | 9% | dual-CT half |
| h1s s1m | 2 718 | 163k | **~5.0†** | **80%** | 91% | 9% | dual-CT live |

† seals/req from **h2load completed reqs**, not scrape `reqs` (undercount on bulk).

### H1 request-phase (H1 only; useful)

| Cell | parse cyc/req | handle | build | seal cyc/req (timebase) |
|------|-------------:|-------:|------:|------------------------:|
| h1s plaintext | **1186** | 114 | 6 | 12 |
| h1s s64k | 298 | 488 | 5 | (multi-seal; use stacks) |
| h1s s1m | 172 | 1491 | 5 | (multi-seal; use stacks) |

For **tiny H1.s**, instrumented phases say **parse ≫ seal**. That matches stacks: we are not AES-bound on plaintext.

---

## Stack samples (worker thread)

Main thread is almost entirely `kevent` (idle coordinator). Workers do the work.

### 1) H2 plaintext — **HPACK + send dominate** (why we lose to ntex/go)

Approx top-level worker time (from call-graph children):

| Bucket | ~share | Evidence |
|--------|-------:|----------|
| **HPACK decode** | **~38%** | `hpack::decode_string` top of worker |
| **send / `sendto`** | **~22%** | `host_submit_send` → `__sendto` |
| SSL_read (request decrypt) | ~6% | `tls_host_ssl_read_burst` → `SSL_read` |
| SSL_write / seal | ~5% | small records |
| alloc / append / maps | ~5% | arena, `map_insert`, `_append_elems` |

**Interpretation:** small H2 is **not** “OpenSSL AES is slow.” It is **per-request H2 framing tax** — especially **HPACK string decode** — plus **one send syscall per response** and TLS record bookkeeping (`WPACKET_*` in leaf samples). ntex/go win this class with cheaper H2 header paths and tighter event loops.

### 2) H2 s1m — **AES encrypt + send + buffer growth**

| Bucket | ~share | Evidence |
|--------|-------:|----------|
| **SSL_write / AES-GCM encrypt** | **~43%** | `tls_seal_window` → `SSL_write` → `armv8_aes_gcm_encrypt` / `unroll8_eor3_aes_gcm_enc_128_kernel` |
| **send** | **~35%** | `host_submit_send` → `__sendto` |
| **`runtime::_append_elems`** | **~13%** | growing `h2_out` / frame buffers |
| H2 frame flush | ~4% | `_flush_stream_one_frame` |
| HPACK | ~1% | negligible once body dominates |

Dual-CT: **`ahead_seal_share≈80%`** — seal∥send is engaged. Cursor path (no O(n) `remove_range`) is not the bastion-era memmove catastrophe; remaining buffer cost is **append growth**, not front-delete.

### 3) H1.s plaintext — **syscall duplex bound**

| Bucket | ~share |
|--------|-------:|
| **send** | **~34%** |
| **recv** | **~23%** |
| SSL_write seal | ~10% |
| SSL_read | ~9% |
| scanner / parse | ~5%+ |
| response/materialize | ~3% |

Matches phase_stats: **parse > seal**. Gap vs drogon/go on small H1.s is **event+syscall+parse path**, not crypto.

### 4) H1.s s1m — **encrypt + send** (clean bulk story)

| Bucket | ~share |
|--------|-------:|
| **SSL_write / AES-GCM** | **~55%** |
| **send** | **~39%** |
| recv / read / other | ~6% |

Dual-CT ahead **80%**. Materialize is one-shot heading+body into plain cursor then multi-window seal (`seals/req≈5` for 1 MiB @ 256 KiB window). Loss vs drogon (~9k vs ~2.7k fair-matrix) is still largely **how many serial turns + copy/encrypt path**, not dual-CT “off.”

---

## Root-cause ranking (kqueue product gap)

| Pri | Where time goes | Cells | Fix direction |
|----:|-----------------|-------|---------------|
| **P0** | **HPACK decode_string** | H2 small | Faster HPACK (static table hot path, fewer allocs, decode without per-string heavy path); compare ntex/go header pipelines |
| **P0** | **Per-response `sendto` + kevent rearm** | all small | Batch readiness; ensure dual-CT/submit path minimizes transitions; check kqueue oneshot rearm cost vs ntex tokio |
| **P1** | **AES-GCM in OpenSSL mem-BIO** | bulk H2/H1 | Already hardware AES; residual: fewer records (larger effective plain batches already 256KiB), less WPACKET/malloc inside OpenSSL, eventual kTLS |
| **P1** | **`_append_elems` on H2 bulk** | H2 s1m | Pre-size `h2_out` / frame scratch; reserve for content-length known bodies |
| **P2** | **H1 request parse / header maps** | H1 small | Scanner + `map[string]string` header path (sample shows `map_get` / `map_insert` / `sanitize_key`) |
| **P2** | **Full materialize on H1.s** | H1 oneshot | Ciphered split already helps ≥8KiB; keep static body → plain cursor without extra copies where possible |
| **P3** | **`path_reqs` / H2 phase undercount** | metrics honesty | Note_req on response complete for multi-window; H2 phase_n per exchange |

### Explicitly *not* the main small-H2 story

- Dual-CT “broken” on small — ahead≈0% is expected (one seal/req; nothing to overlap).
- O(n) `pending` front-delete — fixed (cursors); bulk sample no longer 70% memmove in `remove_range`.
- AES uniquely bad vs peers on **plaintext** — encrypt is single-digit % of worker time there.

---

## How this maps to peer ranks (Darwin)

| Observation | Matches matrix |
|-------------|----------------|
| H2 small dominated by HPACK+send, not AES | proactr **0.48×** ntex on h2 plaintext |
| H2 bulk = AES + send; dual-CT 80% | proactr beats ntex on h2 s1m (**1.6×**), still **0.56×** go |
| H1 small = send/recv/parse | proactr 4th on h1s ladder |
| H1 bulk = AES + send | drogon still wins absolute GB/s; we are encrypt/send limited |

---

## Reproduce

```bash
cd comparisons/tls-h2
# instrumented counters
(cd proactr && odin build . -out:server.instr.bin -o:speed \
  -define:HTTP_PHASE_STATS=true -define:HTTP_PHASE_STATS_EVERY=100000)
export CERT_FILE=$PWD/certs/cert.pem KEY_FILE=$PWD/certs/key.pem SSL_CERT_FILE=$CERT_FILE
PORT=18443 WORKERS=8 ./proactr/server.instr.bin &
# reset + load + scrape
curl -sk -X POST --http1.1 https://127.0.0.1:18443/_matrix/reset
h2load -c100 -D12 -t4 https://127.0.0.1:18443/plaintext
curl -sk --http1.1 https://127.0.0.1:18443/_matrix/stats

# stacks (debug binary)
(cd proactr && odin build . -out:server.prof.bin -o:speed -debug \
  -define:HTTP_PHASE_STATS=true)
# during load:
sample <pid> 10 1 -file /tmp/proactr-sample.txt
```

---

## Verdict

| Question | Answer |
|----------|--------|
| Where does small H2 CPU go? | **HPACK (~38%) + send (~22%)**; crypto minority |
| Where does bulk H2/H1 CPU go? | **OpenSSL AES-GCM encrypt (~40–55%) + send (~35–40%)**; dual-CT ahead ~80% |
| Is dual-CT working on kqueue? | **Yes** on multi-window cells |
| Is memmove/remove_range still P0? | **No** for H2 bulk; residual is **append growth** |
| Top optimize levers | **HPACK**, **syscall/rearm density**, **h2_out reserve**, then OpenSSL/kTLS |

Next work should start at **HPACK + small-request event path**, not another dual-CT pass, unless bulk vs go is the goal (then encrypt/send + fewer copies).
