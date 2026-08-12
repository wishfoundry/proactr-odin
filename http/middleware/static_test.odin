package middleware

/*
Unit tests for static file helpers (path jail, Range, ETag, If-Range, validators)
plus integration-style tests: OS temp dir, real open, prepare → body_file cmds.
No live server — package-private _static_prepare_file (same path static_handler uses
before respond) so Range/304/HEAD ownership can be asserted without network.
*/

import "core:fmt"
import "core:os"
import http ".."
import "core:path/filepath"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
test_static_resolve_rel_basic :: proc(t: ^testing.T) {
	rel, ok := static_resolve_rel("/foo/bar.txt", "", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "foo/bar.txt")

	rel, ok = static_resolve_rel("/", "", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "")

	rel, ok = static_resolve_rel("/static/a.js", "/static", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "a.js")

	rel, ok = static_resolve_rel("/static", "/static", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "")
}

@(test)
test_static_resolve_rel_escape :: proc(t: ^testing.T) {
	// Absolute URL paths with ".." clean to an absolute path still rooted at "/".
	// That becomes a relative name under the static root (not a host FS escape).
	// Lexical FS jail is static_path_under_root after join(root, rel).
	rel, ok := static_resolve_rel("/../etc/passwd", "", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "etc/passwd")

	rel, ok = static_resolve_rel("/foo/../../etc/passwd", "", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "etc/passwd")

	// Relative request that retains ".." after clean must be rejected.
	_, ok = static_resolve_rel("../../../etc/passwd", "", false)
	testing.expect(t, !ok)

	// Percent-encoded ".." same as absolute clean → rel under root name space.
	rel, ok = static_resolve_rel("/%2e%2e/etc/passwd", "", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "etc/passwd")

	// Full jail: join + clean must stay under root_abs.
	root := "/var/www"
	joined := "/var/www/../etc/passwd" // would be used if join were wrong
	// simulate cleaned candidate outside root
	testing.expect(t, !static_path_under_root(root, "/var/etc/passwd"))
	testing.expect(t, static_path_under_root(root, "/var/www/etc/passwd"))
	_ = joined
	_ = rel
}

@(test)
test_static_resolve_rel_null_and_strip :: proc(t: ^testing.T) {
	// Embedded NUL
	_, ok := static_resolve_rel("/foo\x00/bar", "", false)
	testing.expect(t, !ok)

	// strip_prefix mismatch
	_, ok = static_resolve_rel("/other/a", "/static", false)
	testing.expect(t, !ok)

	// Invalid percent encoding
	_, ok = static_resolve_rel("/%zz", "", false)
	testing.expect(t, !ok)
}

@(test)
test_static_resolve_rel_dotfiles :: proc(t: ^testing.T) {
	_, ok := static_resolve_rel("/.env", "", false)
	testing.expect(t, !ok)

	_, ok = static_resolve_rel("/foo/.git/config", "", false)
	testing.expect(t, !ok)

	rel: string
	rel, ok = static_resolve_rel("/.env", "", true)
	testing.expect(t, ok)
	testing.expect_value(t, rel, ".env")

	// ".well-known" is still a dot segment — denied by default.
	_, ok = static_resolve_rel("/.well-known/acme", "", false)
	testing.expect(t, !ok)
}

@(test)
test_static_path_has_dot_segment :: proc(t: ^testing.T) {
	testing.expect(t, static_path_has_dot_segment(".env"))
	testing.expect(t, static_path_has_dot_segment("a/.b/c"))
	testing.expect(t, !static_path_has_dot_segment("a/b/c"))
	testing.expect(t, !static_path_has_dot_segment(""))
	testing.expect(t, !static_path_has_dot_segment("foo.bar"))
}

