# Published benchmarks

## Primary suite: TFB-style

See [`../comparisons/tfb/`](../comparisons/tfb/).

| Report | Status |
|--------|--------|
| `tfb-*.md` | Add after first Linux baselining run |

### Required columns

Peer · test · RPS · p50 · p99 · errors · workers · host · commit SHAs

### Do not publish as product claims

- vapor-style gen-HTML bulk RPS
- `/plaintext` alone
- JSON codec bake-offs (out of this suite)
- Fortunes without DB + HTML escape

## empty-ok

Wiring canary only (`../comparisons/empty-ok/`).

## Published

| Report | Host | Notes |
|--------|------|-------|
| [tfb-uring-bastion-2026-07-16.md](tfb-uring-bastion-2026-07-16.md) | ranch-bastion | io_uring plaintext + fortunes |
