# Implementation Code-Quality Critic — R1

**Bar:** WOW ≥ 9 only when work is **production-honest for its claimed phase**.  
**Subject:** Implemented Phase 0–1 structure + PR4 POD foundation of Plan A R4 — **not** the design doc, **not** full TLS/H2 product.  
**Claim under review:** contracts freeze + `Stream_Slot` sole exchange + planner four-field / `Plan_Policy` / E0.8 tables + pipe POD (`Conn_Pt_Ring` / `Wire_Conn_State` / `Tls_Pipe`) embedded and init-clean on Connection.  
**Baselines:** Design CQ R4 **9.5 WOWED** (paper law). This is **code**, not graft prose.

---

## Score: **7.1 / 10**

## WOWED: **no**

| Layer | Score | Note |
|-------|------:|------|
| App contracts (E0.1–E0.3, matrix, honesty) | 8.8 | Real files; short; PART I voice. E0.4–E0.7 still Planned theater until CI greps. |
| Pure planner laws (four-field PC, E0.8 tables) | 8.6 | Strong pure tests; `Plan_Context` diet real; host meters split. |
| Stream_Slot exchange migration | 7.0 | Conn dual-write of stream/session fields **removed** — real. Response/Loop dual **not**. |
| Pipe POD foundation (PR4) | 6.2 | Types + pure tests land. **Zero** hot-path use. Dual wire bag forever-risk. |
| Free-order / dual free honesty | 6.5 | Session/slab close path mostly careful; incomplete free seams remain. |
| API surface purity (package exports) | 5.8 | Host zoo public; progressive `stream_*` still a public product; dead helpers. |
| **Overall (this phase scope)** | **7.1** | Structure progress without dual-world exit. Not freeze-grade implementation. |

**One-liner:** The design freeze is sharper than the tree. Exchange fields moved into `Stream_Slot`, contracts and E0.8 tables are real, pipe POD is typed and tested — then Response stays in `Loop`, two wire bags sit on every Connection with only one live, package-public host vocabulary leaks, and progressive `stream_*` still contradicts the frozen NEVER list. For “structure + pure laws” this is a solid **mid-7**, not a 9.

---

## What landed (credit, not WOW)

### Contracts (Phase 0 docs)

| Artifact | Judgment |
|----------|----------|
| `/Users/bngreer/Projects/proactr-odin/docs/APP_CONTRACT.md` | Honest oneshot / Effects / four-field / hangup / NEVER. App-author length correct. |
| `/Users/bngreer/Projects/proactr-odin/docs/MIDDLEWARE_CONTRACT.md` | May/must-not table matches plan. File stays File. |
| `/Users/bngreer/Projects/proactr-odin/docs/CAPABILITY_MATRIX.md` | Phase readiness ⏳/✅ + README honesty rules. Eng≠product H2 stated. |
| `/Users/bngreer/Projects/proactr-odin/docs/PHASE0_E0.md` | E0.1–E0.3 + E0.8 **Done**; E0.4–E0.7 **Planned** — correctly labeled, not greenwashed. |

`ARCHITECTURE.md` points authors at contracts and away from design dump. Good social wiring.

### Planner (structure + pure laws)

- `Plan_Context` is **exactly four fields**; `Plan_Host` / `Plan_Policy` hold meters (`ciphered`, `max_iovecs`, …). Rename `tls` → `ciphered` is the right axis.
- Live `plan_context(res)` strips host meters; `plan_policy` drives wire/`plan_body`.
- E0.8 tables in `http/plan_test.odin` lock File+ciphered → no Sendfile, gather only clear, `max_write_unit` coalesce, `Conn_Caps` → `plan_host_from_caps` → no Sendfile under Ciphered, reflect four-field public surface.
- `plan_body` pure policy is still the best code in this tranche.

### Stream_Slot (PR2-shaped)

Pre-diff, session + progressive stream lived on `Connection`. Post-diff:

```odin
// Connection: sole storage for exchange fields — no dual-write on Connection
slot: Stream_Slot
```

Hot paths (`wire.odin`, `session*.odin`, `response.odin`, `connection_close`) read `conn.slot.*`. Free-list ABA `gen` preserved in `stream_slot_reset_exchange`. That is **real** dual-write removal for exchange markers on the pipe type. Design §D “Stream_Slot sole exchange” is half-true in code.

### Pipe POD (PR4)

`http/pipe.odin` + `pipe_test.odin`: constants, `Seal_SM`, `Seal_Unit`, `Wire_Conn_State`, `Conn_Pt_Ring` admit/release high-water, gen-checked `seal_q_*`, `seal_q_remove_gen`, `Tls_Pipe` skeleton without SSL*. `conn_alloc` / `connection_destroy` init/reset `pt` / `wire_conn` / `tls_pipe`. Tests assert bags exist on `Connection`. For “types + pure laws only — no OpenSSL, no ring” the **file-level** claim is honest.