@(test)
test_static_path_under_root :: proc(t: ^testing.T) {
	testing.expect(t, static_path_under_root("/var/www", "/var/www"))
	testing.expect(t, static_path_under_root("/var/www", "/var/www/index.html"))
	testing.expect(t, !static_path_under_root("/var/www", "/var/www_evil"))
	testing.expect(t, !static_path_under_root("/var/www", "/var/www2/x"))
	testing.expect(t, !static_path_under_root("/var/www", "/etc/passwd"))
	testing.expect(t, !static_path_under_root("/var/www", "/var/ww"))

	// FS root mount: every absolute path is under "/".
	testing.expect(t, static_path_under_root("/", "/"))
	testing.expect(t, static_path_under_root("/", "/etc/passwd"))
	testing.expect(t, static_path_under_root("/", "/var/www/index.html"))
}

@(test)
test_static_parse_byte_range :: proc(t: ^testing.T) {
	// bytes=start-end
	s, e, ok, unsat := static_parse_byte_range("bytes=0-499", 1000)
	testing.expect(t, ok && !unsat)
	testing.expect_value(t, s, i64(0))
	testing.expect_value(t, e, i64(499))

	// open end
	s, e, ok, unsat = static_parse_byte_range("bytes=500-", 1000)
	testing.expect(t, ok && !unsat)
	testing.expect_value(t, s, i64(500))
	testing.expect_value(t, e, i64(999))

	// suffix
	s, e, ok, unsat = static_parse_byte_range("bytes=-100", 1000)
	testing.expect(t, ok && !unsat)
	testing.expect_value(t, s, i64(900))
	testing.expect_value(t, e, i64(999))

	// clamp end
	s, e, ok, unsat = static_parse_byte_range("bytes=0-9999", 1000)
	testing.expect(t, ok && !unsat)
	testing.expect_value(t, e, i64(999))

	// unsatisfiable: start past end
	_, _, ok, unsat = static_parse_byte_range("bytes=1000-1001", 1000)
	testing.expect(t, !ok && unsat)

	// unsatisfiable empty file open range
	_, _, ok, unsat = static_parse_byte_range("bytes=0-", 0)
	testing.expect(t, !ok && unsat)

	// multi-range ignored (not unsatisfiable)
	_, _, ok, unsat = static_parse_byte_range("bytes=0-1,2-3", 1000)
	testing.expect(t, !ok && !unsat)

	// malformed
	_, _, ok, unsat = static_parse_byte_range("items=0-1", 1000)
	testing.expect(t, !ok && !unsat)

	_, _, ok, unsat = static_parse_byte_range("bytes=5-1", 1000)
	testing.expect(t, !ok && !unsat)
}

@(test)
test_static_etag_and_if_none_match :: proc(t: ^testing.T) {
	tag := static_etag_format(100, 123456789, 42)
	testing.expect(t, tag[0] == '"')
	testing.expect(t, tag[len(tag) - 1] == '"')

	testing.expect(t, static_if_none_match(tag, tag))
	testing.expect(t, static_if_none_match(tag, "*"))
	// weak compare for If-None-Match
	weak := fmt.tprintf("W/%s", tag)
	testing.expect(t, static_if_none_match(tag, weak))
	list := fmt.tprintf("\"other\", %s", tag)
	testing.expect(t, static_if_none_match(tag, list))
	testing.expect(t, !static_if_none_match(tag, `"nope"`))
	testing.expect(t, !static_if_none_match(tag, ""))
}

@(test)
test_static_if_modified_since :: proc(t: ^testing.T) {
	// Fri, 05 Feb 2023 09:01:10 GMT
	mt, ok := http.date_parse("Fri, 05 Feb 2023 09:01:10 GMT")
	testing.expect(t, ok)

	testing.expect(t, static_if_modified_since(mt, "Fri, 05 Feb 2023 09:01:10 GMT"))
	testing.expect(t, static_if_modified_since(mt, "Fri, 05 Feb 2023 09:01:11 GMT"))
	testing.expect(t, !static_if_modified_since(mt, "Fri, 05 Feb 2023 09:01:09 GMT"))
	testing.expect(t, !static_if_modified_since(mt, "not-a-date"))

	// Sub-second mtime still compares at second resolution via unix seconds.
	mt2 := time.Time{_nsec = time.time_to_unix_nano(mt) + 500_000_000}
	testing.expect(t, static_if_modified_since(mt2, "Fri, 05 Feb 2023 09:01:10 GMT"))
}

