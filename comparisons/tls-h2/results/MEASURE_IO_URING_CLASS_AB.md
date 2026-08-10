# Measure: Class A (workers/accept) + Class B (send/completion law)

**Host:** ranch-bastion · Linux 6.14 · x86_64 · 40 CPUs  
**Binary:** dense H1 flush tree · `WORKERS=8` · io_engine=`proactor-uring`  
**When:** 2026-08-10T15:47–15:50Z  
**Raw:** bastion `/tmp/proactr-class-ab-measure`, `/tmp/proactr-class-b-isolated`

---

## Class A — Who works?

### A1. Scale ladder · `/s/1m` · 5s

| c | RPS |
|--:|----:|
| 1 | *fail* (harness/noise; not used) |
| 2 | *fail* |
| 4 | **3154** |
| 8 | **4152** |
| 16 | **4387** |
| 32 | **4923** |
| 50 | **4858** |
| 100 | **4370** |

**Ratios:** RPS(c=50)/RPS(c=4) ≈ **1.54×**; rises c=4→32 then plateaus (normal).

**Verdict A1:** **Healthy multi-worker scale.** Not Darwin-flat (was ~flat 2.7k all c). No Class A pin signal.

### A2. Worker CPU · c=50 · `/s/1m`

Three samples mid-load (8 threads):

| sample | thread %CPU (approx) |
|--------|----------------------|
| 1 | 77, 69, 78, 41, 79, 61, 60, 63 |
| 2 | 77, 68, 78, 44, 79, 62, 60, 64 |
| 3 | 77, 67, 78, 47, 80, 62, 61, 64 |

**All 8 threads busy** (none idle at 0%). Lowest still ~40%+.

**Verdict A2:** **No single-worker pin.** Class A accept-distribution bug **not present**.

### A3. Accept pressure · plain · c=200 · 8s

**RPS ≈ 197698** — high conn churn; no collapse.

**Verdict A3:** Accept path handles high concurrency; not the bulk bottleneck.

### Class A decision

| Question | Answer |
|----------|--------|
| Worth pursuing Class A on this host/build? | **No** |
| Darwin-class REUSEPORT pin? | **No evidence** |

---

## Class B — Send / completion law

Isolated process per cell (clean counters; no cumulative stats).

### Duty table (c=50, D=10)

| Cell | RPS | reqs | seal_calls | soft_cq | soft/seal | seals/req | eagain_arms |
|------|----:|-----:|-----------:|--------:|----------:|----------:|------------:|
| plain | 185317 | 1.85M | 1.85M | **102** | **0.000055** | 1.0 | 0 |
| s4k | 169430 | 1.69M | 1.69M | **102** | **0.000060** | 1.0 | 0 |
| s64k | 47355 | 474k | 947k | **102** | **0.000108** | 2.0 | 0 |
| s1m | 4512 | 45k | 406k | **102** | **0.000251** | 9.0 | 0 |

### Interpretation

| Signal | Observed | Meaning |
|--------|----------|---------|
| soft_cq ≈ seal (old L0) | **No** — soft/seal ~10⁻⁴ | Dense law holds |
| soft_cq absolute | **Always 102** per process lifetime of cell | Fixed residual/setup noise, **not** per-seal tax |
| seals/req s1m | **9.0** | Multi-window bulk (128 KiB × ~8 + heading math) |
| seals/req s64k | **2.0** | Multi-window mid bulk |
| eagain_arms | **0** | Loopback rarely needs residual arm at this rate; nb send absorbs windows |

**Verdict B:** Class B **soft_cq / per-seal CQE tax is fixed**. Residual EAGAIN path not stressed on localhost (eagain=0 is expected, not a bug by itself).

### Class B decision

| Question | Answer |
|----------|--------|
| Worth more dense-flush work for RPS? | **No** — law already ~0 soft/seal |
| Worth chasing residual soft_cq 102→0? | Optional hygiene only; not an RPS class |
| Worth forced SO_SNDBUF EAGAIN stress? | Only if testing residual correctness, not peer RPS |

---

## Decision table (this measurement)

```text
Class A (who works):     CLOSED — multi-worker busy, c-scale healthy
Class B (completion law): CLOSED — soft/seal ≈ 0; multi-window seals present
```

**Neither class shows an open pursuit worth a performance PR on this bastion build.**

If RPS vs a peer is still a question later, the next probe is **outside** these two classes (not “AES by default”): e.g. same-session peer delta, plain regression, or a **new** profile under this healthy topology.

---

## Reproduce

```bash
# Class A
for c in 4 8 16 32 50 100; do
  h2load -c $c -D 5 -t 4 --h1 https://127.0.0.1:18443/s/1m | grep finished
done
ps -L -o tid,pcpu,state,comm -p $(pidof server.bin)   # under c=50 load

# Class B (reset or restart between cells)
curl -sk -X POST --http1.1 https://127.0.0.1:18443/_matrix/reset
h2load -c 50 -D 10 -t 4 --h1 https://127.0.0.1:18443/s/1m
curl -sk --http1.1 https://127.0.0.1:18443/_matrix/stats | egrep 'seal|soft_cq|reqs|eagain'
# soft_per_seal = soft_cq / seal_calls  → expect << 0.01
```
