# Implementation critic — memory handling (r1)

**Posture:** harsh memory critic. Credit only for free-order that cannot leak under incomplete handlers, free-list reuse, or CQE afterlife. “Phase 1 POD” does not excuse **orphan heap**, **zero-without-free**, or **gen theater**.  
**Bar:** WOW ≥ 9 for Phase 0–1 + pipe POD **only if** every exchange/conn recycle path is pad-safe, gen-honest, dual-pointer-safe, and slab tax is intentional (not accidental dual bags).  
**Subject:** live `http/` — `Stream_Slot` / `session_pad` / gen ABA, `stream_slot_reset_exchange`, `Connection` size with `pt`/`wire_conn`/`tls_pipe`, Response `_slot`/`_conn`, known `test_dynamic_unwritten` leak.  
**Measured (odin `size_of`, 2026-08-08):**

| Type | Bytes | Note |
|------|------:|------|
| `Connection` | **5160** | ~5.0 KiB per free-list record |
| `Wire_State` | 1152 | live clear-H1 schedule |
| `Wire_Conn_State` | **1304** | Phase 1 POD; **not on hot path** |
| `Tls_Pipe` | 16 | skeleton |
| `Conn_Pt_Ring` | 8 | admitted+hw only |
| `Stream_Slot` | 104 | session + progressive markers |
| `Loop` | 2232 | still owns `req`/`res` |
| `Response` | 1920 | still in `Loop`, not slot |
| `Seal_Unit` | 40 | × `SEAL_Q_CAP=32` = 1280 of wire_conn |
| `Session_State` | 96 | heap (`conn_allocator`) |

**Not in scope:** redesign of Plan A ontology; peer benches; TLS record physics (no CT slabs yet).

---

## Verdict

| Axis | Score | Note |
|------|------:|------|
| **session_pad / free-on-destroy** | **5.5 / 10** | Happy path frees after `on_close`. Orphan pad if `sse_alloc` without session; `reset_exchange` zeros pointer without free. |
| **gen / ABA honesty** | **6.5 / 10** | Free-list preserve + attach bump + skip-0 are correct. Dual `st.gen` bump-on-destroy vs `slot.gen`; no bump on stream/exchange death (plan §E.4 incomplete). |
| **slab / Connection growth** | **6.0 / 10** | `wire_conn` alone = **25.3%** of `Connection`; dual wire bags ≈ **47.6%**. Dead weight until Phase 2. |
| **UAF / dual pointers** | **7.0 / 10** | Timer-deferred `Session_State` free is solid. `Response` dual `_conn`+`_slot` and `Session._conn` (plan wanted `_slot`) are residual dual-write surface. |
| **test / bookkeeping hygiene** | **7.5 / 10** | Known 64B leak in `test_dynamic_unwritten`; stream pool abandon on close is good. |
| **Overall (memory for Phase 0–1 + POD)** | **6.4 / 10** | |

### WOWED: **No**

**One-line:** Gen preserve on free-list and session happy-path free-order are competent; memory bar fails on **orphan `session_pad`**, **reset-without-free**, **premature 1.3 KiB `seal_q` on every conn**, and **incomplete dual gen / dual Response pointers** relative to Plan A free-order and sole-ownership laws.

WOW withheld until pad cannot outlive destroy, gen has one owner story, and Connection slab tax is either justified by a live consumer or deferred.

---

## Mandate checks (user-specified)

### 1. `Stream_Slot.session_pad` / gen ABA / free on destroy

#### What works

| Mechanism | Evidence | Grade |
|-----------|----------|-------|
| Pad alloc on slot | `sse_alloc` → `conn.slot.session_pad` + `session_pad_size`; assert one pad / attach cycle | **OK** |
| Free after `on_close` | `_session_destroy`: hooks → `mem.free(session_pad)` → nil fields | **OK (happy path)** |
| Gen preserve free-list | `stream_slot_reset_exchange`: save `gen`, `slot^={}`, restore `gen`, wire `conn` | **OK** |
| Attach bump + skip 0 | `stream_slot_bump_gen`; `sse_start` / `ws_start` set `st.gen` / `Session.id` | **OK** |
| Timer CQE afterlife | `Session_State` stays live until `timer_pending_cqes==0`; free only then | **OK (UAF-aware)** |
| Public handle ABA (basic) | `session_status` / `session_post_external`: nil session or `public.id != s.id` | **OK for H1 free-list** |

