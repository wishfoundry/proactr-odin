package http

import "core:encoding/json"
import "core:io"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Sets the response to one that sends the given HTML.
respond_html :: proc(r: ^Response, html: string, status: Status = .OK, loc := #caller_location) {
	r.status = status
	headers_set_content_type(&r.headers, mime_to_content_type(Mime_Type.Html))
	body_set(r, html, loc)
	respond(r, loc)
}

// Sets the response to one that sends the given plain text.
respond_plain :: proc(r: ^Response, text: string, status: Status = .OK, loc := #caller_location) {
	r.status = status
	headers_set_content_type(&r.headers, mime_to_content_type(Mime_Type.Plain))
	body_set(r, text, loc)
	respond(r, loc)
}

/*
Sends the content of the file at the given path as the response.

Phase 0: synchronous read (no nbio). Phase 2 may reintroduce completion-based file I/O via proactr.

The content type is taken from the path, optionally overwritten using the parameter.

If the file doesn't exist, a 404 response is sent.
If any other error occurs, a 500 is sent and the error is logged.
*/
respond_file :: proc(r: ^Response, path: string, content_type: Maybe(Mime_Type) = nil, loc := #caller_location) {
	assert_has_td(loc)
	assert(!r.sent, "response has already been sent", loc)

	mime := content_type.? or_else mime_from_extension(path)
	headers_set_content_type(&r.headers, mime_to_content_type(mime))

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.debugf("respond_file, read %q error: %v", path, err)
		respond_with_status(r, .Not_Found)
		return
	}

	body_set_bytes(r, data, loc)
	respond_with_status(r, .OK)
}

/*
Responds with the given content, determining content type from the given path.

This is very useful when you want to `#load(path)` at compile time and respond with that.
*/
respond_file_content :: proc(r: ^Response, path: string, content: []byte, status: Status = .OK, loc := #caller_location) {
	mime := mime_from_extension(path)
	content_type := mime_to_content_type(mime)

	r.status = status
	headers_set_content_type(&r.headers, content_type)
	body_set(r, content, loc)
	respond(r, loc)
}

/*
Sets the response to one that, based on the request path, returns a file.
base:    The base of the request path that should be removed when retrieving the file.
target:  The path to the directory to serve.
request: The request path.

Path traversal is detected and cleaned up.
The Content-Type is set based on the file extension, see the MimeType enum for known file extensions.
*/
respond_dir :: proc(r: ^Response, base, target, request: string, loc := #caller_location) {
	if !strings.has_prefix(request, base) {
		respond(r, Status.Not_Found)
		return
	}

	// Detect path traversal attacks.
	req_clean, err_req   := filepath.clean(request, context.temp_allocator)
	base_clean, err_base := filepath.clean(base, context.temp_allocator)
	if err_req != nil || err_base != nil || !strings.has_prefix(req_clean, base_clean) {
		respond(r, Status.Not_Found)
		return
	}

	file_path, _ := filepath.join([]string{"./", target, strings.trim_prefix(req_clean, base_clean)}, context.temp_allocator)
	respond_file(r, file_path, loc = loc)
}

// Sets the response to one that returns the JSON representation of the given value.
respond_json :: proc(r: ^Response, v: any, status: Status = .OK, opt: json.Marshal_Options = {}, loc := #caller_location) -> (err: json.Marshal_Error) {
	opt := opt

	r.status = status
	headers_set_content_type(&r.headers, mime_to_content_type(Mime_Type.Json))

	// Going to write a MINIMUM of 128 bytes at a time.
	rw:  Response_Writer
	buf: [128]byte
	response_writer_init(&rw, r, buf[:])

	// Ends the body and sends the response.
	defer io.close(rw.w)

	if err = json.marshal_to_writer(rw.w, v, &opt); err != nil {
		headers_set_close(&r.headers)
		response_status(r, .Internal_Server_Error)
	}

	return
}

// Status / redirect / problem helpers (oneshot; App Contract body_* + respond)

/*
Pure status with no body. Prefer this name over respond(r, status).

Same as respond_with_status (also in the `respond` procedure group).
Does not clear existing body cmds — call before body_set, or use when no body is set.
*/
respond_status :: proc(r: ^Response, status: Status, loc := #caller_location) {
	respond_with_status(r, status, loc)
}

