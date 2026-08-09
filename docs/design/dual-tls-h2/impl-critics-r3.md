# Implementation Critics R3 — multi-axis (post R2 fixes)

**Bar:** WOW ≥ 9 for **claimed phase scope only**: Phase 0–1 structure + PR1–PR4 foundation.  
**Not scored as product:** full TLS, H2 multiplex, M1–M6, seal∥send hot path, peer RPS floors.  
**Date:** 2026-08-08  
**Subject:** live `http/` + `docs/PHASE0_E0.md` + `docs/IMPLEMENTATION_STATUS.md` + E0 scripts after R2 fix loop.

### Verify commands (this pass)

| Command | Result |
|---------|--------|
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **98/98 pass** |
| `odin test http/middleware -define:ODIN_TEST_THREADS=1 -o:none` | **33/33 pass** |
| `scripts/check_e0_bans.sh` | **OK** (E0.5–E0.7 + README honesty) |
| `scripts/check_app_contract_sample.sh` | **OK** (E0.4 sample = `examples/empty_ok`) |

### R2 → fixed (spot-checked)

| R2 ID | Claim | Evidence | Verdict |
|-------|--------|----------|---------|
| **H-M1** | `PHASE0_E0.md` contradicted tree on PR2 | PR2 **Done** — Response + session + progressive on `conn.slot`; `Loop` is `req` only; clear-H1 wire still `Connection.wire`. E0.4 **Done (clear H1)**. No “Response still Loop.” | **Fixed** |
| Status alignment | Two status docs, opposite PR2 truth | `PHASE0_E0.md` ↔ `IMPLEMENTATION_STATUS.md` same Done rows + non-claims | **Fixed** |
| **MEM-M1** | `stream_send_slab` zero-without-return in reset | `stream_slot_reset_exchange`: `stream_pool_put` then nil, then free pad, then zero (fail-closed) | **Fixed** |
| **CQ-M1 framing** | Dual exchange *meaning* unread as dual storage | `Response` comments: `_streaming` / `_session_attached` are **response-path facade** (oneshot body API guards); `slot.stream_*` / `slot.session` are **exchange/wire truth** — not dual copies of the same bits | **Documented / reclassified** |

R2 holds still green: pad free-before-zero, `slot.gen` sole ABA, thin `Wire_Conn_State` (`q` nil), Response on `Stream_Slot.res`, Connection ~3880 B idle tax removed, E0 scripts.

---

## Scoreboard

| Axis | Score | WOWED |
|------|------:|:-----:|
| Code quality | **9.1** | **yes** |
| Performance | **9.3** | **yes** |
| Memory | **9.3** | **yes** |
| Shortcuts honesty | **9.2** | **yes** |
| **Mean** | **9.2** | — |

**All four axes clear the WOW bar.** Residuals below are Phase 2+ work or true minors — not structure-grade withhold reasons.

---

## Code quality — Score **9.1** / WOWED **yes** / residuals

### Why WOW for phase scope

R2 withheld at 8.8 on residual dual *meaning* and public host surface after PR2 location was already real. R3 closes the *misread*:

1. **PR2 sole exchange location remains real** (unchanged credit): `Stream_Slot` owns `res`; `Loop` is `req` only; hot path `&conn.slot.res`.
2. **Facade vs wire is intentional layering, not unfinished dual storage.**  
   - Wire/exchange: `slot.stream_open` / `stream_ending` / `session` / pool slab.  
   - Response path: `_streaming` / `_stream_ended` / `_session_attached` close oneshot `body_*` / `respond` once progressive or session takes the response.  
   Comments state explicitly: do not treat these as copies of the same bits; do not read `slot.stream_open` for body asserts. That is a freeze-grade host design, not a half-migration.
3. **PR4 bag honesty** still holds: thin `Wire_Conn_State`, deferred `Seal_Queue`, pure tests.
4. **Fail-closed free-order** in `stream_slot_reset_exchange` matches pad law (slab return + pad free before zero).
5. **E0 enforcement is code** (`check_e0_bans`, `check_app_contract_sample`).

### Residuals (Phase 2+ or true minors — do not block WOW)

| ID | Issue | Class |
|----|--------|--------|
| **CQ-R1** | Dual wire bags; live submit still only `Wire_State` | **Phase 2** Law S1 migration (documented; clear-H1 correct) |
| **CQ-R2** | Host vocabulary still package-public (`seal_q_*`, progressive stream API) | **Minor** for foundation; examples banned; package-private / split is later freeze polish |
| **CQ-R3** | `response_slot` / `response_conn` still underused vs raw `_conn` | **Minor** hot-path hygiene |
| **CQ-R4** | H2 multi-slot must keep facade/wire write sites from desyncing | **Phase 2+** invariant tests when N>1 lands |

### WOWED: **yes**

Phase claim is structure + pure laws + honest dual-world exit for **exchange location**. Semantic duals that remain are either layered facades (documented) or Phase 2 schedule ownership. Not a soft-fail.

---

## Performance — Score **9.3** / WOWED **yes** / residuals

### Why WOW (held from R2)

No regression from R3 free-order work (put before zero is cold path). R2 performance thesis still stands:

| Concurrent clear-H1 conns | Idle `Wire_Conn_State` tax |
|--------------------------:|--------------------------:|
| 10 000 | **~240 KiB** (was ~12.7 MiB with embedded seal_q) |
| 64 000 | **~1.5 MiB** |

- `Connection` ~**3880** B; no re-embed of `Seal_Queue` on free-list.
- Default respond skips `plan_body` / `plan_policy` unless optimize / prefer flags.
- `Stream_Slot` N=1 embed; no pointer-chase tax on empty-ok CQE path.
- No TLS bulk RPS product claim.

