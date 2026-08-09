# Plan R1: Native kqueue reactor host (Darwin/BSD) — rip proactor façade

**Status:** draft for multi-critic loop  
**Date:** 2026-08-09  
**Goal:** On readiness-native OS (Darwin/BSD), run HTTP/TLS host with **native kqueue reactor law**, not proactor-emulation via soft-CQ. Linux stays true io_uring proactor. **App contract unchanged.**

---

## 0. Problem statement

### What we have

```text
APP_CONTRACT (respond / body_* / effects)
        │
        ▼
http host written as proactor SM
  seal → host_submit_send → proactr.submit_* → CQE → host_on_wire
        │
        ▼
proactr portable API (Completion)
        │
   ┌────┴────┐
io_uring   kqueue façade
(true)     (try I/O → soft_cq / EVFILT_*)
```

On kqueue, `submit_send` does one nonblocking `send`; full delivery posts **soft completion**; partial/EAGAIN arms `EVFILT_WRITE`. The host still treats every send as an **op with a completion boundary**. Bulk TLS (dual-CT depth 2, seal → arm → CQE → promote) cannot match drogon’s **encrypt+write until EAGAIN** reactor loop.

### What failed under proactor law (do not re-run as product flags)

H1 dense, Dual_Ct N=4, BIO peek package, windowed H2 frame, NODELAY, 1 MiB seal — critics + remeasure closed these as free RPS under the **current** host law.

### Thesis

The expensive ongoing tax is **emulating proactor on kqueue + host written only for that lie**. Native reactor on Darwin is one honest path, not “proactor + façade + density hacks.”

---

## 1. Non-goals

| Non-goal | Why |
|----------|-----|
| Change APP_CONTRACT / handlers / middleware public API | Frozen product identity |
| Expose readiness, kqueue, or engine choice to apps | Violates contract |
| Delete Linux io_uring proactor | True proactor stays product on Linux |
| kTLS / leave OpenSSL as required for this plan | Separate track |
| Beat drogon 3× in PR1 | Honest stretch; gate is duty-cycle + RPS movement |
| Full HTTP/3 / demux multi-protocol | Out of scope |
| Keep kqueue façade *and* reactor forever | Façade deleted or reduced to timers-only after cutover |

---

## 2. Target architecture

```text
APP_CONTRACT  (unchanged)
        │
        ▼
http host
  shared: parse, route, H2, HPACK, planner, sessions, TLS setup (OpenSSL provider)
  engine-specific: accept / recv / send / TLS bulk flush / wire ownership
        │
   ┌────┴─────────────────────┐
   │                          │
Io_Proactor                 Io_Reactor
(Linux; Windows later)      (Darwin/BSD)
proactr io_uring            native kqueue
submit + CQE                readiness + do work
dual-CT CQE law             seal/write-until-EAGAIN
```

**Selection:** compile-time `when ODIN_OS` (or single `IO_ENGINE` enum set at worker start). No runtime app switch.

**proactr package after cutover:**

| OS | Role |
|----|------|
| Linux | Full proactor (unchanged product) |
| Darwin/BSD | **Optional:** timers + listen helpers only, **or** delete socket ops from kqueue platform and move listen/accept into host reactor |
| Windows | Unchanged IOCP for this plan (phase later if needed) |

---

## 3. Public API impact

| Surface | Change |
|---------|--------|
| `APP_CONTRACT` oneshot / long-lived / plan_context | **None** |
| `examples/`, middleware public hooks | **None** |
| `proactr` as *app* dependency | Apps already must not use ring; host-only |
| Operator metrics | Add `io_engine=reactor-kqueue\|proactor-uring` on `/_matrix/stats` |
| Docs | ARCHITECTURE + IMPLEMENTATION_STATUS honesty |

**Ergonomics law:** If a handler `#if`s OS or engine, the plan failed.

---

## 4. Internal boundary: `Host_Io` (host-private)

Introduce a **host-private** interface (not public package API) used only by `http/wire`, `tls_*`, `server` loop:

```odin
// Conceptual — names flexible; lives in http/ or http/io/
Host_Io :: struct {
  // Worker-local
  wait: proc(io: ^Host_Io, timeout_ms: int) -> []Io_Event, // or pull model
  // Connection ops (engine implements)
  arm_accept:  ...,
  arm_recv:    ...,
  // Send: engine-specific law
  // Proactor: submit buffer, completion later
  // Reactor: write until EAGAIN / full; may complete sync in call
  send_ct:     proc(conn: ^Connection, buf: []u8) -> Send_Result,
  // Send_Result: Full | Partial_Armed | Error
}
```

