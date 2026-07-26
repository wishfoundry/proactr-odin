#+private
package http

import "base:intrinsics"
import "base:runtime"

import "core:bufio"
import "core:mem/virtual"

Scan_Callback :: #type proc(user_data: rawptr, token: string, err: bufio.Scanner_Error)
Split_Proc    :: #type proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool)

scan_lines :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	return bufio.scan_lines(data, at_eof)
}

scan_num_bytes :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	assert(split_data != nil)
	n := int(uintptr(split_data))
	assert(n >= 0)

	if at_eof && len(data) < n {
		return
	}

	if len(data) < n {
		return
	}

	return n, data[:n], nil, false
}

// A callback based scanner over the connection.
// Phase 0: buffer/token logic retained; async read is stubbed (no nbio/proactr yet).
Scanner :: struct /* #no_copy */ {
	connection:                   ^Connection,
	split:                        Split_Proc,
	split_data:                   rawptr,
	buf:                          [dynamic]byte,
	max_token_size:               int,
	start:                        int,
	end:                          int,
	token:                        []byte,
	_err:                         bufio.Scanner_Error,
	consecutive_empty_reads:      int,
	max_consecutive_empty_reads:  int,
	successive_empty_token_count: int,
	done:                         bool,
	could_be_too_short:           bool,
	user_data:                    rawptr,
	callback:                     Scan_Callback,
}

INIT_BUF_SIZE :: 1024
DEFAULT_MAX_CONSECUTIVE_EMPTY_READS :: 128

scanner_init :: proc(s: ^Scanner, c: ^Connection, buf_allocator := context.allocator) {
	s.connection     = c
	s.split          = scan_lines
	s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.buf.allocator  = buf_allocator
}

scanner_destroy :: proc(s: ^Scanner) {
	delete(s.buf)
}

scanner_reset :: proc(s: ^Scanner) {
	remove_range(&s.buf, 0, s.start)
	s.end   -= s.start
	s.start  = 0

	s.split                        = scan_lines
	s.split_data                   = nil
	s.max_token_size               = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.token                        = nil
	s._err                         = nil
	s.consecutive_empty_reads      = 0
	s.max_consecutive_empty_reads  = DEFAULT_MAX_CONSECUTIVE_EMPTY_READS
	s.successive_empty_token_count = 0
	s.done                         = false
	s.could_be_too_short           = false
	s.user_data                    = nil
	s.callback                     = nil
}

// scanner_init_pooled installs a fixed slice as scanner.buf without owning it via free.
// len=cap so the free window is the full RECV size. Recycle via scanner_reset_pooled.
@(private)
scanner_init_pooled :: proc(s: ^Scanner, c: ^Connection, window: []u8) {
	s^ = {}
	s.connection = c
	s.split = scan_lines
	s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	raw := runtime.Raw_Dynamic_Array {
		data      = raw_data(window),
		len       = len(window),
		cap       = len(window),
		allocator = runtime.nil_allocator(),
	}
	s.buf = transmute([dynamic]byte)raw
}

// scanner_reset_pooled clears parse state and restores pooled buf len to capacity.
@(private)
scanner_reset_pooled :: proc(s: ^Scanner) {
	if cap(s.buf) > 0 {
		raw := cast(^runtime.Raw_Dynamic_Array)&s.buf
		raw.len = raw.cap
	}
	s.start = 0
	s.end = 0
	s.split = scan_lines
	s.split_data = nil
	s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.token = nil
	s._err = nil
	s.consecutive_empty_reads = 0
	s.max_consecutive_empty_reads = DEFAULT_MAX_CONSECUTIVE_EMPTY_READS
	s.successive_empty_token_count = 0
	s.done = false
	s.could_be_too_short = false
	s.user_data = nil
	s.callback = nil
}

// scanner_prepare resets parse state for a new request and restores the RECV window.
// Pooled: len=cap. Dynamic: scanner_reset may shrink len via remove_range — restore to opts.recv_buf_size.
@(private)
scanner_prepare :: proc(c: ^Connection) {
	if c.scanner_pooled {
		scanner_reset_pooled(&c.scanner)
	} else {
		scanner_reset(&c.scanner)
		recv_n := c.server.opts.recv_buf_size
		if cap(c.scanner.buf) >= recv_n && len(c.scanner.buf) < recv_n {
			resize(&c.scanner.buf, recv_n)
		}
	}
	c.scanner.connection = c
}