@(test)
test_static_if_range_allows :: proc(t: ^testing.T) {
	etag := `"100-200"`
	lm := "Fri, 05 Feb 2023 09:01:10 GMT"

	// No If-Range → allow
	testing.expect(t, static_if_range_allows("", etag, lm))

	// Matching strong etag
	testing.expect(t, static_if_range_allows(etag, etag, lm))

	// Weak etag must not allow Range
	testing.expect(t, !static_if_range_allows(`W/"100-200"`, etag, lm))

	// Mismatched etag
	testing.expect(t, !static_if_range_allows(`"other"`, etag, lm))

	// Matching date
	testing.expect(t, static_if_range_allows(lm, etag, lm))

	// Mismatched date
	testing.expect(t, !static_if_range_allows("Fri, 05 Feb 2023 09:01:11 GMT", etag, lm))
}

@(test)
test_static_content_range_fmt :: proc(t: ^testing.T) {
	testing.expect_value(t, static_content_range_fmt(0, 499, 1000), "bytes 0-499/1000")
	testing.expect_value(t, static_content_range_fmt(-1, 0, 1000), "bytes */1000")
}

@(test)
test_static_resolve_rel_clean_dots :: proc(t: ^testing.T) {
	// Redundant . and // cleaned
	rel, ok := static_resolve_rel("/a/./b//c", "", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "a/b/c")

	// Internal .. that stays under root
	rel, ok = static_resolve_rel("/a/b/../c", "", false)
	testing.expect(t, ok)
	testing.expect_value(t, rel, "a/c")
}

@(test)
test_cmd_file_owned_flag :: proc(t: ^testing.T) {
	c := http.cmd_file(3, 0, 10, owned = true)
	testing.expect(t, .Owned in c.flags)
	testing.expect(t, .Known_Length in c.flags)
	c2 := http.cmd_file(3, 0, 10)
	testing.expect(t, .Owned not_in c2.flags)
}

@(test)
test_static_content_type_html_charset :: proc(t: ^testing.T) {
	// Static path must emit charset for HTML/CSS/JS and octet-stream for unknown.
	testing.expect_value(t, http.mime_content_type_for_path("x.HTML"), "text/html; charset=utf-8")
	testing.expect_value(t, http.mime_content_type_for_path("x.bin"), "application/octet-stream")
	extra := []http.Mime_Extra{{ext = ".gltf", content_type = "model/gltf+json"}}
	testing.expect_value(t, http.mime_content_type_for_path_extra("a.gltf", extra), "model/gltf+json")
}

// Integration: temp dir + real open/prepare (no live server)

@(private = "file")
_static_test_fixture :: proc(t: ^testing.T) -> (dir, file_path: string, body: string, ok: bool) {
	when ODIN_OS == .Windows {
		// Elite prepare path is POSIX; Windows uses full-read stub.
		return "", "", "", false
	} else {
		tmp, err := os.make_directory_temp("", "proactr-static-*", context.allocator)
		if err != nil {
			testing.expectf(t, false, "make_directory_temp: %v", err)
			return "", "", "", false
		}
		body = "Hello, static world!\n" // 21 bytes
		joined, jerr := filepath.join([]string{tmp, "hello.txt"}, context.allocator)
		if jerr != nil {
			_ = os.remove_all(tmp)
			testing.expectf(t, false, "filepath.join: %v", jerr)
			return "", "", "", false
		}
		werr := os.write_entire_file(joined, transmute([]byte)body)
		if werr != nil {
			_ = os.remove_all(tmp)
			delete(joined)
			testing.expectf(t, false, "write_entire_file: %v", werr)
			return "", "", "", false
		}
		return tmp, joined, body, true
	}
}

