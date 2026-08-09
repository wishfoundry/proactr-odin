# Impl Critic R1 — PERFORMANCE (Plan A Phase 0–1 + pipe POD)

**Bar:** WOW ≥ 9 for **phase scope** — structure must not regress clear-H1 request/wire path; no fake TLS bulk claims; memory and control-plane taxes must be honest.  
**Scope:** Implemented code under `http/` after Phase 0 (E0 + plan tables) + Phase 1 (Stream_Slot sole exchange, pipe POD embed).  
**Out of scope for score:** Plan-document architecture scores (`critic-performance-r4.md` 9.50); TLS bulk / H2 multiplex (Phase 2+); peer RPS floors.  
**Inputs:** `http/plan.odin`, `http/response.odin`, `http/pipe.odin`, `http/slot.odin`, `http/server.odin` (`Connection`), `http/conn_slab.odin`, `http/wire.odin`, `docs/PHASE0_E0.md`, plan-a summary spine.  
**Method:** Read the hot paths that clear-H1 actually runs; measure POD sizes; reject theater that claims “pipe ready” without wire ownership.

---

## Score

| Axis | Score | Verdict |
|------|------:|---------|
| **Composite (phase scope)** | **8.15** | **Not WOWED.** Clear-H1 RPS path is largely clean; Connection pays ~1.3 KiB dead schedule bag before any cipher path exists. |
| Plan_Context diet / Plan_Policy hot-path | **9.1** | Public four fields real; default respond skips `plan_body`/`plan_policy`. |
| Conn_Pt_Ring / Wire_Conn_State Connection cost | **5.8** | `Wire_Conn_State` = **1304 B/conn**, unused on clear-H1; pure slab dead weight. |
| Stream_Slot indirection vs old fields | **8.9** | Embedded N=1; hot paths use `conn.slot.*` — no meaningful chase tax. |
| Materialize / ciphered / max_write_unit honesty | **9.0** | Defaults do **not** force accidental always-materialize. |
| TLS bulk claim honesty | **9.4** | Skeleton only; no bulk RPS story. Correct. |

**Not WOWED (8.15).** Phase structure is competent and mostly non-regressive on the request path. It fails elite “pay only for what the phase runs” on Connection layout. Architecture WOW (plan R4) is not implementation WOW.

---

## Measured facts (not vibes)

`size_of` on the same field layouts as `http/pipe.odin` / `http/slot.odin` / `http/wire.odin` (host pointer size 8):

| Type | Bytes | Role on clear-H1 today |
|------|------:|------------------------|
| `Plan_Context` | 16 | Advanced handler read only |
| `Plan_Policy` | 28 | Optimize-wire plan input |
| `Conn_Pt_Ring` | **8** | Admission counters only (no slab yet) |
| `Tls_Pipe` | **16** | Zero engine; init on alloc/reset |
| `Stream_Slot` | **104** | Live: session + progressive stream |
| `Wire_State` | **384** | **Sole live outbound executor** |
| `Seal_Unit` | 40 | Unused on wire |
| `Wire_Conn_State` | **1304** | **`seal_q[32]` ≈ 1280 B** — not driving send |
| Plan A bags on `Connection` (`pt`+`wire_conn`+`tls_pipe`+`slot`) | **1432** | ~91% is idle `seal_q` |

Scale of dead schedule bag alone:

| Concurrent clear-H1 conns | Approx. bytes in unused `Wire_Conn_State` |
|--------------------------:|------------------------------------------:|
| 10 000 | ~12.7 MiB |
| 64 000 | ~79 MiB |

Comments in code already admit the truth:

```text
// Plan A pipe bags (POD; not yet driving clear-H1 wire path — Phase 2+)
pt:        Conn_Pt_Ring,
wire_conn: Wire_Conn_State,
tls_pipe:  Tls_Pipe,
```

Dual outbound bags coexist: **`Wire_State` (live)** and **`Wire_Conn_State` (Law S1 skeleton, idle)**. That is structural debt, not dual *execution* — but Connection size still pays both.

---

## WOWED (what this phase actually got right)