scanner_scan :: proc(
	s: ^Scanner,
	user_data: rawptr,
	callback: proc(user_data: rawptr, token: string, err: bufio.Scanner_Error),
) {
	set_err :: proc(s: ^Scanner, err: bufio.Scanner_Error) {
		switch s._err {
		case nil, .EOF:
			s._err = err
		}
	}

	if s.done {
		callback(user_data, "", .EOF)
		return
	}

	// Check if a token is possible with what is available
	// Allow the split procedure to recover if it fails
	if s.start < s.end || s._err != nil {
		advance, token, err, final_token := s.split(s.split_data, s.buf[s.start:s.end], s._err != nil)
		if final_token {
			s.token = token
			s.done = true
			callback(user_data, "", .EOF)
			return
		}
		if err != nil {
			set_err(s, err)
			callback(user_data, "", s._err)
			return
		}

		// Do advance
		if advance < 0 {
			set_err(s, .Negative_Advance)
			callback(user_data, "", s._err)
			return
		}
		if advance > s.end - s.start {
			set_err(s, .Advanced_Too_Far)
			callback(user_data, "", s._err)
			return
		}
		s.start += advance

		s.token = token
		if s.token != nil {
			if s._err == nil || advance > 0 {
				s.successive_empty_token_count = 0
			} else {
				s.successive_empty_token_count += 1

				if s.successive_empty_token_count > s.max_consecutive_empty_reads {
					set_err(s, .No_Progress)
					callback(user_data, "", s._err)
					return
				}
			}

			s.consecutive_empty_reads = 0
			s.callback = nil
			s.user_data = nil
			callback(user_data, string(token), s._err)
			return
		}
	}

	// If an error is hit, no token can be created
	if s._err != nil {
		s.start = 0
		s.end = 0
		callback(user_data, "", s._err)
		return
	}

	could_be_too_short := false

	// Make room for more data if the free window is empty.
	if s.end == len(s.buf) {
		if s.max_token_size <= 0 {
			s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		}

		if s.end - s.start >= s.max_token_size {
			set_err(s, .Too_Long)
			callback(user_data, "", s._err)
			return
		}

		// Compact consumed prefix without shrinking len (preserves free window to cap/len).
		if s.start > 0 {
			n := s.end - s.start
			if n > 0 {
				copy(s.buf[0:], s.buf[s.start:s.end])
			}
			s.end = n
			s.start = 0
		}

		// Still full: grow dynamic buffers; pooled/fixed windows cannot grow.
		if s.end == len(s.buf) {
			pooled := s.connection != nil && s.connection.scanner_pooled
			if pooled {
				// Fixed RECV window exhausted; treat as too long rather than realloc.
				set_err(s, .Too_Long)
				callback(user_data, "", s._err)
				return
			}

			// overflow check
			new_size := INIT_BUF_SIZE
			if len(s.buf) > 0 {
				overflowed: bool
				if new_size, overflowed = intrinsics.overflow_mul(len(s.buf), 2); overflowed {
					set_err(s, .Too_Long)
					callback(user_data, "", s._err)
					return
				}
			}

			old_size := len(s.buf)
			resize(&s.buf, new_size)

			could_be_too_short = old_size >= len(s.buf)
		}
	}

	// Read data into the buffer
	s.consecutive_empty_reads += 1
	s.user_data = user_data
	s.callback = callback
	s.could_be_too_short = could_be_too_short

	assert_has_td()
	// Submit recv into the free window of the scanner buffer. Buffer must stay
	// valid until the Recv CQE (host calls scanner_on_bytes from that path).
	_ = could_be_too_short
	buf := s.buf[s.end:len(s.buf)]
	if len(buf) == 0 {
		s._err = .No_Progress
		callback(user_data, "", s._err)
		return
	}
	err := host_submit_recv(s.connection, buf)
	if err != .None {
		s._err = .Unknown
		callback(user_data, "", s._err)
		return
	}
	// Callback resumes after Recv CQE → scanner_on_bytes → scanner_scan.
}

// Phase 2 entry: host calls this when a proactr Recv completes into s.buf[s.end:].
scanner_on_bytes :: proc(s: ^Scanner, received: int, closed: bool) {
	context.temp_allocator = virtual.arena_allocator(&s.connection.temp_allocator)

	if closed || received == 0 {
		s._err = .EOF
		if s.callback != nil {
			scanner_scan(s, s.user_data, s.callback)
		}
		return
	}

	if received < 0 || len(s.buf) - s.end < received {
		s._err = .Bad_Read_Count
		if s.callback != nil {
			scanner_scan(s, s.user_data, s.callback)
		}
		return
	}

	s.end += received
	if received > 0 {
		s.successive_empty_token_count = 0
	}
	if s.callback != nil {
		scanner_scan(s, s.user_data, s.callback)
	}
}
