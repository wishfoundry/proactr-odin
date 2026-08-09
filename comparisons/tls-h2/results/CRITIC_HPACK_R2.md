# HPACK critic R2 — P0 modernization (WOW)

**When:** 2026-08-09  
**Tests:** huffman 8 · hpack 30 · http2 54 — all green  
**Prior:** `CRITIC_HPACK.md` (F decode perf, static-only encoder, clone/`inject_at` debt)

## Loop summary

| Round | Agents | Verdict |
|-------|--------|---------|
| Implement | Huffman FSM + HPACK ring/encoder/integer (parallel) | landed |
| Critic R1 | perf / correctness / ownership (3× harsh) | **PASS** (not WOW) |
| Fix | ownership flags, exact Huffman free, SETTINGS, list budget, tests | landed |
| Critic R2 | combined harsh | **WOW** |

## What shipped (P0)

| Item | Status |
|------|--------|
| Huffman nybble FSM (`decode_table.odin` + `gen_decode_table.py`) | Done · `decode_slow` for cross-check |
| Dynamic table ring O(1) insert/evict | Done |
| No third clone on incremental (`insert_owned`) | Done |
| Explicit `name_owned` / `value_owned` (no pointer free heuristic) | Done |
| Encoder dynamic table + incremental + never-indexed + size updates | Done |
| Wired on `Http2_Connection.enc` / `conn_send_headers` | Done |
| Integer + string length caps | Done |
| Decoded list size budget (`List_Too_Large`) | Done |
| SETTINGS_HEADER_TABLE_SIZE advertise + peer→encoder + local→decoder limit | Done |
| Negative / ownership / encoder↔decoder tests | Done |

## Spot profile (post-fix, Darwin, debug TLS binary)

- h2load h2 `/plaintext` ~**87k req/s** (4 workers, debug; prior fair matrix ~62k with 8 workers — not apples-to-apples but directionally better).
- Sample: **no `huffman::` linear-scan frames**; residual HPACK time is `decode_string` / clone (expected under heap model).
- Huffman FSM is no longer the 38% worker murder weapon.

## Critic R2 overall: **WOW**

P0 complete. Residual **P2** (not blockers):

1. Arena-native header/table bytes (stream/connection region free)
2. Encoder `find_pair`/`find_name` sublinear map
3. Indexing policy polish (without-index for one-shots)
4. `List_Too_Large` → more precise H2 error code if desired

## Reproduce tests

```bash
odin test huffman -all-packages
odin test hpack -all-packages
odin test http2 -all-packages
# regenerate Huffman table after TABLE edits:
python3 huffman/gen_decode_table.py
```
