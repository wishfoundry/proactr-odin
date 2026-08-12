// Package qpack implements QPACK (RFC 9204) header compression for HTTP/3.
// This file holds the static table (RFC 9204 Appendix A): 99 fixed name/value
package qpack

Static_Entry :: struct {
	name:  string,
	value: string,
}

STATIC_TABLE_LEN :: 99

// @(rodata) (not a `::` constant) so it can be runtime-indexed by a wire index.
@(rodata)
STATIC_TABLE := [STATIC_TABLE_LEN]Static_Entry {
	{name = ":authority", value = ""},                                     //  0
	{name = ":path", value = "/"},                                         //  1
	{name = "age", value = "0"},                                           //  2
	{name = "content-disposition", value = ""},                            //  3
	{name = "content-length", value = "0"},                                //  4
	{name = "cookie", value = ""},                                         //  5
	{name = "date", value = ""},                                           //  6
	{name = "etag", value = ""},                                           //  7
	{name = "if-modified-since", value = ""},                              //  8
	{name = "if-none-match", value = ""},                                  //  9
	{name = "last-modified", value = ""},                                  // 10
	{name = "link", value = ""},                                           // 11
	{name = "location", value = ""},                                       // 12
	{name = "referer", value = ""},                                        // 13
	{name = "set-cookie", value = ""},                                     // 14
	{name = ":method", value = "CONNECT"},                                 // 15
	{name = ":method", value = "DELETE"},                                  // 16
	{name = ":method", value = "GET"},                                     // 17
	{name = ":method", value = "HEAD"},                                    // 18
	{name = ":method", value = "OPTIONS"},                                 // 19
	{name = ":method", value = "POST"},                                    // 20
	{name = ":method", value = "PUT"},                                     // 21
	{name = ":scheme", value = "http"},                                    // 22
	{name = ":scheme", value = "https"},                                   // 23
	{name = ":status", value = "103"},                                     // 24
	{name = ":status", value = "200"},                                     // 25
	{name = ":status", value = "304"},                                     // 26
	{name = ":status", value = "404"},                                     // 27
	{name = ":status", value = "503"},                                     // 28
	{name = "accept", value = "*/*"},                                      // 29
	{name = "accept", value = "application/dns-message"},                  // 30
	{name = "accept-encoding", value = "gzip, deflate, br"},               // 31
	{name = "accept-ranges", value = "bytes"},                             // 32
	{name = "access-control-allow-headers", value = "cache-control"},      // 33
	{name = "access-control-allow-headers", value = "content-type"},       // 34
	{name = "access-control-allow-origin", value = "*"},                   // 35
	{name = "cache-control", value = "max-age=0"},                         // 36
	{name = "cache-control", value = "max-age=2592000"},                   // 37
	{name = "cache-control", value = "max-age=604800"},                    // 38
	{name = "cache-control", value = "no-cache"},                          // 39
	{name = "cache-control", value = "no-store"},                          // 40
	{name = "cache-control", value = "public, max-age=31536000"},          // 41
	{name = "content-encoding", value = "br"},                             // 42
	{name = "content-encoding", value = "gzip"},                           // 43
	{name = "content-type", value = "application/dns-message"},            // 44
	{name = "content-type", value = "application/javascript"},             // 45
	{name = "content-type", value = "application/json"},                   // 46
	{name = "content-type", value = "application/x-www-form-urlencoded"},  // 47
	{name = "content-type", value = "image/gif"},                          // 48
	{name = "content-type", value = "image/jpeg"},                         // 49
	{name = "content-type", value = "image/png"},                          // 50
	{name = "content-type", value = "text/css"},                           // 51
	{name = "content-type", value = "text/html; charset=utf-8"},           // 52
	{name = "content-type", value = "text/plain"},                         // 53
	{name = "content-type", value = "text/plain;charset=utf-8"},           // 54
	{name = "range", value = "bytes=0-"},                                  // 55
	{name = "strict-transport-security", value = "max-age=31536000"},      // 56
	{name = "strict-transport-security", value = "max-age=31536000; includesubdomains"},          // 57
	{name = "strict-transport-security", value = "max-age=31536000; includesubdomains; preload"}, // 58
	{name = "vary", value = "accept-encoding"},                            // 59
	{name = "vary", value = "origin"},                                     // 60
	{name = "x-content-type-options", value = "nosniff"},                  // 61
	{name = "x-xss-protection", value = "1; mode=block"},                  // 62
	{name = ":status", value = "100"},                                     // 63
	{name = ":status", value = "204"},                                     // 64
	{name = ":status", value = "206"},                                     // 65
	{name = ":status", value = "302"},                                     // 66
	{name = ":status", value = "400"},                                     // 67
	{name = ":status", value = "403"},                                     // 68
	{name = ":status", value = "421"},                                     // 69
	{name = ":status", value = "425"},                                     // 70
	{name = ":status", value = "500"},                                     // 71
	{name = "accept-language", value = ""},                                // 72
	{name = "access-control-allow-credentials", value = "FALSE"},          // 73
	{name = "access-control-allow-credentials", value = "TRUE"},           // 74
	{name = "access-control-allow-headers", value = "*"},                  // 75
	{name = "access-control-allow-methods", value = "get"},                // 76
	{name = "access-control-allow-methods", value = "get, post, options"}, // 77
	{name = "access-control-allow-methods", value = "options"},            // 78
	{name = "access-control-expose-headers", value = "content-length"},    // 79
	{name = "access-control-request-headers", value = "content-type"},     // 80
	{name = "access-control-request-method", value = "get"},               // 81
	{name = "access-control-request-method", value = "post"},              // 82
	{name = "alt-svc", value = "clear"},                                   // 83
	{name = "authorization", value = ""},                                  // 84
	{name = "content-security-policy", value = "script-src 'none'; object-src 'none'; base-uri 'none'"}, // 85
	{name = "early-data", value = "1"},                                    // 86
	{name = "expect-ct", value = ""},                                      // 87
	{name = "forwarded", value = ""},                                      // 88
	{name = "if-range", value = ""},                                       // 89
	{name = "origin", value = ""},                                         // 90
	{name = "purpose", value = "prefetch"},                                // 91
	{name = "server", value = ""},                                         // 92
	{name = "timing-allow-origin", value = "*"},                           // 93
	{name = "upgrade-insecure-requests", value = "1"},                     // 94
	{name = "user-agent", value = ""},                                     // 95
	{name = "x-forwarded-for", value = ""},                                // 96
	{name = "x-frame-options", value = "deny"},                            // 97
	{name = "x-frame-options", value = "sameorigin"},                      // 98
}

// Decoder path: resolve a wire index to its entry. Single bounds-checked array
// access, the only lookup the decoder needs.
static_get :: #force_inline proc(index: int) -> (Static_Entry, bool) {
	if index < 0 || index >= STATIC_TABLE_LEN do return {}, false
	return STATIC_TABLE[index], true
}

// Encoder path — exact (name, value) match → "Indexed" field representation.
// Linear scan: the table is tiny and cache-hot (well under a microsecond), and
// the encode-path bottleneck is the QUIC/UDP send, not header lookup.
static_find_pair :: proc(name, value: string) -> (index: int, ok: bool) {
	for e, i in STATIC_TABLE {
		if e.name == name && e.value == value do return i, true
	}
	return 0, false
}

// Encoder path — name-only match → "Literal with Name Reference". Returns the
// LOWEST index for that name (keeps wire indices small / deterministic).
static_find_name :: proc(name: string) -> (index: int, ok: bool) {
	for e, i in STATIC_TABLE {
		if e.name == name do return i, true
	}
	return 0, false
}
