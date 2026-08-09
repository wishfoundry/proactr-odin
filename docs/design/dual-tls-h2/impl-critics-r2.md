# Implementation Critics R2 — multi-axis (post R1 fixes)

**Bar:** WOW ≥ 9 for **claimed phase scope only**: Phase 0–1 structure + PR1–PR4 foundation.  
**Not scored as product:** full TLS, H2 multiplex, M1–M6, seal∥send hot path, peer RPS floors.  
**Date:** 2026-08-08  
**Subject:** live `http/` + `docs/IMPLEMENTATION_STATUS.md` + E0 scripts after R1 fix loop.

### Verify commands (this pass)

| Command | Result |
|---------|--------|
| `odin test http -o:none` | **98/98 pass** (threads=1 and default) |
| `scripts/check_e0_bans.sh` | **OK** (E0.5–E0.7 + README honesty) |
| `scripts/check_app_contract_sample.sh` | **OK** (E0.4 sample = `examples/empty_ok`) |

### Measured layout (odin `size_of`, host ptr 8)

| Type | Bytes | vs R1 critic |
|------|------:|--------------|
| `Connection` | **3880** | was **5160** (−1280) |
| `Wire_State` | 1152 | live clear-H1 schedule (unchanged role) |
| `Wire_Conn_State` | **24** | was **1304** (seal_q no longer embedded) |
| `Seal_Queue` | 1288 | POD only; stack/tests; `wire_conn.q` nil on clear-H1 |
| `Stream_Slot` | **2024** | owns `res: Response` (1920) + session/stream markers |
| `Response` | 1920 | home = `Stream_Slot.res` (not `Loop`) |
| `Tls_Pipe` / `Conn_Pt_Ring` / `Plan_Context` | 16 / 8 / 16 | skeleton / admission / diet unchanged |

### R1 → fixed (spot-checked)

| Claim | Evidence | Verdict |
|-------|----------|---------|
| `session_pad` free-before-zero | `stream_slot_free_pad` then zero in `stream_slot_reset_exchange` | **Fixed** |
| destroy / close / clean free orphans | `_session_destroy`, `connection_close` else-branch, `clean_request_loop` if `session==nil` | **Fixed** |
| `slot.gen` sole ABA; destroy bumps; `seal_q_remove_gen` when `q` set | `_session_destroy` + `test_session_destroy_bumps_slot_gen` | **Fixed** |
| `test_dynamic_unwritten` leak | `defer delete(d)` on first arm | **Fixed** (suite clean under mem track) |
| `Wire_Conn_State` slim; `Seal_Queue` deferred | 24 B; `q` nil; `test_wire_conn_state_size_budget` | **Fixed** |
| Response on `Stream_Slot.res`; `Loop` is `req` only | `Loop { conn, req }`; zero `loop.res` greps | **Fixed** |
| `IMPLEMENTATION_STATUS.md` + E0 scripts | status honest; scripts green | **Landed** |

---

## Scoreboard

| Axis | Score | WOWED |
|------|------:|:-----:|
| Code quality | **8.8** | **no** |
| Performance | **9.3** | **yes** |
| Memory | **9.1** | **yes** |
| Shortcuts honesty | **8.6** | **no** |
| **Mean** | **9.0** | — |

Two axes clear the WOW bar; two do not. Mean sits at the edge of 9 because the structural fatals from R1 are gone — residual Majors are real but narrower.

---

## Code quality — Score **8.8** / WOWED **no** / residuals

### What earned the jump (R1 was 7.1)

1. **PR2 sole exchange location is real.** `Stream_Slot` owns `res: Response`; `Loop` is request-cycle only (`conn` + `req`). Hot path uses `&conn.slot.res` / `l.conn.slot.res`. `loop.res` is greppably dead. That was R1 **M1** (Fatal under overclaim); it is closed for phase structure.
2. **Pad / gen free-order laws are coded, not sketched.** Single free helper; destroy bumps `slot.gen` and optionally drains seal units by attach gen; tests cover orphan pad + gen bump + remove_gen.
3. **PR4 bag is no longer a fake 1.3 KiB schedule.** Thin `Wire_Conn_State` + separate `Seal_Queue` matches “types + pure laws, clear-H1 not on pipe physics.”
4. **E0 enforcement is code**, not review hope (`check_e0_bans`, `check_app_contract_sample`).
5. **Planner diet + E0.8 tables** remain strong pure laws (unchanged credit).

### Remaining Majors (real)

