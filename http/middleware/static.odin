package middleware

// Static file serving (package middleware).
//
// Elite-quality static files: path jail, no directory listing, ETag / Last-Modified,
// Range / 206 / If-Range (resumable downloads), Cache-Control, SPA fallback.
// Large files use http.body_file + prefer_sendfile (sendfile / chunked pread), not full read.
//
// Platform quality:
//   Elite path is POSIX (Linux/Darwin): open + fstat + http.body_file(owned) + prefer_sendfile.
//   Windows: best-effort full-read, limited Range/validators (no sendfile host path).
//
// See STATIC.md in this package for full usage.

import "core:fmt"
import http ".."
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Options for static_handler / static_middleware.
// Zero-value flags that default ON use disable_* so Static_Opts{root="public"} is safe.
//
// Elite quality is POSIX (Linux/Darwin). Windows: best-effort full-read, limited Range/validators.
Static_Opts :: struct {
	// Required: directory to serve (relative or absolute). Resolved once at handler creation.
	root: string,
	// Optional URL prefix stripped before joining to root (e.g. "/static").
	strip_prefix: string,
	// Directory index file name. Empty → "index.html". Use disable_index to turn off.
	index: string,
	// If the resolved file is missing, serve this path under root with 200 (GET only).
	spa_fallback: string,
	// Cache-Control max-age in seconds; 0 omits max-age (unless immutable).
	max_age_secs: int,
	// Append Cache-Control "immutable" (fingerprinted assets). Implies long max-age if max_age_secs==0.
	immutable: bool,
	// When true, realpath the target and re-check it stays under root. Default false.
	follow_symlinks: bool,
	// When true, allow path segments starting with '.'. Default false (404).
	// ACME HTTP-01 and similar under `/.well-known/` need serve_dotfiles=true, or a separate
	// route that is not subject to the default dotfile deny (".well-known" is a dot segment).
	serve_dotfiles: bool,
	// Defaults ON; set true to disable.
	disable_index:          bool,
	disable_ranges:         bool,
	disable_etag:           bool,
	disable_last_modified:  bool,
	// Optional extension overrides (ext lowercase with leading '.', e.g. ".gltf").
	// Matched before builtin mime table. Content-Type may include charset.
	extra_mimes: []http.Mime_Extra,
}

// Resolved once when building a handler/middleware.
// Package-private so static_test can build real open/prepare paths without a live server.
@(private)
Static_State :: struct {
	opts:     Static_Opts,
	root_abs: string, // absolute, cleaned, no trailing slash (except "/")
	next:     Maybe(^http.Handler),
	// true → dedicated handler (404/405); false → middleware (fall through).
	terminal: bool,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// http.Handler for a route: GET/HEAD serve files under opts.root; other methods → 405.
static_handler :: proc(opts: Static_Opts, allocator := context.allocator) -> http.Handler {
	st := _static_state_new(opts, nil, true, allocator)
	h: http.Handler
	h.user_data = st
	h.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		st := (^Static_State)(h.user_data)
		_static_serve(st, req, res)
	}
	return h
}

// Middleware: serve static on GET/HEAD when found; otherwise call next.
// Non-GET/HEAD fall through to next (unlike static_handler which returns 405).
static_middleware :: proc(opts: Static_Opts, next: ^http.Handler, allocator := context.allocator) -> http.Handler {
	assert(next != nil, "static_middleware requires next")
	st := _static_state_new(opts, next, false, allocator)
	h: http.Handler
	h.user_data = st
	h.next = next
	h.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		st := (^Static_State)(h.user_data)
		_static_serve(st, req, res)
	}
	return h
}

// Convenience: static_handler with strip_prefix set (mount URL prefix → filesystem root).
// Example: builder_get(&b, "/assets/{*path}", static_mount("/assets", "public/assets"))
static_mount :: proc(prefix, root: string, allocator := context.allocator) -> http.Handler {
	return static_handler(Static_Opts{root = root, strip_prefix = prefix}, allocator)
}

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested)
// ---------------------------------------------------------------------------

