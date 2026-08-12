#+build windows
package proactr

// Windows IOCP proactor backend.
// WSASend/WSARecv/AcceptEx → GetQueuedCompletionStatusEx.
// Timeouts are portable software timers in proactr.odin (no per-timeout threads).

import "core:sys/windows"

// Win_Ov is the sole platform-private object for an in-flight Operation.
// Always starts with OVERLAPPED so CONTAINING_RECORD from lpOverlapped works.
// Freed only from _platform_operation_cleanup (via operation_free).
Win_Ov :: struct {
	ov:          windows.OVERLAPPED,
	op_id:       u32,
	is_accept:   bool,
	accept_sock: windows.SOCKET,
	addr_buf:    []u8,
}

Ring_Impl :: struct {
	iocp:         windows.HANDLE,
	active:       bool,
	entries:      u32,
	accept_ex:    windows.LPFN_ACCEPTEX,
	accept_ex_ok: bool,
	// Side table: op_id → Win_Ov* (parallel ownership with Operation slab).
	// Indexed by op id; nil if none.
	ovs: [dynamic]^Win_Ov,
}

@(private="file")
_wsa_started: bool

_ring_init_platform :: proc(r: ^Ring, entries: u32) -> Error {
	if !_wsa_started {
		data: windows.WSADATA
		if windows.WSAStartup(0x0202, &data) != 0 {
			return .Init_Failed
		}
		_wsa_started = true
	}

	iocp := windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, 0, 0)
	if iocp == nil {
		return .Init_Failed
	}

	want := entries if entries > 0 else DEFAULT_ENTRIES
	r.impl = {
		iocp    = iocp,
		active  = true,
		entries = want,
		ovs     = make([dynamic]^Win_Ov, 0, int(want), r.allocator),
	}
	return .None
}

_ring_destroy_platform :: proc(r: ^Ring) {
	for w in r.impl.ovs {
		if w != nil {
			if w.is_accept && w.addr_buf != nil {
				delete(w.addr_buf)
			}
			free(w, r.allocator)
		}
	}
	delete(r.impl.ovs)
	if r.impl.iocp != nil {
		windows.CloseHandle(r.impl.iocp)
		r.impl.iocp = nil
	}
	r.impl.active = false
}

_win_ovs_set :: proc(r: ^Ring, id: u32, w: ^Win_Ov) {
	for len(r.impl.ovs) <= int(id) {
		append(&r.impl.ovs, nil)
	}
	// Replace previous (should be nil).
	if r.impl.ovs[id] != nil {
		_win_free_ov(r, r.impl.ovs[id])
	}
	r.impl.ovs[id] = w
}

_win_ovs_take :: proc(r: ^Ring, id: u32) -> ^Win_Ov {
	if int(id) >= len(r.impl.ovs) {
		return nil
	}
	w := r.impl.ovs[id]
	r.impl.ovs[id] = nil
	return w
}

_win_free_ov :: proc(r: ^Ring, w: ^Win_Ov) {
	if w == nil {
		return
	}
	if w.is_accept && w.addr_buf != nil {
		delete(w.addr_buf)
	}
	free(w, r.allocator)
}

_platform_operation_cleanup :: proc(r: ^Ring, id: u32, op: ^Operation) {
	_ = op
	w := _win_ovs_take(r, id)
	_win_free_ov(r, w)
}

_win_assoc :: proc(r: ^Ring, sock: windows.SOCKET) {
	_ = windows.CreateIoCompletionPort(windows.HANDLE(uintptr(sock)), r.impl.iocp, 0, 0)
}

_win_new_ov :: proc(r: ^Ring, op_id: u32) -> ^Win_Ov {
	w := new(Win_Ov, r.allocator)
	w^ = {}
	w.op_id = op_id
	_win_ovs_set(r, op_id, w)
	return w
}

_win_pending_ok :: proc() -> bool {
	err := windows.WSAGetLastError()
	return err == windows.WSA_IO_PENDING || err == windows.ERROR_IO_PENDING
}


_submit_nop :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = op
	w := _win_new_ov(r, id)
	if !windows.PostQueuedCompletionStatus(r.impl.iocp, 0, 0, &w.ov) {
		_ = _win_ovs_take(r, id)
		_win_free_ov(r, w)
		return .Submit_Failed
	}
	return .None
}

_submit_accept :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	listener := windows.SOCKET(uintptr(op.fd))
	_win_assoc(r, listener)

	if !r.impl.accept_ex_ok {
		if !windows.load_accept_ex(listener, &r.impl.accept_ex) {
			return .Submit_Failed
		}
		r.impl.accept_ex_ok = true
	}

	accept_sock := windows.WSASocketW(
		windows.AF_INET,
		windows.SOCK_STREAM,
		windows.IPPROTO_TCP,
		nil,
		0,
		windows.WSA_FLAG_OVERLAPPED,
	)
	if accept_sock == windows.INVALID_SOCKET {
		accept_sock = windows.socket(windows.AF_INET, windows.SOCK_STREAM, windows.IPPROTO_TCP)
		if accept_sock == windows.INVALID_SOCKET {
			return .Submit_Failed
		}
	}

	addr_buf := make([]u8, 128, r.allocator)
	w := _win_new_ov(r, id)
	w.is_accept = true
	w.accept_sock = accept_sock
	w.addr_buf = addr_buf

	local_len := windows.DWORD(size_of(windows.SOCKADDR_STORAGE_LH) + 16)
	bytes: windows.DWORD
	ok := r.impl.accept_ex(
		listener,
		accept_sock,
		raw_data(addr_buf),
		0,
		local_len,
		local_len,
		&bytes,
		&w.ov,
	)
	if ok || _win_pending_ok() {
		return .None
	}
	windows.closesocket(accept_sock)
	_ = _win_ovs_take(r, id)
	_win_free_ov(r, w)
	return .Submit_Failed
}

