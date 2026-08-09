# Code Quality Critic — Round 2

**Bar:** WOW ≥ 9 only. Full plans read (not summaries).  
**Mandate:** verify each R1 Fatal/Major closed; residual issues severity-labeled; WOW when truly fixed.

---

## Plan A
### Score: 9.2/10
### WOWED: yes

### R1 Fatal/Major closure audit

| R1 ID | Issue | Status | Where closed |
|-------|--------|--------|--------------|
| **F1** | L2 cipher opacity without drive SM | **CLOSED** | **§E**: `Tls_Phase` Handshake→Open→Closing→Closed; mem-BIO-only bulk; `T1–T6` arm-only-from-CQE; free-order **§E.4**; CT×2 + seal∥send; SSL never leaves module |
| **F2** | `Wait_Flow` + snapshot windows dual truth | **CLOSED** | **Law W1/W2 §C.3–C.4**: live windows on `slot.flow` / conn H2; re-read every unit; plan advisory only; cursor slot-owned; RST/GOAWAY aborts — no resume into freed plan |
| **M3** | `Frame_State` god-object | **CLOSED** | **§G**: exclusive `Connection_Framer` + `#raw_union` `H1_Framer \| H2_Engine`; sans-I/O `feed` / `pull_control` |
| **M4** | Large-body / high-water missing | **CLOSED** | **§F.1–F.3**: `PULL_WINDOW` 64 KiB, `PT_HIGH_WATER` 256 KiB, `CT_SLOTS=2`, deferred `src_off/remaining` without public pull rail; peak O(window) law |
| **M5** | Response migration dual-write | **CLOSED** | **§D.2**: Phase 1 exit hard — Response binds `_slot`; Connection pipe-only; **grep-clean** dual-write of `conn.session` / `conn.wire.exec_*` / `conn.stream_*` |
| **M6** | H2 duplex recv-while-send not law | **CLOSED** | **Law D1 §J** + **T5** burst drain after recv CQE; anti-pattern table rejects unarm-on-flow-block |
| **M7** | Slot storage soft Phase 1 exit | **CLOSED** | **§D.1–D.2**: slot is sole storage of Response/Session/wire_slot/plan; Connection holds slab header + pipe only; H1 = N=1 same types |

R1 minors (**m8–m10**): Exec_Op fusion via `Commit_Unit` (**§F.4**); caps/proto stripped from app API (App Contract / **§B.2**); soft 503 honesty Phase 4. Closed as design law; residual op-list length is cosmetic (see below).

### What forces quality (R2)

- **Ownership graph is complete end-to-end.** L5→L4→L3→L2→L1 with *must not know* columns; Stream_Slot sole exchange; Connection pipe-only; Tls_Pipe normative SM — the R1 hole at L2 is filled without inventing a second product ontology.
- **Live-window law is structural, not culture.** W1 forbids freezing flow as plan token bucket; executor unit loop re-reads; Wait_Flow parks **cursor**, not a freed plan blob. That is the difference between correct multiplex and intermittent over-send/stall.
- **Write physics are numbered and phase-gated.** 64 KiB pull, ~4-record batch, CT×2, PT high-water, socket send ∈ {0,1}, CT pipeline ∈ {0,1,2} — in **Phase 2**, not “polish later.” Public bulk contract = windows/inflight, not op laundry.
- **Phase 1 exit is a merge gate, not a hope.** Grep-clean dual-write + Response→slot is implementable review criteria. H1 as degenerate N=1 means Phase 3 is slab length + framer, not a second host rewrite.
- **App Contract + CI same sample** freezes the quality invariant apps actually need: correct on clear H1 ⇒ correct on TLS/H2 without protocol branches.
- **Retained R1 strengths:** Conn_Caps truth table, pure `plan_body` table tests (PR3), allocator lifetime table (**§D.3**), ABA Session gen, Law S1 single submit path, middleware cmd-only, no public resume/stream-id/SSL.

### Residual issues (R2)

**Major (none fatal — do not block freeze; fix in Phase 1–3 PR checklist)**