### 1. Plan_Context diet is real — and the hot path mostly ignores Plan_Policy

Public surface is four fields only (`sendfile_ok`, `preferred_copy_budget`, `max_write_unit`, `zero_copy_send`). Host meters (`max_iovecs`, `fixed_files`, `ciphered`, ring free, SQE budget) live on `Plan_Host` / `Plan_Policy`, not on `plan_context*`.

Critical for performance: **default wire does not call `plan_body` or `plan_policy`.**

- `Default_Server_Opts.plan_optimize = false`
- `response_send_got_body` enters `plan_body(cmds, plan_policy(r))` **only** when `_response_wire_use_optimize(r)` (server opt-in or per-request `prefer_gather` / `prefer_sendfile`)
- Materialize path uses `plan_body_materialize_only` — fixed single `Write_Slice`, no policy walk, no ciphered branch

So the Plan_Context “diet” is not a tax: the empty-ok / default oneshot path does not recompute host meters, does not project public↔policy, and does not run the multi-branch optimize planner. That is the correct Phase 0–1 shape.

`plan_policy_for` when optimize *is* on is O(1) field reads + optional `proactr.ring_has_fixed_files` (thread-local ring bit). Not free, but **once per respond**, not per byte — acceptable.

### 2. No accidental materialize-always from ciphered / max_write_unit

Live fill hard-codes honesty for this phase:

```text
// No cipher path yet; zero-copy send unknown; max_write_unit stays 0 (ignore).
p.ciphered = false
p.zero_copy_send = false
p.max_write_unit = 0
```

Planner law (when optimize runs):

| Flag | Live default | Force materialize? |
|------|--------------|--------------------|
| `ciphered` | `false` | **No** |
| `max_write_unit` | `0` (ignore) | **No** |
| `preferred_copy_budget` | 4096 | Only under **optimize** for small mem bodies — intentional policy, pre-existing planner law |

Default path is materialize-only by **opt-in design** (`plan_optimize` false), not because `ciphered` or `max_write_unit` poisoned the policy. E0.8 / `plan_test` lock: `ciphered` kills Sendfile; `max_write_unit > 0` forces mem materialize; unit **does not** block clear Sendfile. That is correct v0 semantics, not a silent regression.

Bastion-driven wire rule (single mem segment → materialize even under Writev plan) is a **stability fix**, not a ciphered false positive. Document it as such; do not rebrand it as “TLS ready materialize.”

### 3. Stream_Slot indirection cost is noise

`Stream_Slot` is **embedded** on `Connection` (N=1), not a pointer-chased heap object. Live exchange fields (session, stream markers, pin recv, stream slab) moved into the bag; hot code mostly does `conn.slot.session` / `conn.slot.stream_*` — one struct offset, same class as former top-level fields.

`Response._slot` + `response_slot()` fallback exists for future multi-slot; on H1 it is set to `&c.slot` at `response_init`. Extra pointer is setup cost, not CQE-path tax. Session/PIN/stream completion paths do not walk `Response` → slot → conn for the common case; they hold `^Connection`.

**Vs old flat fields:** memory is comparable (~104 B live state that had to live somewhere). Ownership clarity improved without a second copy of session state (dual-write exit is the performance-relevant win: one gen, one session pointer).

### 4. Conn_Pt_Ring is not a fake second window

`Conn_Pt_Ring` is **8 bytes**: `admitted` + `high_water`. No second growable PT buffer on Connection. Law PT1 “must-alias / no dual full PT” is **not** violated by this POD. That is the right skeleton: admission first, slab free-list later. Do not ding this bag as bulk bloat — it is not.

### 5. Honesty: no TLS bulk performance story

- `Tls_Pipe` has no SSL*, no CT slabs, no mem-BIO
- Capability matrix / phase docs keep TLS H1 at Phase 2; product H2 later
- Comments: “not yet driving clear-H1”; “No cipher path yet”
- No CI number claims “TLS bulk ≤ 4× HW” for this phase (correct — that CI is Phase 2)

**Do not allow README or matrix language to imply pipe POD embed = TLS bulk ready.** Structure types are not evidence.