// Resolve the request URL path into a clean relative path under root (no leading '/').
// Does not touch the filesystem. ok=false → treat as not found / forbidden.
static_resolve_rel :: proc(
	request_path: string,
	strip_prefix: string,
	serve_dotfiles: bool,
	allocator := context.temp_allocator,
) -> (
	rel: string,
	ok: bool,
) {
	if strings.contains_rune(request_path, 0) {
		return "", false
	}

	path := request_path
	if path == "" {
		path = "/"
	}

	if strip_prefix != "" {
		sp := strip_prefix
		// Normalize strip prefix: no trailing slash except root.
		for len(sp) > 1 && (sp[len(sp) - 1] == '/' || sp[len(sp) - 1] == '\\') {
			sp = sp[:len(sp) - 1]
		}
		if sp != "/" && sp != "" {
			if path == sp {
				path = "/"
			} else if strings.has_prefix(path, sp) && (len(path) == len(sp) || path[len(sp)] == '/') {
				path = path[len(sp):]
				if path == "" {
					path = "/"
				}
			} else {
				return "", false
			}
		}
	}

	// Percent-decode (%2e%2e etc.). Invalid encoding → reject.
	decoded, dec_ok := net.percent_decode(path, allocator)
	if !dec_ok {
		return "", false
	}
	if strings.contains_rune(decoded, 0) {
		return "", false
	}

	// Lexical clean (collapses ., .., //).
	cleaned, cerr := filepath.clean(decoded, allocator)
	if cerr != nil {
		return "", false
	}

	// Force relative: drop leading separators.
	rel = cleaned
	for len(rel) > 0 && (rel[0] == '/' || rel[0] == '\\') {
		rel = rel[1:]
	}
	if rel == "." {
		rel = ""
	}

	// Escape after clean.
	if rel == ".." || strings.has_prefix(rel, "../") || strings.has_prefix(rel, "..\\") {
		return "", false
	}

	if !serve_dotfiles && static_path_has_dot_segment(rel) {
		return "", false
	}

	ok = true
	return
}

// True if any path segment is a dotfile (".env", ".git", …). "." / ".." ignored.
static_path_has_dot_segment :: proc(rel: string) -> bool {
	if rel == "" {
		return false
	}
	start := 0
	for i := 0; i <= len(rel); i += 1 {
		sep := i == len(rel) || rel[i] == '/' || rel[i] == '\\'
		if !sep {
			continue
		}
		seg := rel[start:i]
		if len(seg) > 0 && seg[0] == '.' && seg != "." && seg != ".." {
			return true
		}
		start = i + 1
	}
	return false
}

// Lexical jail: candidate must equal root or be root + separator + rest.
// Special case: root_abs "/" (or "\") is the filesystem root — any absolute path is under it.
// (Without this, candidate[len("/")] is never a separator and every path under "/" is rejected.)
static_path_under_root :: proc(root_abs, candidate: string) -> bool {
	if root_abs == "" || candidate == "" {
		return false
	}
	if candidate == root_abs {
		return true
	}
	// FS root: every absolute path is a descendant.
	if root_abs == "/" || root_abs == "\\" {
		return candidate[0] == '/' || candidate[0] == '\\'
	}
	if !strings.has_prefix(candidate, root_abs) {
		return false
	}
	if len(candidate) <= len(root_abs) {
		return false
	}
	c := candidate[len(root_abs)]
	return c == '/' || c == '\\'
}

// Strong ETag from size + mtime nanoseconds (+ optional inode). Always quoted.
static_etag_format :: proc(size: i64, mtime_nsec: i64, inode: u64 = 0, allocator := context.temp_allocator) -> string {
	if inode != 0 {
		return fmt.tprintf("\"%v-%v-%v\"", inode, size, mtime_nsec)
	}
	return fmt.tprintf("\"%v-%v\"", size, mtime_nsec)
}

