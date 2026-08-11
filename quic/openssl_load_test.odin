package quic

import "core:testing"

@(test)
test_os_init_loads_openssl :: proc(t: ^testing.T) {
	err := os_init()
	testing.expect_value(t, err, Os_Error.None)
	testing.expect(t, g_os.ready, "g_os.ready after os_init")
	testing.expect(t, g_os.cipher_aes_128_gcm != nil, "AES-128-GCM prefetched")
	testing.expect(t, g_os.kdf_hkdf != nil, "HKDF prefetched")
	if g_os.OpenSSL_version_num != nil {
		v := g_os.OpenSSL_version_num()
		testing.expect(t, v >= OPENSSL_VERSION_MIN_3_5, "OpenSSL version >= 3.5")
	}
}

@(test)
test_rand_bytes_smoke :: proc(t: ^testing.T) {
	testing.expect(t, os_ensure())
	buf: [16]u8
	rand_bytes(buf[:])
	// Extremely unlikely all zeros after RAND_bytes.
	all_zero := true
	for b in buf {
		if b != 0 {
			all_zero = false
			break
		}
	}
	testing.expect(t, !all_zero, "rand_bytes should produce non-zero data")
}
