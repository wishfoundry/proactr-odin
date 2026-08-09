# App Contract

**Frozen public story for application and middleware authors.**  
If it is correct on clear HTTP/1.1, it is correct on HTTPS and HTTP/2 — *for capabilities marked ✅ in [`CAPABILITY_MATRIX.md`](CAPABILITY_MATRIX.md)* (including TLS H2 concurrent unary + multi-SSE after PR9 offline M1–M6). ⏳ cells (e.g. WS-on-H2, bulk firehose) are listen/phase-gated, not handler `#if`.

Host design docs under `docs/design/` are **not** required reading for app authors. See also [`MIDDLEWARE_CONTRACT.md`](MIDDLEWARE_CONTRACT.md) and [`PHASE0_E0.md`](PHASE0_E0.md).

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
  Hangup law: ONLY .Client_Gone (never protocol death enums)
  Backpressure: ONLY .Writable

ADVANCED (optional read — never required for correctness)
  plan_context(res) → exactly four fields:
    sendfile_ok, preferred_copy_budget, max_write_unit, zero_copy_send

NEVER (reject PR / docs / examples)
  SSL*, Provider, BIO, stream ids, Response._sid, Session as frame id
  body_set_pull or any app-registered pull / Host_Pull from app code
  io.Stream as SSE/long-lived API
  resume / poll / "arm write"
  Conn_Proto / Message_Proto / caps / http/debug in handler or examples/
  body modes that mean writev | sendfile | SSL_write
  progressive stream_* as a second long-lived product
  third public intent rail (anything beyond commands | effects)
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