---

## Fatal

**None for the claimed phase scope** (structure + contracts + pure laws; clear-H1 still drives `Wire_State`).

Would become Fatal if marketed as “Phase 1 dual-write gone / pipe owns send” or “Stream_Slot sole exchange complete”:

1. Response + exchange flags still dual-home with `Loop` / Response.
2. `Wire_State` + `Wire_Conn_State` dual wire bags with only one live.
3. Public progressive `stream_*` product rail vs APP_CONTRACT NEVER.

Those are **Major** under the honest claim; they would be **Fatal** under overclaim.

---

## Major

### M1 — Response still lives in `Loop`, not `Stream_Slot`

```odin
Loop :: struct {
	conn: ^Connection,
	req:  Request,
	res:  Response,   // exchange still here
}
```

Plan A: slot owns exchange; Connection is pipe. Implementation: exchange **markers** moved to `Stream_Slot`; **Response** (cmds, profile, streaming flags, hooks, buffer bind) remains `conn.loop.res`. Session teardown still goes through `conn.loop.res` (`_session_end`, `_session_destroy`).

`Response` gained `_slot` and private helpers `response_slot` / `response_conn` — **neither helper is called anywhere**. Every site still uses `r._conn` / `conn.slot` dual paths. That is dual-write **scaffolding without migration**.

**Phase-honest read:** PR2 moved the fields that dual-wrote on Connection. It did **not** complete “sole exchange ownership.” H2 multi-slot will hit this wall first.

### M2 — Dual exchange flags: Response × Stream_Slot

| Response (request-scoped) | Stream_Slot (exchange) | Risk |
|---------------------------|------------------------|------|
| `_streaming` | `stream_open` | Two truths for “stream active” |
| `_stream_ended` | `stream_ending` | Terminal state split |
| `_session_attached` | `session != nil` | Attach dual; destroy clears both by hand |

Asserts and paths check **both** families (`respond`, `sse_start`, `stream_end`, session end). Keep-alive `clean_request_loop` zeroes `loop.res` and slot markers separately. One missed clear → desync under the next protocol feature.

This is residual dual-write of **meaning**, not just field location.

### M3 — Dead pipe bags; dual wire forever-risk

Live executor is exclusively `Connection.wire: Wire_State` (`wire.odin`: kind, pending_send, exec_bufs, iovecs, file_send_*).

Pipe bags on every Connection:

- `pt: Conn_Pt_Ring` — only `pt_ring_init` on alloc/destroy
- `wire_conn: Wire_Conn_State` — only `wire_conn_init` (full `seal_q[32]` of `Seal_Unit` cold)
- `tls_pipe: Tls_Pipe` — only `tls_pipe_init` → Handshake

**No** `pt_admit` / `seal_q_push` / `seal_n_*` on the hot path. Only `pipe_test.odin` exercises laws.

Comments admit “not yet wired — Phase 2+.” That is honest labeling. Quality problem: **two outbound schedule homes** (`Wire_State` vs `Wire_Conn_State`) with Law S1 (“only wire_conn may submit_send”) **unimplemented**. Until clear-H1 submits through one bag, PR4 is type inventory + free-list paint, not foundation under load.

`Conn_Pt_Ring` is admission counters only (“fixed slab free-list — later PR”). Must-alias PT1 is a comment, not a memory ownership structure. Acceptable for POD PR; do not score as PT1 closed.

### M4 — Incomplete free seams (wire / slab / dual bags)

**Good:**

- `connection_close` → `_stream_pool_abandon` before forgetting slab; session destroy before close.
- `_wire_fail` abandons stream pool.
- Destroy path resets `Wire_State` queues + `stream_slot_reset_exchange` + pipe bag inits.

**Incomplete / brittle:**

1. **`clean_request_loop`** sets `conn.slot.stream_send_slab = nil` **without** `stream_pool_put`. Relies on every prior path having abandoned. Fail-closed would call `_stream_pool_abandon` here always.
2. **`connection_destroy` free-list path** zeroes slot via `stream_slot_reset_exchange` (loses slab pointer) assuming close already returned the slab. True if only `connection_close` → destroy; false if any bypass.
3. **Non free-list destroy / thread free** nils `c.slot.stream_send_slab` without put (`conn_slab.odin` shutdown paths) — same class as pre-slot code, not improved by POD.
4. **Dual bag free:** destroy resets both `wire` and `wire_conn`/`pt`/`tls_pipe`, but there is no single §E.4 free-order helper. When seal_q holds `bytes` views and CT slabs exist, free-order will be invented under fire unless one ordered free proc exists **now** as a stub with clear steps.
5. **`_conn_wire_in_flight`** only inspects `wire.kind` — never `wire_conn.sock_send_inflight` / `tls_pipe.sock_send_inflight`. Second truth for “can close?” waiting to fork.