#### Fatal / near-fatal: orphan pad + zero-without-free

```odin
// stream_slot_reset_exchange — http/slot.odin
gen := slot.gen
slot^ = {}          // zeros session_pad pointer
slot.gen = gen
slot.conn = pipe
// NO free of previous session_pad
```

```odin
// connection_close — only destroys session if non-nil
if c.slot.session != nil {
    _session_destroy(c, after_wire = false)
}
// … later …
connection_destroy → stream_slot_reset_exchange  // pad pointer dropped cold
```

| Scenario | Result |
|----------|--------|
| `sse_alloc` then `sse_start` then End/Close | Pad freed in `_session_destroy` | **Safe** |
| `sse_alloc` then handler returns / panic path / never `sse_start` then conn close | `session == nil` → **no free**; destroy **zeros pad** | **HEAP LEAK** |
| `_session_destroy` when `conn.server == nil` | Free gated on `server != nil` | **Pad stuck / leak** |
| Double destroy | First free+nil; second early-return on `st.closed` | **Safe** |

Comment on destroy says “Session must already be destroyed” — that is an **invariant hope**, not a **defensive free**. Memory critics do not grade hopes.

**Verdict:** Free-on-destroy is **incomplete**. Treat as **Fatal** for memory bar (orphan path is real API shape: docs say “Call before `sse_start`”).

#### Major: dual gen owners

| Epoch | `slot.gen` | `Session_State.gen` | `Session.id` |
|-------|------------|---------------------|--------------|
| Attach | bumped | `= slot.gen` | `= st.gen` |
| Live | stable | `== slot.gen` | stable copy |
| Destroy | **unchanged** | **`st.gen += 1`** (diverges) | still attach id on `st.public` |
| Exchange recycle (unary) | **unchanged** | n/a | n/a |
| Free-list reuse | preserved | n/a | n/a |

Plan **§E.4** stream death: bump gen intent → remove `seal_q` by gen → free storage → gen++.  
Plan **§D.6** lookup: `slot.gen == id && !closed`.

Implementation:

- Bumps `slot.gen` **only on session attach**, not on stream RST / exchange end / clean_request_loop.
- Extra `st.gen += 1` on destroy **without** updating `st.public.id` and **without** bumping `slot.gen` — dual counter with no single owner.
- Mailbox stores `st.gen` at post; drain compares `st.gen != slot.gen` only while `conn.slot.session` still non-nil (after destroy session is nil, so path is mostly dead).

For Phase 1 (no live `seal_q` on clear-H1), **Session handle** ABA still works because free-list + attach bump eventually move `slot.gen`, and ended sessions nil the pointer. That is **luck of the phase**, not law implementation.

When Phase 2+ enqueues `Seal_Unit{slot_gen}`, **stale units can match a non-bumped live gen across exchange recycling** unless every death path bumps `slot.gen` and dequeues by that gen. POD helpers (`seal_q_pop_gen_checked`, `seal_q_remove_gen`) exist; **host never drives them**. Gen is half-wired.

**Verdict:** ABA is **partial**. Dual gen is **Major** correctness debt labeled as memory/ABA.

#### Minor: dead pin fields

`stream_pin_gen`, `stream_pin_byte` live on every slot; `_stream_pin_arm` is a no-op (disabled without cancel). Bytes are small (slot = 104 total) but they are **ghost state** on the free-list footprint with no consumer.

---

### 2. `stream_slot_reset_exchange` preserves gen correctly