1. **Wire_Conn unit identity under stream abort is thinner than the free-order rigor elsewhere.**  
   Law S1 and fairness comments require a queue of sealed units across slots, but the type sketch still shows `pending: []u8` without `slot_gen` / unit identity (**§D.4**). Conn-level free-order (**§E.4**) is excellent for Closing; stream RST (**W2/D2**) says abort cursor and free PT views, but does **not** normatively say: *dequeue non-inflight sealed units tagged for this gen; if mid-socket-send, wait CQE then recycle*. Under concurrent deferred + RST races, that is the classic UAF / double-recycle class. **Close with:** `Seal_Unit { slot_gen, view, is_ct }` (or equivalent) + gen-checked remove on slot death — steal the shape from peer free-order without changing ontology.

**Minor**

2. **`Exec_Op_Kind` still lists a long private zoo** despite `Commit_Unit` fusion (**§F.4**). Fusion rule is correct; keep the public teaching surface as windows/inflight only, and avoid growing micro-ops as the “real API” in reviews.
3. **Public `Plan_Context` still carries staging pressure fields** (`output_ring_free`, `sqe_budget`, `max_iovecs`, `fixed_files`) — thinner than R1 dump, but still invite middleware “if ring low then…” mechanism branches. Prefer host-private snap for ring/SQE; keep public to semantic constraints (`sendfile_ok`, budgets, `max_write_unit`, zc).
4. **Stream-level free-order is prose-scattered** (W2 + D2 + E.4) vs one diagram. Conn death is normative; stream death should get a short ordered list next to E.4 for implementer parity.

### What would make residual vanish (optional polish)

- Normative `Seal_Unit` + gen on wire_conn queue; stream-abort free-order bullets.  
- Diet public Plan_Context to four semantic fields; host snap for the rest.  
- Keep everything else — freeze is WOW-grade.

---

## Plan B
### Score: 9.1/10
### WOWED: yes

### R1 Fatal/Major closure audit

| R1 ID | Issue | Status | Where closed |
|-------|--------|--------|--------------|
| **F1** | Dual Loop vs `H2_Stream_Slot` architectures | **CLOSED** | **§A.2–A.3**: single `Stream_Slot`; H1 = N=1; kill long-term `Connection.loop` as response storage; dual-write forbidden after Phase 1 |
| **F2** | Three outbound owners + fuse optionality | **CLOSED** | **Law O1–O2 §C.1**: only pipe/`Cipher_State` post-encrypt submits; framer never `submit_send`; **no fuse optionality** — one path, tested |
| **M3** | Weak Session ABA | **CLOSED** | **§A.2 laws 3–4**, **§E.3**: `Session.id` = gen; lookup checks gen; CQE abort on mismatch |
| **M4** | TLS before structure (god Connection intermediate) | **CLOSED** | **§G Phase 0–1** slot façade + plan tables **before** Phase 3 Cipher_State |
| **M5** | Planner soft; no caps table / flow law | **CLOSED** (quality bar met) | **§B.4** Conn_Caps truth table; **Law O4** live re-read; Phase 0 pure `plan_body` policy tables; `plan_cursor` slot-owned abort on RST |
| **M6** | `rx_hold` growable firehose | **CLOSED** | **§C.2** fixed `BIO_RX_HOLD_MAX`; overflow → protocol error / close |
| **M7** | Forever vapor fork dual-maint | **CLOSED** (design intent) | **§A.4 / §G Steal vs own**: cherry-pick facts/vectors; rewrite storage to slots; **not** dual-maint vapor `server/` package |
| **M8** | `Response._sid` layering landmine | **CLOSED** | **§A.2**: `frame_id` private on slot; Response binds slot / token — never `_sid` |

R1 minors: free-order → **§L** full SM; `Conn_Proto` product worlds → orthogonal **Conn_Caps**; `io.Stream` refused in freeze; Provider under cipher only. Closed.

### What forces quality (R2)

