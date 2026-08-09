# Harsh critic: proactr `hpack` (+ `huffman`)

**Scope:** `hpack/hpack.odin`, `hpack/integer.odin`, `hpack/hpack_test.odin`, `huffman/huffman.odin`, wire-up in `http2/connection.odin` / `http2/flow.odin`  
**Peer reference:** Vapor’s stack is **SwiftNIO `NIOHPACK`** (Vapor HTTP/2 = NIO). Release notes claim **~2× then ~1.5× HPACK encode** wins (fabianfett); decode uses a **nybble FSM table**, not bit-linear search.  
**Context:** kqueue TLS profile put **`hpack::decode_string` ~38%** of worker time on H2 plaintext — this package is on the critical path.

**Stance:** adversarial. Correct enough to pass Appendix C samples is not “good HPACK.”

---

## Scorecard

| Axis | Grade | One-line |
|------|:-----:|----------|
| Spec surface (decode forms) | **B** | Indexed + all literal forms + size updates present |
| Spec hardness (limits, bombs, SETTINGS) | **D+** | Soft integers; no list-size; encoder table absent; SETTINGS not fully wired |
| Performance (decode) | **F** | Huffman is **O(bits × 257)** linear scan — profiled as top H2 small cost |
| Performance (encode) | **D** | Static-only; no encoder dynamic table → fat blocks forever |
| Memory / allocators | **D** | Per-string `clone` / double-clone on insert; dynamic table `inject_at(0)` O(n) |
| RAII discipline | **B** | Explicit `destroy` / `headers_destroy`; no Swift-style ARC in hot path |
| Code quality / structure | **B-** | Small, readable; comments honest about encoder simplicity and Huffman debt |
| Tests | **C+** | C.1–C.4 happy path; thin failure / adversarial coverage |
| vs NIOHPACK (Vapor) | **lose** | NIO: full encoder + FSM Huffman + ring-ish table storage; we: textbook slow decode |

**Overall:** shippable decoder for interoperability; **not** a high-performance or production-hardened HPACK core.

---

## 1. Correctness (RFC 7541 / HTTP/2)

### What is fine

- Static table Appendix A (61 entries) matches the RFC layout.
- Index resolution §2.3.3: static then dynamic; index 0 rejected via `table_get`.
- Representations: Indexed (`0x80`), Literal Incremental (`0x40`), Size Update (`0x20`), Literal without / never (`0x00`/`0x10` share 4-bit name prefix) — decode path is the right shape.
- Size updates rejected after a field (`seen_field`) — §4.2 spirit.
- Size update `> dt.limit` → `Bad_Size_Update`.
- Entry size = `name+value+32` (§4.1); oversize entry empties / refuses insert (§4.4).
- Huffman: EOS-in-stream error; padding must be all-1s; EOS length bound.
- Appendix C.1–C.4 vectors in tests (including Huffman C.4) — **tests pass**.

### Spec / protocol gaps (real)

