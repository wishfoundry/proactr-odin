# Effect-based Sessions (SSE first, WebSocket later)

**Status:** Progressive Stream + Session API with follow-up pins (pool, temp detach, PIN, mailbox wake short-circuit).  
**Code:** `http/session.odin`, `session_sse.odin`, `session_ws.odin`, `stream_pool.odin`, `response.odin` / `wire.odin` Stream  

### As-built pins

| Pin | Status |
|-----|--------|
| Fixed Stream send slabs (8 KiB) | **Done** — per-worker `Stream_Buf_Pool`; multi-CQE for larger bodies |
| Worker `max_stream_bytes_total` | **Done** — pool admission + metrics |
| Temp-slot detach | **Done** — after Start drive; later drives use 64 KiB worker `session_scratch` |
| Shrink `resp_buf` for sessions | **Done** — at attach + compact after CQE |
| Compact delivered prefix | **Done** — after apply + after Stream CQE |
| Hangup detection | **Idle timer + send error** (PIN recv disabled without cancel API — hang with External) |
| Mailbox wake | **Partial** — `mail_pending` → `ring_wait(0)` (not eventfd) |
| Idle vs Heartbeat timers | **Done** |
| Timer UAF / session epoch | **Done** |
| WS outbound + upgrade | **Done** (send-oriented; no inbound frame parse) |

---

## Happy path

```odin
pad := cast(^Tick)http.sse_alloc(res, size_of(Tick))
http.sse_start(res, on_ticks, {user = pad, on_close = on_close})

on_ticks :: proc(sess: ^http.Session, ev: http.Session_Event, user: rawptr) -> http.Effects {
	st := (^Tick)(user)
	switch ev.kind {
	case .Start:
		return http.effects_of(
			http.effect_sse_event("hello", "ok"),
			http.effect_arm(1 * time.Second),
		)
	case .Timer:
		st.n += 1
		if st.n >= 10 {
			return http.effects_of(http.effect_sse_data("bye"), http.effect_end())
		}
		return http.effects_of(
			http.effect_sse_data(fmt.tprintf("%d", st.n)),
			http.effect_arm(1 * time.Second),
		)
	case .Client_Gone, .Idle_Timeout:
		return http.effects_of(http.effect_abort())
	case .External, .Writable:
		return {}
	}
	return {}
}
```

---

## Public API (summary)

| API | Role |
|-----|------|
| `conn_allocator` / `sse_alloc` | Long-lived pad (freed after `on_close`) |
| `sse_start` | Defaults CT/cache-control, begin stream, attach, drive Start, detach temp |
| `effect_sse_*` / `effect_arm` / `effect_end` / `effect_abort` | Sans-I/O effects |
| `session_post_external` | Worker-affine external cookie → `.External` |
| `session_mailbox_drain` | Host loop (auto after CQEs) |
| `ws_accept_upgrade` / `ws_start` / `effect_ws_*` | WebSocket D3 |

---

## Wire model

- `Wire_Kind.Stream` — one send in flight  
- Send body from **pool slab** (≤8 KiB per CQE); unsent tail stays in compacting `resp_buf`  
- After CQE: return slab, compact, reflush if more data  
- Hangup: **no PIN recv** (disabled without cancel); use Idle_Timeout + send errors  
- Error/close paths always `stream_pool_put` via `_stream_pool_abandon`

---

## Remaining follow-ups (optional)

1. True eventfd / EVFILT_USER wake (today: zero wait when `mail_pending`)  
2. Portable recv cancel (PIN disarm without waiting for CQE)  
3. Soft 503 on session/pool admission instead of assert  
4. Full WS inbound frame codec  

---

## Tests

```bash
odin test http -o:none
odin test http/middleware -o:none
```
