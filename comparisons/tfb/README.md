# Plain text / HTML baselines (io_uring on Linux)

**No JSON.** Routes:

| Path | Role |
|------|------|
| `GET /plaintext` | I/O ceiling (`text/plain`) |
| `GET /fortunes` | **Primary** — DB + sort + HTML escape |

## io_uring (ranch-bastion)

Default `SERVERS` on Linux are **io_uring-backed only**. See [`IO_URING.md`](IO_URING.md).

| Peer | Backend |
|------|---------|
| `ntex` | neon-uring |
| `ntex-compio` | ntex + compio runtime |
| `compio` | compio-net (io_uring driver) |
| `asio` | `BOOST_ASIO_HAS_IO_URING` + `DISABLE_EPOLL` |
| `laytan` | core:nbio Linux = io_uring |
| `proactr` | (when live) |

**Not** in default matrix (no net io_uring): `go`, `drogon`.

## ranch-bastion quick start

```bash
# from laptop
rsync -az --exclude '.git' --exclude '**/target' \
  ./ ranch-bastion.local:Projects/proactr-odin/

ssh ranch-bastion.local '
  export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"
  cd ~/Projects/proactr-odin
  ./scripts/check_io_uring.sh
  ./comparisons/tfb/build_uring.sh
  SERVERS="ntex ntex-compio compio laytan" \
    BENCH_Z=15s BENCH_C=64 WORKERS=8 \
    ./comparisons/tfb/run_bench.sh | tee /tmp/proactr-tfb-uring.log
'
```

Optional Asio (needs `libsqlite3-dev` + `liburing-dev`):

```bash
SERVERS="ntex ntex-compio compio asio laytan" ./comparisons/tfb/run_bench.sh
```

## Env

| Var | Default (Linux) |
|-----|-----------------|
| `SERVERS` | `ntex ntex-compio compio laytan` |
| `TESTS` | `plaintext fortunes` |
| `REQUIRE_URING` | `1` (runs `scripts/check_io_uring.sh`) |
| `DATABASE_PATH` | `/tmp/proactr-tfb.sqlite` |
| `WORKERS` | `1` |
| `BENCH_C` / `BENCH_Z` | `64` / `15s` |
