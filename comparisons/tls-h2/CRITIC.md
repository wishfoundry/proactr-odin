# Harsh critic — TLS/H2 peer matrix

Role: adversarial correctness + honesty for **proactr vs ntex / drogon / go** under **TLS** and **HTTP/2**.

**Scope:** `comparisons/tls-h2/` harness + peers + instrumentation  
**Do not** accept cleartext TFB numbers as TLS/H2 evidence.

---

## Verdict template

**Verdict:** PASS | FAIL  
**Date:**  
**Built peers:**  
**Ran peers:**  

---

## Backend labels (required)

| Peer | I/O | TLS stack | H2 |
|------|-----|-----------|-----|
| proactr | io_uring | OpenSSL mem-BIO | ALPN h2 host |
| ntex | neon-uring | OpenSSL | bind_openssl ALPN h2\|http/1.1 |
| drogon | trantor **epoll** | OpenSSL | primarily H1; no_h2 → N/A |
| go | net/http epoll | crypto/tls | auto HTTP/2 |

---

## Fake-bench checklist

| # | Check | Required |
|---|--------|----------|
| C1 | ntex peer exists, builds, runs under TLS | CRITICAL |
| C2 | drogon peer exists, builds, runs under TLS | CRITICAL |
| C3 | go peer under TLS H1 + H2 | CRITICAL |
| C4 | Same routes, body lens, certs, WORKERS, host | CRITICAL |
| C5 | h2 cell requires Application protocol h2 else N/A | CRITICAL |
| C6 | failed/errored/timeout → INVALID not silent RPS | CRITICAL |
| C7 | Body content prefix (not length-only) | IMPORTANT |
| C8 | Backend labels in SUMMARY | CRITICAL |
| C9 | Clear TFB numbers never mixed into this table | CRITICAL |
| C10 | Instrumentation scrape after cells | IMPORTANT |
| C11 | drogon h2 not claimed as product win if no_h2 | CRITICAL |
| C12 | Worker model labels (GOMAXPROCS vs threads) | IMPORTANT |

---

## Instrumentation minimum

| Peer | Scrape |
|------|--------|
| proactr | `/_matrix/stats` seal/pt/ct/h2_flush + optional PHASE |
| ntex/go/drogon | `/_matrix/stats` reqs + bytes |

---

## Always-do

1. Read wire paths, not README claims.
2. Empty peer dirs = FAIL.
3. Prefer CRITICAL / IMPORTANT / NIT.
4. Top 3 code fixes ordered by truthfulness then RPS insight.