// Parse a single HTTP byte range. end is inclusive.
// ok && !unsatisfiable → use [start,end]
// !ok && unsatisfiable → 416
// !ok && !unsatisfiable → ignore Range (malformed / multi / empty header)
static_parse_byte_range :: proc(header: string, size: i64) -> (start, end: i64, ok: bool, unsatisfiable: bool) {
	h := strings.trim_space(header)
	if h == "" || size < 0 {
		return 0, 0, false, false
	}
	// Only "bytes=" unit.
	if !strings.has_prefix(h, "bytes=") {
		return 0, 0, false, false
	}
	spec := h[len("bytes="):]
	// Multi-range: ignore (send full 200) rather than multipart.
	if strings.contains(spec, ",") {
		return 0, 0, false, false
	}
	spec = strings.trim_space(spec)
	if spec == "" {
		return 0, 0, false, false
	}

	// suffix: bytes=-N
	if spec[0] == '-' {
		if len(spec) < 2 {
			return 0, 0, false, false
		}
		n, n_ok := strconv.parse_i64(spec[1:])
		if !n_ok || n <= 0 {
			return 0, 0, false, false
		}
		if size == 0 {
			return 0, 0, false, true
		}
		if n >= size {
			return 0, size - 1, true, false
		}
		return size - n, size - 1, true, false
	}

	// start-end or start-
	dash := strings.index_byte(spec, '-')
	if dash < 0 {
		return 0, 0, false, false
	}
	start_s := spec[:dash]
	end_s := spec[dash + 1:]
	if start_s == "" {
		return 0, 0, false, false
	}
	s, s_ok := strconv.parse_i64(start_s)
	if !s_ok || s < 0 {
		return 0, 0, false, false
	}
	if end_s == "" {
		// bytes=start-
		if size == 0 {
			return 0, 0, false, true
		}
		if s >= size {
			return 0, 0, false, true
		}
		return s, size - 1, true, false
	}
	e, e_ok := strconv.parse_i64(end_s)
	if !e_ok || e < 0 {
		return 0, 0, false, false
	}
	if s > e {
		return 0, 0, false, false
	}
	if size == 0 || s >= size {
		return 0, 0, false, true
	}
	if e >= size {
		e = size - 1
	}
	return s, e, true, false
}

// If-None-Match: true → respond 304 (weak comparison; supports * and comma list).
static_if_none_match :: proc(etag: string, header: string) -> bool {
	h := strings.trim_space(header)
	if h == "" || etag == "" {
		return false
	}
	if h == "*" {
		return true
	}
	// Split on commas.
	rest := h
	for len(rest) > 0 {
		part: string
		if i := strings.index_byte(rest, ','); i >= 0 {
			part = strings.trim_space(rest[:i])
			rest = rest[i + 1:]
		} else {
			part = strings.trim_space(rest)
			rest = ""
		}
		if part == "" {
			continue
		}
		if static_etag_equal_weak(etag, part) {
			return true
		}
	}
	return false
}

// Weak etag equality: optional W/ prefix, then quoted-string compare.
static_etag_equal_weak :: proc(a, b: string) -> bool {
	return static_etag_strip(a) == static_etag_strip(b)
}

static_etag_strip :: proc(tag: string) -> string {
	t := strings.trim_space(tag)
	if strings.has_prefix(t, "W/") || strings.has_prefix(t, "w/") {
		t = strings.trim_space(t[2:])
	}
	return t
}

// If-Modified-Since: true → 304 when mtime (truncated to seconds) <= IMS.
static_if_modified_since :: proc(mtime: time.Time, header: string) -> bool {
	ims, ok := http.date_parse(strings.trim_space(header))
	if !ok {
		return false
	}
	// Compare at second resolution (HTTP-date has no subsecond).
	mt := time.time_to_unix(mtime)
	it := time.time_to_unix(ims)
	return mt <= it
}

// If-Range: true → Range may be applied. Value is ETag or HTTP-date.
// Strong match for ETag; exact HTTP-date match against last_mod_http string.
static_if_range_allows :: proc(if_range, etag, last_mod_http: string) -> bool {
	h := strings.trim_space(if_range)
	if h == "" {
		return true // no If-Range → allow Range
	}
	// ETag forms start with " or W/"
	if h[0] == '"' || strings.has_prefix(h, "W/") || strings.has_prefix(h, "w/") {
		// Strong comparison for If-Range: weak validators must not match.
		if strings.has_prefix(h, "W/") || strings.has_prefix(h, "w/") {
			return false
		}
		return static_etag_strip(etag) == static_etag_strip(h)
	}
	// HTTP-date: must equal Last-Modified representation.
	return h == last_mod_http
}

// Format Content-Range for 206 or 416 (size-only). start < 0 → unsatisfiable form.
static_content_range_fmt :: proc(start, end, size: i64, allocator := context.temp_allocator) -> string {
	_ = allocator
	if start < 0 {
		return fmt.tprintf("bytes */%v", size)
	}
	return fmt.tprintf("bytes %v-%v/%v", start, end, size)
}

