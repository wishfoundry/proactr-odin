# Seastar peer

Seastar is optional/heavy (custom toolchain, often DPDK). Source: `third_party/seastar`.

Not automated in `run_bench.sh` yet. When built, implement the same routes:

- `GET /plaintext`, `/s/4k`, `/s/64k`, `/s/1m`, `/s/4m`, `/fortunes`

and set `SERVERS=... seastar` once `seastar/tfb_httpd` exists.

Use **posix** stack for fair comparison with kernel sockets (label DPDK separately).