**Casey / simplicity amendment:** Prefer **two compile-time host files** (`server_loop_proactor.odin`, `server_loop_reactor.odin`) over a fat vtable if vtable obscures the hot path. Vtable only if it prevents `#if` soup in protocol code.

**Rule:** Protocol code (scanner, H2 feed, respond planning) never calls `proactr.submit_*` directly after migration; only `Host_Io` / loop files do.

---

## 5. Phased delivery (ship gates per phase)

### Phase 0 — Spec freeze (docs only, 1 PR)

- This plan + ARCHITECTURE section “dual host I/O laws”  
- Explicit: façade deprecation path  
- Metric definitions for duty cycle (below)  
- **No behavior change**

**Exit:** Critics WOW / APPROVE plan (this loop).

### Phase 1 — Host I/O boundary without behavior change (Linux + Darwin)

- Extract `host_submit_send` / `host_submit_recv` / accept arm / `host_dispatch` behind `Host_Io_Proactor` that is 1:1 with today  
- Both OS still proactor path (Darwin still façade)  
- All tests green; matrix **flat** (±3%)

**Exit:** Refactor-only; no RPS claim.

### Phase 2 — Reactor loop skeleton (Darwin only)

- New worker loop: `kevent` wait → dispatch readable/writable/error  
- Accept + cleartext H1 tiny path **or** TLS H1 plaintext first (choose one vertical slice)  
- Proactor path untouched on Linux  
- **Do not** yet delete façade if proactor still used for residual ops

**Vertical slice recommendation (amendable):**  
**TLS H1 oneshot** (matrix cells) is the product gap; cleartext-first is safer but delays learning. Prefer **TLS H1 plaintext + s4k** as first reactor slice (full dual-CT can stay; send law changes).

**Exit:** Darwin serves matrix H1.s plaintext with `io_engine=reactor-kqueue`; correctness 0 errors; RPS not worse than −10% on plain (guard).

### Phase 3 — Reactor TLS bulk law (the point)

On reactor engine only:

```text
while plain remaining and socket writable:
  SSL_write(window)   // keep 256KiB or match OpenSSL comfort
  drain wBIO → write(fd) until EAGAIN or CT empty
  if EAGAIN: arm EVFILT_WRITE; return
// no soft-CQ between full windows
```

- Dual-CT depth-2 **optional** on reactor: either drop to single CT residual buffer (drogon-like) or keep 2 as residual-only when EAGAIN mid-window  
- Proactor Linux dual-CT unchanged  
- Fairness: max plain bytes or max SSL_write count per kevent turn (e.g. 2 MiB / 8 windows) so one conn cannot starve worker

**Exit gate (Darwin matrix, 3× remeasure):**

| Cell | Gate |
|------|------|
| h1s s1m | ≥ **+15%** vs pre-phase3 same-host baseline (not fantasy drogon parity) |
| h1s plain | ≥ **−3%** |
| h2 plain / h2 s1m | ≥ **−5%** if H2 still on proactor façade; or same gates if H2 already on reactor |
| failed/timeout | 0 |

**Duty-cycle instrumentation (required, not optional theater):**

```text
path_metrics or PHASE:
  seal_windows_per_kevent_turn
  nb_send_full_without_arm
  eagain_arms_per_req
  plain_bytes_sealed_per_wall_ms   // goodput proxy
```

Ship RPS claim only if **also** `seal_windows_per_kevent_turn` ↑ and/or `eagain_arms_per_MiB` ↓ vs proactor-façade baseline.

### Phase 4 — H2 on reactor (Darwin)

- Port `h2_host_flush_out` to reactor send law (dense until-EAGAIN is natural)  
- Keep H2 protocol engine shared  

**Exit:** h2 cells green; h2 s1m not regressed vs Phase 3 façade H2; prefer improvement.

### Phase 5 — Delete kqueue proactor façade socket path

- Remove or stub `proactr` kqueue `submit_send/recv/accept` if unused  
- Keep software timers (portable soft_cq or reactor timer list)  
- `ring_backend_name()` → `"reactor-kqueue"` on Darwin host stats  

**Exit:** No Darwin code path calls `proactr.submit_send` for HTTP sockets.

### Phase 6 — Hardening

- Soak, multi-conn fairness, WANT_READ duplex during bulk  
- Document ceiling vs drogon if still 0.5×  

