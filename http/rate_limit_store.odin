// Bounded sharded GCRA store for local rate limiting.
// Pure admit engine: no HTTP, no wall clock. See docs/ARCHITECTURE.md
package http

import "base:runtime"
import "core:sync"
import "core:time"

Store_Full :: enum u8 {
	Evict_Cold,  // new key may admit after evicting cold entry in shard
	Fail_Closed, // new key when shard full → deny
}

// GCRA parameters for one policy bucket.
GCRA :: struct {
	emission_interval_ns: i64, // period_ns / limit (≥ 1)
	delay_tolerance_ns:   i64, // burst * emission_interval_ns
	limit:                u64,
	period_ns:            i64, // for fail-closed / overflow retry_after
}

// Pure decision. No wall clock. No HTTP headers.
Decision :: struct {
	allowed:     bool,
	limit:       u64,
	remaining:   u64,
	retry_after: time.Duration,
}

@(private)
Store_Entry :: struct {
	tat:     i64,
	last_ns: i64,
}

@(private)
Store_Shard :: struct {
	mu:      sync.Mutex,
	entries: map[u64]Store_Entry,
	cap:     int,
}

// Fixed-capacity sharded GCRA store. Host owns lifetime when using store_* directly.
Store :: struct {
	shards:     []Store_Shard,
	shard_mask: u64,
	on_full:    Store_Full,
	allocator:  runtime.Allocator,
	// stats (atomics)
	allows:      u64,
	denies:      u64,
	evicts:      u64,
	full_denies: u64,
}

// capacity = max live keys globally, partitioned per shard:
//   per_shard_cap = max(1, ceil(capacity / shard_count))
// shard_count must be power of two (0 → 16).
store_init :: proc(
	s: ^Store,
	capacity: int,
	shard_count := 16,
	on_full: Store_Full = .Evict_Cold,
	allocator := context.allocator,
) -> bool {
	if s == nil || capacity < 1 {
		return false
	}
	n := shard_count
	if n <= 0 {
		n = 16
	}
	if n <= 0 || (n & (n - 1)) != 0 {
		return false
	}
	per := capacity / n
	if capacity % n != 0 {
		per += 1
	}
	if per < 1 {
		per = 1
	}

	s^ = {}
	s.allocator = allocator
	s.on_full = on_full
	s.shard_mask = u64(n - 1)
	s.shards = make([]Store_Shard, n, allocator)
	for i in 0 ..< n {
		s.shards[i].cap = per
		s.shards[i].entries = make(map[u64]Store_Entry, per, allocator)
	}
	return true
}

store_destroy :: proc(s: ^Store) {
	if s == nil {
		return
	}
	for &sh in s.shards {
		delete(sh.entries)
	}
	delete(s.shards, s.allocator)
	s^ = {}
}

// burst == 0 → burst = limit. limit == 0 or period <= 0 → ok=false.
gcra_from_limit_period :: proc(limit: u64, period: time.Duration, burst: u64) -> (g: GCRA, ok: bool) {
	if limit == 0 || period <= 0 {
		return {}, false
	}
	b := burst
	if b == 0 {
		b = limit
	}
	period_ns := i64(period)
	if period_ns < 1 {
		period_ns = 1
	}
	interval := period_ns / i64(limit)
	if interval < 1 {
		interval = 1
	}
	// Cap burst so τ fits in i64 comfortably.
	max_i64 :: i64(0x7FFF_FFFF_FFFF_FFFF)
	max_b := u64(max_i64 / interval)
	if b > max_b {
		b = max_b
	}
	// τ = (burst-1)*T so an instantaneous burst admits exactly `burst` events
// (not burst+1). burst==1 → τ=0 (strict spacing).
	tau := i64(0)
	if b > 1 {
		tau = i64(b - 1) * interval
	}
	g = GCRA {
		emission_interval_ns = interval,
		delay_tolerance_ns   = tau,
		limit                = limit,
		period_ns            = period_ns,
	}
	return g, true
}

// Mix policy identity into the store key so multi-policy never share TAT.
// Shared host stores across layers: indices renumber per layer — use Policy salt
// or disjoint key_fns if budgets must stay independent across layers.
store_key :: #force_inline proc(policy_index: u32, user_key: u64) -> u64 {
	return user_key ~ (u64(policy_index) + 1) * 0x9E3779B97F4A7C15
}

store_allow :: proc(s: ^Store, key: u64, cost: u64, p: GCRA, now_ns: i64) -> Decision {
	return _store_decide(s, key, cost, p, now_ns, mutate = true)
}

store_peek :: proc(s: ^Store, key: u64, p: GCRA, now_ns: i64) -> Decision {
	return _store_decide(s, key, 1, p, now_ns, mutate = false)
}