| Check | Result |
|-------|--------|
| Gen saved across `slot^ = {}` | **Yes** |
| `conn` rewired to pipe | **Yes** |
| Called from `conn_alloc` and `connection_destroy` | **Yes** |
| Does not free owned heap (`session_pad`, `stream_send_slab`) | **By design — and that is the hazard** |
| Clears `session` pointer without freeing `Session_State` | **Yes** — relies on prior `_session_destroy` |

**Preserve-gen itself: PASS.**  
**Reset as a complete exchange teardown: FAIL** (ownership not drained).

Required shape for a memory-safe reset (sketch):

1. If `session != nil` → `_session_destroy` (or assert already destroyed).  
2. If `session_pad != nil` → free (defensive; covers orphan alloc).  
3. If `stream_send_slab != nil` → `stream_pool_put` / abandon (defensive).  
4. Then gen-preserving zero + wire `conn`.

Today step 4 alone is what runs on destroy. Close path does 1 and pool abandon **only when session / close path cooperates**.

---

### 3. Connection larger with `pt` / `wire_conn` / `tls_pipe` — slab / chunk impact

#### Measured tax

| Component | Bytes | % of Connection |
|-----------|------:|----------------:|
| `Wire_Conn_State` (`seal_q[32]`) | **1304** | **25.3%** |
| `Tls_Pipe` | 16 | 0.3% |
| `Conn_Pt_Ring` | 8 | 0.2% |
| **Phase 1 POD total** | **1328** | **25.7%** |
| Live `Wire_State` | 1152 | 22.3% |
| **Dual wire bags** (`wire` + `wire_conn`) | **2456** | **47.6%** |
| Without Phase 1 POD (est.) | ~3832 | — |

Default `CONN_CHUNK_SIZE = 64`:

| Metric | Value |
|--------|------:|
| Connection records / chunk | 64 × 5160 ≈ **322.5 KiB** |
| Of which inert `wire_conn` | 64 × 1304 ≈ **81.5 KiB / chunk** |
| vs default `resp_buf` | 1304 / ~1.0 MiB ≈ **0.12%** per live conn |

#### Interpretation (harsh)

1. **Absolute vs resp_buf:** POD tax is **noise next to 1 MiB `resp_buf`** and multi‑MiB temp slots. Anyone who says “Connection is huge because of TLS POD” without measuring `resp_buf` is wrong.  
2. **Relative to pipe header craft:** embedding a **full 32-deep `Seal_Unit` queue on every clear-H1 free-list record before any seal path exists** is **premature layout**. That is **81.5 KiB of pure queue POD per 64-conn grow** that never moves a byte.  
3. **Dual schedule bags:** live owner remains `Wire_State` (exec_bufs, iovecs, file_send, kind). Planned Law S1 owner is `Wire_Conn_State`. Until merge, every Connection carries **two** outbound schedule worlds (~2.4 KiB). That is dual-maint **in memory**, not only in docs.  
4. **Cache / free-list churn:** `connection_destroy` / `conn_alloc` touch the whole record (slot reset + three `*_init`s). Larger records worsen free-list locality for accept storms even when fields are cold.  
5. **H2 multi-slot foreshadow:** plan wants `slots: []Stream_Slot` on the pipe; today H1 embeds one 104-byte slot **plus** a conn-global 1304-byte seal_q that will be shared (good) — but the dual `Wire_State` will still need a migration story so multi-slot does not inherit **two** mem queues.

**Verdict:** Not a process-RSS disaster vs resp_buf. **Is** a Phase 1 **slab craft miss**: pay full `SEAL_Q_CAP` storage for pure tests that could live in `pipe_test` stacks until Phase 2 wires Law S1.

Acceptable temporary **only** if status docs say “POD embedded for layout freeze; not wire physics” **and** a tracked follow-up either (a) drives wire through `wire_conn` or (b) shrinks/caps the embedded queue until then. Currently PHASE0 language overclaims structure landed; memory critic aligns with shortcuts critic on that honesty gap.

---

### 4. UAF risks: `Response._slot` after recycle; session gen

#### Response lifetime

