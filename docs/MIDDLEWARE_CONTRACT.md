# Middleware Contract

**Companion to [`APP_CONTRACT.md`](APP_CONTRACT.md).** Middleware authors share the same public surface as handlers: commands, effects, and the optional four-field `plan_context`. No protocol introspection, no crypto imports, no stream ids.

---

## May / must not

| May | Must not |
|-----|----------|
| Rewrite `[]Response_Cmd` only | Import `tls` / Provider / SSL |
| Read **four-field** `plan_context` only | Read stream ids, slots, rings, SQEs |
| Set headers before `respond` / before `sse_start` | Emit frames, ALPN, or HPACK |
| Short-circuit with unary `respond_*` | Assume exchange finished after `next` for SSE (open ≠ end) |
| Keep `File` / `Static` / `Bytes` under TLS/H2 | Branch “if TLS then different body mode” for correctness |

---

## Rules

- **File stays File.** The planner demotes mechanism when `sendfile_ok` is false. Middleware does not swap body modes for TLS or HTTP/2 correctness.
- **Stream body bytes are never middleware’s job.** Long-lived traffic is Effects (`sse_start` / `ws_start`), not middleware-owned progressive pulls.
- **No sample / godoc / helper** that registers host deferred-produce (`Host_Pull` / pull) from app or middleware code.
- **Same handler.** Middleware that is correct on clear HTTP/1.1 is correct on HTTPS and HTTP/2 for capabilities marked ✅ in this document. No protocol `#if` in middleware layers.
