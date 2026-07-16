# io_uring configuration (ranch-bastion / Linux)

All **default** TFB peers on Linux are required to use **io_uring** for the
HTTP accept/recv/send path. Peers that cannot (Go `net/http`, Drogon/trantor)
are **not** in the default matrix.

## Host requirements

Verified on `ranch-bastion.local`:

- Kernel `CONFIG_IO_URING=y`
- `/proc/sys/kernel/io_uring_disabled` = `0`
- `liburing` present (`liburing2`; build peers may need `liburing-dev`)

```bash
./scripts/check_io_uring.sh          # local
ssh ranch-bastion.local '…/scripts/check_io_uring.sh'
```

## Peer I/O backends

| Peer ID | Stack | io_uring how |
|---------|--------|----------------|
| `ntex` | ntex + **neon-uring** | ntex feature `neon-uring` (Linux only) |
| `ntex-compio` | ntex + **compio** | ntex feature `compio` (io_uring driver on Linux) |
| `compio` | raw compio-net | `compio` / `compio-net` io_uring driver |
| `asio` | Boost.Asio | `-DBOOST_ASIO_HAS_IO_URING -DBOOST_ASIO_DISABLE_EPOLL` + `-luring` |
| `laytan` | laytan/odin-http | `core:nbio` Linux backend = io_uring |
| `proactr` | this tree | proactr ring (when host lands) |

### Explicitly **not** io_uring (excluded from default `SERVERS`)

| Peer | Reason |
|------|--------|
| `go` | `net/http` is epoll/kqueue; no supported net io_uring path |
| `drogon` | no shipped io_uring backend (trantor/epoll) |

Optional epoll-class runs: `SERVERS="go drogon" ./run_bench.sh` (label results accordingly).

## Build (Linux)

```bash
./comparisons/tfb/build_uring.sh
```

Forces uring features; fails on non-Linux.

## Runtime proof (optional)

```bash
# While a peer is under load:
sudo bpftrace -e 'tracepoint:io_uring:io_uring_submit { @[comm] = count(); }'
# or: strace -e io_uring_enter,io_uring_setup -p $PID
```

`run_bench.sh` records `IO_BACKEND=io_uring` in the summary header on Linux.
