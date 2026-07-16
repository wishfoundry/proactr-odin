# TechEmpower-style workload (honest baselines)

This suite follows the tests **real frameworks submit to TechEmpower** —
not vapor-http’s generated-HTML matrix (which optimizes for “dynamic but cheap”
and produces inflated RPS that don’t track TE-style rankings).

## Why vapor’s “realistic” numbers are optimistic

| vapor `realistic-gen-html` | This suite (`tfb`) |
|----------------------------|--------------------|
| Per-request string append of safe HTML | **JSON encode**, **HTML-escape untrusted text**, optional **DB round-trips** |
| No Date/Server discipline | TE-style response headers |
| Bodies sized for bandwidth theater (1–4 MiB) | TE body sizes (tiny JSON / small HTML table) |
| Closed-loop RPS only | **RPS + p50/p99 + error%** (oha latency-correction when available) |
| “Generated” but never escapes XSS | Fortunes includes `<script>…` and UTF-8 Japanese |

TechEmpower’s own ranking default is **Fortunes**, not plaintext: DB fetch →
insert runtime row → **sort by message** → **escape** → HTML template.

## Endpoints (TE-compatible)

| Path | Test | Work required |
|------|------|----------------|
| `GET /json` | JSON | Serialize `{"message":"Hello, World!"}` as JSON each request (`Content-Type: application/json`) |
| `GET /plaintext` | Plaintext | Body `Hello, World!` (`text/plain`) — **ceiling only**, not a product claim |
| `GET /fortunes` | Fortunes | Load all fortune rows (unknown count at compile time), append `"Additional fortune added at request time."`, **sort by message**, render HTML table with **escaped** messages |
| `GET /db` | Single query | One random `World` row by id → JSON `{"id":N,"randomNumber":M}` |
| `GET /queries?queries=N` | Multi query | N independent World fetches (clamp 1..500), JSON array |

Optional later: `/updates` (TE updates test).

## Fortune data

Exact TE seed set (12 rows), including:

- XSS probe: `<script>alert("This should not be displayed in a browser alert box.");</script>`
- UTF-8: `フレームワークのベンチマーク`

Runtime insert:

```text
id=0  message="Additional fortune added at request time."
```

Sort key: **message** string ascending (byte/UTF-8 order as in TE).

HTML shape (whitespace may vary slightly; structure must match):

```html
<!DOCTYPE html>
<html>
<head><title>Fortunes</title></head>
<body>
<table>
<tr><th>id</th><th>message</th></tr>
<tr><td>…</td><td>…escaped…</td></tr>
…
</table>
</body>
</html>
```

Escape at least: `& < > " '`.

## Database

Default for local baselines: **SQLite** file prepared by `schema/init_sqlite.sql`
(same logical data as TE Postgres).

```bash
./schema/prepare.sh   # creates /tmp/proactr-tfb.sqlite by default
export DATABASE_PATH=/tmp/proactr-tfb.sqlite
```

Postgres is optional (`DATABASE_URL`) for TE-apples comparison; all peers in
v1 target SQLite so laptop/bastion runs need no docker.

**Important:** in-memory fortune tables (no SQL) are **not** allowed in this suite.
That was the easy cheat path.

## Headers

Every response should include:

| Header | Value |
|--------|--------|
| `Server` | peer short name (`Go`, `Ntex`, `Drogon`, `Laytan`, …) |
| `Content-Type` | per test |
| `Date` | RFC 7231 (or framework auto Date) when the stack provides it |

## Load methodology

1. **Warmup** 3 s discarded (or first N requests).
2. **Steady** fixed **duration** (default 15 s), not a tiny fixed request count that finishes in the L1 cache warm window only.
3. Prefer **oha** with `--latency-correction` (mitigates coordinated omission).
4. Report for each cell: **RPS (2xx)**, **p50**, **p99**, **errors**, **non-2xx**.
5. Equal **worker/thread** knobs across peers (`WORKERS`, default = half of nproc or 1).
6. HTTP/1.1 cleartext, keep-alive (TE default). Separate short-connection run optional via `KEEPALIVE=0`.

## What we deliberately do *not* do (anti-cheat)

- No immortal prebuilt response bodies for `/json` or `/fortunes`
- No skipping HTML escape
- No compile-time fortune list without a DB read path
- No ranking peers by `/plaintext` alone
- No 4 MiB bulk as a stand-in for “realistic”
- No mimalloc / jemalloc required (optional; document if enabled)

## Peer classes

| Class | Peers | Notes |
|-------|-------|--------|
| A — app servers | ntex, go, drogon, laytan, proactr | Full endpoint set |
| B — I/O demos | asio (minimal), compio | May implement subset; label clearly |
| C — proxy | envoy | Front a Class A upstream; measure overhead |

## Comparability with published TE numbers

This suite is **TE-shaped** but not identical hardware/TFB tooling. Do not claim
“beats TE rank N” without same cloud instance + wrk pipeline. Claim instead:
“on host X, under oha C=…, peer ordering for fortunes/json.”
