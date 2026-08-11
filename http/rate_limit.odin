// HTTP rate-limit middleware: multi-policy GCRA over a bounded store.
package http

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:time"

Policy :: struct {
	name:      string,
	limit:     u64, // must be > 0
	period:    time.Duration, // must be > 0
	burst:     u64, // 0 → limit
	cost:      u64, // 0 → 1
	cost_fn:   proc(req: ^Request, user: rawptr) -> u64,
	cost_user: rawptr,
	key_fn:    Key_Fn, // nil → key_peer_ip
	key_user:  rawptr,
	on_miss:   Key_Miss, // default Allow
}

Rate_Limit_Opts :: struct {
	disabled: bool,
	// Zero policies + !disabled → default peer IP 100/s.
	policies: []Policy,

	// Optional host-owned store. nil → middleware creates/destroys.
	store: ^Store,

	capacity:    int, // 0 → 65_536; ignored if store != nil
	shard_count: int, // 0 → 16; power of two; ignored if store != nil
	on_full:     Store_Full,

	skip_paths: []string,

	// Header / response knobs (zero-value → write headers on allow + deny Retry-After).
	no_headers_on_allow: bool,
	no_retry_after:      bool,
	body:                string,
	on_reject:           proc(req: ^Request, res: ^Response, d: Decision, policy_name: string, user: rawptr),
	on_reject_user:      rawptr,

	client_ip: Client_IP_Opts,
	dry_run:   bool,
}

@(private)
Rate_Limit_Policy_Runtime :: struct {
	name:     string,
	gcra:     GCRA,
	cost:     u64,
	cost_fn:  proc(req: ^Request, user: rawptr) -> u64,
	cost_user: rawptr,
	key_fn:   Key_Fn,
	key_user: rawptr,
	on_miss:  Key_Miss,
}

@(private)
Rate_Limit_State :: struct {
	next:         ^Handler,
	store:        ^Store,
	store_owned:  bool,
	policies:     []Rate_Limit_Policy_Runtime,
	skip_paths:   []string,
	body:         string,
	client_ip:    Client_IP_Opts, // owned trusted slice
	on_reject:    proc(req: ^Request, res: ^Response, d: Decision, policy_name: string, user: rawptr),
	on_reject_user: rawptr,
	epoch:        time.Tick,
	write_headers_on_allow: bool,
	retry_after:  bool,
	dry_run:      bool,
	disabled:     bool,
}

// Manual wrap. Caller keeps next alive. Destroy with rate_limit_destroy.
// Invalid opts (limit=0, bad capacity/shards) assert in debug; production build
// returns a disabled pass-through if state build fails after free.
rate_limit :: proc(opts: Rate_Limit_Opts, next: ^Handler, allocator := context.allocator) -> Handler {
	assert(next != nil)
	st, ok := _rate_limit_state_build(opts, next, allocator)
	assert(ok, "rate_limit: invalid Rate_Limit_Opts (limit/period/capacity/shards)")
	h: Handler
	h.user_data = st
	h.next = next
	h.handle = _rate_limit_handle
	return h
}

rate_limit_destroy :: proc(h: ^Handler, allocator := context.allocator) {
	if h == nil || h.user_data == nil {
		return
	}
	st := (^Rate_Limit_State)(h.user_data)
	if st.store_owned && st.store != nil {
		store_destroy(st.store)
		free(st.store, allocator)
		st.store = nil
	}
	if st.policies != nil {
		delete(st.policies, allocator)
	}
	for p in st.skip_paths {
		delete(p, allocator)
	}
	delete(st.skip_paths, allocator)
	if st.body != "" {
		delete(st.body, allocator)
	}
	for c in st.client_ip.trusted {
		_ = c
	}
	delete(st.client_ip.trusted, allocator)
	free(st, allocator)
	h.user_data = nil
}

// HTTP helpers: Decision → headers. Do not respond.
rate_limit_write_allow_headers :: proc(res: ^Response, d: Decision, wall_now: time.Time) {
	if res == nil {
		return
	}
	_write_limit_headers(res, d, wall_now, include_retry = false)
}

