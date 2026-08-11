# Project identity

| | |
|--|--|
| **Name** | proactr-odin |
| **I/O** | Proactor / completion-based (io_uring-first) |
| **HTTP** | package `http` on `proactr` |
| **Client** | package `client` |
| **Upstream** | `vendor/laytan/odin-http` (unmodified baseline) |

## Principles

1. **Completions, not readiness** — submit + complete is the primary API.
2. **Linux first** — optimize io_uring; other OS backends are secondary.
3. **Batched CQ reaping** — amortize syscalls; multi-shot where available.
4. **Explicit op lifetime** — in-flight ops own buffers until completion.
5. **Thin HTTP host** — parse/respond sit on the proactor; no hidden `core:nbio`.
6. **Measure peers** — published set is proactr / laytan / ntex / drogon / go
   (`benchmarks/TFB.md`); harnesses under `comparisons/`.
