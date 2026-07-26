#+build !linux
package proactr

// Non-Linux: fixed files / registered recv pool are unavailable.
// Real implementations live only in platform_linux.odin.

ring_has_fixed_files :: proc(r: ^Ring) -> bool {
	_ = r
	return false
}

ring_set_listen_file :: proc(r: ^Ring, fd: i32) -> Error {
	_ = r
	_ = fd
	return .Unsupported
}

ring_file_alloc :: proc(r: ^Ring) -> (slot: i32, ok: bool) {
	_ = r
	return -1, false
}

ring_file_set :: proc(r: ^Ring, slot: i32, fd: i32) -> Error {
	_ = r
	_ = slot
	_ = fd
	return .Unsupported
}

ring_file_clear :: proc(r: ^Ring, slot: i32) -> Error {
	_ = r
	_ = slot
	return .Unsupported
}

ring_has_fixed_buffers :: proc(r: ^Ring) -> bool {
	_ = r
	return false
}

ring_register_recv_pool :: proc(
	r: ^Ring,
	count: u32 = DEFAULT_REG_BUF_COUNT,
	buf_size: u32 = DEFAULT_RECV_BUF_SIZE,
) -> Error {
	_ = r
	_ = count
	_ = buf_size
	return .Unsupported
}

ring_recv_buf_alloc :: proc(r: ^Ring) -> (index: i32, slice: []u8, ok: bool) {
	_ = r
	return -1, nil, false
}

ring_recv_buf_free :: proc(r: ^Ring, index: i32) {
	_ = r
	_ = index
}

ring_recv_buf_slice :: proc(r: ^Ring, index: i32) -> []u8 {
	_ = r
	_ = index
	return nil
}
