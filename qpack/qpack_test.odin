package qpack

import "core:testing"

@(test)
test_static_table :: proc(t: ^testing.T) {
	testing.expect_value(t, len(STATIC_TABLE), 99)
	testing.expect_value(t, STATIC_TABLE[0].name, ":authority")
	testing.expect_value(t, STATIC_TABLE[1].value, "/")
	testing.expect_value(t, STATIC_TABLE[17].value, "GET")
	// RFC 9204 index 98 is x-frame-options/sameorigin (NOT www-authenticate,
	// which is an HPACK-only entry the design doc's example test got wrong).
	testing.expect_value(t, STATIC_TABLE[98].name, "x-frame-options")
	testing.expect_value(t, STATIC_TABLE[98].value, "sameorigin")

	i, ok := static_find_pair(":method", "GET")
	testing.expect(t, ok && i == 17, "find_pair :method GET -> 17")

	n, nok := static_find_name(":status")
	testing.expect(t, nok && n == 24, "find_name :status -> first index 24")

	_, miss := static_find_pair("nonexistent", "x")
	testing.expect(t, !miss, "missing pair returns ok=false")
}
