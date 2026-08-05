# Five-profile peer matrix — ranch-bastion (v1)

**Host:** ranch-bastion · WORKERS=8 · c=100 · z=15s · oha · FORCE_REBUILD=1  
**Rules:** [`../PROFILE_MATRIX.md`](../PROFILE_MATRIX.md)  
**TSV:** `profile_matrix_v1.tsv`

## Mechanism legend (required)

| Label | Meaning |
|-------|---------|
| `preconcat_blob` | Multi-slice intent merged once at process start; one buffer on wire |
| `multi_send` | proactr-opt: sequential multi-buffer send (**not** kernel writev) |
| `file_read_full` | Full file read into userspace then send |
| `file_chunked` | proactr-opt: chunked pread+send (**not** kernel sendfile) |
| `materialize_copy` | CL body, single buffer |
| `sse_oneshot_CL` | 42 B event-stream, Content-Length (peer-fair oneshot) |

**Drogon:** I/O = **epoll**. oha `Size/request` is often **wrong** on large bodies (e.g. 1362 vs 524288); **post-load body re-check is source of truth**. RPS kept only if body contracts passed.

## Full RPS table (all cells body-check OK; no INVALID)

| peer | tiny | gen | assembled | blob | file | sse |
|------|-----:|----:|----------:|-----:|-----:|----:|
| proactr-mat | 350249 | 374261 | 13157 | 6313 | 4814 | 359069 |
| proactr-opt | 360268 | 358772 | 16904 | 6996 | 7453 | 344317 |
| laytan | 324113 | 323673 | 5502 | 2301 | 1930 | 274862 |
| ntex | 357965 | 360002 | 11953 | 5536 | 6094 | 346252 |
| drogon† | 290496 | 289899 | 2847 | 1471 | 825 | 291719 |

† epoll + oha size untrusted on large routes.

## Mechanism-split views (do not cross-rank)

### A. Framing / tiny work (`materialize_copy` / static 13 B)

| peer | tiny | gen | sse |
|------|-----:|----:|----:|
| proactr-mat | 350k | 374k | 359k |
| proactr-opt | 360k | 359k | 344k |
| ntex | 358k | 360k | 346k |
| laytan | 324k | 324k | 275k |
| drogon | 290k | 290k | 292k |

### B. Preconcat large static (`preconcat_blob` / single buffer)

| peer | assembled (512 KiB) | blob (1 MiB) |
|------|--------------------:|-------------:|
| proactr-mat | 13157 | 6313 |
| ntex | 11953 | 5536 |
| laytan | 5502 | 2301 |
| drogon† | 2847 | 1471 |

**proactr-opt assembled (16904) is multi_send — not in this table.**

### C. File paths (split)

| peer | mechanism | file RPS |
|------|-----------|---------:|
| proactr-mat | file_read_full | 4814 |
| ntex | file_read_full | 6094 |
| laytan | file_read_full | 1930 |
| drogon† | file_read_full | 825 |
| proactr-opt | **file_chunked** | **7453** |

### D. proactr mat vs opt (same host, different mechanism)

| route | mat | opt | note |
|-------|----:|----:|------|
| assembled | 13157 preconcat | 16904 multi_send | different mechanism |
| file | 4814 read_full | 7453 chunked | different mechanism |
| tiny/gen/blob/sse | similar | similar | both materialize-class |

## What this matrix is allowed to claim

- Five body profiles with **peer-shared contracts** (length + content + file=disk).  
- Dual proactr modes.  
- Honest mechanism labels (multi_send ≠ writev; chunked ≠ sendfile).  
- Competitive framing vs ntex on tiny/gen/sse.  
- Preconcat large-body ceiling vs ntex/laytan/drogon.

## What it still must not claim

- Kernel writev or sendfile parity with ntex.  
- Peer multi-iovec contest (peers preconcat).  
- Long-lived SSE ranking.  
- Fortunes / DB framework ranking.

## Reproduce

```bash
ssh ranch-bastion.local
cd ~/Projects/proactr-odin
WORKERS=8 BENCH_C=100 BENCH_Z=15s FORCE_REBUILD=1 \
  LOGDIR=/tmp/profile-matrix-run ./comparisons/tfb/run_profile_matrix.sh
```
