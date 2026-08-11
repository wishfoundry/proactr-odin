// Alt-Svc (RFC 7838) — Chrome-like alternative-service discovery.
//
// Servers advertise `Alt-Svc: h3=":443"; ma=86400` on h1/h2 responses. We parse,
// cache by origin, and on the next Auto dial to that origin try H3 first,
// falling back to TCP+ALPN if QUIC fails (same recovery shape as browsers).
//
// Non-goals: Alt-Used request header, persist=1 disk store, h2-over-alt TCP
// (we only follow h3 / h3-* ALPNs onto QUIC).
package client

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"


// Default max-age when `ma` is omitted (RFC 7838 §3.1: 24 hours).
ALT_SVC_DEFAULT_MA_SECS :: 86400

// How long to avoid re-trying a failed H3 alt (Chrome-like broken-alt backoff).
ALT_SVC_BROKEN_BACKOFF :: 60 * time.Second

// One cached alternative for an origin (scheme://host:port).
Alt_Svc_Entry :: struct {
	// ALPN id from the advertisement ("h3", "h3-29", …). Only h3* is dialed.
	protocol: string,
	// Empty host → same host as the origin.
	host:     string,
	port:     int,
	expires:  time.Time,
	// When set and still in the future, skip this alt (QUIC dial failed recently).
	broken_until: time.Time,
}

// Process-wide cache (Chrome stores this globally). Clear with alt_svc_cache_clear in tests.
Alt_Svc_Cache :: struct {
	mu:        sync.Mutex,
	entries:   map[string]Alt_Svc_Entry, // owned keys; entry strings owned
	allocator: mem.Allocator,
	inited:    bool,
}

// Package default — used when Options.follow_alt_svc and alt_svc_cache is nil.
@(private)
_g_alt_svc: Alt_Svc_Cache

// Origin key: "https://example.com:443"
origin_key :: proc(scheme, host: string, port: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s://%s:%d", scheme, host, port, allocator = allocator)
}

// True for ALPN ids we can dial over QUIC (h3, h3-29, h3-32, …).
alt_svc_is_h3 :: proc(protocol: string) -> bool {
	if protocol == "h3" do return true
	return strings.has_prefix(protocol, "h3-")
}

// Parse one Alt-Svc field value (may list several alternatives). Returns owned
// entries (caller deletes protocol/host strings). `clear` → ok with empty slice
// and clear=true.
alt_svc_parse :: proc(
	value: string,
	allocator := context.allocator,
) -> (entries: []Alt_Svc_Entry, clear: bool, ok: bool) {
	v := strings.trim_space(value)
	if len(v) == 0 do return nil, false, false
	if v == "clear" do return nil, true, true

	list: [dynamic]Alt_Svc_Entry
	list.allocator = allocator

	// Split top-level alternatives on commas not inside quotes.
	start := 0
	in_q := false
	for i in 0 ..= len(v) {
		at_end := i == len(v)
		c := u8(0) if at_end else v[i]
		if !at_end && c == '"' do in_q = !in_q
		if at_end || (c == ',' && !in_q) {
			part := strings.trim_space(v[start:i])
			if len(part) > 0 {
				e, eok := _alt_svc_parse_one(part, allocator)
				if eok do append(&list, e)
			}
			start = i + 1
		}
	}
	if len(list) == 0 {
		delete(list)
		return nil, false, false
	}
	return list[:], false, true
}

