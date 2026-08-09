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
| Hangup detection | **Idle timer + send error** (clear PIN disabled without cancel); **ciphered Open** arms CT recv for peer FIN / close_notify → `.Client_Gone` |
| Mailbox wake | **Partial** — `mail_pending` → `ring_wait(0)` (not eventfd) |
| Idle vs Heartbeat timers | **Done** |
| Timer UAF / session epoch | **Done** |
| WS outbound + upgrade | **Done** (send-oriented; no inbound frame parse) |
| Soft 503 session admission | **Done** — over `max_sessions_per_worker × threads` → 503 + invalid `Session` (id=0); metric `session_metrics_admission_reject`; check `session_status` / `id != 0` |
| TLS H1 SSE/WS (PR6) | **Done (same App Contract)** — `sse_start` / `ws_start` over ciphered progressive stream (`_stream_try_submit` → `tls_host_stream_try_submit`); listen PEMs enable host TLS (no handler `#if`). Not H2 / not M6. |

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

- `Wire_Kind.Stream` — one send in flight (clear H1)  
- Clear send: body from **pool slab** (≤8 KiB per CQE); unsent tail stays in compacting `resp_buf`  
- After clear CQE: return slab, compact, reflush if more data  
- Hangup: clear-H1 **no PIN recv** (disabled without cancel) → Idle_Timeout + send errors; TLS H1 arms **CT recv** on session attach / mid-idle (Open+ssl) → peer FIN / close_notify → `.Client_Gone`  
- Ciphered progressive send (PR6): plain frames still written into `resp_buf`; `_stream_try_submit` routes to `tls_host_stream_try_submit` (windowed `SSL_write` → `tls_ct_tx`; **no** stream_pool slabs; no plain-send bypass)  
- Mid-session TLS CT complete does **not** oneshot-clean the request loop  
- Error/close paths: clear slabs via `_stream_pool_abandon`; TLS CT uses `tls_ct_tx`  

Implementer notes: [`TLS_H1.md`](TLS_H1.md). Ship scorecard: [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).

---

## Remaining follow-ups (optional)

1. True eventfd / EVFILT_USER wake (today: zero wait when `mail_pending`)  
2. Portable recv cancel (PIN disarm without waiting for CQE)  
3. Soft 503 on **stream pool** bytes admission (session cap soft path is **Done**)  
4. Full WS inbound frame codec  
5. H2 / M6 concurrent multi-SSE — **Done offline (PR9)** — matrix ✅; see `H2_PRODUCT_BASELINE.md`  


---

## Tests

```bash
odin test http -o:none
# includes PR6: ciphered session attach (SSE/WS), hangup CT gate, tls_host stream long-lived
odin test http/middleware -o:none
```

Manual TLS SSE (OpenSSL + PEMs): `examples/https_demo` `/sse` — see [`TLS_H1.md`](TLS_H1.md).