### M5 — Package API surface leaks (host zoo is public)

Odin package default: unprefixed symbols are public. The following are **importable host vocabulary** with no `@(private)`:

| Symbol class | Examples | Contract stance |
|--------------|----------|-----------------|
| Planner host | `Plan_Host`, `Plan_Policy`, `plan_policy*`, `plan_host_*`, `Conn_Caps`, `plan_body`, `Exec_Op*` | App Contract: host meters / Exec_Op not author story |
| Pipe / slot | `Stream_Slot`, `Seal_Unit`, `Wire_Conn_State`, `Tls_Pipe`, `pt_admit`, `seal_q_*` | Framework-private; tutorials must not say these words |
| Progressive product | `Response_Stream`, `response_begin_stream` / `begin_stream`, `stream_write` / `stream_flush` / `stream_end` | APP_CONTRACT **NEVER**: “progressive stream_* as a second long-lived product” |
| Advanced ok-ish | `plan_context`, `Handler_Profile`, `response_set_profile` | Four-field PC is intentional; profile is host bias surface |

Examples currently do not import host types (good). The freeze is still theater if any package consumer can `http.plan_body` / `http.seal_q_push` / `http.begin_stream` as peer APIs. `RESPONSE_COMMAND_PLANNER.md` still teaches Phase 5 `Response_Stream` as first-class product — conflicts with APP_CONTRACT NEVER and PART I “long-lived = Effects only.”

### M6 — Live fill does not use `Conn_Caps`

`plan_host_from_caps` + E0.8 case 7 prove Ciphered kills Sendfile. Live `plan_policy_for` hardcodes `p.ciphered = false` and never reads caps / ALPN / pipe state. Orthogonal caps exist only for tests. Fine for clear-H1; the **wiring seam** for Phase 2 is a comment, not a single fill function that later sets `.Ciphered`. Risk: next PR re-hardcodes flags beside caps.

---

## Minor

1. **`response_slot` / `response_conn` dead code** — written for migration, unused. Delete or route all accessors through them (prefer the latter, then drop raw `_conn` from session paths).

2. **E0.4–E0.7 Planned** — same-handler CI, `http/debug` ban, Host_Pull ban, stream-id print ban. Docs honest; review-only enforcement decays. Grep CI is cheap; land it.

3. **`Exec_Op_Kind` zoo public** — `Patch_CL`, `Flush` listed; teaching surface design residual carried into package API. Keep enum; mark `@(private)` or file-private if Odin allows the split you need for tests (`plan_test` is same package — private is fine).

4. **`plan.odin` header still dual-narrates** Phase 5 `Response_Stream` as a third lifetime rail next to cmds/Effects. Contradicts APP_CONTRACT. Update header to “legacy progressive / host-only; long-lived product = Effects.”

5. **Connection size tax** — full `seal_q[SEAL_Q_CAP]` + dual wire bags on every clear-H1 conn before any TLS. Acceptable for layout freeze; measure and document; do not grow CT slabs the same way without freelist.

6. **`Handler_Profile` + `response_set_profile` + `response_plan_preview`** — powerful host/advanced surface; not in APP_CONTRACT “only public story.” Borderline leak for authors who discover them. Godoc should say “advanced / non-required.”

7. **PHASE0 claims “Phase 1 structure landed: PR1–PR4”** — true as inventory; oversells dual-write exit. Prefer “PR2 field move + PR4 POD types; dual wire and Response-in-Loop remain.”

8. **No free-order unit test for stream RST mid-seal_q on a live Connection** — pure `seal_q_remove_gen` tests exist; integrated free-order (design §E.4) does not. Expected pre-TLS; track as Phase 2 gate.

---

## Dual-write remnant checklist (grep targets)

| Remnant | Status | File anchors |
|---------|--------|--------------|
| `Connection.stream_*` / `Connection.session` | **Gone** | migrated to `slot` |
| `Connection.wire` (live) + `wire_conn`/`pt`/`tls_pipe` (dead) | **Active dual bags** | `server.odin` Connection |
| `Loop.res` vs `Stream_Slot` | **Active** | Response home wrong |
| `Response._streaming` / `_stream_ended` / `_session_attached` vs slot | **Active dual meaning** | `response.odin`, `session.odin` |
| `Response._conn` + `_slot` (helpers unused) | **Active dual pointer** | `response.odin` |
| `plan_policy_for` ciphered hardcode vs `Conn_Caps` | **Active dual fill** | `response.odin` |
| Progressive `stream_*` vs Effects long-lived | **Active dual product** | `response.odin` + APP_CONTRACT |

