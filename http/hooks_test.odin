package http

import "core:testing"

@(test)
test_respond_hooks_lifo_order :: proc(t: ^testing.T) {
	// Pure hook registration + fire without a live connection for order check.
	// _response_fire_respond_hooks needs r._conn.loop.req — use a stack Connection.
	conn: Connection
	res: Response
	// Minimal bind (skip full response_init buffer setup).
	res._conn = &conn
	res._slot = &conn.slot
	conn.slot.conn = &conn
	conn.slot.res = res

	test_hook_order = make([dynamic]int, 0, 4)
	defer {
		delete(test_hook_order)
		test_hook_order = nil
	}

	response_on_respond(&res, rawptr(uintptr(1)), test_hook_cb)
	response_on_respond(&res, rawptr(uintptr(2)), test_hook_cb)
	response_on_respond(&res, rawptr(uintptr(3)), test_hook_cb)
	testing.expect_value(t, res._on_respond_n, u8(3))

	_response_fire_respond_hooks(&res)
	testing.expect_value(t, res._on_respond_n, u8(0))
	// LIFO: 3, 2, 1
	testing.expect_value(t, len(test_hook_order), 3)
	testing.expect_value(t, test_hook_order[0], 3)
	testing.expect_value(t, test_hook_order[1], 2)
	testing.expect_value(t, test_hook_order[2], 1)
}

@(private)
test_hook_order: [dynamic]int

@(private)
test_hook_cb :: proc(req: ^Request, res: ^Response, user: rawptr) {
	_ = req
	_ = res
	append(&test_hook_order, int(uintptr(user)))
}

@(test)
test_respond_hooks_max :: proc(t: ^testing.T) {
	res: Response
	for i in 0 ..< RESPOND_HOOKS_MAX {
		response_on_respond(&res, nil, proc(req: ^Request, res: ^Response, user: rawptr) {})
	}
	testing.expect_value(t, res._on_respond_n, u8(RESPOND_HOOKS_MAX))
}

@(test)
test_complete_hooks_register :: proc(t: ^testing.T) {
	res: Response
	response_on_complete(&res, nil, proc(req: ^Request, res: ^Response, user: rawptr) {})
	testing.expect_value(t, res._on_complete_n, u8(1))
}