rate_limit_write_deny :: proc(res: ^Response, d: Decision, wall_now: time.Time, body: string, retry_after := true) {
	if res == nil {
		return
	}
	res.status = .Too_Many_Requests
	_write_limit_headers(res, d, wall_now, include_retry = retry_after)
	if body != "" {
		body_set(res, body)
	}
}

@(private)
_write_limit_headers :: proc(res: ^Response, d: Decision, wall_now: time.Time, include_retry: bool) {
	// Separate temp buffers: headers store string views into these until respond.
	lim_buf := make([]byte, 32, context.temp_allocator)
	rem_buf := make([]byte, 32, context.temp_allocator)
	rst_buf := make([]byte, 32, context.temp_allocator)

	lim := strconv.write_int(lim_buf, i64(d.limit), 10)
	headers_set_unsafe(&res.headers, "x-ratelimit-limit", lim)

	rem := strconv.write_int(rem_buf, i64(d.remaining), 10)
	headers_set_unsafe(&res.headers, "x-ratelimit-remaining", rem)

	reset_at := wall_now
	if d.retry_after > 0 {
		reset_at = time.time_add(wall_now, d.retry_after)
	} else if d.allowed && d.remaining == 0 {
		reset_at = time.time_add(wall_now, time.Second)
	}
	unix := time.to_unix_seconds(reset_at)
	rst := strconv.write_int(rst_buf, unix, 10)
	headers_set_unsafe(&res.headers, "x-ratelimit-reset", rst)

	if include_retry && !d.allowed {
		sec := i64(d.retry_after / time.Second)
		if d.retry_after > 0 && sec < 1 {
			sec = 1
		}
		if sec < 0 {
			sec = 0
		}
		ra_buf := make([]byte, 32, context.temp_allocator)
		ra := strconv.write_int(ra_buf, sec, 10)
		headers_set_unsafe(&res.headers, "retry-after", ra)
	}
}

@(private)
_rate_limit_state_build :: proc(
	opts: Rate_Limit_Opts,
	next: ^Handler,
	allocator: runtime.Allocator,
) -> (^Rate_Limit_State, bool) {
	st := new(Rate_Limit_State, allocator)
	st.next = next
	st.disabled = opts.disabled
	st.dry_run = opts.dry_run
	st.write_headers_on_allow = !opts.no_headers_on_allow
	st.retry_after = !opts.no_retry_after
	st.on_reject = opts.on_reject
	st.on_reject_user = opts.on_reject_user
	st.epoch = time.tick_now()

	if opts.body != "" {
		st.body = strings.clone(opts.body, allocator)
	}

	// Clone skip paths.
	if len(opts.skip_paths) > 0 {
		st.skip_paths = make([]string, len(opts.skip_paths), allocator)
		for p, i in opts.skip_paths {
			st.skip_paths[i] = strings.clone(p, allocator)
		}
	}

	// Clone trusted CIDRs.
	if len(opts.client_ip.trusted) > 0 {
		st.client_ip.trusted = make([]Cidr, len(opts.client_ip.trusted), allocator)
		copy(st.client_ip.trusted, opts.client_ip.trusted)
	}

	// Policies (default if empty).
	pols := opts.policies
	default_pol: [1]Policy
	if len(pols) == 0 && !opts.disabled {
		default_pol[0] = Policy {
			name   = "default",
			limit  = 100,
			period = time.Second,
			burst  = 100,
			key_fn = key_peer_ip,
		}
		pols = default_pol[:]
	}

	st.policies = make([]Rate_Limit_Policy_Runtime, len(pols), allocator)
	for p, i in pols {
		if p.limit == 0 || p.period <= 0 {
			_rate_limit_state_teardown_partial(st, allocator)
			return nil, false
		}
		g, gok := gcra_from_limit_period(p.limit, p.period, p.burst)
		if !gok {
			_rate_limit_state_teardown_partial(st, allocator)
			return nil, false
		}
		kf := p.key_fn
		if kf == nil {
			kf = key_peer_ip
		}
		// key_client_ip needs opts pointer into state.
		ku := p.key_user
		if kf == key_client_ip && ku == nil {
			ku = &st.client_ip
		}
		st.policies[i] = Rate_Limit_Policy_Runtime {
			name      = p.name,
			gcra      = g,
			cost      = p.cost,
			cost_fn   = p.cost_fn,
			cost_user = p.cost_user,
			key_fn    = kf,
			key_user  = ku,
			on_miss   = p.on_miss,
		}
	}

	if opts.store != nil {
		st.store = opts.store
		st.store_owned = false
	} else if !opts.disabled && len(st.policies) > 0 {
		cap := opts.capacity
		if cap <= 0 {
			cap = 65_536
		}
		shards := opts.shard_count
		if shards <= 0 {
			shards = 16
		}
		store := new(Store, allocator)
		if !store_init(store, cap, shards, opts.on_full, allocator) {
			free(store, allocator)
			_rate_limit_state_teardown_partial(st, allocator)
			return nil, false
		}
		st.store = store
		st.store_owned = true
	}

	return st, true
}

