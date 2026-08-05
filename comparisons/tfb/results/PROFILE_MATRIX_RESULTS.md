# Five-profile peer matrix — ranch-bastion **v2** (WOW package)

**Host:** ranch-bastion · WORKERS=8 · c=100 · z=15s · oha · FORCE_REBUILD=1  
**Rules:** [`../PROFILE_MATRIX.md`](../PROFILE_MATRIX.md)  
**Artifacts:** `profile_matrix_v2.tsv` (pull from bastion `/tmp/profile-matrix-v2/`)  
**INVALID cells:** none (post-load body re-check fail-closed)

## Mechanism legend

| Label | Meaning |
|-------|---------|
| `preconcat_blob` | 8×64 KiB intent merged at process start; one buffer on wire |
| `multi_send` | proactr-opt sequential multi-buffer send (**not** kernel writev) |
| `file_read_full` | Full file read into userspace then send |
| `file_chunked` | proactr-opt chunked pread+send (**not** kernel sendfile) |
| `materialize_copy` / `sse_oneshot_CL` | Content-Length body; SSE = exact 42 B event-stream |

**Drogon:** I/O = **epoll**. oha `Size/request` often wrong on large bodies; **post-load body re-check is source of truth**.

## Full RPS (v2, all body contracts green)

| peer | tiny | gen | assembled | blob | file | sse |
|------|-----:|----:|----------:|-----:|-----:|----:|
| proactr-mat | **370305** | **366295** | 14204 | 6045 | 4871 | 346734 |
| proactr-opt | 347343 | **368913** | **18445**† | **7936** | **8359**‡ | 338772 |
| ntex | 347122 | 345236 | 10726 | 4825 | 5799 | **349872** |
| laytan | 319643 | 318491 | 7550 | 2866 | 2363 | 259190 |
| drogon§ | 288236 | 291240 | 2843 | 1448 | 839 | 291243 |

† `multi_send` — do not rank vs peer preconcat  
‡ `file_chunked` — do not rank vs peer `file_read_full`  
§ epoll

## Mechanism-split ranks (only same mechanism)

### Framing (13 B / 42 B CL)

| peer | tiny | gen | sse |
|------|-----:|----:|----:|
| proactr-mat | **370k** | **366k** | 347k |
| proactr-opt | 347k | **369k** | 339k |
| ntex | 347k | 345k | **350k** |
| laytan | 320k | 318k | 259k |
| drogon | 288k | 291k | 291k |

### Preconcat large static

| peer | assembled 512 KiB | blob 1 MiB |
|------|------------------:|-----------:|
| proactr-mat | **14204** | **6045** |
| ntex | 10726 | 4825 |
| laytan | 7550 | 2866 |
| drogon | 2843 | 1448 |

### File

| peer | mechanism | RPS |
|------|-----------|----:|
| proactr-opt | file_chunked | **8359** |
| ntex | file_read_full | 5799 |
| proactr-mat | file_read_full | 4871 |
| laytan | file_read_full | 2363 |
| drogon | file_read_full | 839 |

### proactr mat vs opt (informational)

| route | mat | opt | mechanisms |
|-------|----:|----:|------------|
| assembled | 14204 | 18445 | preconcat vs multi_send |
| file | 4871 | 8359 | read_full vs chunked |
| tiny | 370k | 347k | both materialize-class |

## Allowed claims

- Peer-shared body contracts (content + file=disk + post-load re-check).  
- Dual proactr modes with honest multi_send / file_chunked labels.  
- Competitive framing vs ntex on tiny/gen/sse.  
- Preconcat large-body ceiling: proactr-mat > ntex ≫ laytan ≫ drogon.  
- Wire counter name: `plan_wire_multi_send_total` (not writev).

## Forbidden claims

- Kernel writev or sendfile.  
- Peer multi-iov assembled contest.  
- Long-lived SSE.  
- Fortunes as framework RPS.

## Reproduce

```bash
ssh ranch-bastion.local
cd ~/Projects/proactr-odin
WORKERS=8 BENCH_C=100 BENCH_Z=15s FORCE_REBUILD=1 \
  LOGDIR=/tmp/profile-matrix-v2 ./comparisons/tfb/run_profile_matrix.sh
```