### Residuals (not Majors for this phase)

- Dual `Wire_State` + thin `wire_conn` intentional until Law S1.
- `Response` ~1920 B per conn was always paid (was on `Loop`; now on slot).

### WOWED: **yes**

---

## Memory — Score **9.3** / WOWED **yes** / residuals

### Why WOW (bump from R2 9.1)

R2 WOWED memory with residual **MEM-M1** (slab zero-without-return in reset — same *class* as the old pad bug, lower likelihood). R3 closes that class:

```odin
// stream_slot_reset_exchange — fail-closed before zero
if slot.stream_send_slab != nil {
    stream_pool_put(slot.stream_send_slab)
    slot.stream_send_slab = nil
    slot.stream_send_len = 0
}
stream_slot_free_pad(slot)
// preserve gen; zero; rewire conn
```

| R1/R2 failure | R3 state |
|---------------|----------|
| Orphan `session_pad` | Free on close/destroy/clean; tests under mem track |
| `reset_exchange` pad zero-without-free | `stream_slot_free_pad` first |
| **`reset_exchange` slab zero-without-return** | **`stream_pool_put` first** |
| Dual gen | `slot.gen` sole owner |
| Premature seal_q on every conn | Deferred; `q == nil` clear-H1 |
| Test leaks | Suite green with tracking (98 + 33) |

### Residuals (true minors)

| ID | Issue | Note |
|----|--------|------|
| **MEM-R1** | `clean_request_loop` still nils `stream_send_slab` without put | Happy path already abandoned on wire CQE; destroy/reset fail-closed. Prefer defensive put for symmetry — not an active suite leak. |
| **MEM-R2** | Gen not bumped on unary keep-alive | Correct while no live `Seal_Unit` on clear-H1; Phase 2 when seals enqueue. |

### WOWED: **yes**

Free-order fatals for pad **and** stream slab are closed on the reset path that free-list destroy uses.

---

## Shortcuts honesty — Score **9.2** / WOWED **yes** / residuals

### Why WOW (was 8.6 — only H-M1 blocked)

R2 honesty was excellent **except** `PHASE0_E0.md` still sold PR2 as Partial / Response-on-Loop. That single freeze-table lie was the withhold. R3 rewrites it:

| Gate / PR | PHASE0_E0 | IMPLEMENTATION_STATUS | Code |
|-----------|-----------|------------------------|------|
| E0.1–E0.3, E0.5–E0.8 | Done | Done | Artifacts + scripts + tests |
| E0.4 | **Done (clear H1)**; multi-protocol later | Same | `examples/empty_ok` + script |
| PR1 | Done | Done | Four-field `Plan_Context` |
| PR2 | **Done** — Response on slot; Loop = req; wire = `Connection.wire` | **Done (N=1)** same words | `Stream_Slot.res` |
| PR4 | Done — thin bag; Seal_Queue deferred | Same | `size_of(Wire_Conn_State) < 64` |
| PR5+ | Not started | Not started | No TLS/H2 product |

Non-claims line intact: not TLS product, not HTTP/2, not M1–M6. README still avoids unphased H2 marketing. Scripts green this pass.

### Residuals (true minors — do not block WOW)

| ID | Issue | Note |
|----|--------|------|
| **H-R1** | E0 scripts not necessarily wired into a repo CI workflow file | Status **honest**: “host/repo choice — run scripts in CI when ready.” Freeze has runnable gates; workflow file is ops, not doc lie. |
| **H-R2** | Multi-protocol same-handler CI | Correctly deferred with TLS/H2 phases. |

### WOWED: **yes**

Status docs no longer contradict each other or the tree. That was the R2 honesty bar.

---

## Mean and phase bottom line

**Mean score: 9.2**  
**WOW on all axes: yes**

| Loop | Quality | Perf | Memory | Honesty | Mean | All WOW? |
|------|--------:|-----:|-------:|--------:|-----:|:--------:|
| R1 | 7.1 | (fail tax) | (pad/gen/leak) | ~5.8 | mid | no |
| R2 | 8.8 | **9.3** | **9.1** | 8.6 | 9.0 | no |
| **R3** | **9.1** | **9.3** | **9.3** | **9.2** | **9.2** | **yes** |

### Exact blockers if any axis were still < 9

**None.** (R3 grants WOW on quality and honesty: residuals are Phase 2 Law S1 / multi-slot, package-privacy polish, optional CI workflow wiring, and defensive put symmetry in `clean_request_loop`.)

### Optional polish (not required for this bar)

1. Defensive `stream_pool_put` (or `_stream_pool_abandon`) inside `clean_request_loop` before nil — matches reset fail-closed.
2. Package-private host seals / progressive second rail godoc when API freeze deepens.
3. Wire `./scripts/check_app_contract_sample.sh && ./scripts/check_e0_bans.sh` into whatever CI workflow exists.
4. Phase 2: single Law S1 submit owner; facade/wire invariant tests at N>1.

### Phase-scope bottom line

R1 correctly failed structure (Response-in-Loop, orphan pad, dual gen, 1.3 KiB dead seal bag).  
R2 fixed those and WOWED perf/memory; withheld quality/honesty on dual-meaning framing and a stale `PHASE0_E0.md`.  
R3 aligns freeze docs with code, fail-closes stream-slab return on slot reset, and documents Response flags as request-path facade vs slot wire truth.  

**Phase 0–1 + PR1–PR4 foundation clears a four-axis WOW ≥ 9 bar.** Do not re-score as TLS/H2 product until PR5+ lands.
)
