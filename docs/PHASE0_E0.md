# Phase 0 ergonomics freeze (E0.1–E0.8)

**Merge blocker** before any TLS/H2 author marketing. Plan source: `docs/design/dual-tls-h2/plan-a.md` PART I. App authors read only the contracts linked below — not the design dump as required reading.

**Live ship checklist (honest):** [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).

| Gate | Artifact / check | Status |
|------|------------------|--------|
| **E0.1** | [`docs/APP_CONTRACT.md`](APP_CONTRACT.md) ≤1 page — App Contract only (no seal SM, no Exec_Op, no Provider, no pipe physics) | **Done** |
| **E0.2** | [`docs/MIDDLEWARE_CONTRACT.md`](MIDDLEWARE_CONTRACT.md) — may/must-not table | **Done** |
| **E0.3** | [`docs/CAPABILITY_MATRIX.md`](CAPABILITY_MATRIX.md) — author-facing ⏳/✅ + honesty rules | **Done** |
| **E0.4** | Same handler sample under clear H1; zero protocol `#if`, no stream ids | **Done (clear H1)** — sample `examples/empty_ok`; `scripts/check_app_contract_sample.sh`. Multi-protocol same-handler jobs wait for TLS/H2 phases |
| **E0.5** | No `examples/` import of `http/debug` (or caps/proto introspection) | **Done** — `scripts/check_e0_bans.sh` |
| **E0.6** | No sample/helper registers **Host_Pull** / pull from app code | **Done** — `scripts/check_e0_bans.sh` |
| **E0.7** | No example sets or prints stream id / `Response._sid` | **Done** — `scripts/check_e0_bans.sh` |
| **E0.8** | Pure `plan_body` policy tables: File+ciphered → no Sendfile | **Done** — `http/plan_test` E0.8 |

**Phase 1 structure (landed foundation — not TLS product):**

| PR | Status |
|----|--------|
| **PR1** Plan_Context four-field public surface | **Done** |
| **PR2** Stream_Slot N=1 | **Done** — `Response` + session + progressive stream on `conn.slot`; `Loop` is `req` only; clear-H1 schedule still `Connection.wire` |
| **PR3 / E0.8** plan tables | **Done** |
| **PR4** pipe POD | **Done** — pure types/tests; thin `Wire_Conn_State` (`Seal_Queue` deferred); clear-H1 still `Wire_State` |
| **PR5** TLS H1 oneshot host wire | **Done** — mem-BIO accept/handshake + ciphered windowed send; see `IMPLEMENTATION_STATUS.md` / `TLS_H1.md` |
| **PR6** TLS H1 SSE/WS progressive stream | **Done** — same App Contract; `tls_host_stream_try_submit`; hangup CT recv; session tests |
| **PR7** H2 engine sans-I/O | **Done** — see `H2_ENGINE.md` |
| **PR8** H2 host foundation | **Done** — ALPN h2 + multi-slot |
| **PR9** H2 product M1–M6 / SSE-on-H2 | **Done offline** — concurrent + multi-SSE; baseline `H2_PRODUCT_BASELINE.md` |

Ownership today: **exchange Response lives on `Stream_Slot`**. Request stays on `Loop` for the H1 parse cycle. Byte schedule remains `Wire_State` until Phase 2 owns Law S1 with `wire_conn`.

TLS H1 + TLS H2 concurrent/SSE (offline M1–M6) are product for matrix ✅ cells.
WS-on-H2 and bastion RPS still ⏳. See [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).

---

## Example / docs bans (E0.5–E0.7)

**Enforcement:** `./scripts/check_e0_bans.sh` (run in CI next to E0.4).

Hard fail if:

- Examples import `http/debug`, or introspect caps / message proto from app code.
- Any sample registers host deferred-produce (`Host_Pull` / `body_set_pull` / pull) from app code.
- Any example sets or prints stream id / `Response._sid`.
- Root README claims “supports HTTP/2” or “HTTP/2 ready” without a phase gate.

See also the NEVER block in [`APP_CONTRACT.md`](APP_CONTRACT.md).

### E0.4 same-handler sample

- **Clear H1 sample:** `examples/empty_ok` (no protocol `#if`, no stream ids).
- **Check:** `./scripts/check_app_contract_sample.sh`
- **CI one-liner:**  
  `./scripts/check_app_contract_sample.sh && ./scripts/check_e0_bans.sh`
- Multi-protocol same-handler jobs (TLS H1 / H2) land with those phases — not now.

---

## Dual-API social ban

The freeze is theater if examples reintroduce dual APIs. Review examples with the same ferocity as types. Host design docs (PART II / `docs/design/dual-tls-h2/`) are **not** linked from app README as required reading.

Framework authors may know slot · pipe · framer · cipher. **App tutorials never say those words.**
