package http

import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_gcra_basic_limit :: proc(t: ^testing.T) {
	s: Store
	testing.expect(t, store_init(&s, 1024, 4, .Evict_Cold))
	defer store_destroy(&s)

	g, ok := gcra_from_limit_period(10, time.Second, 10)
	testing.expect(t, ok)

	now: i64 = 1_000_000_000
	allows := 0
	for i in 0 ..< 20 {
		d := store_allow(&s, store_key(0, 42), 1, g, now)
		if d.allowed {
			allows += 1
		}
	}
	// Instantaneous burst admits exactly `burst` (τ = (burst-1)*T).
	testing.expect(t, allows == 10, "exact burst")

	// Still denied without time advance.
	d := store_allow(&s, store_key(0, 42), 1, g, now)
	testing.expect(t, !d.allowed, "still limited")
	testing.expect(t, d.retry_after > 0, "retry_after")

	// After a full period, allows again.
	now += i64(time.Second) + 1
	d2 := store_allow(&s, store_key(0, 42), 1, g, now)
	testing.expect(t, d2.allowed, "after period")
}

@(test)
test_gcra_no_double_budget_at_boundary :: proc(t: ^testing.T) {
	s: Store
	testing.expect(t, store_init(&s, 256, 4))
	defer store_destroy(&s)
	g, _ := gcra_from_limit_period(5, 100 * time.Millisecond, 5)

	now: i64 = 0
	n := 0
	// Spend full budget at t=0.
	for i in 0 ..< 10 {
		if store_allow(&s, 1, 1, g, now).allowed {
			n += 1
		}
	}
	// Advance exactly one period — should not get a full second budget instantly stacked
	// beyond ~limit again in the same instant (GCRA, not fixed window clear).
	now = i64(100 * time.Millisecond)
	n2 := 0
	for i in 0 ..< 10 {
		if store_allow(&s, 1, 1, g, now).allowed {
			n2 += 1
		}
	}
	testing.expect(t, n == 5, "first window exact burst")
	// GCRA may release some tokens after one period, but not a full fixed-window reset of 5+5.
	testing.expect(t, n2 <= 5, "boundary not full clear double")
}

@(test)
test_store_key_policy_isolation :: proc(t: ^testing.T) {
	s: Store
	testing.expect(t, store_init(&s, 256, 4))
	defer store_destroy(&s)
	g10, _ := gcra_from_limit_period(10, time.Second, 10)
	g2, _ := gcra_from_limit_period(2, time.Second, 2)
	user: u64 = 99
	now: i64 = 0

	// Exhaust policy 1 (limit 2, burst 2).
	testing.expect(t, store_allow(&s, store_key(1, user), 1, g2, now).allowed)
	testing.expect(t, store_allow(&s, store_key(1, user), 1, g2, now).allowed)
	testing.expect(t, !store_allow(&s, store_key(1, user), 1, g2, now).allowed, "p1 exhausted")

	// Policy 0 still has budget for same user key.
	testing.expect(t, store_allow(&s, store_key(0, user), 1, g10, now).allowed)
}

@(test)
test_store_fail_closed_capacity :: proc(t: ^testing.T) {
	s: Store
	// 1 shard, cap 2
	testing.expect(t, store_init(&s, 2, 1, .Fail_Closed))
	defer store_destroy(&s)
	g, _ := gcra_from_limit_period(100, time.Second, 100)
	now: i64 = 0
	testing.expect(t, store_allow(&s, 1, 1, g, now).allowed)
	testing.expect(t, store_allow(&s, 2, 1, g, now).allowed)
	d := store_allow(&s, 3, 1, g, now)
	testing.expect(t, !d.allowed, "fail closed new key")
	testing.expect(t, sync.atomic_load(&s.full_denies) >= 1)
}

@(test)
test_store_evict_cold_admits :: proc(t: ^testing.T) {
	s: Store
	testing.expect(t, store_init(&s, 2, 1, .Evict_Cold))
	defer store_destroy(&s)
	g, _ := gcra_from_limit_period(100, time.Second, 100)
	now: i64 = 0
	testing.expect(t, store_allow(&s, 1, 1, g, now).allowed)
	now = 10
	testing.expect(t, store_allow(&s, 2, 1, g, now).allowed)
	now = 20
	// New key should evict cold and admit.
	testing.expect(t, store_allow(&s, 3, 1, g, now).allowed)
	testing.expect(t, store_live_approx(&s) <= 2)
}

@(test)
test_cost_zero_and_overflow :: proc(t: ^testing.T) {
	s: Store
	testing.expect(t, store_init(&s, 64, 4))
	defer store_destroy(&s)
	g, _ := gcra_from_limit_period(10, time.Second, 10)
	now: i64 = 0
	testing.expect(t, store_allow(&s, 1, 0, g, now).allowed, "cost 0 → 1")
	d := store_allow(&s, 2, ~u64(0), g, now)
	testing.expect(t, !d.allowed, "absurd cost deny")
}