---

## Issues (harsh)

### Fatal (phase scope)

**None for clear-H1 RPS correctness.** No evidence that Plan_Policy diet or Stream_Slot alone breaks empty-ok / oneshot materialize throughput. No ciphered default that forces full-file pread on clear Sendfile optimize path.

### Major

| # | Issue | Why it matters |
|---|--------|----------------|
| **M1** | **`Wire_Conn_State` = 1304 B dead weight on every Connection** | `seal_q: [SEAL_Q_CAP]Seal_Unit` with `SEAL_Q_CAP=32` and `Seal_Unit=40` lands **before** any code submits from that queue. Clear-H1 still arms `Wire_State` only. At 10k conns ~13 MiB; at 64k ~79 MiB — pure cold bytes in the slab. Elite hosts do not tax H1 conn density for an H2/TLS schedule bag that is not wired. **This is the #1 reason score &lt; 9.** |
| **M2** | **Free-list recycle zeros the dead bag** | `wire_conn_init` / `connection_destroy` path assigns `wc^ = {}` → full **1304 B memset** on every conn free-list reuse (plus 16 B `Tls_Pipe` + 8 B pt). Under accept/close churn this is real CPU; under keep-alive reuse it still runs destroy/reset paths that re-init bags. Live phase should not pay Phase-2 schedule wipe on every recycle. |
| **M3** | **Dual outbound bags (Wire_State + Wire_Conn_State) without a size budget** | Law S1 says one schedule owns `submit_send`. Today two POD homes exist; only one runs. Risk is not double-send *yet* — it is (a) Connection bloat and (b) Phase 2 “just also arm wire_conn” without retiring clear laundry, which is a **perf architecture** failure mode already called out in plan critics (Commit_Unit re-split). No `size_of(Connection)` CI / comment budget freezes the debt. |

### Minor → Major edge

| # | Issue | Note |
|---|--------|------|
| **m1** | **`_seal_q_pop_front` is O(n) shift** | Fine for pure tests. Shipping this algorithm into TLS bulk / H2 seal dequeue would be a self-inflicted hot-path tax. Phase 2 must replace with ring indices **before** wire uses it — not after first bulk bench. |
| **m2** | **Duplicate inflight bookkeeping fields** | `Wire_Conn_State.sock_send_inflight` / `seal_n` and `Tls_Pipe.sock_send_inflight` / `seal_n` — dual sources of truth waiting for Phase 2. Zero cost now; bug + branch tax later. Pick one owner early. |
| **m3** | **`plan_policy` → `plan_policy_apply_profile` projects via `plan_policy_context` then copies four fields back** | Optimize path only; micro. Prefer in-place public-field bias without full struct rebuild if optimize becomes default for TFB. |
| **m4** | **`Response._slot` + `_conn` dual bind** | Correct for multi-slot future; H1 pays two pointers and `response_slot` branches. Noise on oneshot. Keep; do not add a third. |
| **m5** | **Optimize Writev gated to `n_mem >= 2`** | Correct bastion fix; re-measure when single-slice gather is safe so materialize is not permanent for the common static body under `plan_optimize`. Not a Phase 0–1 regression — a deferred win. |

### Not issues (stop re-litigating)

- **Default materialize-only** — intentional; not a Plan_Context failure.
- **`Conn_Pt_Ring` 8 B admission** — correct; not a fake ring buffer.
- **`Stream_Slot` embed for H1** — correct N=1; not a map/heap slot table.
- **Embedding type names for Phase 2** — fine if **size** stays Phase-1-cheap; only `seal_q[32]` fails that test.

---

## Axis notes (focus questions)

### Did Plan_Context diet or Plan_Policy add hot-path cost?

**Mostly no.** Diet is a win for API and for avoiding host meters on the public surface. The **default** oneshot path never builds `Plan_Policy`. Optimize path builds a 28-byte policy once per respond and runs pure `plan_body` — dominated by I/O and copy, not planner.  