@(private)
_alt_svc_parse_one :: proc(part: string, allocator: mem.Allocator) -> (Alt_Svc_Entry, bool) {
	// protocol="authority"; ma=N; persist=1
	eq := strings.index_byte(part, '=')
	if eq < 1 do return {}, false
	proto := strings.trim_space(part[:eq])
	rest := strings.trim_space(part[eq + 1:])
	if len(rest) == 0 || rest[0] != '"' do return {}, false
	endq := strings.index_byte(rest[1:], '"')
	if endq < 0 do return {}, false
	auth := rest[1:1 + endq]
	params := strings.trim_space(rest[1 + endq + 1:])

	host: string
	port := 0
	if len(auth) == 0 {
		// empty authority invalid
		return {}, false
	}
	if auth[0] == ':' {
		// ":443" — same host, explicit port
		p, pok := strconv.parse_int(auth[1:])
		if !pok || p <= 0 do return {}, false
		port = p
	} else if ci := strings.index_byte(auth, ':'); ci >= 0 {
		host = auth[:ci]
		p, pok := strconv.parse_int(auth[ci + 1:])
		if !pok || p <= 0 do return {}, false
		port = p
	} else {
		// host only — default 443 for h3
		host = auth
		port = 443
	}

	ma := ALT_SVC_DEFAULT_MA_SECS
	// parameters: ; ma=86400 ; persist=1
	for len(params) > 0 {
		if params[0] == ';' do params = strings.trim_space(params[1:])
		if len(params) == 0 do break
		semi := -1
		for j in 0 ..< len(params) {
			if params[j] == ';' {
				semi = j
				break
			}
		}
		token := params if semi < 0 else params[:semi]
		params = "" if semi < 0 else params[semi:]
		token = strings.trim_space(token)
		if peq := strings.index_byte(token, '='); peq > 0 {
			name := strings.to_lower(strings.trim_space(token[:peq]), context.temp_allocator)
			val := strings.trim_space(token[peq + 1:])
			if name == "ma" {
				if n, nok := strconv.parse_int(val); nok && n >= 0 do ma = n
			}
		}
	}

	e := Alt_Svc_Entry {
		protocol = strings.clone(proto, allocator),
		host     = strings.clone(host, allocator) if len(host) > 0 else "",
		port     = port,
		expires  = time.time_add(time.now(), time.Duration(ma) * time.Second),
	}
	return e, true
}

alt_svc_entry_destroy :: proc(e: Alt_Svc_Entry, allocator := context.allocator) {
	delete(e.protocol, allocator)
	delete(e.host, allocator)
}

@(private)
_alt_svc_ensure :: proc(c: ^Alt_Svc_Cache, allocator: mem.Allocator) {
	if c.inited do return
	c.allocator = allocator
	c.entries = make(map[string]Alt_Svc_Entry, allocator)
	c.inited = true
}

// Store / replace h3* alternatives for origin. `clear` wipes the origin.
// Non-h3 ads are ignored (we don't dial h2 alts over a second TCP today).
alt_svc_cache_put :: proc(
	c: ^Alt_Svc_Cache,
	origin_scheme, origin_host: string,
	origin_port: int,
	entries: []Alt_Svc_Entry,
	clear: bool,
	allocator := context.allocator,
) {
	_alt_svc_ensure(c, allocator)
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)

	key_tmp := origin_key(origin_scheme, origin_host, origin_port, context.temp_allocator)
	if clear {
		if old, ok := c.entries[key_tmp]; ok {
			// Find owned key for delete.
			for k in c.entries {
				if k == key_tmp {
					delete_key(&c.entries, k)
					delete(k, c.allocator)
					alt_svc_entry_destroy(old, c.allocator)
					break
				}
			}
		}
		return
	}

	// Prefer first h3* entry (Chrome picks among alternatives; we keep one).
	chosen: Alt_Svc_Entry
	found := false
	for e in entries {
		if alt_svc_is_h3(e.protocol) {
			chosen = e
			found = true
			break
		}
	}
	if !found do return

	// Replace existing.
	if old, ok := c.entries[key_tmp]; ok {
		for k in c.entries {
			if k == key_tmp {
				delete_key(&c.entries, k)
				delete(k, c.allocator)
				alt_svc_entry_destroy(old, c.allocator)
				break
			}
		}
	}
	nk := strings.clone(key_tmp, c.allocator)
	ne := Alt_Svc_Entry {
		protocol = strings.clone(chosen.protocol, c.allocator),
		host     = strings.clone(chosen.host, c.allocator) if len(chosen.host) > 0 else "",
		port     = chosen.port,
		expires  = chosen.expires,
	}
	c.entries[nk] = ne
}