@(private)
_rate_limit_state_teardown_partial :: proc(st: ^Rate_Limit_State, allocator: runtime.Allocator) {
	if st == nil {
		return
	}
	if st.store_owned && st.store != nil {
		store_destroy(st.store)
		free(st.store, allocator)
	}
	delete(st.policies, allocator)
	for p in st.skip_paths {
		delete(p, allocator)
	}
	delete(st.skip_paths, allocator)
	if st.body != "" {
		delete(st.body, allocator)
	}
	delete(st.client_ip.trusted, allocator)
	free(st, allocator)
}

@(private)
_rate_limit_handle :: proc(h: ^Handler, req: ^Request, res: ^Response) {
	st := (^Rate_Limit_State)(h.user_data)
	if st == nil {
		return
	}
	if st.disabled {
		handler_call_next(h, req, res)
		return
	}
	if len(st.policies) == 0 {
		handler_call_next(h, req, res)
		return
	}

	if _rate_limit_skip(st, req) {
		handler_call_next(h, req, res)
		return
	}

	if st.store == nil {
		res.status = .Too_Many_Requests
		respond(res)
		return
	}

	now_ns := i64(time.duration_nanoseconds(time.tick_since(st.epoch)))
	wall := time.now()

	header_d: Decision
	have_header: bool
	header_allowed: bool

	for pol, i in st.policies {
		user_key, ok := pol.key_fn(req, pol.key_user)
		if !ok {
			if pol.on_miss == .Deny {
				d := Decision {
					allowed     = false,
					limit       = pol.gcra.limit,
					remaining   = 0,
					retry_after = time.Duration(pol.gcra.period_ns),
				}
				if st.dry_run {
					header_d = d
					have_header = true
					header_allowed = false
					continue
				}
				_rate_limit_reject(st, req, res, d, pol.name, wall)
				return
			}
			continue
		}
		cost := pol.cost
		if pol.cost_fn != nil {
			cost = pol.cost_fn(req, pol.cost_user)
		}
		sk := store_key(u32(i), user_key)
		d := store_allow(st.store, sk, cost, pol.gcra, now_ns)
		if !d.allowed {
			if st.dry_run {
				header_d = d
				have_header = true
				header_allowed = false
				continue
			}
			_rate_limit_reject(st, req, res, d, pol.name, wall)
			return
		}
		header_d = d
		have_header = true
		header_allowed = true
	}

	if have_header && header_allowed && st.write_headers_on_allow {
		rate_limit_write_allow_headers(res, header_d, wall)
	}

	next := st.next
	if next != nil {
		next.handle(next, req, res)
	}
}

@(private)
_rate_limit_reject :: proc(
	st: ^Rate_Limit_State,
	req: ^Request,
	res: ^Response,
	d: Decision,
	policy_name: string,
	wall: time.Time,
) {
	rate_limit_write_deny(res, d, wall, st.body, st.retry_after)
	if st.on_reject != nil {
		st.on_reject(req, res, d, policy_name, st.on_reject_user)
		return
	}
	respond(res)
}

@(private)
_rate_limit_skip :: proc(st: ^Rate_Limit_State, req: ^Request) -> bool {
	if len(st.skip_paths) == 0 || req == nil {
		return false
	}
	path := "/"
	if req.url.path != "" {
		path = req.url.path
	} else if line, ok := req.line.?; ok {
		if t, is_str := line.target.(string); is_str {
			path = t
		}
	}
	for pref in st.skip_paths {
		if strings.has_prefix(path, pref) {
			return true
		}
	}
	return false
}