---

## 6. Correctness laws (non-negotiable)

1. **TLS record order:** never send CT from seal N+1 before seal N fully on wire (or residual ordered).  
2. **Buffer lifetime:** reactor may complete send sync; no UAF of CT slab / resp_buf.  
3. **Partial write:** remainder armed on EVFILT_WRITE; no busy spin.  
4. **Duplex:** bulk send must not starve TLS read (WINDOW_UPDATE / pipelined H1); arm read when appropriate.  
5. **close_on_io / Closing:** same fail-closed as today.  
6. **Session Writable:** map from “was EAGAIN, now writable” — same app event.  
7. **No app-visible engine.**  

---

## 7. Comparison to drogon (honest)

| Drogon | This plan |
|--------|-----------|
| trantor EventLoop + Channel level-trigger | Host reactor + kqueue |
| `sendData`: multi SSL_write(64k)+sendTLSData until buffered | Phase 3 bulk law |
| Full body often in one MsgBuffer | Keep borrowed body / heading split (we’re ahead on copies) |
| No proactor | Darwin only; Linux stays proactor |
| OpenSSL mem-BIO | Same |

We are **not** forking drogon. We adopt **readiness + until-EAGAIN send law** on Darwin only.

---

## 8. Casey Muratori / quality principles (design constraints)

1. **One obvious way on each OS** — no façade that pretends kqueue is uring.  
2. **Hot path readable** — reactor bulk loop should fit on one screen; no 12-state dual-CT promote soup unless needed for residual.  
3. **No speculative generality** — Host_Io is host-private; don’t publish “pluggable engines” for apps.  
4. **Measure the law** — duty-cycle counters before RPS victory laps.  
5. **Delete dead code** — Phase 5 removes façade; no permanent dual for Darwin.  

---

## 9. Performance expectations (harsh)

| Outcome | Plausible |
|---------|-----------|
| h1s s1m +15–40% on Darwin | If façade CQE tax was real |
| h1s s1m → drogon parity | **Unlikely** in this plan alone (OpenSSL userspace still) |
| h1s plain flat / slight up | If less soft-CQ churn |
| Linux matrix | **Unchanged** (no code path) |

If Phase 3 duty cycle moves and RPS does not, stop and document ceiling — do not invent N=4 again.

---

## 10. Risk register

| Risk | Mitigation |
|------|------------|
| Two host paths diverge forever | Shared protocol tests; engine tag in CI matrix |
| Phase 1 drive-by breakage | Flat matrix gate; no behavior change |
| Reactor bulk starves other conns | Per-turn byte/window cap |
| H2 left on façade mid-migration | Explicit Phase 4; matrix labels `io_engine` |
| Timer dual implementation | Keep one timer source (proactr soft timers or reactor heap) |
| Scope explosion | Vertical slice Phase 2–3 before H2 |

---

## 11. PR / agent implementation order

1. **Docs Phase 0** (this plan finalized)  
2. **Phase 1** proactor Host_Io extract (agent: refactor)  
3. **Phase 2** reactor skeleton + TLS H1 plain (agent: implement)  
4. **Phase 3** bulk until-EAGAIN + metrics (agent: implement)  
5. **Impl critics** after Phase 3  
6. **Matrix remeasure** Darwin  
7. Phase 4–5 after Phase 3 gates  

---

## 12. Success definition (“critics WOW”)

Plan WOW when critics agree:

1. App API truly unchanged  
2. Façade is deleted on Darwin, not accumulated  
3. Phases have real gates and duty-cycle metrics  
4. Scope is vertical-slice honest (not “rewrite all HTTP in one PR”)  
5. Drogon comparison is law-level, not cargo-cult  
6. Linux proactor preserved  
7. Failed density experiments are not re-opened as flags under reactor without new evidence  

Implementation WOW when:

1. Correctness tests + 0 matrix errors  
2. Phase 3 RPS gate + duty-cycle movement  
3. No APP_CONTRACT leak  
4. Code is simpler on Darwin hot path than façade + dual-CT soup  

---

## 13. Open questions for critics (resolve in loop)

1. Phase 2 vertical slice: TLS H1 plain first vs cleartext first?  
2. Host_Io vtable vs `when ODIN_OS` file split?  
3. Keep dual-CT on reactor bulk or single residual buffer?  
4. Timers: stay in proactr soft_cq on Darwin or move into reactor?  
5. FreeBSD/OpenBSD same reactor path as Darwin in Phase 2 or Darwin-only first?  
