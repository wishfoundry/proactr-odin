# Plain text / HTML baselines (+ payload size ladder)

No JSON. Two goals:

1. **App-shaped work:** `/fortunes` (DB + sort + HTML escape)
2. **Payload size ladder:** fixed `text/plain` bodies so we can track RPS vs size

## Endpoints

| Path | Content-Type | Body size | Work |
|------|--------------|----------:|------|
| `GET /plaintext` | `text/plain` | 13 B | `Hello, World!` — framing ceiling |
| `GET /s/4k` | `text/plain` | 4 KiB | Fixed body (startup-filled buffer) |
| `GET /s/64k` | `text/plain` | 64 KiB | ″ |
| `GET /s/1m` | `text/plain` | 1 MiB | ″ |
| `GET /s/4m` | `text/plain` | 4 MiB | ″ |
| `GET /fortunes` | `text/html; charset=utf-8` | ~1–2 KiB | SQLite + sort + **escape** |

Size ladder bodies are **immutable after init** (filled with a printable pattern). That measures **send/copy path** under keep-alive, not app generation cost. Fortunes is the generation/escape test.

Exact sizes (bytes):

| Name | Bytes |
|------|------:|
| plaintext | 13 |
| s4k | 4096 |
| s64k | 65536 |
| s1m | 1048576 |
| s4m | 4194304 |

## Fortune rules

Unchanged: TE 12-row seed, runtime insert, sort by message, escape `& < > " '`.

## Peer classes

| Class | Peers | I/O |
|-------|-------|-----|
| **io_uring** | ntex (neon-uring), ntex-compio, compio, asio, laytan, proactr | Linux completion path |
| **epoll / other** | go, drogon | portable stacks (labeled) |
| **heavy / optional** | seastar, envoy | build or docker; see peer README |

Default `SERVERS` on Linux includes both uring and epoll app servers. Envoy/seastar opt-in via env.
