# Competitor hot-path audit → ranked backlog

**Date:** 2026-08-09  
**Host law:** Darwin kqueue · OpenSSL mem-BIO · dual-CT · **no kTLS**  
**Method:** four parallel reverse-engineering agents (ntex, drogon, go, vapor-http) + summary critic  
**Scoreboard anchor:** R3 full matrix (`PERF_LOOP_STATUS.md`)

---

## 0. Scoreboard — who owns which cell

| Cell | proactr | Best peer | × | Dominant tax (proactr) |
|------|--------:|-----------|--:|------------------------|
| h2 plain | 93.7k | ntex 128k | **0.73×** | HPACK ~38% + send ~22% |
| h2 s4k | 78.9k | ntex 133k | **0.59×** | + body copies |
| h2 s64k | 27.9k | ntex 49k | **0.57×** | frame build + seal turns |
| h2 s1m | 1.78k | go 3.0k | **0.59×** *(beats ntex)* | AES + send + `_append` |
| h1s plain | 113k | drogon 150k | **0.75×** | send/recv + parse |
| h1s s4k | 96k | drogon 151k | **0.64×** | duplex + seal setup |
| h1s s64k | 30k | drogon 67k | **0.44×** | encrypt+send turns |
| h1s s1m | 2.8k | drogon 9.2k | **0.30×** | **largest hole** |

Dual-CT is live (`ahead≈80%`). That is why **h2 s1m beats ntex**. Remaining bulk gap is not “turn dual-CT on.”

---

## 1. Per-competitor bottom lines

### ntex (small/mid H2 champion)

| Advantage | Evidence | Stealable? |
|-----------|----------|------------|
| HPACK string decode reuses buffer (no post-Huffman exact realloc) | `ntex-h2` decoder BytesMut; proactr `decode_string` double-alloc | **Yes — P0** |
| ~2 body copies via `Bytes` refcount + `split_to` | vs proactr materialize→pending→`h2_out` | **Yes** |
| Thread-local BytePages / Io buf cache | `ntex-bytes`, `ntex-io` | Yes (Med) |
| writev write task ≤64 KiB | `ntex-net` tokio `run_wrt` | Low on TLS CT |
| TCP_NODELAY on accept | `ntex-net` | Tried — **failed bulk** |
| LTO + CGU=1 | harness Cargo.toml | Fairness noise |

**Why proactr wins h2 s1m vs ntex:** 256 KiB seal + dual-CT beats ntex’s 16 KiB page SSL_write churn.

### drogon (H1.s bulk champion ~3×)

| Advantage | Evidence | Stealable? |
|-----------|----------|------------|
| **Tight multi `SSL_write`(64 KiB)+immediate `write(fd)` until EAGAIN** | `OpenSSLProvider::sendData` | **Yes — #1 bulk** |
| Depth ≈ SO_SNDBUF, not dual-CT=2 | in-loop while writable | Yes (eng change) |
| Level-triggered reactor one-turn density | trantor | Partial under kqueue |
| Full-body double copy on peer | `setBody` + `renderToBuffer` | **proactr already better** (borrowed body) |
| TCP_NODELAY | **OFF** | Proactr A/B was not “peer parity” |
| TLS sendfile | **No** (cleartext only) | N/A |

**Key insight:** drogon is **not** zero-copy and still crushes bulk. Weapon is **encrypt→socket density**, not body physics.

### go (h2 s1m champion)

| Advantage | Evidence | Stealable? |
|-----------|----------|------------|
| Zero-copy body: frames from handler slice | `writeDataFromHandler` + `Consume` | **Yes** |
| Pure Go AES-GCM assembly, no mem-BIO | `crypto/tls` | **Not fully** |
| writev on TLS | **Not used** | Myth — skip |
| M:N + per-request goroutines | runtime | Not stealable |
| 16 KiB DATA + dynamic TLS records | http2 + crypto/tls | Low after body path |

### vapor-http (`~/Projects/odin-http`)

