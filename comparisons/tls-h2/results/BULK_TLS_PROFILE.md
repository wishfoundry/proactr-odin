# Bulk TLS profile — proactr on ranch-bastion

**When:** 2026-08-09  
**Host:** ranch-bastion · Linux 6.14 · OpenSSL 3.4.1 (dynlib mem-BIO)  
**Binary:** `odin build -o:speed -debug` (symbols; RPS lower than fair matrix)  
**Load:** h2load `-c 100 -D 12 -t 4` · WORKERS=8 · cipher TLS_AES_128_GCM_SHA256  
**Tool:** `sudo perf record -g --call-graph dwarf -p $pid` during load  
**Artifacts:** `/tmp/proactr-bulk-tls-profile/` on bastion  

---

## Throughput under profile (debug binary)

| Cell | RPS | MB/s or GB/s | seals/req | notes |
|------|----:|-------------:|----------:|-------|
| h1s s64k | 4 115 | 258 MB/s | **2.0** | fair matrix was ~10.6k (no `-debug`) |
| h2 s64k | 4 211 | 264 MB/s | **2.0** | similar to h1s under debug |
| h1s s1m | 3 323 | 3.25 GB/s | **17.0** | 1 MiB / 64 KiB pull ≈ 16 windows |
| h2 s1m | 1 076 | 1.06 GB/s | **16.8** | same window math + H2 framing tax |

Fair-matrix absolute RPS differ (no debug); **call-stack distribution** is the signal.

---

## Path metrics (profile run)

| Cell | seal_calls | ct_sends | materialize | h2_flush |
|------|----------:|---------:|------------:|---------:|
| h1s s64k | 98 957 | 98 957 | 49 479 | 0 |
| h2 s64k | 101 465 | 101 465 | 1 | 101 464 |
| h1s s1m | 679 381 | 679 381 | 39 965 | 0 |
| h2 s1m | 220 649 | 220 649 | 1 | 220 648 |

`ct_pt_ratio ≈ 1.000` on bulk → encrypt expansion is tiny; cost is **how many times** we seal/send, not CT blowup.

---

## Where CPU goes

### 1. H2 s1m — smoking gun: buffer shifts (~72% self in memcpy)

Self-time #1: `__memmove_avx_unaligned_erms` **72%**

Call chain:

```
copy_slice_raw (~55%)
  └─ remove_range_dynamic_array (~37%)
       └─ http2::_flush_stream_one_frame   # flow.odin:114
            └─ conn_send_body → conn_send_response → h2_host_send_response
```

Also ~18% memcpy under `h2_host_flush_out` (prefix drop of `h2_out` after SSL_write).

**Interpretation:** every DATA frame does `remove_range(&s.pending, 0, n)` which memmoves the remainder of a **1 MiB** buffer. O(n²) total copy work for large bodies. Same pattern when consuming `conn.h2_out` after partial SSL_write.

This is **not** OpenSSL AES dominating H2 bulk — it is **dynamic-array front-delete**.

### 2. H1s s1m — encrypt + serial seal after send

Children under `_server_thread_main` (~97%):

| Share | Path |
|------:|------|
| ~30% | `host_on_wire_send` → `tls_host_on_send_complete` → `tls_host_flush_response` → **SSL_write** → **EVP_EncryptUpdate** (~17%) |
| rest | ring wait / submit / materialize / BIO_read copies |

Live path is **serial**: one SSL_write window → drain CT → `submit_send` → CQE → next window. Matches `seal_calls ≈ 17 × reqs`.

### 3. H1s s64k — more I/O wait, less pure encrypt

Children:

| Share | Path |
|------:|------|
| ~41% | `ring_wait` → `io_uring_enter` → `io_send` → **tcp_sendmsg** |
| ~13% self | memmove (BIO_read + materialize `copy_slice`) |
| materialize | `_response_materialize_cmds` copies static body into response buffer each request |

At 64 KiB with 8 workers, CPU is split between **syscall/send path** and **copies**, not only AES.

### 4. H2 s64k — frame build + seal

~25% under `h2_host_send_response` → `conn_send_body` → `_flush_stream_one_frame` (append + remove_range starts to show).  
Seal path still ~2 units per response.

### DSO share (illustrative)

| Cell | Dominant DSO story |
|------|--------------------|
| h1s s64k | server + kernel io_uring/tcp path significant |
| h2 s1m | **libc ~74% self** (memmove) — application buffer churn |

---

## Root-cause ranking (bulk gap vs ntex/go/drogon)

| Priority | Issue | Evidence | Fix direction |
|----------|--------|----------|---------------|
| **P0** | H2 `pending` / `h2_out` front-delete O(n) | 72% memmove → `remove_range` in `_flush_stream_one_frame` | Cursor/read-offset instead of `remove_range`; ring buffer or slice cursor |
| **P1** | Serial seal∥send (live) | `seal_calls ≈ body/64KiB`; SSL_write only after send CQE | Dual-CT / seal while send inflight (PR5.1 SM already pure) |
| **P2** | Full-body materialize on H1 TLS | `materialize == reqs`; copy_slice under respond | Prefer static body → SSL_write without intermediate full materialize when possible |
| **P3** | Mem-BIO CT drain copies | BIO_read → memmove under `tls_host_flush_response` | Larger CT slabs / fewer BIO round-trips; eventual kTLS later |
| **P4** | Window size | 64 KiB pull → many CQEs for 1 MiB | Larger windows once dual-CT safe |

---

## What this is *not*

- Not “AES-GCM is uniquely slow on OpenSSL vs go” as the whole story — go still wins bulk, but our **H2 path spends majority time in memmove**, not crypto.
- Not io_uring failure — h1s s64k spends substantial time *in* successful send; the issue is **how much work we do per byte sealed** and **how many serial turns**.
- Not drogon H2 (N/A); compare bulk H2 only to ntex/go.

---

## Repro

```bash
ssh ranch-bastion.local
cd ~/Projects/proactr-odin/comparisons/tls-h2
# build with symbols
(cd proactr && odin build . -out:server.bin -o:speed -debug)
# start server, then:
sudo perf record -o /tmp/p.data -g --call-graph dwarf -p $(pgrep -n server.bin) -- \
  env SSL_CERT_FILE=$PWD/certs/cert.pem h2load -c 100 -D 12 -t 4 --h1 https://127.0.0.1:18443/s/1m
sudo perf report -i /tmp/p.data --stdio --children --percent-limit 1 | less
```

---

## Recommended next implementation order

1. **H2 pending cursor** — **DONE** (CRITIC_H2_CURSOR_R2 PASS).  
2. **h2_out consume by cursor** — **DONE** (same PR).  
3. **Live dual-CT seal∥send** — **DONE** (CRITIC_DUAL_CT_R2 PASS). Bastion: h2 s64k **~42–45k**, h2 s1m **~2.4–2.9k**, h1s s64k **~50k** (post-cursor was ~6k / 1.9k / 10k).  
4. Full peer matrix re-rank; residual: progressive stream still serial, H1 materialize, mem-BIO copies.