Residual: if someone turns `plan_optimize` on globally for “performance,” small bodies hit `preferred_copy_budget` materialize and single-mem bodies skip Writev — that is **policy**, not diet cost. Measure with eyes open; do not blame four-field `Plan_Context`.

### Are Conn_Pt_Ring / Wire_Conn_State dead weight on Connection size?

| Bag | Dead weight? |
|-----|----------------|
| `Conn_Pt_Ring` | **No** (8 B; will be live meters) |
| `Tls_Pipe` | **Negligible** (16 B skeleton) |
| `Wire_Conn_State` | **Yes — major** (1304 B idle `seal_q`) |

**Verdict:** Pipe POD as a *concept* is fine; **eager full `SEAL_Q_CAP` array on every clear-H1 Connection is not elite.**

### Stream_Slot indirection cost vs old fields?

**Acceptable / near-zero.** Nested field access, not pointer-chased exchange. Session/stream ownership concentration removes dual-write gen/session bugs that would cost more than an offset. Score high on this axis.

### Accidental materialize-always from ciphered / max_write_unit?

**No.** Live `ciphered=false`, `max_write_unit=0`. Materialize-always is the **default wire mode** when optimize is off — explicit, tested, and pre-TLS. Do not confuse “safe default” with “policy poison.”

### Honesty: fake TLS bulk?

**Clean.** No bulk claims tied to this embed. Keep it that way: types ≠ measured seal∥send, ≠ 4× firehose CI, ≠ product H2.

---

## What would WOW (≥ 9.0 phase scope)

Surgical — not redesign of Plan A laws:

| # | Change | Effect |
|---|--------|--------|
| 1 | **Do not embed `seal_q[SEAL_Q_CAP]` until Phase 2 wire owns S1** — e.g. `wire_conn: Wire_Conn_State` with **len/cursor only** now, or `^Seal_Q` allocated on first ciphered/multiplex conn, or `SEAL_Q_CAP` behind a later `when` / phase flag | Removes ~1.28 KiB/conn and recycle memset; biggest single jump |
| 2 | **`size_of` Connection / pipe-bag budget test** (or comment + CI assert) that fails if clear-H1 bags grow without a phase note | Prevents silent second 1 KiB |
| 3 | **Ring-index seal_q** (head/tail) before first production consumer of `seal_q_pop_*` | Avoids O(n) shift in TLS bulk |
| 4 | **Single inflight owner** when Seal_SM lands (retire duplicate bools on `Tls_Pipe` vs `Wire_Conn_State`) | Prevents dual-branch CQE path |
| 5 | **Preserve** default-path rule: materialize-only must not start calling `plan_policy` “for consistency” | Protects empty-ok |
| 6 | Optional: empty-ok / plan-bench **before/after** bag embed note in `comparisons/plan` or TFB meta — one line of evidence that RPS and RSS did not move for the wrong reason | Converts “shouldn’t regress” to measured |

None of these reopen four-field `Plan_Context`, Stream_Slot sole ownership, or PT1 must-alias.

---

## Harsh one-liner

Phase 0–1 **did not poison the clear-H1 respond path** with Plan_Policy or ciphered materialize lies — good. It **did park a 1304-byte empty seal queue on every Connection** for a schedule that still does not own the socket. That is structure-first done with a density blind spot. **8.15 — not WOWED.** Fix the dead `seal_q` embed (or prove RSS is irrelevant with numbers) and this phase clears 9.

---

## Close

| Question | Answer |
|----------|--------|
| Regress clear-H1 hot path? | **Unlikely on RPS** (default path clean) |
| Regress clear-H1 density / RSS? | **Yes, quietly** (`Wire_Conn_State`) |
| Plan_Context diet cost? | **No** (optimize-gated) |
| Stream_Slot tax? | **No** |
| Materialize honesty? | **Yes** |
| TLS bulk honesty? | **Yes** |
| Ship as Phase 1 structure? | **Yes, with M1 tracked** — do not freeze 1304 B/conn as sacred |

**WOWED: no (8.15).**  
**Architecture plan remains freeze-grade; this impl critic only grades Phase 0–1 + pipe POD as landed.**