| ID | Issue | Why still Major under phase claim |
|----|--------|-----------------------------------|
| **CQ-M1** | **Dual exchange *meaning*** — `Response._streaming` / `_stream_ended` / `_session_attached` vs `Stream_Slot.stream_*` / `session` | Location dual-write is dead; **semantic** dual-write is not. Keep-alive and session paths still maintain two flag families by hand. H2 multi-slot will desync first here. |
| **CQ-M2** | **Dual wire bags with Law S1 unimplemented** | Live submit is still only `Wire_State`. `wire_conn` / `pt` / `tls_pipe` init-only on clear-H1. Honest for phase — but quality freeze is incomplete until one “can I send / can I close?” truth or an explicit `// Law S1: Wire_State is temporary sole submit until Phase 2` single helper that later flips. |
| **CQ-M3** | **Package host zoo still public** | `Stream_Slot`, `Seal_Unit`, `seal_q_*`, `plan_body`, progressive `begin_stream` / `stream_write` / `stream_end` importable. APP_CONTRACT NEVER (progressive second long-lived rail) still conflicts with public `Response_Stream` product. Examples clean; package boundary is not. |

### Not WOWED (why < 9)

Structure progress is elite for PR2 location + PR4 size honesty. WOW for *code quality* still needs either (a) one flag family for stream/session attach state, or (b) package-private host vocabulary so freeze cannot be bypassed by `import http` spelunking. Neither is theater — both are unfinished duals.

### Minors (do not block WOW alone)

- `response_slot` / `response_conn` still **uncalled**; hot path still reads `r._conn` directly.
- `plan_policy_for` still hardcodes `ciphered = false` (phase-correct; wiring seam is comment-only).
- `clean_request_loop` nils `stream_send_slab` without `_stream_pool_abandon` (relies on prior paths) — see Memory residual.

---

## Performance — Score **9.3** / WOWED **yes** / residuals

### Why WOW for phase scope

R1 withheld WOW primarily because every free-list Connection paid **~1304 B** of idle `seal_q[32]` (~12.7 MiB @ 10k conns). That tax is **gone**:

| Concurrent clear-H1 conns | R1 idle `Wire_Conn_State` | R2 idle `Wire_Conn_State` |
|--------------------------:|--------------------------:|--------------------------:|
| 10 000 | ~12.7 MiB | **~240 KiB** |
| 64 000 | ~79 MiB | **~1.5 MiB** |

`Connection` **5160 → 3880** (−~25%). Clear-H1 still drives `Wire_State` only; pipe bags are init noise, not CQE tax.

Other R1 performance credits still hold:

- Default respond skips `plan_body` / `plan_policy` unless optimize / prefer flags.
- No accidental always-materialize from `ciphered` / `max_write_unit` defaults.
- `Stream_Slot` embedded N=1; Response move is layout, not pointer-chase on CQE path.
- `Conn_Pt_Ring` remains 8 B admission — no second PT window.
- No TLS bulk RPS claim in product surface.

### Residuals (not Majors for this phase)

- Dual `Wire_State` + thin `wire_conn` is intentional debt until Law S1 migration — **not** a clear-H1 RPS regression.
- `Response` still ~1920 B per conn (always was, via `Loop`); slot ownership did not invent that cost.
- Progressive stream path and session PIN still host complexity; out of empty-ok critical path.

### WOWED: **yes**

Phase bar: structure must not regress clear-H1 and must not tax every conn for deferred seal storage. **Met.**

---

## Memory — Score **9.1** / WOWED **yes** / residuals

### Why WOW for phase scope

R1 memory bar failed on **orphan pad**, **zero-without-free**, **dual gen**, **1.3 KiB seal embed**, and **test leak**. Each is closed:

| R1 failure | R2 state |
|------------|----------|
| Orphan `sse_alloc` pad | Freed on close (no session), destroy/reset, clean_request_loop; tests under mem track |
| `reset_exchange` zero-without-free | `stream_slot_free_pad` first |
| Dual gen (`st.gen += 1` vs `slot.gen`) | `slot.gen` sole owner; `st.gen` attach snapshot; destroy bumps slot |
| Premature seal_q on every conn | Deferred; `q == nil` clear-H1 |
| `test_dynamic_unwritten` 64 B leak | `defer delete`; suite green with tracking |

Session happy path free-order (hooks → free pad → nil session → deferred `Session_State` free on timer drain) remains competent. Destroy defensively drains live session before slot reset.

### Remaining Majors (real, narrower)

| ID | Issue | Severity note |
|----|--------|----------------|
| **MEM-M1** | **`stream_send_slab` zero-without-return** in `stream_slot_reset_exchange` / `clean_request_loop` | Same *class* as the old pad bug, lower *likelihood*: `connection_close` calls `_stream_pool_abandon` first. Fail-closed would abandon inside reset always. Not an active suite leak; still a free-order hole for any bypass destroy. |

### Not listed as Major (phase-honest)

- Gen not bumped on unary keep-alive recycle: correct while no live `Seal_Unit` on clear-H1; attach/destroy own gen. Stub bump-on-exchange-end when Phase 2 enqueues seals.
- `Response._conn` + `_slot` dual pointers: UAF risk is H2 freelist-shaped; H1 slot address is stable in free-list Connection. Residual dual surface, scored under CQ-M1/pointer hygiene more than active leak.

### WOWED: **yes**