---

## Scorecard vs design CQ R4 (paper 9.5)

| Design spine item | Design R4 | Impl R1 | Note |
|-------------------|----------:|--------:|------|
| Four-field Plan_Context | 9.5 | **8.7** | Real; live fill still ignores caps |
| Stream_Slot sole exchange | 9.5 | **6.8** | Markers yes; Response/Loop no |
| Dual-write grep-clean Phase 1 | 9.5 | **6.5** | Conn fields clean; dual worlds remain |
| Conn_Pt_Ring must-alias | 9.5 | **5.5** | Counter POD only; no slabs |
| Seal_Unit + gen seal_q | 9.5 | **7.0** | Pure laws tested; never scheduled |
| Close SM free-order | 9.5 | **6.0** | Manual paths; no ordered helper |
| Public surface purity | 9.5 | **5.8** | Host zoo + stream_* public |
| E0 social machine-guns | 9.5 | **7.5** | Docs yes; CI half missing |
| **CQ overall** | **9.5** | **7.1** | Paper ≫ tree |

Design WOW does **not** transfer. Implementation must re-earn it.

---

## What would WOW (≥9 for this phase scope)

Not “finish TLS.” For **structure + contracts + pure laws** to clear the bar:

1. **Response home** — `Stream_Slot` owns (or exclusively aliases) request Response storage for the exchange; `Loop` stops being the exchange owner. At minimum: all host code goes through `response_slot` / `response_conn`; kill dead helpers-by-nonuse.

2. **One flag family** — derive streaming/session attach from `Stream_Slot` (and/or single Response bit updated only from slot mutators). Delete `_session_attached` dual or make it a pure cache with one writer.

3. **One wire bag story for clear-H1** — either:
   - document `Wire_State` as temporary clear executor and schedule its delete when `Wire_Conn_State` absorbs Send/Writev/Sendfile, **with a single free-order proc** that clears both during transition; or
   - start clear submits from `wire_conn` now (even if seal_q is always length-1 clear units).  
   Dead bags with Law S1 comments and zero call sites are not foundation — they are dual-maint bait.

4. **Privacy** — `@(private)` (or file-private) for `Exec_Op*`, `Plan_Host`, `Plan_Policy` if tests allow, `Conn_Caps`, pipe types/helpers, `Stream_Slot` if possible; keep `plan_context` public. Package boundary is the freeze enforcement, not hope.

5. **Reconcile progressive stream API with APP_CONTRACT** — demote `begin_stream`/`stream_*` to private host/SSE implementation detail **or** rewrite NEVER to an honest dual product. The freeze cannot say NEVER while godoc sells Phase 5 stream API.

6. **Fail-closed free** — `_stream_pool_abandon` at the top of `clean_request_loop` and destroy; one `_conn_free_exchange_and_wire(conn)` implementing §E.4 order (even as no-op steps for CT/PT). Never nil-without-put.

7. **Caps fill seam** — `plan_policy_for` calls `plan_host_from_caps(conn_caps(conn))` with `conn_caps` returning `{}` today. One function to flip Ciphered later.

8. **E0.4–E0.7 CI greps** — fail build on examples importing host debug/caps, Host_Pull registration, stream id prints. Cheap; kills social dual re-entry.

9. **Kill dead code** — unused `response_slot`/`response_conn` either wired or removed in the same PR that claims migration.

Ship those and a re-score can hit **≥9 for structure phase** without any TLS record bytes. Until then: **7.1, not WOWED**.

---

## Verdict for merge / next PR

| Question | Answer |
|----------|--------|
| May Phase 0 contracts merge? | **Yes** — E0.1–E0.3/E0.8 are production-honest; land E0.4–E0.7 greps soon. |
| May PR4 POD types merge under “foundation”? | **Yes with label** — types + pure tests only; do not claim Law S1/PT1 operational. |
| Is dual-write gone? | **No** — Connection field dual-write gone; Response/Loop, Response×slot flags, Wire_State×Wire_Conn remain. |
| Ready for TLS PR as sole next step? | **No** — fix Response home / dual flags / free helper / privacy first or TLS will cement dual bags. |

**Harsh bottom line:** This is competent structural scaffolding that stops short of the ownership exit the design already celebrated. Do not confuse “fields moved and POD types exist” with “Phase 1 dual-write exit.” Re-earn the 9 on the tree.
