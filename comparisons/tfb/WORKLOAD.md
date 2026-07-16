# Plain text / HTML baselines

Compares HTTP stacks on **text/plain** and **text/html** only.

JSON is **out of scope** for now — encoder choice (sonic vs serde vs encoding/json
vs JsonCpp) dominates RPS and muddies I/O / host comparison.

## Endpoints

| Path | Content-Type | Work |
|------|--------------|------|
| `GET /plaintext` | `text/plain` | Body `Hello, World!` each response — **I/O ceiling** |
| `GET /fortunes` | `text/html; charset=utf-8` | **Primary.** SQLite fetch all fortunes → append runtime row → **sort by message** → HTML table with **escaped** messages |

No `/json`, `/db`, or `/queries` in this suite.

## Why fortunes (not vapor gen-HTML)

| vapor gen-HTML | This `/fortunes` |
|----------------|------------------|
| Trusted template-ish append | Untrusted messages must be **escaped** |
| No data plane | Real **DB read** every request |
| Large bodies for bandwidth theater | Small TE-sized table (app-shaped) |
| XSS never appears | Includes `<script>…` probe + UTF-8 Japanese |

## Fortune rules (TE-compatible)

Seed: 12 rows (see `schema/init_sqlite.sql`), including:

- `<script>alert("This should not be displayed in a browser alert box.");</script>`
- `フレームワークのベンチマーク`

Per request:

1. `SELECT id, message FROM fortune` (must not hardcode the list as the only path)
2. Append `{id:0, message:"Additional fortune added at request time."}`
3. Sort by **message** ascending
4. Render:

```html
<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>
<tr><th>id</th><th>message</th></tr>
<tr><td>…</td><td>…escaped…</td></tr>
…
</table></body></html>
```

Escape at least: `& < > " '`.

## Database

```bash
./schema/prepare.sh
export DATABASE_PATH=/tmp/proactr-tfb.sqlite
```

SQLite only for v1. In-memory fortune tables without a SQL read are **not** allowed for published numbers.

## Headers

| Header | Value |
|--------|--------|
| `Server` | peer short name |
| `Content-Type` | as above |

## Load methodology

1. Warmup (default 3s), then steady duration (default 15s)
2. Prefer **oha** with `--latency-correction`
3. Report **RPS (2xx)**, **p50**, **p99**, **errors**
4. Equal `WORKERS` across peers

## Ranking

| Test | Role |
|------|------|
| `/fortunes` | **Primary** product comparison |
| `/plaintext` | Ceiling / sanity only — never the sole claim |

## Anti-cheat

- No immortal prebuilt HTML for `/fortunes`
- No skipping escape
- No compile-time-only fortune list without DB
- No JSON endpoints masquerading as this suite
