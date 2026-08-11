// Rate-limit key extractors and client-IP / CIDR helpers.
package http

import "core:net"
import "core:strings"

// Returns ok=false → policy on_miss applies.
Key_Fn :: proc(req: ^Request, user: rawptr) -> (key: u64, ok: bool)

Key_Miss :: enum u8 {
	Allow, // skip this policy
	Deny,  // reject
}

// Precompiled CIDR for trusted proxies.
Cidr :: struct {
	addr: net.Address,
	bits: u8,
}

Client_IP_Opts :: struct {
	// Empty → key_client_ip behaves like key_peer_ip (never reads XFF).
	trusted: []Cidr,
}

Composite2 :: struct {
	a:      Key_Fn,
	a_user: rawptr,
	b:      Key_Fn,
	b_user: rawptr,
}

// Site-wide single bucket.
key_global :: proc(_: ^Request, _: rawptr) -> (u64, bool) {
	return 0, true
}

key_peer_ip :: proc(req: ^Request, _: rawptr) -> (u64, bool) {
	if req == nil {
		return 0, false
	}
	return hash_net_address(req.client.address), true
}

// method + path — available before router match (outer middleware).
key_method_path :: proc(req: ^Request, _: rawptr) -> (u64, bool) {
	if req == nil {
		return 0, false
	}
	method := "?"
	path := "/"
	if line, ok := req.line.?; ok {
		method = method_string(line.method)
		if req.url.path != "" {
			path = req.url.path
		} else if t, is_str := line.target.(string); is_str {
			path = t
		}
	} else if req.url.path != "" {
		path = req.url.path
	}
	h := hash_bytes(transmute([]u8)method)
	h = hash_mix(h, hash_bytes(transmute([]u8)path))
	return h, true
}

// ok=false when route_pattern empty (outer onion before match).
key_route_pattern :: proc(req: ^Request, _: rawptr) -> (u64, bool) {
	if req == nil || req.route_pattern == "" {
		return 0, false
	}
	return hash_bytes(transmute([]u8)req.route_pattern), true
}

// user = ^string header name (will be sanitized via headers_get).
key_header :: proc(req: ^Request, user: rawptr) -> (u64, bool) {
	if req == nil || user == nil {
		return 0, false
	}
	name := (^string)(user)^
	if name == "" {
		return 0, false
	}
	v, ok := headers_get(req.headers, name)
	if !ok || v == "" {
		return 0, false
	}
	return hash_bytes(transmute([]u8)v), true
}

key_composite2 :: proc(req: ^Request, user: rawptr) -> (u64, bool) {
	if req == nil || user == nil {
		return 0, false
	}
	c := (^Composite2)(user)
	if c.a == nil || c.b == nil {
		return 0, false
	}
	ka, oka := c.a(req, c.a_user)
	if !oka {
		return 0, false
	}
	kb, okb := c.b(req, c.b_user)
	if !okb {
		return 0, false
	}
	return hash_mix(ka, kb), true
}

// Peer IP unless peer ∈ trusted; then X-Forwarded-For (right→left, first untrusted).
key_client_ip :: proc(req: ^Request, user: rawptr) -> (u64, bool) {
	if req == nil {
		return 0, false
	}
	peer := req.client.address
	opts: ^Client_IP_Opts
	if user != nil {
		opts = (^Client_IP_Opts)(user)
	}
	if opts == nil || len(opts.trusted) == 0 || !address_in_cidrs(peer, opts.trusted) {
		return hash_net_address(peer), true
	}
	xff, ok := headers_get_unsafe(req.headers, "x-forwarded-for")
	if !ok || xff == "" {
		return hash_net_address(peer), true
	}
	if client, cok := xff_client_address(xff, opts.trusted); cok {
		return hash_net_address(client), true
	}
	return hash_net_address(peer), true
}

// Parse "a.b.c.d/nn" or IPv6 "x::y/nn" into Cidr.
cidr_parse :: proc(s: string) -> (c: Cidr, ok: bool) {
	slash := strings.index_byte(s, '/')
	if slash < 0 {
		return {}, false
	}
	addr_s := s[:slash]
	bits_s := s[slash + 1:]
	bits, bok := parse_u8_dec(bits_s)
	if !bok {
		return {}, false
	}
	addr := net.parse_address(addr_s)
	if addr == nil {
		return {}, false
	}
	switch a in addr {
	case net.IP4_Address:
		if bits > 32 {
			return {}, false
		}
	case net.IP6_Address:
		if bits > 128 {
			return {}, false
		}
	}
	return Cidr{addr = addr, bits = bits}, true
}

address_in_cidrs :: proc(addr: net.Address, cidrs: []Cidr) -> bool {
	for c in cidrs {
		if address_in_cidr(addr, c) {
			return true
		}
	}
	return false
}