| ID | Issue | Severity | Evidence |
|----|--------|----------|----------|
| **S1** | **Encoder has no dynamic table** — only static exact match → Indexed, else **Literal Without Indexing**. Never emits Incremental Indexing, Never Indexed, or size updates. Peer decoder learns nothing from us; every request re-pays full literals. | **Product / wire efficiency** | `encode` ~216–230; comment admits “deliberately simple” |
| **S2** | **No encoder respect for peer `SETTINGS_HEADER_TABLE_SIZE`** — NIO tracks encoder max and emits size-update prefixes; we ignore peer SETTINGS for HPACK entirely. | Medium | `connection.odin` SETTINGS switch never touches an encoder table (there is none) |
| **S3** | **Decoder `dt.limit` not tied to local SETTINGS changes** — init(4096) only. If local `SETTINGS_HEADER_TABLE_SIZE` ever changes at runtime, size-update validation stays at 4096. | Low today / latent | `hpack.init(&c.dec, 4096)`; no `dec.limit = …` on SETTINGS |
| **S4** | **Prefix integer overflow / integer bomb** — `value += (b&0x7f)<<m` is unchecked wrap; length cast to `int` then slice. Hostile blocks can force huge `length` / wrap before `Truncated`. | **High** (DoS class) | `integer.odin` 37–40; `decode_string` 193–197 |
| **S5** | **No `MAX_HEADER_LIST_SIZE` / decoded size accounting** during HPACK — connection has `max_header_bytes` on **wire fragment**, not decoded header list size (§6.5.2 / HPACK abuse). | Medium | decode always appends; no running size |
| **S6** | **Never Indexed vs Without Indexing** collapsed on decode (OK for table) but **encoder never emits 0x10** for secrets (`authorization`, `cookie`). Privacy/proxy guidance ignored. | Medium (policy) | encode path only `0x00` / Indexed |
| **S7** | **No field-name lowercase validation** at HPACK layer (HTTP/2 requires lowercase names). May be handled later in `_validate_request_headers` — still a compression-context footgun if validation is partial. | Low–Med | not in `hpack` |
| **S8** | **Partial Appendix C** — no C.5 response series, C.6 Huffman responses, explicit size-update vectors, never-indexed wire, bad padding, truncated mid-integer. | Test debt | `hpack_test.odin` |

Decoder is “interops with polite clients.” It is **not** hardened like nghttp2/NIO against malicious HPACK.

---

## 2. Performance (why H2 plaintext dies here)

### P0 — Huffman decode is algorithmically wrong for hot path

```odin
// huffman/huffman.odin — per bit, scan entire 257-entry TABLE
for bit := 7; bit >= 0; bit -= 1 {
    cur = (cur << 1) | …
    for sym, i in TABLE {           // up to 257 compares per bit
        if sym.nbits != cur_len do continue
        if (sym.code >> …) == cur { … }
    }
}
```

Package comment admits: *“linear table match per emitted symbol; FSM/state-table decode is a later optimization.”*

**Cost model:** ~8×L bit steps × ~O(257) → hundreds of compares per compressed byte.  
**Profile (kqueue H2 plaintext):** `hpack::decode_string` / HPACK ~**38%** of worker samples.

**NIOHPACK (Vapor):** `getHuffmanEncodedString` walks a **`HuffmanDecoderTable` by nybble** (state + 4 bits → symbol/next/flags). That is **O(input bytes)** with tiny constant — industry standard (same family as nghttp2).

**Encode side (NIO):** PR series “Improve HPACKEncoding performance by ~2× / ~1.5×” — bit-packing into `ByteBuffer` with fast paths. Our encode uses `append` per byte/chunk + optional huffman via temp scratch; acceptable for rare responses, not competitive if encode ever matters.

### P1 — Dynamic table insert is O(n) memmove

```odin
inject_at(&dt.entries, 0, owned)  // every insert shifts entire array
```

RFC newest-first index 0. Correct semantics, **bad structure**. Each incremental insert costs O(entries). NIO `HeaderTableStorage` is built for ring/head-index style growth (O(1) insert, O(1) index with wrap).

Under chatty clients that *do* use incremental indexing, decoder table maintenance becomes another memmove tax (same class as the old H2 `pending` bug).

### P2 — Allocation storm on every field

| Path | Allocs |
|------|--------|
| Indexed static | **clone name + clone value** even though static is `rodata` |
| Literal raw | `strings.clone` of raw |
| Literal Huffman | `dynamic` grow in decode + owned string |
| Incremental | `decode_literal` owns strings, then **`insert` clones again** → **2× name/value** |

NIO still allocates strings, but: (1) Huffman decode writes into a single pre-sized buffer; (2) table storage is specialized; (3) encoder reuses table hits so later requests avoid re-encoding.

**No per-connection / per-block arena** for decoded headers: each field is an independent heap string on `c.allocator`. Stream free is N×`delete` in `headers_destroy`. That fights the project’s handmade-allocator ethos (arenas, explicit lifetime, batch reclaim).

### P3 — Encoder strategy guarantees permanent fat requests

