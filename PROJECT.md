# Project identity

| | |
|--|--|
| **Name** | **proactr-odin** |
| **Not** | [laytan/odin-http](https://github.com/laytan/odin-http) (upstream baseline only under `vendor/`) |
| **Not** | vapor-http (multi-protocol demux experiment — separate tree) |
| **Odin packages** | `proactr`, `http` |
| **I/O model** | Proactor / completion-based, io_uring-first |
| **Upstream vendor** | `vendor/laytan/odin-http` |

## Design principles

1. **Completions, not readiness** — the primary API is submit + complete, not poll-for-readable.
2. **Linux first** — optimize the io_uring path; other OS backends are secondary.
3. **Batched CQ reaping** — amortize syscalls; prefer multi-shot / multishot accept where available.
4. **Explicit op lifetime** — every in-flight op owns its buffer/user data until CQ.
5. **HTTP stays thin** — protocol parse/respond sits on the proactor host; no hidden `core:nbio` dependency.
6. **Bench or it didn’t happen** — peer servers under `comparisons/` and third_party sources under `third_party/`.

## Relationship to laytan/odin-http

- Start from laytan’s HTTP types, routing, headers, scanner ideas.
- Replace the nbio host loop with `proactr`.
- Keep upstream tree unmodified in `vendor/` for apples-to-apples RPS baselines.
