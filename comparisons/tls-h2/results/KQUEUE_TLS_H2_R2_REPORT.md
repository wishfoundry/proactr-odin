# Darwin TLS matrix R2 — post HPACK / encoder enhancements

**When:** 2026-08-09T15:09Z  
**Host:** M2 Pro 12-core · Darwin 25.5.0 · WORKERS=8 · h2load `-c100 -D15 -t4`  
**Tree includes:** Huffman FSM decode · ring HPACK table · explicit ownership · encoder dynamic table (live on `conn_send_headers`) · integer/list caps  
**Artifacts:** `kqueue_summary_r2.tsv`, `KQUEUE_TLS_H2_R2.md`, `kqueue_instrumentation_r2.txt`  
**Baseline R1:** `KQUEUE_TLS_H2.md` (13:40Z, pre-HPACK)

Honesty: ntex Darwin banner/stats now `io=tokio`. Drogon h2 remains **N/A** (product). Single-run laptop ranks — not bastion.

---

## Headline

| Cell | R1 proactr | R2 proactr | Δ | Best peer R2 | proactr / best |
|------|----------:|----------:|---:|-------------:|---------------:|
| **h2 plaintext** | 61 845 | **93 347** | **+51%** | ntex 127 k | **0.73×** (was 0.48×) |
| **h2 s4k** | 64 476 | **78 256** | **+21%** | ntex 130 k | **0.60×** (was 0.49×) |
| **h2 s64k** | 25 116 | **27 588** | **+10%** | ntex 48 k | **0.58×** |
| **h2 s1m** | 1 745 | 1 753 | ~0% | go 2 990 | **0.59×** |
| h1s plaintext | 114 933 | 116 035 | ~0% | drogon 152 k | 0.76× |
| h1s s1m | 2 726 | 2 753 | ~0% | drogon 8 923 | 0.31× |

**HPACK work moved the needle where it should:** small/mid **H2**. H1.s and bulk H2 (AES/send) are flat — also expected.

Peers stable (±1%) → delta is us, not machine noise.

---

## Full R2 RPS (h2load)

```
peer     proto  test       rps
proactr  h2     plaintext  93346.80
proactr  h2     s4k        78256.33
proactr  h2     s64k       27588.13
proactr  h2     s1m         1752.80
proactr  h1s    plaintext 116035.40
proactr  h1s    s4k        99221.60
proactr  h1s    s64k       29245.13
proactr  h1s    s1m         2753.00
ntex     h2     plaintext 127276.20
ntex     h2     s4k       130201.87
ntex     h2     s64k       47622.47
ntex     h2     s1m         1089.67
ntex     h1s    *         ~136k–139k / 59k / 2.0k
drogon   h2     *          N/A (no_h2)
drogon   h1s    *         ~152k / 154k / 70k / 8.9k
go       h2     *         ~113k / 112k / 38k / 3.0k
go       h1s    *         ~145k / 121k / 53k / 4.9k
```

All cells `status=ok` or intentional `no_h2`. Zero failed/timeout.

### Encoder evidence (responses)

h2load traffic line for proactr h2 plaintext:

- **Header space savings ~95%** (was ~45% in R1-class runs)

That is server **HPackEncoder** dynamic indexing on repeated response headers (`content-type`, `:status`, etc.), not just decode speed.

---

## Rank changes (H2 only)

| Cell | R1 order | R2 order |
|------|----------|----------|
| plaintext | ntex ≫ go ≫ **proactr** | ntex > go > **proactr** (much closer) |
| s4k | ntex ≫ go ≫ proactr | ntex > go > proactr |
| s64k | ntex > go > proactr | same; proactr +10% absolute |
| s1m | go > proactr > ntex | **unchanged** (AES/send) |

Still **not peer-first** on small H2, but no longer half of ntex on plaintext.

---

## Next levers (ordered by expected impact)

Based on R2 matrix + prior post-fix samples + residual path design (fresh sample this session idled on `kevent` only — loadgen PATH glitch; R1.5 profile + R2 counters still apply).

### P0 — still on the critical path for small H2

| # | Lever | Why | Target cells |
|---|--------|-----|----------------|
| **1** | **Request header memory path** | Decode no longer linear-Huffman, but still **clone into stream + host re-clone into request** (`h2_host` scrap). Ntex/go avoid a triple photocopy. | h2 plaintext / s4k |
| **2** | **Syscall / rearm density** | Prior samples: **sendto + recvfrom + SSL_read** large share after HPACK. One CT send per tiny response; kqueue oneshot rearm. Batch readiness / fewer transitions. | h2 + h1s small |
| **3** | **H1 request parse / header maps** | H1.s flat vs R1; phase/parse + `map[string]` still tax. Not HPACK. | h1s plaintext |

### P1 — bulk / mid TLS

| # | Lever | Why | Target |
|---|--------|-----|--------|
| **4** | **OpenSSL mem-BIO seal path** | s1m H2 still AES+send; dual-CT ahead ~80% already. Larger effective windows, fewer BIO round-trips, less WPACKET malloc (profile leaf). | h2/h1s s64k–s1m |
| **5** | **`h2_out` / frame buffer reserve** | Prior bulk: `_append_elems` ~13%. Pre-size known Content-Length bodies. | h2 s1m |
| **6** | **Close gap vs go on h2 s1m** | go ~3.0k vs us ~1.75k. Encrypt+send efficiency, not HPACK. | h2 s1m |
| **7** | **Close gap vs drogon on h1s bulk** | drogon ~9k vs us ~2.8k on s1m H1.s — largest remaining absolute hole. Materialize + serial seal turns. | h1s s1m |

### P2 — polish

| # | Lever | Notes |
|---|--------|-------|
| **8** | Encoder name→index map | Linear scan over dynamic table; only matters with fat tables |
| **9** | Arena-native HPACK bytes | Connection/stream region free; stops N×delete |
| **10** | `path_reqs` multi-chunk fix | Instrumentation honesty only |
| **11** | Loadgen headroom check | Prove h2load isn’t capping ~150k H1 cells |

### Explicitly **not** next

- Another Huffman algorithm pass (done; ~200× microbench; H2 small +51%).  
- SIMD Huffman decode (serial FSM).  
- Inventing drogon H2 numbers.

---

## Suggested work order

1. **Arena or single-copy H2 request headers** (decode → request without middle owned list clone).  
2. **Profile with fixed PATH** on R2 binary: confirm post-HPACK top is send/recv/SSL_read + clone, not Huffman.  
3. **H1.s bulk**: materialize/seal window audit vs drogon (why 0.3× on s1m).  
4. **h2 s1m**: seal window + CT slab + send coalescing vs go.

---

## Verdict

| Question | Answer |
|----------|--------|
| Did enhancements show up in peer matrix? | **Yes** — h2 plaintext **+51%**, s4k **+21%**, header savings ~95% |
| Peer-competitive on Darwin H2 small? | **Closer, still no** — 0.73× ntex plaintext |
| H1 / bulk moved? | **No** — next work is TLS/syscall/materialize, not HPACK |
| Rebench vs R1 honest? | Peers flat; drogon still H1-only N/A for h2 |

**Bottom line:** HPACK P0 paid off on the intended cells. Next dollar of RPS is **header ownership / syscall path (small)** and **seal+send+materialize (bulk H1.s vs drogon, bulk H2 vs go)**.
