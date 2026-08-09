# H2 product baseline (PR9 M1–M6)

Recorded offline product bar for TLS HTTP/2 concurrent unary + multi-SSE.
Linked from [`IMPLEMENTATION_STATUS.md`](../../IMPLEMENTATION_STATUS.md) and
[`CAPABILITY_MATRIX.md`](../../CAPABILITY_MATRIX.md).

**Honesty:** this is an **offline unit** baseline (sans-I/O engine + host glue).
It is **not** a peer-matrix RPS claim and **not** a live bastion firehose number.
Live `curl --http2` / bastion RPS remain **future** evidence.

---

## Status snapshot

| Surface | Result |
|---------|--------|
| Engine packages (`http2/`, `hpack/`, `huffman/`) | Green offline unit tests |
| Host concurrent dispatch (`h2_serial_dispatch=false` default) | Green offline |
| **M1–M6 product gates** | Green offline (`http/h2_m_gates_test.odin` + engine RR/flow tests) |
| Live bastion multi-stream RPS | **Not measured** — do not claim peer RPS |
| Full h2spec suite | **Not** claimed (strict unit subset only) |
| WS-on-H2 | **Still ⏳** |
| Large-body TLS bulk firehose on ring | **Still ⏳** (M2/M5 prove flow windows offline; not live multi-MiB CI) |

---

## Product gates (M1–M6)

| Gate | Meaning | Offline test name(s) |
|------|---------|----------------------|
| **M1** | Concurrent unary ≥2 on one H2 conn | `test_m1_concurrent_unary_two_get` (+ `test_h2_host_concurrent_two_get_streams`) |
| **M2** | Concurrent deferred large bodies ≥2; WINDOW_UPDATE drains both pending | `test_m2_concurrent_deferred_large_bodies_window_update` |
| **M3** | Fair RR: two pending streams both progress under shared conn window | `test_m3_fair_rr_both_streams_progress` (+ `http2.test_h2_flush_rr_two_pending_streams`, `http2.test_h2_flush_multi_pending_always_rr`) |
| **M4** | Duplex: flush does not unarm CT recv; send-complete always takes arm path when Open (`h2_test_arm_recv_count`) | `test_m4_duplex_flush_does_not_unarm_recv` |
| **M5** | Peak **on-wire** DATA O(window), not O(sum full bodies) | `test_m5_peak_wire_o_window_not_o_sum_bodies` (+ `http2.test_h2_peak_wire_o_window_two_large_bodies`) |
| **M6** | ≥2 concurrent SSE via **dispatch+handler**; RST → Client_Gone once (M6a+M6b) | `test_m6_two_concurrent_sse_sessions` (+ `test_h2_sse_two_sessions_data_frames`, `test_h2_sse_rst_client_gone_once`) |

### Fairness (M3 mechanism)

`Http2_Connection.flush_rr` + `_flush_pending_rr` whenever **≥2 streams have
pending** (including first multi-pending flush after body buffer, conn-level
`WINDOW_UPDATE`, and positive SETTINGS window growth). One DATA quantum per stream
turn (`quantum = max(1, conn_window / n_pending)`) so a fat stream cannot
starve another under a shared connection window. A sole pending stream still
drains fully.

### Peak / bulk honesty (M5)

- **On-wire** DATA without further WINDOW_UPDATE is bounded by stream + connection
  windows (O(window)).
- Oneshot `conn_send_body` / `conn_send_response` may **buffer** the remainder in
  `stream.pending` (backpressure signal = buffered > 0). That is not a claim of
  O(window) heap for the full body dump path.
- Live multi-MiB bulk RPS / firehose on the TLS ring is **not** part of this baseline.

### Duplex (M4)

`h2_host_flush_out` does not clear `tls_ct_recv_inflight`.
`h2_host_on_send_complete` always takes the arm path while `tls_pipe.state == Open`
(offline proof: `h2_test_arm_recv_count`; live path calls `tls_host_arm_recv`).
Flush never requires unarming recv first.

### Concurrent scrap honesty (MEM)

Handlers on one worker are **sequential** (no nested respond). Shared
`conn.resp_buf` materialize scrap is safe for oneshot because each respond
copies into engine `pending` before the next take/handler. “Concurrent” H2 =
multi-slot hold + interleaved CQEs, not re-entrant handlers.

---

## How to run

From the repo root (no OpenSSL required for offline gates):

```bash
# Engine + fair RR / flow
odin test http2 -o:none

# Host + M1–M6 gates (includes prior concurrent GET / SSE / RST tests)
odin test http -define:ODIN_TEST_THREADS=1 -o:none

# Example filter (M gates only):
odin test http -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_NAMES=http.test_m1_concurrent_unary_two_get,http.test_m2_concurrent_deferred_large_bodies_window_update,http.test_m3_fair_rr_both_streams_progress,http.test_m4_duplex_flush_does_not_unarm_recv,http.test_m5_peak_wire_o_window_not_o_sum_bodies,http.test_m6_two_concurrent_sse_sessions \
  -o:none

# E0 honesty bans
./scripts/check_e0_bans.sh
```

Manual live probe (when PEMs + OpenSSL work; **not** RPS matrix):

```bash
odin build examples/https_demo -out:examples/https_demo/https_demo.bin -o:none
./examples/https_demo/https_demo.bin &
curl -k --http2 https://127.0.0.1:18443/
# Concurrent streams with curl alone are limited; prefer offline M1–M6 for product bar.
```

---

## Explicit non-claims

| Claim | Status |
|-------|--------|
| Offline M1–M6 + eng tests green | **This baseline** |
| Peer matrix / bastion multi-stream RPS | **Not measured** |
| Full h2spec | **Not** claimed |
| WS over H2 | **⏳** |
| Live dual-CT seal∥send bulk firehose | **⏳** |
| HPACK encoder dynamic indexing | **Not** implemented |
| Inbound recv-window throttle | **Not** implemented (1:1 auto WINDOW_UPDATE) |

See also: [`H2_ENGINE.md`](../../H2_ENGINE.md), design plan Phase 5 / PR9 in
`docs/design/dual-tls-h2/plan-a.md`.