// ---------------------------------------------------------------------------
// Internal serve path
// ---------------------------------------------------------------------------

// Package-private for integration tests (temp dir + real open/prepare).
@(private)
_static_state_new :: proc(opts: Static_Opts, next: ^http.Handler, terminal: bool, allocator := context.allocator) -> ^Static_State {
	assert(opts.root != "", "Static_Opts.root is required")
	st := new(Static_State, allocator)
	st.opts = opts
	if st.opts.index == "" && !st.opts.disable_index {
		st.opts.index = "index.html"
	}
	if st.opts.disable_index {
		st.opts.index = ""
	}
	// Absolute root via realpath (resolves symlinks on the root itself).
	root_abs, err := os.get_absolute_path(opts.root, allocator)
	if err != nil || root_abs == "" {
		// Fall back to clean join of cwd-relative path.
		cleaned, _ := filepath.clean(opts.root, allocator)
		root_abs = cleaned
	}
	// Drop trailing slash (keep "/" as-is).
	for len(root_abs) > 1 && (root_abs[len(root_abs) - 1] == '/' || root_abs[len(root_abs) - 1] == '\\') {
		root_abs = root_abs[:len(root_abs) - 1]
	}
	st.root_abs = root_abs
	if next != nil {
		st.next = next
	}
	st.terminal = terminal
	return st
}

@(private)
_static_serve :: proc(st: ^Static_State, req: ^http.Request, res: ^http.Response) {
	rline, has_line := req.line.?
	if !has_line {
		_static_not_found_or_next(st, req, res)
		return
	}

	// redirect_head_to_get: method becomes .Get with is_head=true.
	is_head := req.is_head || rline.method == .Head
	is_get_or_head := rline.method == .Get || rline.method == .Head || req.is_head
	if !is_get_or_head {
		if st.terminal {
			http.headers_set_unsafe(&res.headers, "allow", "GET, HEAD")
			http.respond(res, http.Status.Method_Not_Allowed)
		} else {
			_static_call_next(st, req, res)
		}
		return
	}

	req_path := req.url.path
	if req_path == "" {
		req_path = "/"
	}

	rel, rel_ok := static_resolve_rel(req_path, st.opts.strip_prefix, st.opts.serve_dotfiles)
	if !rel_ok {
		_static_not_found_or_next(st, req, res)
		return
	}

	// Build candidate filesystem path.
	full: string
	if rel == "" {
		full = st.root_abs
	} else {
		joined, jerr := filepath.join([]string{st.root_abs, rel}, context.temp_allocator)
		if jerr != nil {
			_static_not_found_or_next(st, req, res)
			return
		}
		full = joined
	}
	full_clean, fc_err := filepath.clean(full, context.temp_allocator)
	if fc_err != nil || !static_path_under_root(st.root_abs, full_clean) {
		_static_not_found_or_next(st, req, res)
		return
	}

	served_path, open_ok := _static_open_path(st, full_clean, is_head)
	if !open_ok {
		// SPA fallback (GET only; HEAD may still probe spa file).
		if st.opts.spa_fallback != "" && !is_head {
			spa_full, spa_ok := _static_spa_path(st)
			if spa_ok {
				served_path, open_ok = _static_open_path(st, spa_full, false)
			}
		} else if st.opts.spa_fallback != "" && is_head {
			spa_full, spa_ok := _static_spa_path(st)
			if spa_ok {
				served_path, open_ok = _static_open_path(st, spa_full, true)
			}
		}
	}
	if !open_ok {
		_static_not_found_or_next(st, req, res)
		return
	}

	_static_send_file(st, req, res, served_path, is_head)
}

@(private)
_static_spa_path :: proc(st: ^Static_State) -> (path: string, ok: bool) {
	fb := st.opts.spa_fallback
	// Normalize to URL path form for resolve (jail + dotfile checks).
	fb_path := fb
	if fb_path == "" {
		return "", false
	}
	if fb_path[0] != '/' {
		fb_path = strings.concatenate([]string{"/", fb_path}, context.temp_allocator)
	}
	rel, rel_ok := static_resolve_rel(fb_path, "", st.opts.serve_dotfiles)
	if !rel_ok {
		return "", false
	}
	joined, jerr := filepath.join([]string{st.root_abs, rel}, context.temp_allocator)
	if jerr != nil {
		return "", false
	}
	cleaned, cerr := filepath.clean(joined, context.temp_allocator)
	if cerr != nil || !static_path_under_root(st.root_abs, cleaned) {
		return "", false
	}
	return cleaned, true
}