Static pair hits (`:method GET`, `:path /`, …) are fine. Anything with a value (`:authority`, `user-agent`, cookies) is **literal every time**. NIO default indexing: first request pays insert; subsequent requests become **1-byte Indexed** refs.

For a TFB-style H2 GET with authority + few headers, NIO encoder shrinks after the first request on a connection; **we never do**.

### P4 — `static_find_pair` / `static_find_name` linear 61-scan

Minor vs Huffman, but encode of many headers does 61×string compares twice. NIO uses indexed lookup structures over static+dynamic. Easy win later with perfect-hash / name map for static.

### P5 — `append` growth on encode dst / huffman scratch

`encode_string` huffman path: `make` temp + `append(..scratch)`. Fine at low RPS; on response encode under load, reserve capacity once per block (NIO `ByteBuffer` capacity discipline).

---

## 3. Memory allocators & anti-RAII

### Good (matches proactr culture)

- Explicit `init` / `destroy` on `HPackDynamicTable`.
- Explicit `headers_destroy` for decoded lists — **no** destructor magic, no ARC.
- Allocator parameter threaded through `decode` / `decode_string` (not hidden globals).
- Tests may use `defer`; library API does not force RAII types.

### Bad (not handmade / not arena-friendly)

| Pattern | Problem |
|---------|---------|
| `strings.clone` per field | General-purpose heap; no slab/arena recycle |
| Huffman ` [dynamic]u8` grow | Realloc churn; unknown final size until decode ends |
| Double clone on incremental | Table and `out` don’t share storage |
| Static headers cloned into `out` | Needless; could return `string` views into `HPACK_STATIC` with a “owned vs borrowed” flag — or always copy into request arena once |
| Table as `[dynamic]Header` + `inject_at` | Contiguous array + front insert = GC-style churn without the GC |

**Desired shape (proactr-native):**

1. Connection- or stream-scoped **arena** for decoded header bytes.  
2. `Header` = `{name, value: string}` pointing into arena; free = arena reset.  
3. Dynamic table stores **offsets into a ring buffer of bytes** (or interned slices with refcount/bump), O(1) insert.  
4. Huffman decode writes **into arena reserved span**, not a throwaway dynamic.

NIO still uses Swift `String` (more RAII/ARC than we want), but its **table + Huffman** mechanics are the right performance target; we should copy *algorithms*, not Swift ownership.

---

## 4. Code quality

### Strengths

- Small files, clear RFC section comments.
- Integer codec isolated (`integer.odin`); shared primitive comment is honest.
- Error enum is small and actionable for COMPRESSION_ERROR mapping.
- Encoder limitation is **documented**, not silent.

### Weaknesses

- **Performance footguns left as “later”** while product is already TLS/H2 RPS-bound on HPACK.
- **Dual ownership model** (clone everywhere) is the easy correctness path and the wrong long-term path.
- **Encoder/decoder asymmetry** is a footgun for anyone reading “full HPACK” in the package header — package doc says full **decoder**, simple encoder; still easy to mis-sell.
- Naming: `HPackDynamicTable` vs package `hpack` (nit).
- No fuzz harness (NIO/Envoy have HPACK fuzzers in the wild; we only have unit vectors).

---

## 5. Comparison: proactr hpack vs Vapor / NIOHPACK

| Capability | proactr | NIOHPACK (Vapor HTTP/2) |
|------------|---------|-------------------------|
| Decoder forms | Full-ish | Full |
| Encoder dynamic table | **No** | **Yes** (default indexable) |
| Size update emit | **No** | **Yes** (beginEncoding / setDynamicTableSize) |
| Never-indexed encode | **No** | **Yes** |
| Huffman decode | Linear bit × table scan | **Nybble FSM table** |
| Huffman encode | Simple bit pack | Optimized buffer write (multi-PR speedups) |
| Dynamic table structure | `[dynamic]` + `inject_at(0)` | Specialized `HeaderTableStorage` |
| Lookup | Linear static scan | `firstHeaderMatch` over static+dynamic |
| Memory | Per-string clone | ByteBuffer + String (Swift) |
| Proven RPS work | Profiled **hot on decode** | Explicit encode 2×/1.5× release work |