| Advantage | Evidence | Stealable? |
|-----------|----------|------------|
| Multi-`SSL_write` to CT high-water + mid-loop arm | `nbio_tls.odin` | **Yes — denser than depth-2** |
| H2 rBIO burst-256 + growable `rx_hold` | vapor TLS bulk postmortem | Yes (correctness + mild RPS) |
| Clear fill-until-EAGAIN | `nbio_h1.odin` | Partial under proactor |
| HPACK / Huffman | linear Huffman, O(n) table inject | **proactr already surpassed** (FSM + ring) |
| BoringSSL static bastion | historical | Optional A/B only |

---

## 2. Cross-competitor technique matrix

| Technique | ntex | drogon | go | vapor | **proactr** | Cells |
|-----------|:----:|:------:|:--:|:-----:|-------------|-------|
| Seal/write until EAGAIN (many windows/turn) | ~ | **YES** | ~ | **YES** | **NO** (1 seal + CQE + 1 ahead) | **h1s bulk** |
| Dual-CT depth-2 | partial | no | no | multi-SSL denser | **YES 256 KiB** | bulk (beats ntex h2 s1m) |
| HPACK Huffman no double-alloc | **YES** | n/a | good | good | **RESIDUAL** | h2 plain/s4k |
| H2 header borrow | strong | n/a | strong | — | **DONE** | h2 small |
| H2 static body zero/low copy | ~2 | n/a | **YES** | better | **TRIPLE** | h2 mid/bulk |
| Page buffer pools | **YES** | chains | GC | — | partial | all Med |
| writev TLS CT | writev clear | — | **no** | — | single CT buf | low |
| rBIO burst + rx_hold | solid | — | solid | **YES** | short bio risk | duplex |
| Pure AES / no mem-BIO | OpenSSL | OpenSSL | **YES** | BoringSSL opt | OpenSSL | bulk ceiling |
| TCP_NODELAY | on | **OFF** | often on | varies | A/B failed | dead |
| kTLS | rare | no | limited | research | **out** | — |

**≥2 peers independently validate:**

1. In-turn multi encrypt+send until EAGAIN — drogon + vapor  
2. Fewer H2 body copies — go + ntex  
3. HPACK decode buffer reuse — ntex + profile (38%)  
4. Dense multi-window seal without CQE between every slab — drogon + vapor  

---

## 3. Unified ranked backlog

### P0 — next engineering

#### P0-1. Seal-until-EAGAIN / multi-window per turn
- **Peers:** drogon + vapor  
- **Cells:** h1s s1m (primary), h1s s64k, then h2 bulk  
- **Impact:** High — honest **+40–120%** h1s s1m possible (2.8k → ~4–6k+); full 9.2k may need more  
- **Why not dead end:** dual-CT already overlaps seal∥send; drogon wins *despite* 2× body copy by maximizing windows per kevent turn. Prior fails were 1 MiB / NODELAY / rearm — none attacked **sync multi-window drain**.  
- **Files:** `http/tls_dual_ct.odin`, `tls_oneshot.odin`, `h2_flush.odin`, `wire.odin`, `proactr/platform_kqueue.odin`  
- **Gate:** h1s s1m ≥ **+15%** vs R3 2778 **and** h1s plain ≥ −3%; no h2 plain rank regression  
- **Risk:** High correctness (partial write, WANT_READ, promote-before-residual)

#### P0-2. HPACK `decode_string` — kill Huffman double-alloc
- **Peers:** ntex; profile `decode_string` ~38%  
- **Cells:** h2 plain, h2 s4k  
- **Impact:** Med–High **+8–20%** h2 plain (not full 0.73→1.0 alone)  
- **Files:** `hpack/hpack.odin` (~301–316)  
- **Gate:** h2 plain ≥ **+8%**; HPACK unit vectors green  
- **Risk:** Med (ownership / table free / stream borrow)

#### P0-3. H2 oneshot borrowed body (kill triple-buffer)
- **Peers:** go + ntex  
- **Cells:** h2 s4k/s64k/s1m  
- **Impact:** Med **+10–25%** mid; s1m **+10–20%** (kills `_append` ~13%)  
- **Files:** `http/h2_host.odin`, `http2/*`, `h2_flush.odin`  
- **Gate:** h2 s4k **or** s1m ≥ **+8%**; no UAF after handler return  
- **Risk:** Med–High (body lifetime vs stream free; multi-slot)

### P1 — after P0 foundations

