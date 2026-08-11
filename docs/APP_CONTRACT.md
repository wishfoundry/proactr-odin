# App Contract

Rules for application and middleware authors. A correct clear HTTP/1.1 handler is
correct on HTTPS and HTTP/2 for the oneshot / SSE / WS surfaces the host exposes.
Gaps (for example WS-on-H2) are listen- or phase-gated — not handler `#if`
protocol branches.

See also [`MIDDLEWARE_CONTRACT.md`](MIDDLEWARE_CONTRACT.md).

---

## App surface (the only public story)

```text
ONESHOT
  body_static | body_bytes | body_file | body_set* wrappers
  headers / status / cookies
  respond(res)                    → plan → execute (host)

LONG-LIVED
  sse_start / ws_start → Effects
  Session events only:
    Start | Timer | External | Client_Gone | Idle_Timeout | Writable
  Hangup: ONLY .Client_Gone (never protocol death enums)
  Backpressure: ONLY .Writable

ADVANCED (optional)
  plan_context(res) → four fields:
    sendfile_ok, preferred_copy_budget, max_write_unit, zero_copy_send

NEVER in handlers / public docs / examples
  SSL*, Provider, BIO, stream ids, Response._sid, Session as frame id
  body_set_pull or app-registered pull / Host_Pull
  io.Stream as SSE/long-lived API
  resume / poll / "arm write"
  Conn_Proto / Message_Proto / caps / http/debug
  body modes that mean writev | sendfile | SSL_write
```

| Path | API |
|------|-----|
| **Oneshot** | headers / status / `body_*` → `respond` |
| **Long-lived** | `sse_start` / `ws_start` → `Effects` |
| **Events** | `Start`, `Timer`, `External`, `Client_Gone`, `Idle_Timeout`, `Writable` |
| **Advanced (optional)** | `plan_context(res)` → **four fields only**. Correctness never requires opening it. |

---

## Mental model (three words)

1. **Intent** — commands or effects (**exactly two rails**)
2. **Exchange** — this request/response or session
3. **Backpressure** — emit effects; host may drop; wait for `.Writable`; death is only `.Client_Gone`

---

## Laws

**Hangup.** All peer death maps to **`.Client_Gone`** only (TCP close/RST, TLS alert, H2 RST_STREAM / stream-affecting GOAWAY, send error). Error codes are logs/metrics — not a second `Session_Event_Kind`.

**Unary bytes.** Only body cmds. The host may window large Static/File privately — **no third public intent rail** (no app pull API, no sample that registers pull from app code).

**Long-lived.** Only Effects. Progressive `stream_*` (if still present) is **not** a second long-lived product — SSE/WS use Effects only.

**Identity.** Public `Session.id` is generation only — never an H2 stream id.

---

## Soft admission (production host path, not app API)

When live sessions hit `max_sessions_per_worker × thread_count`, `sse_start` / `ws_start` **soft-reject** with **503 Service Unavailable** (`Retry-After` defaulted when unset) and return `Session{}` (`id == 0`). They do **not** assert. Callers should check `session_status` or `id != 0` before driving Effects.

H2 multi-slot full refuses the extra stream with `RST_STREAM(REFUSED_STREAM)` and keeps the connection open (not a new app event).

Metric: `session_metrics_admission_reject`. Operator checklist: [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md).