| Fact | Implication |
|------|-------------|
| `Response` lives in `conn.loop.res` (embedded) | Not app-owned heap; handler `^Response` valid only for request/session drive on that conn |
| `response_init` sets `_slot = &c.slot` and `_conn = c` | Dual sugar; addresses stable for H1 embed lifetime of Connection record |
| `clean_request_loop` does `conn.loop.res = {}` | Nils `_slot` / `_conn` before keep-alive reuse |
| `connection_destroy` does `c.loop = {}` | Same before free-list |

**UAF of Response fields after recycle:** low for well-behaved handlers (no stashing `^Response`).  
**UAF of `^Stream_Slot` stashed from `response_slot(r)`:** slot address is **stable** for free-list Connection reuse (embedded field). Fields are reset; **gen may not bump** on unary recycle → stashed slot pointer looks “live” with stale progressive markers zeroed. H2 freelist slots will make this lethal; H1 is “pointer stable, meaning unstable.”

#### Dual `Response._slot` + `_conn` (temporary)

```odin
// response_init
r._slot = &c.slot
r._conn = c

// helpers exist…
response_slot / response_conn  // prefer slot then conn

// but hot path still thrives on r._conn (respond, session, stream, plan_test, …)
```

| Risk | Severity |
|------|----------|
| Divergence if one pointer updated | **Major latent** — two sources of truth |
| Plan §D sole path “Response binds slot; conn via slot.conn” unfinished | **Major plan debt** (also shortcuts critic) |
| Session still `Session{ _conn, id }` not plan’s `_slot` | **Major** for multi-slot; free-list ABA depends on conn pointer + id only |
| Most session/stream code uses `conn.slot.*` via `_conn` | Works for N=1; **blocks** true sole ownership |

`response_conn` prefers `_slot.conn` when set — good. Underuse means dual is not even transitional discipline; it is **parallel sugar**.

#### Session / timer UAF (positive)

| Path | Safety |
|------|--------|
| Timeout CQE user = `^Session_State` after `conn.slot.session = nil` | **Safe** — `closed` branch frees when pending hits 0 |
| Mid-destroy cancel + pending CQEs | **Safe** — deferred free |
| Mailbox holds `^Connection` + gen | Conn free-list reuse: stale if gen/session mismatch; conn pointer may be reused — **gen + session nil checks** required (present for live session; post-destroy session nil) |
| Mid-socket stream slab | Close path `_stream_pool_abandon` before forgetting pointer; destroy nulls slab | **Mostly safe** if close path always runs |

#### Residual UAF / leak edges

1. **`stream_send_slab` on destroy without abandon** (non-`td` teardown path nulls without `stream_pool_put`) — rare; still wrong.  
2. **`_session_destroy` free pad only if `server != nil`** — defensive free should use `st.allocator` / last-known allocator.  
3. **No gen bump on stream death** → future seal_q view UAF class (use-after-logical-free of PT view with matching gen).

---

### 5. Known leak: `test_dynamic_unwritten`

Confirmed under odin test memory tracking:

```text
< 64B/ 64B> < 64B> (0/1) :: http.test_dynamic_unwritten
+++ leak 64B @ … [http.odin:438:test_dynamic_unwritten()]
```

```odin
// first block — make without delete
d  := make([dynamic]int, 4, 8)
du := _dynamic_unwritten(d)
testing.expect(t, len(du) == 4)
// missing: delete(d)
```

Other blocks use `slice.into_dynamic` (no heap).  

**Severity: Minor** (test-only 64B). Still **unacceptable** in a package that enables tracking and claims handmade discipline — it trains “green tests with leaks.”  

**Fix:** `defer delete(d)` (or scoped delete) in the allocating block.

Related production pattern: `_dynamic_unwritten` returns a slice into **unwritten capacity** of a dynamic. Safe only while capacity stable; callers (`_http_write_chunk`, body reserve paths) must not retain the slice across grow. That is intentional and **not** the known leak — but it is a footgun class for future PT ring “view into slab” code. Document once next to Law PT1.

---

### 6. Temporary dual `Response._conn` + `_slot`