address_in_cidr :: proc(addr: net.Address, c: Cidr) -> bool {
	// IPv4-mapped IPv6: try as IPv4 against v4 CIDRs.
	if a6, ok6 := addr.(net.IP6_Address); ok6 {
		if v4, is_mapped := ip6_to_ip4_mapped(a6); is_mapped {
			if address_in_cidr(v4, c) {
				return true
			}
		}
	}
	switch a in addr {
	case net.IP4_Address:
		net4, ok4 := c.addr.(net.IP4_Address)
		if !ok4 {
			return false
		}
		if c.bits > 32 {
			return false
		}
		if c.bits == 0 {
			return true
		}
		am := ip4_to_u32(a)
		nm := ip4_to_u32(net4)
		mask: u32 = 0xFFFF_FFFF
		if c.bits < 32 {
			mask = mask << u32(32 - c.bits)
		}
		return (am & mask) == (nm & mask)
	case net.IP6_Address:
		net6, ok6 := c.addr.(net.IP6_Address)
		if !ok6 {
			return false
		}
		if c.bits > 128 {
			return false
		}
		return ip6_prefix_equal(a, net6, c.bits)
	}
	return false
}

// XFF: walk right → left; first valid address not in trusted.
xff_client_address :: proc(xff: string, trusted: []Cidr) -> (net.Address, bool) {
	// Split without alloc: walk commas from the right.
	end := len(xff)
	for end > 0 {
		// skip trailing space
		for end > 0 && (xff[end - 1] == ' ' || xff[end - 1] == '\t') {
			end -= 1
		}
		if end == 0 {
			break
		}
		start := end
		for start > 0 && xff[start - 1] != ',' {
			start -= 1
		}
		tok := strings.trim_space(xff[start:end])
		if start > 0 {
			end = start - 1 // before comma
		} else {
			end = 0
		}
		if tok == "" {
			continue
		}
		// strip optional port for IPv4 host:port (not for bare IPv6)
		host := tok
		if strings.count(tok, ":") == 1 {
			// likely a.b.c.d:port
			if ci := strings.index_byte(tok, ':'); ci > 0 {
				host = tok[:ci]
			}
		} else if strings.has_prefix(tok, "[") {
			// [v6]:port
			if rb := strings.index_byte(tok, ']'); rb > 0 {
				host = tok[1:rb]
			}
		}
		addr := net.parse_address(host)
		if addr == nil {
			continue
		}
		if !address_in_cidrs(addr, trusted) {
			return addr, true
		}
	}
	return nil, false
}

// --- hashing / IP helpers ---------------------------------------------------

hash_net_address :: proc(addr: net.Address) -> u64 {
	switch a in addr {
	case net.IP4_Address:
		b := transmute([4]u8)a
		return hash_bytes(b[:])
	case net.IP6_Address:
		b := transmute([16]u8)a
		return hash_bytes(b[:])
	}
	return 0
}

hash_bytes :: proc(data: []u8) -> u64 {
	// FNV-1a 64
	h: u64 = 0xcbf29ce484222325
	for b in data {
		h ~= u64(b)
		h *= 0x100000001b3
	}
	return h
}

hash_mix :: #force_inline proc(a, b: u64) -> u64 {
	x := a ~ (b + 0x9E3779B97F4A7C15 + (a << 6) + (a >> 2))
	return x
}

@(private)
ip4_to_u32 :: proc(a: net.IP4_Address) -> u32 {
	b := transmute([4]u8)a
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

@(private)
ip6_to_ip4_mapped :: proc(a: net.IP6_Address) -> (net.IP4_Address, bool) {
	// :ffff:x.x.x.x → words 0..4 zero, 5 = 0xffff
	w := transmute([8]u16be)a
	for i in 0 ..< 5 {
		if u16(w[i]) != 0 {
			return {}, false
		}
	}
	if u16(w[5]) != 0xffff {
		return {}, false
	}
	hi := u16(w[6])
	lo := u16(w[7])
	return net.IP4_Address{u8(hi >> 8), u8(hi), u8(lo >> 8), u8(lo)}, true
}

@(private)
ip6_prefix_equal :: proc(a, network: net.IP6_Address, bits: u8) -> bool {
	if bits == 0 {
		return true
	}
	ab := transmute([16]u8)a
	nb := transmute([16]u8)network
	full := int(bits) / 8
	rem := int(bits) % 8
	for i in 0 ..< full {
		if ab[i] != nb[i] {
			return false
		}
	}
	if rem == 0 {
		return true
	}
	mask := u8(0xff) << u8(8 - rem)
	return (ab[full] & mask) == (nb[full] & mask)
}

@(private)
parse_u8_dec :: proc(s: string) -> (u8, bool) {
	if len(s) == 0 || len(s) > 3 {
		return 0, false
	}
	v: int = 0
	for ch in s {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		v = v * 10 + int(ch - '0')
		if v > 255 {
			return 0, false
		}
	}
	return u8(v), true
}