// Lookup a still-fresh h3 alternative for the origin.
alt_svc_cache_lookup :: proc(
	c: ^Alt_Svc_Cache,
	origin_scheme, origin_host: string,
	origin_port: int,
) -> (e: Alt_Svc_Entry, ok: bool) {
	if c == nil || !c.inited do return {}, false
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)

	key := origin_key(origin_scheme, origin_host, origin_port, context.temp_allocator)
	ent, found := c.entries[key]
	if !found do return {}, false
	now := time.now()
	if time.diff(now, ent.expires) <= 0 {
		// Expired — drop.
		for k in c.entries {
			if k == key {
				delete_key(&c.entries, k)
				delete(k, c.allocator)
				alt_svc_entry_destroy(ent, c.allocator)
				break
			}
		}
		return {}, false
	}
	// Broken-alt backoff: still in cache, but do not dial until cooldown ends.
	if ent.broken_until._nsec != 0 && time.diff(now, ent.broken_until) > 0 {
		return {}, false
	}
	// Return entry borrowing cache storage — valid until put/clear/mark_broken.
	return ent, true
}

// After a failed opportunistic H3 dial, suppress this origin's alt for a while.
alt_svc_cache_mark_broken :: proc(
	c: ^Alt_Svc_Cache,
	origin_scheme, origin_host: string,
	origin_port: int,
	backoff := ALT_SVC_BROKEN_BACKOFF,
) {
	if c == nil || !c.inited do return
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)

	key := origin_key(origin_scheme, origin_host, origin_port, context.temp_allocator)
	if ent, ok := &c.entries[key]; ok {
		ent.broken_until = time.time_add(time.now(), backoff)
	}
}

// Successful H3 dial clears broken state (ma still applies).
alt_svc_cache_mark_ok :: proc(
	c: ^Alt_Svc_Cache,
	origin_scheme, origin_host: string,
	origin_port: int,
) {
	if c == nil || !c.inited do return
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)

	key := origin_key(origin_scheme, origin_host, origin_port, context.temp_allocator)
	if ent, ok := &c.entries[key]; ok {
		ent.broken_until = {}
	}
}

alt_svc_cache_clear :: proc(c: ^Alt_Svc_Cache) {
	if c == nil || !c.inited do return
	sync.mutex_lock(&c.mu)
	// Copy allocator before unlock/zero — delete map under lock.
	alloc := c.allocator
	for k, v in c.entries {
		delete(k, alloc)
		alt_svc_entry_destroy(v, alloc)
	}
	delete(c.entries)
	c.entries = {}
	c.inited = false
	sync.mutex_unlock(&c.mu)
}

// Package-global helpers.
alt_svc_global :: proc() -> ^Alt_Svc_Cache {
	return &_g_alt_svc
}

alt_svc_global_clear :: proc() {
	alt_svc_cache_clear(&_g_alt_svc)
}

// Ingest Alt-Svc header(s) from a response into the cache for this connection's origin.
alt_svc_learn_from_headers :: proc(
	cache: ^Alt_Svc_Cache,
	scheme, host: string,
	port: int,
	headers: []Header,
	allocator := context.allocator,
) {
	if cache == nil do return
	// Multiple Alt-Svc headers are allowed; process each.
	for h in headers {
		if strings.to_lower(h.name, context.temp_allocator) != "alt-svc" do continue
		entries, clear, ok := alt_svc_parse(h.value, context.temp_allocator)
		if !ok do continue
		alt_svc_cache_put(cache, scheme, host, port, entries, clear, allocator)
		for e in entries do alt_svc_entry_destroy(e, context.temp_allocator)
	}
}
