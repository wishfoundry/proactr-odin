# Profile matrix — Darwin kqueue (local)

**Host:** macOS (Apple Silicon) · **I/O:** proactr `platform_kqueue` · ntex  
**Date:** 2026-08-05 · **W=8 · c=100 · z=10s · oha**

## Mechanisms (honest)

| peer | assembled | file | tiny/blob/sse |
|------|-----------|------|-----------------|
| proactr-mat | preconcat materialize | file_read_full | materialize |
| proactr-opt | **multi_send** (no WRITEV on kqueue) | **Darwin sendfile(2)** (default) | materialize |
| proactr-opt-fallback | multi_send | file_chunked (`PLAN_WIRE_SENDFILE=0`) | same |
| ntex | preconcat | file_read_full | materialize |

- `plan_wire_prefer_kernel()` → false on Darwin (no IORING_OP_WRITEV).  
- `plan_wire_prefer_sendfile()` → **true** on Darwin (kqueue + BSD `sendfile`).  
- Implementation: `proactr/platform_kqueue.odin` (`darwin_sendfile` + EVFILT_WRITE on EAGAIN).

## Baseline RPS (before Darwin sendfile — file was chunked)

| peer | tiny | assembled | blob | file | sse |
|------|-----:|----------:|-----:|-----:|----:|
| proactr-mat | **131k** | 12.2k | 5.9k | 3.4k | **131k** |
| proactr-opt (chunked) | **132k** | 11.6k | 6.1k | **5.1k** | 131k |
| ntex | 96k | **17.2k** | **8.3k** | **8.2k** | 100k |

Artifact: `profile_matrix_kqueue.tsv`

## After Darwin sendfile (file + tiny rebench)

Artifact: `profile_matrix_kqueue_sendfile.tsv`

| peer | file 1 MiB | tiny |
|------|----------:|-----:|
| proactr-mat (full-read) | 4.2k | 142k |
| **proactr-opt (Darwin sendfile)** | **10.3k** | 139k |
| ntex (full-read) | 8.3k | 97k |

| comparison | ratio |
|------------|------:|
| opt sendfile / opt chunked (prior) | **~2.0×** |
| opt sendfile / ntex | **~1.24×** |
| opt sendfile / mat full-read | **~2.4×** |

All body-checks **VALID**. End-of-load EPIPE/ENOTCONN on sendfile is client disconnect, not process death.

## vs Linux bastion (not same machine — rank only)

| route | kqueue | bastion Linux |
|-------|--------|---------------|
| tiny/sse | proactr ≥ ntex | proactr ≈ ntex |
| assembled | ntex wins (multi_send only) | proactr WRITEV ≥ ntex preconcat |
| file | proactr **Darwin sendfile > ntex** | proactr **Linux sendfile ~2× ntex** |

## Reproduce

```bash
cd comparisons/tfb
SERVERS="proactr-mat proactr-opt ntex" \
  TESTS="file tiny" WORKERS=8 BENCH_Z=10s \
  LOGDIR=/tmp/profile-matrix-kqueue-sf FORCE_REBUILD=1 \
  ./run_profile_matrix.sh

# Force chunked again:
PLAN_WIRE_SENDFILE=0 ...
```
