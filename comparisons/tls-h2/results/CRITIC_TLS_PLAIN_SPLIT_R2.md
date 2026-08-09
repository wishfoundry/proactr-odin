# Harsh critic — ciphered H1 plain split — R2

Role: re-score after lifetime fix for single Static/Bytes borrow seal.  
**Prior:** [`CRITIC_TLS_PLAIN_SPLIT.md`](CRITIC_TLS_PLAIN_SPLIT.md) (FAIL — C1 silent UAF / materialize-promise).  
**Date:** 2026-08-08

**Files re-checked:**

| Path | Delta |
|------|--------|
| [`http/response.odin`](../../../http/response.odin) | Borrow gate + `body_set_*` docs + optimize comment |
| [`http/plan.odin`](../../../http/plan.odin) | `cmd_static` / `cmd_bytes` flags (unchanged constructors) |

---

## Verdict

**PASS**

No CRITICAL lifetime or Content-Length bugs remain. R1 C1 is closed by host gate + honest API docs.

---

## R1 → R2 fix audit

| R1 item | Status | Evidence |
|---------|--------|----------|
| C1 silent UAF / materialize promise | **Fixed** | Borrow only if `(Static\|\|Bytes) && .Borrowed && !.Owned` (`response.odin` ~1962–1964). `.Owned` Bytes fall through to `_response_materialize_cmds`. |
| `body_set_bytes` claimed copy-at-send | **Fixed** | Docs: buffer must live until wire complete; stack/temp dying at handler return **UNSAFE**; use `body_bytes` Owned or `body_reserve` (`response.odin` ~407–411, ~419). |
| Stale “Ciphered: materialize only” | **Fixed** | Comment ~1922–1923: no Writev/Sendfile; single borrowed may seal without full-body materialize. |
| CL / HEAD / cross-part / multi-cmd / H2 | **Still OK** | Unchanged from R1 non-findings. |
| I2 destroy temp-before-plain-clear | **Open (IMPORTANT)** | Not in stated fix set; hygiene only. |
| I3 no SSL split integration test | **Open (IMPORTANT)** | Cursor unit tests still sufficient for gate logic. |

---

## Checklist (mandated)

| Risk | Result | Notes |
|------|--------|-------|
| Body lifetime | **OK** | Borrow path restricted to explicit Borrowed∖Owned. Owned materializes (handler free-after-respond / stack via Owned safe). Static/`body_set` remain borrow-by-contract — documented; process-static and request-temp until clean remain valid. |
| Content-Length matches body | **OK** | Unchanged: `body_len = len(c.bytes)` for heading + seal view. |
| HEAD no body leak | **OK** | Still `!_response_is_head`. |
| Cross-part SSL_write advance | **OK** | Unchanged cursor. |
| clean clears body before arena reset | **OK** (happy path) | `tls_plain_clear` before `conn_temp_reset` in `clean_request_loop`. |

---

## CRITICAL findings

*None.*

---

## Residual IMPORTANT (non-blocking)

1. **`body_set` default is still Static/Borrowed** — intentional hot path; stack misuse is caller error now that docs match writev LIFETIME. Prefer `body_bytes(owned=true)` for ephemeral buffers (default).
2. **`connection_destroy` still resets temp before `tls_plain_clear`** — dangling alias if close aborts mid-oneshot; no further seal after `close_on_io`.
3. **No OpenSSL integration test** of rest→body seal under dual-CT.

---

## Bottom line

| Item | Status |
|------|--------|
| R1 C1 | Closed |
| Host Owned vs Borrowed gate | Correct (`cmd_static` → Borrowed; `cmd_bytes(true)` → Owned → materialize) |
| CL / HEAD / cursor | Sound |
| Ship lifetime claim | **Yes** |

**Verdict: PASS**