@(private = "file")
_static_test_free_state :: proc(st: ^Static_State) {
	if st == nil {
		return
	}
	if st.root_abs != "" {
		delete(st.root_abs)
	}
	free(st)
}

@(private = "file")
_static_test_cleanup :: proc(dir: string, res: ^http.Response) {
	if res != nil {
		http.response_close_owned_body_files(res)
	}
	if dir != "" {
		_ = os.remove_all(dir)
		delete(dir)
	}
}

@(private = "file")
_static_test_req_res :: proc(method: http.Method, path: string) -> (req: http.Request, res: http.Response) {
	http.request_init(&req)
	req.line = http.Requestline{method = method, target = path, version = {1, 1}}
	req.url.path = path
	req.is_head = method == .Head
	http.headers_init(&res.headers, context.allocator)
	return
}

@(test)
test_static_prepare_get_body_file :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir, fpath, body, ok := _static_test_fixture(t)
		if !ok {
			return
		}
		defer delete(fpath)

		st := _static_state_new(Static_Opts{root = dir}, nil, true)
		defer _static_test_free_state(st)

		req, res := _static_test_req_res(.Get, "/hello.txt")
		defer http.headers_destroy(&req.headers)
		defer http.headers_destroy(&res.headers)
		defer _static_test_cleanup(dir, &res)

		opened, open_ok := _static_open_path(st, fpath, false)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req, &res, opened, false))

		// Default path: body_file + prefer_sendfile, not full read into Bytes.
		testing.expect_value(t, res.status, http.Status.OK)
		testing.expect(t, http.response_prefer_sendfile(&res))
		testing.expect_value(t, http.response_body_cmd_count(&res), 1)
		c, c_ok := http.response_body_cmd(&res, 0)
		testing.expect(t, c_ok)
		testing.expect_value(t, c.kind, http.Response_Cmd_Kind.File)
		testing.expect(t, .Owned in c.flags)
		testing.expect_value(t, c.offset, i64(0))
		testing.expect_value(t, c.length, i64(len(body)))
		testing.expect(t, c.fd >= 0)

		ct, has_ct := http.headers_get_unsafe(res.headers, "content-type")
		testing.expect(t, has_ct)
		testing.expect_value(t, ct, "text/plain; charset=utf-8")
		_, has_ar := http.headers_get_unsafe(res.headers, "accept-ranges")
		testing.expect(t, has_ar)
		etag, has_etag := http.headers_get_unsafe(res.headers, "etag")
		testing.expect(t, has_etag)
		testing.expect(t, len(etag) > 2)
	}
}

@(test)
test_static_prepare_range_206 :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir, fpath, body, ok := _static_test_fixture(t)
		if !ok {
			return
		}
		defer delete(fpath)

		st := _static_state_new(Static_Opts{root = dir}, nil, true)
		defer _static_test_free_state(st)

		req, res := _static_test_req_res(.Get, "/hello.txt")
		http.headers_set_unsafe(&req.headers, "range", "bytes=0-4")
		defer http.headers_destroy(&req.headers)
		defer http.headers_destroy(&res.headers)
		defer _static_test_cleanup(dir, &res)

		opened, open_ok := _static_open_path(st, fpath, false)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req, &res, opened, false))

		testing.expect_value(t, res.status, http.Status.Partial_Content)
		testing.expect_value(t, http.response_body_cmd_count(&res), 1)
		c, c_ok := http.response_body_cmd(&res, 0)
		testing.expect(t, c_ok)
		testing.expect_value(t, c.kind, http.Response_Cmd_Kind.File)
		testing.expect_value(t, c.offset, i64(0))
		testing.expect_value(t, c.length, i64(5)) // bytes 0-4 inclusive
		cr, has_cr := http.headers_get_unsafe(res.headers, "content-range")
		testing.expect(t, has_cr)
		want_cr := fmt.tprintf("bytes 0-4/%v", len(body))
		testing.expect_value(t, cr, want_cr)
	}
}