| Claim | Reality |
|-------|---------|
| Temporary dual for migration | **Yes structurally** (`response_init` sets both; helpers prefer slot) |
| Grep-clean sole path | **No** — vast majority of call sites use `r._conn` / `res._conn` raw |
| Session migrated to `_slot` | **No** — still `_conn` |
| Loop still owns Response | **Yes** — dual bind cannot fix sole storage |
| Memory cost of dual pointers | 16 bytes on Response (trivial) |
| **Semantic / UAF cost** | Two truths; H2 multi-slot will force Session/Response to slot index or `^Stream_Slot` |

**Verdict:** Dual pointers are **cheap in bytes, expensive in ownership law**. Memory critic grades them as **Major residual dual-write**, not a free temporary.

Acceptable Phase 1 exit only with an explicit kill-list:

1. All internal accessors go through `response_slot` / `response_conn`.  
2. Public Session becomes `{_slot, id}` (or `{pipe, slot_idx, id}`) per plan §D.6.  
3. Drop `_conn` when Loop/Response home is decided (slot vs loop) — do not carry both forever.

---

## Findings by severity

### Fatal

| ID | Finding | Required fix |
|----|---------|--------------|
| **F1** | **`session_pad` orphan + `stream_slot_reset_exchange` zero-without-free** | Free pad in `connection_close` / `connection_destroy` **defensively** (even if `session == nil`). Never clear `session_pad` without `mem.free`. Prefer: `_slot_free_pad(slot)` called from destroy, abort, and reset. |
| **F2** | **Invariant “session already destroyed” is unenforced** | Assert or repair in `connection_destroy`: if `session != nil` or `session_pad != nil` or `stream_send_slab != nil`, drain then reset. Fail loud in debug. |

### Major

| ID | Finding | Required fix |
|----|---------|--------------|
| **M1** | **Dual gen** (`slot.gen` attach-only vs `st.gen += 1` on destroy; no stream-death bump) | Single owner: **`slot.gen` only**. Session.id snapshots attach gen. Destroy/RST: bump `slot.gen` (and seal_q remove) per §E.4. Remove meaningless `st.gen += 1` or make `st.gen` a pure copy of attach id (immutable). |
| **M2** | **`Wire_Conn_State` 1304 B embedded while inert** + dual `Wire_State` | Document as intentional layout freeze **or** defer full `seal_q[32]` until Phase 2 (e.g. smaller cap / pointer to schedule bag / test-only stacks). Track dual-bag retirement when Law S1 takes the wire. |
| **M3** | **Response dual `_conn`+`_slot`; Session still `_conn`** | Accessor discipline + plan §D.6 Session shape before multi-slot. Hot path must not raw-touch `_conn` forever. |
| **M4** | **Gen not bumped on exchange / stream end** | Before any live `Seal_Unit` enqueue: death paths must bump + `seal_q_remove_gen`. Phase 1 can stub the call sites now (no-op queue) so Phase 2 does not invent free-order under fire. |

### Minor

| ID | Finding | Required fix |
|----|---------|--------------|
| **m1** | `test_dynamic_unwritten` 64B leak | `delete(d)` / `defer delete` in first block. |
| **m2** | `stream_pin_gen` / `stream_pin_byte` dead | Remove until PIN re-enabled with cancel, or wire gen into CQE identity. |
| **m3** | Pad free gated on `conn.server != nil` | Free via stored allocator / `st.allocator` / server-less path. |
| **m4** | Non-`td` destroy nulls `stream_send_slab` without pool put | Always abandon before nil. |
| **m5** | Stale comment `Connection.session` in session.odin | Fix comment; session is on slot. |

---

## What still earns credit (not enough for WOW)