- **Ontology collapse is the quality win.** R1’s dual H1-Loop / H2-slot world is gone; one type, N slots, gen pooling. That single cut prevents the host god `if h2 != nil` growth that was B’s structural death sentence.
- **Outbound law is non-optional and typed.** O1–O5 + Seal SM with CT[2] and `seal_n ∈ {0,1,2}` make “who submits / who recycles / when seal∥send” unforgeable. Anti-pattern 3 (`send_inflight: bool` alone under TLS bulk) is reviewable.
- **Free-order state machine (§L)** is the best close/UAF discipline of either plan: stream RST vs conn death, gen bump, Seal_Unit dequeue, never free CT/PT referenced by outstanding CQE, never resume Wait_Flow into freed buffers.
- **Multiplex product gates M1–M5** force concurrent deferred + fairness + duplex evidence before any H2 perf claim — quality of “H2 ready” is not marketing folklore.
- **Private physics retained:** mem-BIO-only, window numbers (L5), PT ring high-water, rBIO burst, Provider IOC under cipher, sans-I/O framer, anti-firehose, CQE-only arm.
- **Absorbed Plan A strengths without package fork:** Stream_Slot, wire_conn fairness, Conn_Caps, gen Session, structure-before-crypto, thin public constraints, Client_Gone only.

### Residual issues (R2)

**Major (none fatal — land in Phase 1 checklist)**

1. **Allocator lifetime / per-slot temp detach is not a table.**  
   Plan A’s **§D.3** forces: cipher/HPACK on conn_allocator; request scrap temp; session pad conn-lived; stream slabs from worker pool; **never back long-lived wire with request temp**; per-slot temp detach after SSE Start under multiplex. Plan B implies pools and “session never knows workers” but does not freeze that discipline. Under N≥2 slots this is the second classic UAF class after wire-queue gen. **Close with:** a short lifetime table (steal A’s shape) as Phase 1 exit criterion.

**Minor**

2. **`Framer_State` type sketch holds both `h1` and `h2` fields** while prose says exclusive. Prefer `#raw_union` (or equivalent) so Phase 4–5 cannot grow a kitchen-sink bag “for convenience.”
3. **`Response._conn` “derivable sugar during migration”** (**§A.2**) is softer than A’s grep-clean gate. Dual-write is forbidden at exit, but sugar fields tend to keep half-paths alive. Prefer Response binds slot only; derive conn via `slot.conn`.
4. **`Host_Pull` on private `Slot_Deferred`** is correctly non-public, but a host-registered `pull` proc is a re-entry / blocking hazard if ever exposed to middleware. Keep “host-registered only” as review reject; no third intent rail.
5. **Cherry-pick process risk remains process, not type** — OWNERS + “one tree” is right; still require PR checklist “no vapor `server/` import” so dual-maint does not regress under deadline.

### What would make residual vanish (optional polish)

- Allocator lifetime table + temp-detach law as Phase 1 exit.  
- Exclusive framer storage; Response→slot only (no `_conn` sugar).  
- Keep Seal SM, §L free-order, M1–M5 — freeze is WOW-grade.

---

## Comparative note (1 paragraph)

Round-2 both plans close every R1 code-quality Fatal and Major by converging on the same structural spine: **one `Stream_Slot`**, **one outbound submit path**, **mem-BIO Tls/Cipher SM driven from CQEs**, **live flow re-read**, **H2 duplex recv law**, **thin public App Contract**, **structure before crypto**, **numbered write windows**. Plan A remains slightly stronger on **planner purity, allocator lifetime table, exclusive framer raw-union, and Phase 1 grep-clean migration**; its residual is a thinner **wire-queue unit/gen free-order** under stream RST. Plan B remains slightly stronger on **Seal SM concreteness, Seal_Unit+gen, and normative close free-order (§L)** plus multiplex **M1–M5** product gates; its residual is the **missing allocator/temp-detach table** and a softer Response migration sugar. **Neither has open Fatals.** Residuals are PR-checklist Majors, not redesign triggers. **Both clear the WOW bar.** Prefer freeze language that merges A’s D.3 allocator table + grep-clean with B’s Seal_Unit/§L free-order — optional polish, not a third rewrite. **Scores: A 9.2/10 WOWED, B 9.1/10 WOWED.**

---

## Verdict summary

| | Plan A | Plan B |
|--|--------|--------|
| R1 Fatals closed | 2/2 | 2/2 |
| R1 Majors closed | 5/5 | 6/6 |
| Residual Major | 1 (wire unit gen / stream abort) | 1 (allocator / temp-detach table) |
| Residual Minor | 3 | 4 |
| **Score** | **9.2/10** | **9.1/10** |
| **WOWED** | **yes** | **yes** |