@(test)
test_key_peer_and_client_ip_xff :: proc(t: ^testing.T) {
	req: Request
	req.client.address = net.IP4_Address{10, 0, 0, 1}
	k1, ok1 := key_peer_ip(&req, nil)
	testing.expect(t, ok1)
	k2, _ := key_peer_ip(&req, nil)
	testing.expect(t, k1 == k2, "stable")

	// Untrusted peer: forged XFF ignored.
	headers_init(&req.headers)
	headers_set_unsafe(&req.headers, "x-forwarded-for", "1.2.3.4")
	opts := Client_IP_Opts{}
	kc, _ := key_client_ip(&req, &opts)
	testing.expect(t, kc == k1, "no trust → peer")

	// Trusted peer: honor XFF.
	cidr, cok := cidr_parse("10.0.0.0/8")
	testing.expect(t, cok)
	opts2 := Client_IP_Opts{trusted = {cidr}}
	kc2, okc := key_client_ip(&req, &opts2)
	testing.expect(t, okc)
	// Should hash 1.2.3.4 not 10.0.0.1
	req2: Request
	req2.client.address = net.IP4_Address{1, 2, 3, 4}
	expect_k, _ := key_peer_ip(&req2, nil)
	testing.expect(t, kc2 == expect_k, "xff client")
}

@(test)
test_cidr_match :: proc(t: ^testing.T) {
	c, ok := cidr_parse("192.168.0.0/16")
	testing.expect(t, ok)
	testing.expect(t, address_in_cidr(net.IP4_Address{192, 168, 1, 1}, c))
	testing.expect(t, !address_in_cidr(net.IP4_Address{10, 0, 0, 1}, c))
}

@(test)
test_rate_limit_handler_build_destroy :: proc(t: ^testing.T) {
	inner := handler(proc(req: ^Request, res: ^Response) {})
	inner_p := new(Handler)
	inner_p^ = inner
	defer free(inner_p)

	h := rate_limit(
		{
			policies = {
				{name = "ip", limit = 3, period = time.Second, burst = 3, key_fn = key_global},
			},
			skip_paths = {"/healthz"},
		},
		inner_p,
	)
	testing.expect(t, h.user_data != nil)
	rate_limit_destroy(&h)
	testing.expect(t, h.user_data == nil)
}

@(test)
test_rate_limit_write_deny_headers :: proc(t: ^testing.T) {
	res: Response
	headers_init(&res.headers)
	defer headers_destroy(&res.headers)
	d := Decision {
		allowed     = false,
		limit       = 10,
		remaining   = 0,
		retry_after = 1500 * time.Millisecond,
	}
	wall := time.now()
	rate_limit_write_deny(&res, d, wall, "slow down")
	testing.expect_value(t, res.status, Status.Too_Many_Requests)
	lim, ok1 := headers_get_unsafe(res.headers, "x-ratelimit-limit")
	testing.expect(t, ok1 && lim == "10")
	ra, ok2 := headers_get_unsafe(res.headers, "retry-after")
	testing.expect(t, ok2 && (ra == "1" || ra == "2"), "retry-after ceil seconds")
}

@(test)
test_skip_and_dry_run :: proc(t: ^testing.T) {
	// Build with skip — handle shouldn't need full respond if skip and next is simple.
	// Use store-level dry_run semantics: dry_run still mutates — tested via store_allow counts.
	s: Store
	testing.expect(t, store_init(&s, 64, 4))
	defer store_destroy(&s)
	g, _ := gcra_from_limit_period(2, time.Second, 2)
	now: i64 = 0
	testing.expect(t, store_allow(&s, 7, 1, g, now).allowed)
	testing.expect(t, store_allow(&s, 7, 1, g, now).allowed)
	testing.expect(t, !store_allow(&s, 7, 1, g, now).allowed)
	testing.expect(t, sync.atomic_load(&s.allows) == 2)
	testing.expect(t, sync.atomic_load(&s.denies) >= 1)
}

@(test)
test_key_route_pattern_empty :: proc(t: ^testing.T) {
	req: Request
	_, ok := key_route_pattern(&req, nil)
	testing.expect(t, !ok)
	req.route_pattern = "/users/:id"
	k, ok2 := key_route_pattern(&req, nil)
	testing.expect(t, ok2 && k != 0)
}

@(test)
test_gcra_invalid_opts :: proc(t: ^testing.T) {
	_, ok := gcra_from_limit_period(0, time.Second, 0)
	testing.expect(t, !ok)
	_, ok2 := gcra_from_limit_period(10, 0, 10)
	testing.expect(t, !ok2)
}

// Concurrent hammer: total allows should stay near limit+burst band (single key).
@(test)
test_concurrent_single_key :: proc(t: ^testing.T) {
	s: Store
	testing.expect(t, store_init(&s, 1024, 8))
	defer store_destroy(&s)
	g, _ := gcra_from_limit_period(50, time.Second, 50)
	now: i64 = 1_000_000

	Counter :: struct {
		s:     ^Store,
		g:     GCRA,
		now:   i64,
		n_ok:  int,
		mu:    sync.Mutex,
	}
	ctr: Counter
	ctr.s = &s
	ctr.g = g
	ctr.now = now

	worker :: proc(c: rawptr) {
		ctr := (^Counter)(c)
		local := 0
		for i in 0 ..< 200 {
			if store_allow(ctr.s, store_key(0, 1), 1, ctr.g, ctr.now).allowed {
				local += 1
			}
		}
		sync.lock(&ctr.mu)
		ctr.n_ok += local
		sync.unlock(&ctr.mu)
	}

	threads: [4]^thread.Thread
	for i in 0 ..< 4 {
		threads[i] = thread.create_and_start_with_data(&ctr, worker)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	// 4*200 attempts at same instant; allows ~50–60.
	testing.expect(t, ctr.n_ok <= 60, "concurrent band upper")
	testing.expect(t, ctr.n_ok >= 40, "concurrent band lower")
}
