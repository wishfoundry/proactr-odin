# Static file middleware

Serve local files with caching validators, resumable downloads (HTTP Range), and
zero-copy wire where available (Linux/Darwin sendfile).

**Package:** `http/middleware` (import as `middleware`)  
**Routing:** `http.Builder` + `listen_builder` / `builder_get`  
**Platform:** Elite path is **POSIX** (Linux/Darwin). Windows is best-effort full-read.

---

## Quick start

```odin
package main

import http "path/to/http"
import mw "path/to/http/middleware"
import "core:net"

main :: proc() {
	b: http.Builder
	http.builder_init(&b)
	defer http.builder_destroy(&b)

	// Serve ./public under /static/* (strip URL prefix, terminal 404/405).
	http.builder_get(&b, "/static/{*path}",
		mw.static_mount("/static", "public"))

	// Or full options:
	// opts := mw.Static_Opts{
	// 	root = "public",
	// 	strip_prefix = "/static",
	// 	max_age_secs = 3600,
	// }
	// http.builder_get(&b, "/static/{*path}", mw.static_handler(opts))

	// API + SPA: try files first, then fall through.
	// api := http.handler(api_handler)
	// root := mw.static_middleware(mw.Static_Opts{
	// 	root = "public",
	// 	spa_fallback = "index.html",
	// }, &api)
	// http.builder_get(&b, "/{*path}", root)

	s: http.Server
	http.server_shutdown_on_interrupt(&s)
	err, build_err := http.listen_builder(&s, &b, net.Endpoint{port = 8080})
	if build_err.kind != .None {
		return
	}
	_ = err
}
```

From the repo root, the import path is typically:

```odin
import http "../http"                 // adjust relative to your package
import mw   "../http/middleware"
```

---

## API surface

| Constructor | When to use |
|-------------|-------------|
| `static_handler(opts)` | This route is **only** files. Miss → **404**. Wrong method → **405**. |
| `static_middleware(opts, next)` | Try disk; if miss / non-GET-HEAD → **`next`**. Good for SPA + API. |
| `static_mount(prefix, root)` | Sugar: `static_handler` with `strip_prefix = prefix`. |

### `Static_Opts`

| Field | Default | Notes |
|-------|---------|--------|
| `root` | **required** | Filesystem root (relative or absolute) |
| `strip_prefix` | `""` | URL prefix removed before join (e.g. `"/static"`) |
| `index` | `"index.html"` | Directory index; set `disable_index = true` to turn off |
| `spa_fallback` | `""` | If file missing, serve this under root (GET only), e.g. `"index.html"` |
| `max_age_secs` | `0` | `Cache-Control: max-age=…` when &gt; 0 |
| `immutable` | `false` | Appends `immutable` (fingerprinted assets); long max-age if max_age is 0 |
| `follow_symlinks` | `false` | Safe default; when true, realpath must stay under root |
| `serve_dotfiles` | `false` | Dot segments (`/.git`, `/.well-known`) → 404 unless true |
| `disable_index` | `false` | No directory index |
| `disable_ranges` | `false` | No `Accept-Ranges` / 206 |
| `disable_etag` | `false` | No ETag / If-None-Match |
| `disable_last_modified` | `false` | No Last-Modified / If-Modified-Since |

Zero-value flags that default **on** use `disable_*` so this is enough:

```odin
opts := mw.Static_Opts{root = "public"}
```

---

## Behaviour summary

### Safety
- Path clean + root jail (no `..` escape)
- No directory listing
- Symlinks denied by default (`O_NOFOLLOW` / `lstat`)
- Dotfiles denied by default (ACME `/.well-known` needs `serve_dotfiles = true` or a separate route)

### Caching
- Strong **ETag** + **Last-Modified**
- **If-None-Match** (priority) / **If-Modified-Since** → **304**
- Optional **Cache-Control** (`max_age_secs`, `immutable`)

### Resumable downloads
- `Accept-Ranges: bytes`
- Single `Range`: `bytes=start-end`, `bytes=start-`, `bytes=-suffix`
- **206** + `Content-Range` + part `Content-Length`
- **416** when unsatisfiable
- **If-Range**: apply Range only if validators match; else full **200**

### MIME / Content-Type
- Broad extension table (html/css/js/mjs, images incl. webp/avif, fonts woff/woff2/ttf/otf, pdf, audio/video, wasm, zip, webmanifest, source maps, …)
- **Unknown extension → `application/octet-stream`** (not `text/plain`)
- **Case-insensitive** extensions (`.PNG` == `.png`)
- **UTF-8 charset** on text HTML/CSS/JS/plain/markdown/csv/xml
- Optional `extra_mimes: []http.Mime_Extra` for app-specific types

### Delivery
- POSIX: open + `body_file` + `prefer_sendfile` → **sendfile** (Linux/Darwin) or chunked pread
- Not a full-file `read` into memory for the default path
- HEAD: same headers/validators; no body on the wire

---

## Composition patterns

### Pure asset mount

```odin
http.builder_get(&b, "/assets/{*path}", mw.static_mount("/assets", "dist/assets"))
```

Missing file → 404. POST → 405.

### SPA with API fallback

```odin
api := http.handler(on_api)
// Prefer API routes registered more specifically, or:
// chain: static middleware first for GET file/SPA, else API
spa := mw.static_middleware(mw.Static_Opts{
	root = "public",
	spa_fallback = "index.html",
}, &api)
http.builder_get(&b, "/{*path}", spa)
```

### Long-cache fingerprinted assets

```odin
h := mw.static_handler(mw.Static_Opts{
	root = "public/assets",
	strip_prefix = "/assets",
	immutable = true, // Cache-Control: immutable (+ long max-age)
})
http.builder_get(&b, "/assets/{*path}", h)
```

---

## Handler vs middleware

| | `static_handler` / `static_mount` | `static_middleware` |
|--|----------------------------------|---------------------|
| Miss | **404** | call **next** |
| Non-GET/HEAD | **405** | call **next** |
| Use for | Dedicated `/static/*` | Stack in front of API/SPA |

Same serve path underneath; only failure policy differs.

---

## Server options

Static sets `prefer_sendfile` on the response so file streaming works even when
`Server_Opts.plan_optimize` is false. For best throughput also enable:

```odin
opts := http.Default_Server_Opts
opts.plan_optimize = true   // multi-cmd + file Sendfile policy
opts.plan_sendfile_ok = true
```

Env (wire): `PLAN_WIRE_SENDFILE=0` forces chunked pread instead of kernel/BSD sendfile.

---

## Testing

```bash
odin test http/middleware -o:none
odin test http/ -o:none
```

Pure helpers (path jail, Range, ETag, If-Range) plus temp-dir prepare tests (206/416/304/owned fd).

---

## Related

- Wire path: `http/wire.odin` (sendfile / multi_send / file_chunked)
- Kqueue/Linux file benches: `comparisons/tfb/results/KQUEUE_PROFILE_MATRIX.md`