/*
HTTP 204 No Content. No body (and no Content-Length on wire).

Asserts no body cmds / reserve / writer have been started.
*/
respond_no_content :: proc(r: ^Response, loc := #caller_location) {
	assert_has_td(loc)
	assert(!r.sent, "response has already been sent", loc)
	assert(r._cmd_count == 0, "respond_no_content: body cmds already set", loc)
	assert(!r._heading_written, "respond_no_content: heading already written", loc)
	assert(r._body_off == 0, "respond_no_content: body_reserve in progress", loc)
	assert(!r._streaming, "respond_no_content: stream started", loc)
	response_status(r, .No_Content)
	respond(r, loc)
}

/*
HTTP redirect: sets Location and a 3xx status, then sends with no body.

Default status is .Found (302). Common: .Moved_Permanently (301), .See_Other (303),
.Temporary_Redirect (307), .Permanent_Redirect (308).

`location` must remain valid until the response wire completes (literal / request arena).
*/
respond_redirect :: proc(
	r: ^Response,
	location: string,
	status: Status = .Found,
	loc := #caller_location,
) {
	assert_has_td(loc)
	assert(!r.sent, "response has already been sent", loc)
	assert(r._cmd_count == 0, "respond_redirect: body cmds already set", loc)
	assert(!r._heading_written, "respond_redirect: heading already written", loc)
	assert(r._body_off == 0, "respond_redirect: body_reserve in progress", loc)
	assert(!r._streaming, "respond_redirect: stream started", loc)
	assert(status_is_redirect(status), "respond_redirect: status must be 3xx redirect", loc)
	assert(location != "", "respond_redirect: empty location", loc)

	headers_set(&r.headers, "location", location)
	response_status(r, status)
	respond(r, loc)
}

// RFC 7807 Problem Details (application/problem+json).
// Empty optional strings are still marshaled (Odin json); pass only what you need.
Problem :: struct {
	type:     string, // URI; default "about:blank"
	title:    string,
	status:   int,    // HTTP status as number in the body
	detail:   string,
	instance: string, // URI of this occurrence
}

/*
RFC 7807 problem+json error response.

Sets Content-Type application/problem+json, marshals Problem, and responds.
On marshal failure, closes connection and sends 500 (same pattern as respond_json).
*/
respond_problem :: proc(
	r: ^Response,
	status: Status,
	title: string,
	detail: string = "",
	type: string = "about:blank",
	instance: string = "",
	loc := #caller_location,
) -> (
	err: json.Marshal_Error,
) {
	assert_has_td(loc)
	assert(!r.sent, "response has already been sent", loc)

	r.status = status
	headers_set_content_type(&r.headers, "application/problem+json")

	prob := Problem {
		type     = type if type != "" else "about:blank",
		title    = title,
		status   = int(status),
		detail   = detail,
		instance = instance,
	}

	rw:  Response_Writer
	buf: [128]byte
	response_writer_init(&rw, r, buf[:])
	defer io.close(rw.w)

	opt: json.Marshal_Options
	if err = json.marshal_to_writer(rw.w, prob, &opt); err != nil {
		headers_set_close(&r.headers)
		response_status(r, .Internal_Server_Error)
	}
	return
}

/*
Prefer the procedure group `respond`.
*/
respond_with_none :: proc(r: ^Response, loc := #caller_location) {
	assert_has_td(loc)

	conn := r._conn
	req  := conn.loop.req

	// Respond as head request if we set it to get.
	if rline, ok := req.line.(Requestline); ok && req.is_head && conn.server.opts.redirect_head_to_get {
		rline.method = .Head
	}

	response_send(r, conn, loc)
}

/*
Prefer the procedure group `respond`.
Also available as respond_status for a clearer product name.
*/
respond_with_status :: proc(r: ^Response, status: Status, loc := #caller_location) {
	response_status(r, status)
	respond(r, loc)
}

// Sends the response back to the client, handlers should call this.
respond :: proc {
	respond_with_none,
	respond_with_status,
}