| ID | Name | Peers | Impact |
|----|------|-------|--------|
| P1-1 | CT high-water multi-seal (not 1 MiB window) | vapor+drogon | Med–High refine of P0-1 |
| P1-2 | Worker-local page pools | ntex | Med if malloc shows |
| P1-3 | rBIO burst + fixed rx_hold | vapor | Low–Med RPS; High correctness |

### P2 / P3

- P2: H1 sanitize hygiene (not primary RPS), pre-reserve `h2_out`, DATA size tune  
- P3: BoringSSL A/B, pure AES leave mem-BIO, writev TLS (no), kTLS (out), Go M:N cosplay (no)

---

## 4. What NOT to do

| Dead end | Evidence |
|----------|----------|
| TCP_NODELAY on accept | R4: bulk −11–12% |
| 1 MiB seal window | R2: s1m −6%, plain −10% |
| Heading/body coalesce as main bet | critic REJECT |
| Send/rearm orchestration spray | R3 no RPS |
| “Dual-CT is off” | ahead≈80%; beats ntex h2 s1m |
| kTLS as matrix fix | policy |
| Drogon H2 fiction | no_h2 |
| writev as TLS bulk weapon | go doesn’t use it either |

---

## 5. Next 2–3 loop rounds

### Round A — bulk H1.s (0.30× hole)
1. **P0-1** seal-until-EAGAIN (H1 oneshot first)  
2. Optional **P1-1** if depth still starves  
3. Gate: h1s s1m ≥ +15%; plain ≥ −3%  
4. Success: move toward **0.45–0.55×** drogon (~4–5k+), not fantasy 9k in one PR

### Round B — small H2 pack (0.73× / 0.59× ntex)
1. **P0-2** HPACK buffer physics  
2. **P0-3** H2 body borrow (+ pre-reserve)  
3. Gate: h2 plain ≥ +8% and h2 s4k ≥ +8%; no bulk regression from A  
4. Success: h2 plain **≥ 0.82×** ntex

### Round C — ceilings
1. Soak correctness  
2. Optional pools if malloc-heavy  
3. Offline OpenSSL encrypt+send until-EAGAIN microbench vs drogon bound  
4. Admit residual as architecture if Round A &lt;10%

**If Round A gains &lt;10%:** stop hunting flags; treat bulk as I/O-law ceiling and pivot effort to Round B (named CPU tax).

---

## 6. Harsh honesty

### Real code taxes (fixable without kTLS)
- HPACK Huffman double-alloc — **bug/tax**  
- H2 triple body copy + append growth — **bug/tax**  
- One CT CQE per seal window — **scheduling law**, fixable in principle (P0-1)

### Architectural ceilings
- **h1s s1m 0.30× drogon:** even after P0-1, OpenSSL mem-BIO + CQE host may leave **~0.5–0.7×**  
- **h2 s1m 0.59× go:** pure-Go AES no mem-BIO not fully stealable  
- **h2 plain 0.73× ntex:** HPACK+send; last 5–15% may be event-loop density  
- **kTLS / leave OpenSSL:** biggest theoretical bulk unlock; out of this loop

### North-star metrics
`h1s s1m` ratio to drogon · `h2 plaintext` ratio to ntex · no plain-cell regression &gt;3%

### Commit-order shortlist
1. P0-1 seal-until-EAGAIN  
2. P0-2 HPACK decode_string  
3. P0-3 H2 borrowed body  
4. P1-1 only if P0-1 plateaus  

---

## 7. Source pointers (for re-read)

| Peer | Primary paths |
|------|----------------|
| ntex | `third_party/ntex/`, crates.io `ntex-h2` 1.14.2, `comparisons/tls-h2/ntex/` |
| drogon | `third_party/drogon/trantor/.../OpenSSLProvider.cc` `sendData`, `lib/src/HttpResponseImpl.cc` |
| go | GOROOT `net/http/h2_bundle.go`, `crypto/tls`, `comparisons/tls-h2/go/` |
| vapor | `/Users/bngreer/Projects/odin-http/server/nbio_tls.odin`, `tls_conn.odin`, `docs/TLS_MEMBIO_BULK_ANALYSIS.md` |
| proactr | `http/tls_dual_ct.odin`, `tls_oneshot.odin`, `h2_host.odin`, `hpack/hpack.odin`, `h2_flush.odin` |