@(test)
test_static_prepare_range_416 :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir, fpath, body, ok := _static_test_fixture(t)
		if !ok {
			return
		}
		defer delete(fpath)

		st := _static_state_new(Static_Opts{root = dir}, nil, true)
		defer _static_test_free_state(st)

		req, res := _static_test_req_res(.Get, "/hello.txt")
		http.headers_set_unsafe(&req.headers, "range", "bytes=9999-10000")
		defer http.headers_destroy(&req.headers)
		defer http.headers_destroy(&res.headers)
		defer _static_test_cleanup(dir, &res)

		opened, open_ok := _static_open_path(st, fpath, false)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req, &res, opened, false))

		testing.expect_value(t, res.status, http.Status.Range_Not_Satisfiable)
		testing.expect_value(t, http.response_body_cmd_count(&res), 0) // fd closed, no body
		cr, has_cr := http.headers_get_unsafe(res.headers, "content-range")
		testing.expect(t, has_cr)
		want_cr := fmt.tprintf("bytes */%v", len(body))
		testing.expect_value(t, cr, want_cr)
	}
}

@(test)
test_static_prepare_if_range_match_and_mismatch :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir, fpath, _, ok := _static_test_fixture(t)
		if !ok {
			return
		}
		defer delete(fpath)

		st := _static_state_new(Static_Opts{root = dir}, nil, true)
		defer _static_test_free_state(st)

		// First prepare full GET to capture ETag.
		req0, res0 := _static_test_req_res(.Get, "/hello.txt")
		defer http.headers_destroy(&req0.headers)
		defer http.headers_destroy(&res0.headers)
		opened, open_ok := _static_open_path(st, fpath, false)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req0, &res0, opened, false))
		etag, has_etag := http.headers_get_unsafe(res0.headers, "etag")
		testing.expect(t, has_etag)
		http.response_close_owned_body_files(&res0)

		// Match: Range applied → 206.
		req_m, res_m := _static_test_req_res(.Get, "/hello.txt")
		http.headers_set_unsafe(&req_m.headers, "range", "bytes=1-3")
		http.headers_set_unsafe(&req_m.headers, "if-range", etag)
		defer http.headers_destroy(&req_m.headers)
		defer http.headers_destroy(&res_m.headers)
		opened, open_ok = _static_open_path(st, fpath, false)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req_m, &res_m, opened, false))
		testing.expect_value(t, res_m.status, http.Status.Partial_Content)
		cm, cm_ok := http.response_body_cmd(&res_m, 0)
		testing.expect(t, cm_ok)
		testing.expect_value(t, cm.offset, i64(1))
		testing.expect_value(t, cm.length, i64(3))
		http.response_close_owned_body_files(&res_m)

		// Mismatch: full 200 (Range ignored).
		req_x, res_x := _static_test_req_res(.Get, "/hello.txt")
		http.headers_set_unsafe(&req_x.headers, "range", "bytes=1-3")
		http.headers_set_unsafe(&req_x.headers, "if-range", `"nope-etag"`)
		defer http.headers_destroy(&req_x.headers)
		defer http.headers_destroy(&res_x.headers)
		defer _static_test_cleanup(dir, &res_x)
		opened, open_ok = _static_open_path(st, fpath, false)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req_x, &res_x, opened, false))
		testing.expect_value(t, res_x.status, http.Status.OK)
		cx, cx_ok := http.response_body_cmd(&res_x, 0)
		testing.expect(t, cx_ok)
		testing.expect_value(t, cx.offset, i64(0))
		testing.expect(t, cx.length > 3)
	}
}

