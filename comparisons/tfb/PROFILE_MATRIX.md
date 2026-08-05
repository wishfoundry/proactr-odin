# Five-profile peer matrix (hard rules)

## Profiles

| ID | Path | Body contract (all peers) | What is measured |
|----|------|---------------------------|------------------|
| tiny | `GET /api/tiny` | exactly `Hello, World!` (13 B) | framing ceiling |
| gen | `GET /gen/ok` | exactly `generated:ok\n` (13 B) | build-in-handler, no DB |
| assembled | `GET /static/assembled` | exactly **512 KiB** = 8×64 KiB slices with first byte `'A'+i` | multi-fragment intent |
| blob | `GET /static/blob/1m` | exactly 1 MiB pattern payload | single large static |
| file | `GET /file/1m` | exactly 1 MiB from **same file** `$PLAN_FILE_PATH` | file/send path |
| sse | `GET /sse` | exact bytes below (oneshot events), **Content-Length** (not chunked) | event-stream oneshot framing (peer-fair) |

### Assembled body construction (mandatory)

```
for i in 0..7:
  slice[i] = pattern_payload(65536)
  slice[i][0] = 'A' + i
body = concat(slice[0..7])  # 524288 bytes
```

Pattern = repeating 64-byte hex block:
`0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF`.

### SSE oneshot body (mandatory)

```
event: ping\ndata: 1\n\nevent: ping\ndata: 2\n\n
```

Content-Type: `text/event-stream`. Keep-alive OK. **Not** long-lived hold (label `sse_oneshot`).

### File

- Default path: `/tmp/proactr-profile-file-1m.bin`
- Created by harness if missing (same pattern as 1 MiB blob).
- Peers **must read/serve that file** (not an in-memory alias pretending to be a file).

## Mechanism labels (required in meta)

Each peer/route reports (or harness infers):

| Label | Meaning |
|-------|---------|
| `materialize_copy` | body copied into one buffer then send |
| `preconcat_blob` | multi-slice merged at process start; wire is one blob |
| `multi_send` | multiple sequential sends (proactr “Writev” today) |
| `kernel_writev` | real gather syscall/SQE |
| `file_read_full` | full file read into RAM then send |
| `file_chunked` | chunked pread+send |
| `kernel_sendfile` | real sendfile/splice |
| `sse_oneshot` | one response with event-stream body |
| `sse_hold` | long-lived (not in v1 matrix) |

**Lie ban:** never call `multi_send` “writev” in summaries. Never call `file_chunked` “sendfile”.

## Proactr modes

| SERVERS id | plan_optimize | Profiles |
|------------|---------------|----------|
| `proactr-mat` | false | all routes materialize-friendly |
| `proactr-opt` | true | assembled multi_send; file file_chunked; tiny/gen materialize |

## Forbidden excuses

1. “Assembled is just /s/64k × 8 in spirit” without 512 KiB concat contract  
2. Fortunes as proxy for gen  
3. In-memory buffer labeled as file  
4. Optimize multi_send labeled writev  
5. Skipping body-check under load  
6. Different WORKERS/c/z per peer  
7. Claiming stream ranking on oneshot without saying so  
8. Comparing only proactr A/B and calling it peer validation  

## Pass bar (judge)

- All peers 200 + exact body lengths on all six paths  
- Mechanism labels present and honest  
- Matrix includes **both** proactr-mat and proactr-opt  
- ntex + drogon + laytan on same six paths  
- Bastion (or Linux) WORKERS=8, c≥64, z≥15s  
- No SIZE_WARN on non-drogon; drogon size anomaly documented if oha lies  