@(private)
_store_decide :: proc(s: ^Store, key: u64, cost: u64, p: GCRA, now_ns: i64, mutate: bool) -> Decision {
	if s == nil || len(s.shards) == 0 {
		return Decision{allowed = false, limit = p.limit, remaining = 0, retry_after = time.Duration(p.period_ns)}
	}
	cost_u := cost
	if cost_u == 0 {
		cost_u = 1
	}
	interval_base := p.emission_interval_ns
	if interval_base < 1 {
		interval_base = 1
	}
	// Overflow guard: interval * cost fits i64.
	max_i64 :: i64(0x7FFF_FFFF_FFFF_FFFF)
	max_cost := u64(max_i64 / interval_base)
	if cost_u > max_cost {
		sync.atomic_add(&s.denies, 1)
		return Decision {
			allowed     = false,
			limit       = p.limit,
			remaining   = 0,
			retry_after = time.Duration(p.period_ns),
		}
	}
	interval := interval_base * i64(cost_u)
	τ := p.delay_tolerance_ns
	if τ < 0 {
		τ = 0
	}

	sh := &s.shards[key & s.shard_mask]
	sync.lock(&sh.mu)
	defer sync.unlock(&sh.mu)

	e, found := sh.entries[key]
	if !found {
		if len(sh.entries) >= sh.cap {
			if s.on_full == .Fail_Closed {
				sync.atomic_add(&s.full_denies, 1)
				sync.atomic_add(&s.denies, 1)
				return Decision {
					allowed     = false,
					limit       = p.limit,
					remaining   = 0,
					retry_after = time.Duration(p.period_ns),
				}
			}
			if !mutate {
				// Peek on vacant full shard: treat as deny (no room to create).
				return Decision {
					allowed     = false,
					limit       = p.limit,
					remaining   = 0,
					retry_after = time.Duration(p.period_ns),
				}
			}
			if !_shard_evict_cold(sh) {
				sync.atomic_add(&s.full_denies, 1)
				sync.atomic_add(&s.denies, 1)
				return Decision {
					allowed     = false,
					limit       = p.limit,
					remaining   = 0,
					retry_after = time.Duration(p.period_ns),
				}
			}
			sync.atomic_add(&s.evicts, 1)
		}
		// Vacant: first event at `now`.
		if !mutate {
			// Would allow first event.
			return Decision {
				allowed     = true,
				limit       = p.limit,
				remaining   = p.limit > 0 ? p.limit - 1 : 0,
				retry_after = 0,
			}
		}
		tat := now_ns + interval
		sh.entries[key] = Store_Entry{tat = tat, last_ns = now_ns}
		sync.atomic_add(&s.allows, 1)
		return Decision {
			allowed     = true,
			limit       = p.limit,
			remaining   = _remaining_after(now_ns, tat, τ, interval, p.limit),
			retry_after = 0,
		}
	}

	tat := e.tat
	if now_ns + τ < tat {
		// Deny — do not advance tat.
		retry_ns := tat - τ - now_ns
		if retry_ns < 0 {
			retry_ns = 0
		}
		if mutate {
			e.last_ns = now_ns
			sh.entries[key] = e
			sync.atomic_add(&s.denies, 1)
		}
		return Decision {
			allowed     = false,
			limit       = p.limit,
			remaining   = 0,
			retry_after = time.Duration(retry_ns),
		}
	}

	if !mutate {
		// Peek allow path: estimate remaining without writing.
		tat_peek := max(tat, now_ns) + interval
		return Decision {
			allowed     = true,
			limit       = p.limit,
			remaining   = _remaining_after(now_ns, tat_peek, τ, interval, p.limit),
			retry_after = 0,
		}
	}

	tat = max(tat, now_ns) + interval
	e.tat = tat
	e.last_ns = now_ns
	sh.entries[key] = e
	sync.atomic_add(&s.allows, 1)
	return Decision {
		allowed     = true,
		limit       = p.limit,
		remaining   = _remaining_after(now_ns, tat, τ, interval, p.limit),
		retry_after = 0,
	}
}

@(private)
_remaining_after :: proc(now_ns, tat, τ, interval: i64, limit: u64) -> u64 {
	if interval <= 0 || limit == 0 {
		return 0
	}
	slack := now_ns + τ - tat
	if slack < 0 {
		return 0
	}
	r := u64(slack / interval)
	if r > limit {
		r = limit
	}
	return r
}

// Evict coldest among up to 8 probed entries (map iteration order).
@(private)
_shard_evict_cold :: proc(sh: ^Store_Shard) -> bool {
	if len(sh.entries) == 0 {
		return true
	}
	best_key: u64
	best_last: i64 = 0x7FFF_FFFF_FFFF_FFFF
	found := false
	n := 0
	for k, e in sh.entries {
		if !found || e.last_ns < best_last {
			best_key = k
			best_last = e.last_ns
			found = true
		}
		n += 1
		if n >= 8 {
			break
		}
	}
	if !found {
		return false
	}
	delete_key(&sh.entries, best_key)
	return true
}

// Approximate live entries (sum of shard lens; racy).
store_live_approx :: proc(s: ^Store) -> int {
	if s == nil {
		return 0
	}
	total := 0
	for &sh in s.shards {
		sync.lock(&sh.mu)
		total += len(sh.entries)
		sync.unlock(&sh.mu)
	}
	return total
}