@(test)
test_static_prepare_if_none_match_304 :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir, fpath, _, ok := _static_test_fixture(t)
		if !ok {
			return
		}
		defer delete(fpath)

		st := _static_state_new(Static_Opts{root = dir}, nil, true)
		defer _static_test_free_state(st)

		req0, res0 := _static_test_req_res(.Get, "/hello.txt")
		defer http.headers_destroy(&req0.headers)
		defer http.headers_destroy(&res0.headers)
		opened, open_ok := _static_open_path(st, fpath, false)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req0, &res0, opened, false))
		etag, has_etag := http.headers_get_unsafe(res0.headers, "etag")
		testing.expect(t, has_etag)
		http.response_close_owned_body_files(&res0)

		req, res := _static_test_req_res(.Get, "/hello.txt")
		http.headers_set_unsafe(&req.headers, "if-none-match", etag)
		defer http.headers_destroy(&req.headers)
		defer http.headers_destroy(&res.headers)
		defer _static_test_cleanup(dir, &res)

		opened, open_ok = _static_open_path(st, fpath, false)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req, &res, opened, false))
		testing.expect_value(t, res.status, http.Status.Not_Modified)
		testing.expect_value(t, http.response_body_cmd_count(&res), 0) // short-circuit; fd closed
	}
}

@(test)
test_static_prepare_head_owned_fd_closed :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir, fpath, body, ok := _static_test_fixture(t)
		if !ok {
			return
		}
		defer delete(fpath)

		st := _static_state_new(Static_Opts{root = dir}, nil, true)
		defer _static_test_free_state(st)

		req, res := _static_test_req_res(.Head, "/hello.txt")
		defer http.headers_destroy(&req.headers)
		defer http.headers_destroy(&res.headers)
		// cleanup only removes dir if no cmds left
		defer if dir != "" {
			_ = os.remove_all(dir)
			delete(dir)
		}

		opened, open_ok := _static_open_path(st, fpath, true)
		testing.expect(t, open_ok)
		testing.expect(t, _static_prepare_file(st, &req, &res, opened, true))

		// HEAD still stages body_file (wire will strip body); prove Owned + correct region.
		testing.expect_value(t, res.status, http.Status.OK)
		testing.expect_value(t, http.response_body_cmd_count(&res), 1)
		c, c_ok := http.response_body_cmd(&res, 0)
		testing.expect(t, c_ok)
		testing.expect_value(t, c.kind, http.Response_Cmd_Kind.File)
		testing.expect(t, .Owned in c.flags)
		testing.expect_value(t, c.length, i64(len(body)))
		fd := c.fd
		testing.expect(t, fd >= 0)

		// Materialize HEAD path: close Owned without reading body.
		http.response_close_owned_body_files(&res)

		// fd must be closed (fstat → EBADF).
		stbuf: posix.stat_t
		rc := posix.fstat(posix.FD(fd), &stbuf)
		testing.expect(t, rc != .OK)
	}
}

@(test)
test_static_mount_sets_strip_prefix :: proc(t: ^testing.T) {
	// static_mount is sugar for static_handler(Static_Opts{root, strip_prefix}).
	// Verify the handler's Static_State without serving.
	when ODIN_OS != .Windows {
		dir, err := os.make_directory_temp("", "proactr-mount-*", context.allocator)
		if err != nil {
			testing.expectf(t, false, "make_directory_temp: %v", err)
			return
		}
		defer {
			_ = os.remove_all(dir)
			delete(dir)
		}
		h := static_mount("/assets", dir)
		st := (^Static_State)(h.user_data)
		testing.expect(t, st != nil)
		defer _static_test_free_state(st)
		testing.expect_value(t, st.opts.strip_prefix, "/assets")
		testing.expect_value(t, st.opts.root, dir)
		// Resolve a strip_prefix path through pure helper.
		rel, ok := static_resolve_rel("/assets/x.js", st.opts.strip_prefix, false)
		testing.expect(t, ok)
		testing.expect_value(t, rel, "x.js")
	}
}