_submit_recv :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	sock := windows.SOCKET(uintptr(op.fd))
	_win_assoc(r, sock)
	w := _win_new_ov(r, id)

	buf := windows.WSABUF {
		len = windows.ULONG(len(op.buf)),
		buf = windows.PCHAR(raw_data(op.buf)),
	}
	flags: windows.DWORD
	bytes: windows.DWORD
	rc := windows.WSARecv(sock, &buf, 1, &bytes, &flags, windows.LPWSAOVERLAPPED(&w.ov), nil)
	if rc == 0 || _win_pending_ok() {
		return .None
	}
	_ = _win_ovs_take(r, id)
	_win_free_ov(r, w)
	return .Submit_Failed
}

_submit_send :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	sock := windows.SOCKET(uintptr(op.fd))
	_win_assoc(r, sock)
	w := _win_new_ov(r, id)

	buf := windows.WSABUF {
		len = windows.ULONG(len(op.buf)),
		buf = windows.PCHAR(raw_data(op.buf)),
	}
	bytes: windows.DWORD
	rc := windows.WSASend(sock, &buf, 1, &bytes, 0, windows.LPWSAOVERLAPPED(&w.ov), nil)
	if rc == 0 || _win_pending_ok() {
		return .None
	}
	_ = _win_ovs_take(r, id)
	_win_free_ov(r, w)
	return .Submit_Failed
}

_submit_close :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	sock := windows.SOCKET(uintptr(op.fd))
	res: windows.DWORD = 0
	if windows.closesocket(sock) != 0 {
		res = windows.DWORD(u32(windows.WSAGetLastError()))
	}
	w := _win_new_ov(r, id)
	if !windows.PostQueuedCompletionStatus(r.impl.iocp, res, 0, &w.ov) {
		_ = _win_ovs_take(r, id)
		_win_free_ov(r, w)
		return .Submit_Failed
	}
	return .None
}

// Kernel WRITEV / sendfile: not on IOCP façade (host falls back to multi-send / pread).
_submit_writev :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	_ = r
	_ = id
	_ = op
	return .Unsupported
}

_submit_sendfile :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	_ = r
	_ = id
	_ = op
	return .Unsupported
}

_ring_submit :: proc(r: ^Ring) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return .None
}

// One GQCS batch into out. Portable ring_wait loops for min_complete / timers.
// Does NOT free Win_Ov — operation_free → _platform_operation_cleanup does.
_ring_wait :: proc(
	r: ^Ring,
	out: []Completion,
	min_complete: u32,
	timeout_ms: i32,
) -> (n: int, err: Error) {
	if !r.impl.active {
		return 0, .Unsupported
	}
	if len(out) == 0 {
		return 0, .None
	}

	wait: windows.DWORD = windows.INFINITE
	if timeout_ms >= 0 {
		wait = windows.DWORD(timeout_ms)
	}
	if min_complete == 0 && timeout_ms == 0 {
		wait = 0
	}

	entries: [64]windows.OVERLAPPED_ENTRY
	batch := min(len(out), len(entries))
	removed: windows.ULONG
	ok := windows.GetQueuedCompletionStatusEx(
		r.impl.iocp,
		&entries[0],
		windows.ULONG(batch),
		&removed,
		wait,
		false,
	)
	if !ok && removed == 0 {
		ec := windows.GetLastError()
		if ec == windows.WAIT_TIMEOUT || ec == 258 {
			return 0, .None
		}
		return 0, .Wait_Failed
	}

	n = 0
	for i in 0 ..< int(removed) {
		if n >= len(out) {
			break
		}
		e := entries[i]
		if e.lpOverlapped == nil {
			continue
		}
		w := cast(^Win_Ov)e.lpOverlapped
		op_id := w.op_id
		op := operation_get(r, op_id)
		result: i32

		if op != nil && op.kind == .Accept {
			result = i32(uintptr(w.accept_sock))
			_win_assoc(r, w.accept_sock)
		} else if op != nil && op.kind == .Close {
			if e.dwNumberOfBytesTransferred != 0 {
				result = -i32(e.dwNumberOfBytesTransferred)
			} else {
				result = 0
			}
		} else {
			result = i32(e.dwNumberOfBytesTransferred)
			if result == 0 && e.lpOverlapped.Internal != 0 && op != nil && op.kind != .Nop {
				result = -1
			}
		}

		out[n] = Completion{op_id = op_id, result = result, flags = 0}
		n += 1
	}
	_ = min_complete
	return n, .None
}