Pad/gen/leak fatals fixed; Connection slab tax fixed; remaining MEM-M1 is real but not the R1 “cannot ship structure” bar.

---

## Shortcuts honesty — Score **8.6** / WOWED **no** / residuals

### What improved hard

| Artifact | R1 | R2 |
|----------|----|----|
| `docs/IMPLEMENTATION_STATUS.md` | Missing | **Present, accurate**: PR2 Done (N=1), PR4 thin `q` nil, PR5+ not started, non-claims explicit |
| E0.5–E0.7 | Paper | **Scripts hard-fail**; this pass green |
| E0.4 | Missing | **Sample + script**; Partial multi-protocol / CI workflow correctly labeled |
| Response home docs | “still Loop” truth | Status doc matches code |

`IMPLEMENTATION_STATUS.md` is the honesty spine the R1 critic demanded. README / matrix still avoid “supports HTTP/2.” Non-claims paragraph is sharp.

### Remaining Majors (real)

| ID | Issue | Evidence |
|----|--------|----------|
| **H-M1** | **`docs/PHASE0_E0.md` is stale and contradicts the tree** | Still says PR2 **Partial** — “Request/Response still on `Loop` until PR2 complete” and “Do not read this as Stream_Slot is sole storage… Response still Loop.” **Code and `IMPLEMENTATION_STATUS` say otherwise.** Two status docs with opposite PR2 truth is exactly the overclaim/undercount failure mode R1 called out. |
| **H-M2** | **E0.4 CI workflow still not in-repo** | Scripts exist and pass locally; no workflow job wires them. Status correctly says “CI job optional until workflow wired.” Freeze table language still sells Phase 0 as merge blocker — partial enforcement is honest in status, incomplete as freeze. |

### Not Majors

- PR4 “not on clear-H1 hot path” / dual `Wire_State` — correctly labeled in status and comments.
- E0.4 multi-protocol later — correctly out of scope.

### WOWED: **no**

Honesty is *mostly* excellent, then **PHASE0_E0.md lies about PR2**. One wrong freeze table undoes a clean status doc for reviewers who only open Phase 0. Fix H-M1 or do not claim freeze-doc WOW.

---

## Mean and next-loop fixes

**Mean score: 9.0**  
**WOW on all axes: no** (CQ 8.8, Honesty 8.6 below bar; Perf 9.3 and Memory 9.1 clear it).

### Exact fixes if any axis < 9 (next loop)

#### Code quality → 9+

1. **Collapse dual stream/session flags (CQ-M1):** pick one owner — e.g. slot markers authoritative; Response keeps only request-scoped planner/body flags; `_session_attached` derived from `slot.session != nil` or single write site. Add a small invariant test: after clean/destroy, both families agree.
2. **Single “in flight / may close” helper (CQ-M2):** wrap `_conn_wire_in_flight` to document Law S1 temporary ownership of `Wire_State`; when Phase 2 lands, extend the same proc — do not fork a second check against `wire_conn.sock_send_inflight` ad hoc.
3. **Host vocabulary privacy (CQ-M3):** `@(private)` (or package-split) for `seal_q_*`, pipe POD helpers not needed by apps; progressive `Response_Stream` API marked host/legacy in godoc and/or gated so APP_CONTRACT NEVER is not a public second product. Route new code through `response_conn` / `response_slot` and drop raw `_conn` sprawl.

#### Shortcuts honesty → 9+

1. **Rewrite `PHASE0_E0.md` PR2 row to match code + `IMPLEMENTATION_STATUS.md` (H-M1):** PR2 **Done (N=1)** — Response + session + progressive markers on `Stream_Slot`; `Loop` is `req` only; clear-H1 wire still `Connection.wire`. Delete the “Response still Loop” warning or replace with accurate residual list (dual *meaning* flags, dual wire bags).
2. **Wire scripts into CI when a workflow exists (H-M2):**  
   `./scripts/check_app_contract_sample.sh && ./scripts/check_e0_bans.sh`  
   Status may keep E0.4 Partial for multi-protocol; same-handler sample check should not be optional once any CI is present.

#### Memory residual (optional polish; axis already ≥ 9)

1. **MEM-M1:** call `_stream_pool_abandon` (or equivalent) inside `stream_slot_reset_exchange` / always in `clean_request_loop` before nil — same fail-closed pattern as pad free.

#### Performance

No required fix for WOW. Do not re-embed `Seal_Queue` on clear-H1.

---

## Phase-scope bottom line

R1 was right to withhold WOW: Response-in-Loop, orphan pad, dual gen, and a 1.3 KiB dead seal bag on every conn were structure-grade failures.

This loop **actually fixed those**. Performance and memory now clear a hard phase bar. Code quality is a high-8 on residual dual *meaning* and public host surface — not on missing PR2. Honesty is a high-8 solely because **`PHASE0_E0.md` still narrates a world the code left**. Align that file and tighten flag ownership / package privacy; then a clean four-axis WOW is available without inventing TLS product work.
)
