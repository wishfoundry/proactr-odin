# Examples

| Dir | What |
|-----|------|
| `empty_ok/` | Minimal HTTP empty-OK peer (native) |
| `wasi_demo/` | **proactr WASI proof** — soft_cq / timers work; sockets need host |

WASI is the only WASM backend (no separate JS/`js_wasm32` port). Browser or other
hosts should run `wasi_wasm32` modules and complete ops via `ring_wasi_complete`.

Build scripts are Odin (`build.odin`), not shell. They discover `odin` and `wasmtime`
from **PATH** and env overrides (`ODIN`, `WASMTIME`, `ODIN_ROOT`) — no hardcoded
Homebrew prefixes.

## Prove WASI

```bash
odin run examples/wasi_demo/build.odin -file
# needs wasmtime on PATH (or WASMTIME=...)
# build only:  odin run examples/wasi_demo/build.odin -file -- --no-run
```

Expect `RESULT: OK` and exit 0.

## What is proven vs not

| Capability | Proven? |
|------------|---------|
| Backend name `wasi` | yes |
| `ring_init` / destroy | yes |
| `submit_nop` / `submit_close` → soft_cq | yes |
| `submit_timeout` → `TIMEOUT_ETIME` | yes |
| Host complete: `ring_wasi_complete` | yes |
| Accept/Recv/Send without host | **stays parked** (cannot complete alone) |
| Real TCP / HTTP on WASM | **not implemented** (needs wasi-sockets or host bridge) |
