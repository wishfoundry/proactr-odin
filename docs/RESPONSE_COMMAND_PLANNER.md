# Experiment: Response as Command Buffer + Transport Planner

**Branch:** `exp/response-command-planner`  
**Status:** Phase 3 wired (multi-buffer Writev-style send); Phase 4–5 open  

**Related:** `docs/ARCHITECTURE.md`, `http/response.odin`, `proactr/`, **`comparisons/plan/`** (A/B harness)

### Benchmark harness

Differential policy A/B (materialize vs optimize) with per-route shadow plan counters:

```bash
./comparisons/plan/run_plan_ab.sh
```

See [`comparisons/plan/README.md`](../comparisons/plan/README.md). Use this when changing `plan_body` or wiring profiles so mechanism counters stay honest.

This document is the north star for the experiment. Implementation will adapt as we learn; when choices diverge, update this doc and note *why* so the goals stay explicit.

---

## 1. Why this experiment exists

Today the HTTP host fuses two jobs into one path:

1. **Describe a response** (status, headers, body)
2. **Emit bytes on the wire** (format heading into `resp_buf`, copy body, `pending_send` → `host_submit_send`)

That works and is fast for the TFB-style “one contiguous buffer” path (`body_set`, `body_reserve`). It becomes painful when we want:

- zero-copy / gather writes (`writev`, multi-buffer send)
- file bodies without always reading into userspace first
- middleware that transforms bodies without knowing ring sizes
- TLS, io_uring `send_zc`, different backends — without rewriting handlers

The failure mode to avoid: leaking **transport mechanisms** (writev, sendfile, output rings, SQE shapes) into the public handler/middleware API as “body modes” or sink strategies.

---

## 2. Goals (must stay true)

### G1 — Three-stage pipeline

```
Handler  →  produces intent (commands / body semantics)
Middleware  →  transforms intent (commands → commands)
Transport planner + executor  →  plans and runs syscalls
```

Only the last stage reasons about writev, sendfile, io_uring, TLS record sizing, gather writes, copy thresholds.

### G2 — Semantics ≠ transport

Handlers express **what the body is**, not **how to send it**:

| Intent | Not |
|--------|-----|
| “these bytes are borrowed and immutable for the response lifetime” | “use writev” |
| “this is a file region” | “use sendfile” |
| “these bytes are owned by the request arena” | “copy into the output ring” |

Transport chooses mechanism from intent + `Plan_Context`.

### G3 — Data-oriented, not interface-oriented

Prefer:

- tagged unions / POD command arrays
- `#partial switch` over kinds
- explicit capability bit_sets
- no vtable “impl Body” rediscovery

Odin/Casey shape: **important data is explicit; policy (planner) is separate from mechanism (proactr submit).**

### G4 — Constraints over mechanisms on the public surface

Handlers and advanced code may inspect **constraints**:

- max iovecs, TLS on/off, sendfile available, zero-copy send, free staging budget

They must not call:

- `writev`, `sendfile`, `IORING_OP_SEND_ZC`, etc.

### G5 — Streaming is a different model

SSE / long-lived streams are **not** “just another body kind” next to static bytes.

- Normal: request → response commands → plan → execute → done  
- Stream: middleware ends → `begin_stream` → write/flush/end with different lifetime, timeout, cancellation

Do not force streams into the same command-buffer body path if that creates special cases everywhere.

### G6 — Compatibility and incremental truth

- Default planner path must remain **behavior-compatible** with today’s single-buffer send (heading + body in `resp_buf`, one `pending_send`).
- Existing helpers (`body_set`, `body_reserve` / `body_commit`, `respond_*`) should keep working; they may become thin wrappers that emit commands.
- No big-bang rewrite of the host loop required for v0.

### G7 — Learn in public (this doc)

When the experiment changes direction:

1. Update the relevant section here.
2. Add a short entry under [§10 Decision log](#10-decision-log).
3. Prefer “we tried X, measured Y, kept Z” over silent drift.

---

## 3. Non-goals (for this experiment)

- Full HTTP/2 or HTTP/3 response model  
- Drop-in replacement for laytan’s public API beyond what proactr-http already forked  
- Production TLS stack  
- Perfect zero-copy on every platform on day one  
- Middleware ecosystem completeness (gzip/cache/range as products) — only **shapes** that prove the transform model  
- Making every handler inspect `Plan_Context` (optional advanced path only)

---

## 4. Core model

### 4.1 Response commands (intent)

Handlers append **POD commands**. Nothing hits the socket until plan/execute.

Conceptual kinds:

```
Response_Cmd_Kind
  Status          // or keep status on Response as today
  Header          // or keep Headers map; body is the important cmd stream
  Static          // borrowed []u8, immutable for response lifetime
  Bytes           // owned / temporary bytes (arena or heap; free after send)
  File            // fd + offset + length
  Flush           // optional checkpoint (mostly for streaming later)
```

Ownership and capabilities are **flags**, not separate “Buffer vs Static modes”:

```
Body_Flags / Body_Capability (bit_set)
  Borrowed
  Owned
  Known_Length
  Seekable
  Replayable
  // later: Flushable, Streaming — or streaming stays out of this path
```

**Rule:** `Buffer` / `Static` / `File` / `Chunked` as *transport strategies* must not reappear as the public body API. Those are planner outputs, not handler inputs.

### 4.2 Middleware

```
middleware: []Response_Cmd → []Response_Cmd
```

Depends on **capabilities**, not concrete backend:

| Middleware | Needs | Transform idea |
|------------|--------|----------------|
| Range | Seekable + Known_Length | File/bytes slice → sub-range |
| Cache | Replayable | File → Static/Bytes from cache |
| Gzip (eager) | Replayable + small enough | N cmds → one Owned Bytes |
| Gzip (stream) | separate streaming path | wrap live producer — not command merge |

Middleware never sees output rings or SQE counts.

### 4.3 Plan_Context (constraints)

Snapshot available at plan time (and optionally readable by handlers before emit):

```
Plan_Context
  max_iovecs            // gather budget
  zero_copy_send        // backend capability
  sendfile_ok           // plain TCP, no TLS, OS support
  fixed_files           // registered fd table (Linux)
  tls                   // forces copy / different record path
  output_ring_free      // staging free (if we have a ring)
  sqe_budget            // remaining submit room this batch
  preferred_copy_budget // “copy if total ≤ this” policy knob
```

Handlers that care can branch:

- many `Static` fragments if `max_iovecs` is enough  
- else assemble one `Bytes` and emit once  

Still: they emit **commands**, not syscalls.

### 4.4 Planner (policy)

```
[]Response_Cmd + Plan_Context + headers/status
        →
[]Exec_Op + staging buffers + free-list
```

Planner is a small compiler:

1. Format heading (Content-Length from known lengths, or chunked later).  
2. Merge adjacent Static where useful.  
3. Choose copy-into-one-buffer vs writev vs header+sendfile.  
4. Respect TLS / iovec limits / size thresholds.  
5. Emit execution ops only.

### 4.5 Exec ops (mechanism-facing, private)

```
Exec_Op_Kind
  Write_Slice    // one contiguous buffer (today’s pending_send)
  Writev         // gather header + N body views
  Sendfile       // fd region
  Copy_Into      // materialize source into staging
  Patch_CL       // fixed-width Content-Length patch (body_reserve lineage)
  Flush          // batch / TLS boundary
```

Executor maps these to `proactr` submits and existing CQE handling (`host_on_send`, partial send retry, then next op).

### 4.6 Pipeline picture

```
┌─────────────┐     Response_Cmd[]      ┌────────────┐
│   Handler   │ ─────────────────────►  │ Middleware │
└─────────────┘                         └─────┬──────┘
                                              │ rewrite cmds
                                              ▼
┌─────────────┐     Exec_Op[]           ┌────────────┐
│  Executor   │ ◄────────────────────── │  Planner   │
│  (proactr)  │                         │ + Plan_Ctx │
└─────────────┘                         └────────────┘
```

---

## 5. Mapping onto the current codebase

| Current | Target role |
|---------|-------------|
| `Response._buf` / `conn.resp_buf` | Staging for heading and for planner-chosen `Copy_Into` / single `Write_Slice` |
| `body_set` | Emit `Static` or `Bytes` + plan materialize (v0: same as today) |
| `body_reserve` / `body_commit` | Fast path that is already a micro-plan: heading + in-place body + CL patch → keep as helper or as `Patch_CL` exec op |
| `response_writer_init` (chunked) | Near-term stays; long-term may feed streaming path, not static cmd list |
| `respond` → `response_send` → `pending_send` → `host_submit_send` | `respond` → middleware hooks → `plan_response` → `execute_plan` → submit |
| Single send CQE path | Executor state machine: `exec_i` over `[]Exec_Op`, partials stay on current op |
| `proactr.submit_send` | `Write_Slice`; later `sendv` / `sendfile` submit helpers |

**Degenerate planner (v0 truth):** every response becomes one `Copy_Into` (or in-place build) + one `Write_Slice`. Behavior matches production today; structure enables v1+.

---

## 6. Implementation phases

Do not skip the “structure first” phases. Optimizations only after the command list is real.

### Phase 0 — Scaffold (this doc + types)

- [x] Branch `exp/response-command-planner`
- [x] This plan document
- [x] `http/plan.odin`: `Response_Cmd`, `Body_Flags`, `Plan_Context`, `Exec_Op`, `Plan_Result` + pure `plan_body` / `plan_body_materialize_only`
- [x] Unit-test tables in `http/plan_test.odin`: *input cmds + Plan_Context → expected Exec_Op kinds* (executor not wired)

**Exit:** types compile; tests document intended policy without changing wire path. ✅

### Phase 1 — Emit commands, plan = materialize (behavior-identical)

- [x] `body_static` / `body_bytes` / `body_file` append cmds (file may still materialize via read for now)
- [x] `body_set` becomes wrapper → cmds
- [x] On `respond`, `plan_response` always builds heading + body into `resp_buf` and one `Write_Slice`
- [x] Keep `body_reserve` path working (either still special-cased or expressed as cmds + `Patch_CL`)

**Exit:** existing empty-ok / TFB / examples pass with no intentional perf regression; single-buffer send unchanged in spirit. ✅

### Phase 2 — Plan_Context + capability queries

- [x] Fill `Plan_Context` from server/conn/backend (`ring_has_fixed_files`, TLS flag placeholder, iovec max / copy budget from `Server_Opts`, sendfile on Linux/Darwin plain TCP)
- [x] Optional `plan_context(res)` / `plan_context_for(conn)` for advanced handlers; `response_plan_preview` runs optimize `plan_body` (wire still materialize-only)
- [x] Middleware hook: `Body_Middleware` on Response (`response_body_middleware`); identity + `body_mw_drop_empty_static`; applied before materialize on send
- [x] `Handler_Profile` + `response_set_profile` (prefer_materialize / gather / sendfile bias; zero = defaults, prefer_sendfile opt-in)
- [x] `Server_Opts`: `plan_copy_budget` (0 → default 4096), `plan_max_iovecs` (0 → 1024), `plan_sendfile_ok` (default true)

**Exit:** handlers can read constraints; middleware can rewrite cmds without touching executor. ✅

### Phase 3 — Multi-Static gather (first real optimization)

- [x] Planner: multiple `Static`/`Bytes` with known lengths → prefer `Writev` when `!tls` and over copy budget and within `max_iovecs` (policy already in `plan_body`)
- [x] Wire: pure Writev → multi-buffer sequential `submit_send` queue (`exec_bufs` / `exec_i` / `exec_n`) without requiring kernel writev; `Server_Opts.plan_optimize` (default false) or `prefer_gather`
- [x] Partial-send advances within current buffer; full buffer advances `exec_i`; final CQE → `clean_request_loop` (no temp reset earlier)
- [x] Sendfile / Copy_Into on plan → **materialize fallback** (Phase 4)
- [x] Wire metrics: `plan_wire_writev_total` / `plan_wire_materialize_total`

**Exit:** unit tests + plan harness wire counters show gather when expected; fallback remains correct. ✅

### Phase 4 — File bodies

- [ ] `body_file` as true `File` cmd (no forced full read in handler helpers when possible)
- [ ] Planner: `Write_Slice(headers)` + `Sendfile` when `sendfile_ok && !tls`
- [ ] Else: copy path (read into staging or temporary buffer)

**Exit:** file download path correct; TLS/disabled sendfile still works via copy.

### Phase 5 — Streaming split (only when needed)

- [ ] `begin_stream` / write / flush / end API separate from cmd buffer
- [ ] Document that middleware for streams runs **before** stream starts
- [ ] Do not overload `Response_Cmd.Stream` as a fake static body

**Exit:** SSE-style sketch without poisoning the static planner.

---

## 7. Design rules (checklist while coding)

Use this when reviewing experimental PRs/commits:

1. **Does a handler or middleware mention writev/sendfile/SQE/ring free?**  
   → Move that to planner/executor (or expose only via `Plan_Context` fields).

2. **Is a new “body mode” really a transport strategy?**  
   → Do not put it on `Response` as mode; add an `Exec_Op` or planner branch.

3. **Are ownership and source conflated?**  
   → Prefer `Bytes` + `Borrowed`/`Owned` flags over `Buffer` vs `Static` modes.

4. **Is streaming piggybacked on static respond?**  
   → Split API and lifetimes.

5. **Does the default path still materialize one buffer when policy says so?**  
   → Yes is good. Optimization is optional, correctness path stays simple.

6. **Can middleware decide with only capabilities + cmd kinds?**  
   → If it needs backend internals, the abstraction leaked.

7. **Is `Plan_Context` data that drives decisions, not a syscall façade?**  
   → Handlers describe; planner decides.

---

## 8. Success criteria

### Structural success

- [x] Clear types for intent (`Response_Cmd`) vs execution (`Exec_Op`)
- [x] Planner is the only place that chooses copy vs gather vs sendfile *(wire executes Writev multi-buffer; Sendfile still materialize until Phase 4)*
- [x] At least one middleware-shaped transform exists as cmd rewrite
- [x] Streaming is either out of scope with a written reason, or a separate API

### Behavioral success

- [ ] No regression on current single-buffer correctness
- [ ] `body_reserve` Fortunes-style path still valid (or documented replacement with equal clarity)
- [ ] Partial send and connection cleanup invariants preserved (`pending_send` / multi-op equivalent)

### Learning success

- [ ] Decision log records what we simplified or abandoned
- [ ] Benchmark notes if gather/sendfile lands (even rough)

### Failure criteria (stop or redesign)

- Handler API requires knowing backend op kinds to be correct  
- Every middleware grows a switch on “are we on io_uring?”  
- Command buffer becomes a second full HTTP stack with no use  
- Streaming special cases infect static plan_response  

---

## 9. Open questions

Track answers here as the experiment proceeds.

1. **Headers as cmds vs `Headers` map?**  
   Map is convenient for middleware lookup; cmds are convenient for pure rewrite. Hybrid is fine for v0 (map + body cmds only).

2. **Where does Content-Length get finalized?**  
   Planner after middleware (middleware may change body). Heading format stays late.

3. **Request-scoped arena vs body lifetime for `Static`?**  
   Borrowed slices must outlive send CQEs (same rule as today’s buffer ownership until `host_on_send` clears pending).

4. **Max commands per response?**  
   Fixed small array vs dynamic; prefer fixed + overflow “merge/copy” policy.

5. **Chunked `Response_Writer`?**  
   Keep as-is until Phase 5; do not pretend it is a static cmd list.

6. **Multi-op executor vs single fused buffer?**  
   v0 fused; multi-op only when Writev/Sendfile land.

7. **Public package boundary**  
   What is `http` public vs `@(private)` planner/exec? Prefer private planner forever.

---

## 10. Decision log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-08-04 | Start experiment on branch `exp/response-command-planner` | Isolate from `proactr-perf` production path |
| 2026-08-04 | v0 planner = materialize + single Write_Slice | Preserve correctness; structure before optimization |
| 2026-08-04 | No Body_Mode enum of transport strategies | Avoid mixing semantics with mechanisms |
| 2026-08-04 | Streaming deferred / separate API | Different lifetime and middleware timing |
| 2026-08-05 | Phase 0: pure `plan_body` encodes *intended* optimize policy; `plan_body_materialize_only` is Phase 1 wire default | Tests lock Writev/Sendfile choices before host wiring; wire path stays untouched until Phase 1 |
| 2026-08-05 | Body cmds only (no Status/Header cmds yet) | Headers stay on `Response.headers` for lookup; open question §9.1 deferred |
| 2026-08-05 | Small bodies (≤ `preferred_copy_budget`) always materialize | Avoid gather for tiny responses; matches “simple path first” |
| 2026-08-05 | File without sendfile → `Copy_Into` + `Write_Slice` | Makes the copy stage explicit for later async file read |
| 2026-08-05 | Added `comparisons/plan/` A/B harness with shadow plan counters | Prove per-route Writev/Sendfile policy before wire; RPS informational until Phase 3–4 |
| 2026-08-05 | `/file/1m` wire uses preloaded bytes; shadow plan still `File` | Avoid per-request 1 MiB temp-arena reads under load (crashed workers) |
| 2026-08-05 | Phase 1: `body_set` / `body_*` append `Response_Cmd`; wire uses `plan_body_materialize_only` | Structure first; heading deferred until send so headers stay mutable after body_set |
| 2026-08-05 | Fixed `PLAN_MAX_BODY_CMDS` (32) on Response with assert overflow | Prefer fixed POD over unbounded growth (open question §9.4) |
| 2026-08-05 | `body_reserve` / chunked `response_writer` stay special-cased (heading early) | Not rewritten as cmds yet; avoid breaking Fortunes / JSON writer paths |
| 2026-08-05 | Phase 2: `plan_context` fills from `Server_Opts` + worker ring; wire still `plan_body_materialize_only` | Structure for constraints/middleware without mechanism change |
| 2026-08-05 | `Handler_Profile.prefer_sendfile` is opt-in (`sendfile_ok &= prefer_sendfile`) | Matches `comparisons/plan` plan_ctx_for; zero profile keeps conservative optimize preview |
| 2026-08-05 | Body middleware on Response (`_body_mw`), not global Server hook | Per-request; cleared in `response_init`; toy `body_mw_drop_empty_static` only |
| 2026-08-05 | Body middleware must rewrite in place (same `raw_data`); no post-return host copy | External/stack returns would be UAF; `body_middleware_apply` asserts contract |
| 2026-08-05 | `response_plan_preview` applies middleware on a cmd snapshot (no Response mutate) | Matches send intent without double-apply at wire |
| 2026-08-05 | Phase 3: Writev on wire as multi-buffer sequential sends (not kernel writev yet) | Correctness + partial-send reuse; proactr `submit_send` only; no new SQE kind |
| 2026-08-05 | `Server_Opts.plan_optimize` default false; also enable when `prefer_gather` | No surprise for zero-profile apps; harness sets plan_optimize for PLAN_MODE=optimize |
| 2026-08-05 | Sendfile/Copy_Into plan → materialize on wire in Phase 3 | Defer kernel sendfile to Phase 4; keep single fallback path |
| 2026-08-05 | `Connection.exec_bufs[PLAN_MAX_BODY_CMDS+1]` + `exec_i`/`exec_n` | Fixed POD queue; heading in resp_buf, bodies borrowed until final CQE |
| 2026-08-05 | Package atomics `plan_wire_writev_total` / `plan_wire_materialize_total` | Harness `/metrics` proves real wire path vs shadow policy |

*(Append rows; do not rewrite history — strike through and add superseding rows if needed.)*

---

## 11. Suggested first code touchpoints

| File | Role |
|------|------|
| `docs/RESPONSE_COMMAND_PLANNER.md` | This plan |
| `http/plan.odin` | Types + pure `plan_body` (optimize policy) + `plan_body_materialize_only` + wire counters |
| `http/plan_test.odin` | Table tests: cmds + context → exec op sequence; multi-op advance |
| `http/response.odin` | Emit cmds; plan+execute (materialize or Writev multi-buffer) |
| `http/server.odin` | Multi-buffer executor in `host_on_send`; `plan_optimize` opt |
| `proactr/*` | Phase 4+: sendfile / true writev submit if needed |

---

## 12. One-paragraph reminder

> Handlers produce **body intent** as POD commands. Middleware rewrites commands using **capabilities**. The **planner** turns commands plus **Plan_Context** into an execution plan. The **executor** talks to proactr. Data-oriented design means making intent and constraints explicit — not teaching every layer about writev and ring buffers. When in doubt, keep the wire path dumb and correct, and put cleverness only in the planner.