// Open/stat path; apply index for directories. Returns absolute path of regular file.
// Package-private for integration tests.
@(private)
_static_open_path :: proc(st: ^Static_State, path: string, is_head: bool) -> (out_path: string, ok: bool) {
	_ = is_head
	when ODIN_OS == .Windows {
		// Windows: basic path checks; full sendfile path is POSIX-oriented.
		if !os.is_file(path) {
			if os.is_directory(path) && st.opts.index != "" {
				idx, _ := filepath.join([]string{path, st.opts.index}, context.temp_allocator)
				if os.is_file(idx) {
					return idx, true
				}
			}
			return "", false
		}
		if !st.opts.follow_symlinks {
			// Best-effort: lstat if available.
			info, err := os.lstat(path, context.temp_allocator)
			if err == nil && info.type == .Symlink {
				os.file_info_delete(info, context.temp_allocator)
				return "", false
			}
			if err == nil {
				os.file_info_delete(info, context.temp_allocator)
			}
		}
		return path, true
	} else {
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		stbuf: posix.stat_t
		// Prefer lstat when not following symlinks.
		use_lstat := !st.opts.follow_symlinks
		rc: posix.result
		if use_lstat {
			rc = posix.lstat(cpath, &stbuf)
		} else {
			rc = posix.stat(cpath, &stbuf)
		}
		if rc != .OK {
			return "", false
		}
		if use_lstat && posix.S_ISLNK(stbuf.st_mode) {
			return "", false
		}
		if posix.S_ISDIR(stbuf.st_mode) {
			if st.opts.index == "" {
				return "", false // no listing
			}
			idx, _ := filepath.join([]string{path, st.opts.index}, context.temp_allocator)
			return _static_open_path(st, idx, is_head)
		}
		if !posix.S_ISREG(stbuf.st_mode) {
			return "", false
		}
		if st.opts.follow_symlinks {
			// realpath and re-jail.
			real, rerr := os.get_absolute_path(path, context.temp_allocator)
			if rerr != nil || !static_path_under_root(st.root_abs, real) {
				return "", false
			}
			return real, true
		}
		return path, true
	}
}

