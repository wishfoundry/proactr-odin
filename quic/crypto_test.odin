package quic

import "core:testing"

// RFC 9001 §A.1 — QUIC Initial key derivation test vectors.
// Given:
//   dcid = 0x8394c8f03e515708
// Expected values (RFC 9001 §A.1):
//   initial_secret        = 7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44
//   client_initial_secret = c00cf151ca5be075ed0ebfb5c0ff07c8d3fa65e39b5c85a4a7b3ec4d6b8b3b1b
//   client key            = 1f369613dd76d5467730efcbe3b1a22d
//   client iv             = fa044b2f42a3fd3b46fb255c
//   client hp             = 9f50449e04a0e810283a1e9933adedd2
//   server_initial_secret = 3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b
//   server key            = cf3a5331653c364c88f0f379b6067e37
//   server iv             = 0ac1493ca1905853b0bba03e
//   server hp             = c206b8d9b9f0f37644430b490eeaa314

DCID_RFC9001_A1 :: [8]u8{0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08}

@(test)
test_crypto_rfc9001_a1_client_key :: proc(t: ^testing.T) {
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	ok := derive_initial_keys(&keys, dcid[:])
	testing.expect(t, ok, "derive_initial_keys failed")

	expected_key := [16]u8{
		0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46,
		0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d,
	}
	actual_key := keys.client.key[:16]
	testing.expect(t,
		slice_equal(actual_key, expected_key[:]),
		"client key mismatch vs RFC 9001 §A.1")
}

@(test)
test_crypto_rfc9001_a1_client_iv :: proc(t: ^testing.T) {
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	derive_initial_keys(&keys, dcid[:])

	expected_iv := [12]u8{
		0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b,
		0x46, 0xfb, 0x25, 0x5c,
	}
	testing.expect(t,
		slice_equal(keys.client.iv[:], expected_iv[:]),
		"client iv mismatch vs RFC 9001 §A.1")
}

@(test)
test_crypto_rfc9001_a1_client_hp :: proc(t: ^testing.T) {
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	derive_initial_keys(&keys, dcid[:])

	expected_hp := [16]u8{
		0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10,
		0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2,
	}
	testing.expect(t,
		slice_equal(keys.client.hp[:16], expected_hp[:]),
		"client hp mismatch vs RFC 9001 §A.1")
}

@(test)
test_crypto_rfc9001_a1_server_key :: proc(t: ^testing.T) {
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	derive_initial_keys(&keys, dcid[:])

	expected_key := [16]u8{
		0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c,
		0x88, 0xf0, 0xf3, 0x79, 0xb6, 0x06, 0x7e, 0x37,
	}
	testing.expect(t,
		slice_equal(keys.server.key[:16], expected_key[:]),
		"server key mismatch vs RFC 9001 §A.1")
}

@(test)
test_crypto_rfc9001_a1_server_iv :: proc(t: ^testing.T) {
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	derive_initial_keys(&keys, dcid[:])

	expected_iv := [12]u8{
		0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53,
		0xb0, 0xbb, 0xa0, 0x3e,
	}
	testing.expect(t,
		slice_equal(keys.server.iv[:], expected_iv[:]),
		"server iv mismatch vs RFC 9001 §A.1")
}

@(test)
test_crypto_rfc9001_a1_server_hp :: proc(t: ^testing.T) {
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	derive_initial_keys(&keys, dcid[:])

	expected_hp := [16]u8{
		0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76,
		0x44, 0x43, 0x0b, 0x49, 0x0e, 0xea, 0xa3, 0x14,
	}
	testing.expect(t,
		slice_equal(keys.server.hp[:16], expected_hp[:]),
		"server hp mismatch vs RFC 9001 §A.1")
}

// --- test helper ---

@(private)
slice_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) do return false
	for i in 0..<len(a) {
		if a[i] != b[i] do return false
	}
	return true
}