**Takeaway:** Vapor is not “magic Swift.” It sits on a **deliberately optimized HPACK codec**. Our codec is a **correct teaching implementation** still carrying the comment that the real Huffman decoder is future work — while production TLS/H2 profiles already pin blame here.

---

## 6. Top areas to improve (ordered)

### P0 — Replace Huffman **decode** with a state/nybble table (nghttp2 / NIO style)

- Expected impact: **dominant** win on H2 small RPS (profile: ~38% worker in HPACK).
- Deliverable: `huffman.decode` FSM; keep current as `decode_slow` for tests.
- Acceptance: decode of C.4 vectors; microbench ≫ linear scan; H2 plaintext sample no longer HPACK-dominated.

### P0 — Stop cloning static / shared strings on every Indexed field

- Borrow static table strings into `out` **or** copy once into a **request arena**.
- Kill double-clone on incremental (`insert` should take ownership or share arena bytes).

### P1 — Dynamic table: ring buffer / head index (O(1) insert, O(1) index)

- Eliminate `inject_at(0)` memmove.
- Same bug class as H2 body `pending_off` fix.

### P1 — Real **encoder** dynamic table + Incremental Indexing (NIO `_appendIndexed` model)

- Emit size updates when SETTINGS change.
- Use Never Indexed for sensitive headers.
- Shrinks response **and** request paths over connection lifetime; peer CPU also drops.

### P1 — Integer / length hardening

- Cap prefix integers (e.g. reject if value > 2^32-1 or > remaining+limit).
- Cap string length vs remaining buffer **before** allocate.
- Optional: max decoded header list size from SETTINGS.

### P2 — Arena-backed header storage on `Http2_Connection` / stream

- Align with handmade allocator story; batch free on stream close / GOAWAY.
- Huffman + literals write into arena; table entries point into stable ring or copy-on-evict.

### P2 — Complete RFC test + fuzz surface

- C.5/C.6, size-update placement errors, never-indexed, padding errors, integer bombs, random HPACK fuzz (compression error only — no panic/OOM).

### P3 — Static name/value lookup tables

- Perfect hash or sorted + binary search; only matters after Huffman is fixed.

### P3 — Wire `SETTINGS_HEADER_TABLE_SIZE` ↔ `dec.limit` / encoder max

- Correctness completeness when settings become configurable.

---

## 7. What **not** to do first

- Another dual-CT TLS pass to “fix H2 plaintext” — profile says **HPACK**, not AES.
- Micro-optimizing `prefix_int_encode` before Huffman FSM.
- Porting Swift ARC/`String` APIs — port **table + FSM algorithms** into Odin arenas.

---

## 8. Suggested acceptance bar (harsh)

| Gate | Metric |
|------|--------|
| Huffman decode | ≥10× faster than current on 64–256 B Huffman blobs (microbench) |
| H2 plaintext sample | HPACK **&lt; 15%** worker (from ~38%) |
| Allocs / request (decode of C.4.1-class block) | No double clone; static indexed = 0 heap string allocs if arena/borrow |
| Encoder | After 10 identical GETs on one conn, block size shrinks via dynamic Indexed |
| Fuzz | 1e6 random blocks: no crash; only `Hpack_Error` |

Until P0 Huffman lands, **claiming competitive H2 on kqueue is dishonest** — the matrix loss to ntex/go on small H2 is consistent with this package.

---

## Files under indictment

| File | Worst finding |
|------|----------------|
| `huffman/huffman.odin` | Linear Huffman decode (P0) |
| `hpack/hpack.odin` | Simple encoder; clone/`inject_at` (P0–P1) |
| `hpack/integer.odin` | Unbounded prefix int (P1) |
| `hpack/hpack_test.odin` | Happy-path heavy (P2) |
| `http2/connection.odin` | Decode wired; SETTINGS/arena not co-designed with hpack |

*Critic only — no code changes in this note.*