// Open/stat + validators + Range/ETag and set http.body_file (or 304/416). Does NOT call respond.
// ok=false → open/stat failed (caller should 404/next). On ok, res is fully prepared:
//   304 / 416: no body cmds; fd already closed.
//   200 / 206: prefer_sendfile + Owned File cmd; caller must http.respond() (wire closes) or
//              http.response_close_owned_body_files if abandoning without wire transfer.
// Package-private so tests can assert http.body_file path without a live server.
@(private)
_static_prepare_file :: proc(st: ^Static_State, req: ^http.Request, res: ^http.Response, path: string, is_head: bool) -> bool {
	when ODIN_OS == .Windows {
		// Full-read fallback on Windows (no sendfile host path). Limited Range/validators.
		_ = is_head
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return false
		}
		http.headers_set_content_type(
			&res.headers,
			http.mime_content_type_for_path_extra(path, st.opts.extra_mimes),
		)
		_static_set_cache_headers(st, res)
		res.status = .OK
		if !is_head {
			http.body_set_bytes(res, data)
		}
		return true
	} else {
		_ = is_head // HEAD still sets http.body_file; wire strips body and closes Owned (RFC 9110).
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		flags: posix.O_Flags
		if !st.opts.follow_symlinks {
			flags += {.NOFOLLOW}
		}
		fd := posix.open(cpath, flags)
		if fd < 0 {
			return false
		}

		stbuf: posix.stat_t
		if posix.fstat(fd, &stbuf) != .OK {
			_ = posix.close(fd)
			return false
		}
		if !posix.S_ISREG(stbuf.st_mode) {
			_ = posix.close(fd)
			return false
		}

		size := i64(stbuf.st_size)
		mtime_nsec := i64(stbuf.st_mtim.tv_sec) * 1_000_000_000 + i64(stbuf.st_mtim.tv_nsec)
		mtime := time.Time{_nsec = mtime_nsec}
		inode := u64(stbuf.st_ino)

		etag: string
		if !st.opts.disable_etag {
			etag = static_etag_format(size, mtime_nsec, inode)
			http.headers_set_unsafe(&res.headers, "etag", etag)
		}

		lm_http: string
		if !st.opts.disable_last_modified {
			lm_http = http.date_string(mtime, context.temp_allocator)
			http.headers_set_unsafe(&res.headers, "last-modified", lm_http)
		}

		_static_set_cache_headers(st, res)

		http.headers_set_content_type(
			&res.headers,
			http.mime_content_type_for_path_extra(path, st.opts.extra_mimes),
		)

		// Conditional GET: If-None-Match priority over If-Modified-Since.
		if inm, has := http.headers_get_unsafe(req.headers, "if-none-match"); has && !st.opts.disable_etag {
			if static_if_none_match(etag, inm) {
				_ = posix.close(fd)
				res.status = .Not_Modified
				return true
			}
		} else if ims, has := http.headers_get_unsafe(req.headers, "if-modified-since"); has && !st.opts.disable_last_modified {
			if static_if_modified_since(mtime, ims) {
				_ = posix.close(fd)
				res.status = .Not_Modified
				return true
			}
		}

		// Ranges.
		off: i64 = 0
		length := size
		status := http.Status.OK

		if !st.opts.disable_ranges {
			http.headers_set_unsafe(&res.headers, "accept-ranges", "bytes")
			if rh, has_r := http.headers_get_unsafe(req.headers, "range"); has_r {
				apply_range := true
				if ir, has_ir := http.headers_get_unsafe(req.headers, "if-range"); has_ir {
					apply_range = static_if_range_allows(ir, etag, lm_http)
				}
				if apply_range {
					start, end, rok, unsat := static_parse_byte_range(rh, size)
					if unsat {
						_ = posix.close(fd)
						http.headers_set_unsafe(&res.headers, "content-range", static_content_range_fmt(-1, 0, size))
						// 416 has no body.
						res.status = .Range_Not_Satisfiable
						return true
					}
					if rok {
						off = start
						length = end - start + 1
						status = .Partial_Content
						http.headers_set_unsafe(&res.headers, "content-range", static_content_range_fmt(start, end, size))
					}
				}
			}
		}

		// Prefer sendfile / chunked file stream even when server plan_optimize is off.
		// Default path is http.body_file (not full read) — wire uses Sendfile or materialize pread.
		http.response_set_profile(res, http.Handler_Profile{prefer_sendfile = true})
		res.status = status
		http.body_file(res, i32(fd), off, length, owned = true)
		return true
	}
}

@(private)
_static_send_file :: proc(st: ^Static_State, req: ^http.Request, res: ^http.Response, path: string, is_head: bool) {
	if !_static_prepare_file(st, req, res, path, is_head) {
		_static_not_found_or_next(st, req, res)
		return
	}
	http.respond(res)
}

@(private)
_static_set_cache_headers :: proc(st: ^Static_State, res: ^http.Response) {
	if st.opts.max_age_secs <= 0 && !st.opts.immutable {
		return
	}
	max_age := st.opts.max_age_secs
	if st.opts.immutable && max_age <= 0 {
		max_age = 31536000 // 1y default for fingerprinted assets
	}
	if st.opts.immutable {
		http.headers_set_unsafe(&res.headers, "cache-control", fmt.tprintf("public, max-age=%d, immutable", max_age))
	} else {
		http.headers_set_unsafe(&res.headers, "cache-control", fmt.tprintf("public, max-age=%d", max_age))
	}
}

@(private)
_static_not_found_or_next :: proc(st: ^Static_State, req: ^http.Request, res: ^http.Response) {
	if st.terminal {
		http.respond(res, http.Status.Not_Found)
	} else {
		_static_call_next(st, req, res)
	}
}

@(private)
_static_call_next :: proc(st: ^Static_State, req: ^http.Request, res: ^http.Response) {
	if next, ok := st.next.?; ok && next != nil {
		next.handle(next, req, res)
		return
	}
	http.respond(res, http.Status.Not_Found)
}