1. **Gen preserve across free-list** is the right ABA primitive and is implemented carefully in `stream_slot_reset_exchange`.  
2. **Session_State timer afterlife** is real free-order thinking (CQE may outlive slot.session pointer).  
3. **Stream slab pool** with admit cap + abandon on close is the correct pattern for multi-CQE progressive send.  
4. **Pad free after `on_close`** ordering (hooks first, then host pad) matches public contract.  
5. **Pipe POD purity** (no SSL*, no hidden CT heap yet) keeps Phase 1 from inventing secret multi‑MiB TLS buffers — good non-event.  
6. **Public Session.id is generation, not stream id** — correct product memory of identity.

None of the above forgives orphan pad or dual schedule storage without a consumer.

---

## Scorecard (memory axes)

| # | Axis | Score | WOW? |
|---|------|------:|:----:|
| 1 | Pad ownership / free-on-destroy | 5.5 | No |
| 2 | Gen / ABA / free-list | 6.5 | No |
| 3 | `reset_exchange` completeness | 6.0 | No |
| 4 | Connection slab / dual bags | 6.0 | No |
| 5 | Response/Session dual pointers / UAF | 7.0 | No |
| 6 | Pool / timer / stream slab discipline | 8.0 | Soft |
| 7 | Test / bookkeeping hygiene | 7.5 | No |
| **Overall** | **Memory (Phase 0–1 + POD)** | **6.4** | **No** |

### WOWED: **No** (bar ≥ 9)

---

## Fixes required (ordered)

1. **F1/F2 — Pad cannot orphan (ship blocker for memory bar)**  
   - `_stream_slot_free_pad(slot, allocator)`  
   - Call from `_session_destroy`, `connection_close` (always), and before `stream_slot_reset_exchange` in destroy.  
   - Assert `session_pad == nil` after exchange reset in debug.

2. **M1/M4 — One gen story**  
   - Document: `slot.gen` is sole ABA epoch.  
   - Attach: bump; copy into `Session.id` / `Seal_Unit.slot_gen`.  
   - Destroy/RST/exchange end (when seal lives): bump + `seal_q_remove_gen`.  
   - Delete `st.gen += 1` dual or freeze `st.gen` as attach snapshot only.

3. **M2 — Slab honesty**  
   - Either wire `wire_conn` on the hot path in Phase 2 immediately after POD, **or** shrink embedded queue until then and keep pure tests on stack/`pipe_test` bags.  
   - Status docs: dual `Wire_State` + `Wire_Conn_State` is temporary; size table in freeze notes.

4. **M3 — Dual pointer kill-list**  
   - Internal: only `response_conn` / `response_slot`.  
   - Session → `_slot` (+ id).  
   - Calendar when `_conn` sugar dies (do not wait for H2 panic).

5. **m1 — Fix `test_dynamic_unwritten` leak** (one-liner; do it).

6. **Regression tests (memory)**  
   - `sse_alloc` without `sse_start` + destroy → no leak (tracking).  
   - Free-list reuse: old `Session{id:old}` status false after new attach.  
   - Destroy with in-flight timer CQE → no UAF (existing path; keep a test).  
   - Optional: `size_of(Connection)` budget assert with comment on dual-bag allowance.

---

## Relation to other critics

| Critic | Overlap |
|--------|---------|
| `impl-critic-shortcuts-r1.md` | Sole exchange incomplete; pipe POD not hot path; dual Response bind — **memory critic measures the byte and free-order cost of those shortcuts** |
| Plan A §D.3 / §E.4 / §D.6 | Allocator lifetime table and close SM are **normative**; implementer free-order is still partial |
| Perf critics (R2–R4) | Firehose / PT ring not live yet; this r1 does **not** re-score peak PT — only **struct tax and heap ownership** |

---

## Bottom line

Phase 0–1 + pipe POD **does not WOW on memory**. The gen free-list preserve and timer-deferred session free show the team can write free-order code; the **pad orphan**, **reset-without-free**, **dual gen**, and **1.3 KiB inert seal_q on every Connection** show free-order and slab craft are not yet law.

**Ship memory bar:** F1+F2 fixed, m1 fixed, M1 design note committed.  
**WOW memory bar (≥9):** also M2 honesty or shrink, M3 dual-pointer kill started, M4 death-path gen stubs for seal_q.
)
