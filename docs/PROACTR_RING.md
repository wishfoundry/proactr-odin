# proactr io_uring ring (Phase 1)

## Constraints

- **Raw syscalls only** via `core:sys/linux` (`io_uring_setup`, `io_uring_enter` / `enter2`, `mmap`, `munmap`, `close`).
- **No liburing.** **No `core:nbio`.** We do not import `core:sys/linux/uring` either — proactr owns SQ/CQ mapping and SQE prep so the hot path stays explicit and free of third-party ring helpers.
- Public model: `ring_init` → `submit_*` → `ring_submit` / `ring_wait` / `ring_peek` → `complete_apply`.

## Setup

`io_uring_setup(entries, &params)` with progressive flag fallback (first set that the kernel accepts wins):

| Order | Flags | Why |
|------:|-------|-----|
| 1 | `CLAMP` + `SINGLE_ISSUER` + `COOP_TASKRUN` + `DEFER_TASKRUN` | One worker owns the ring (v1 model); coop + deferred taskrun reduces IPIs / taskwork thrash on modern kernels (6.1+). |
| 2 | `CLAMP` + `SINGLE_ISSUER` + `COOP_TASKRUN` | Same without `DEFER_TASKRUN` (older 6.x). |
| 3 | `CLAMP` + `COOP_TASKRUN` | Multi-task submit still allowed; still cooperative taskrun. |
| 4 | `CLAMP` only | Oldest viable baseline (5.x with clamp). |

**`CLAMP`:** if the requested entry count is out of range or awkward, the kernel clamps instead of failing setup. We also round up to the next power of two (cap 4096) before setup.

**Not enabled in v1:**

- **`SQPOLL`** — kernel SQ thread needs privileges/careful testing; skip until measured.
- **`IOPOLL`** — storage path; not for sockets.
- **`SQE128` / `CQE32`** — non-standard entry sizes; v1 assumes 64-byte SQE / 16-byte CQE.

After setup we require **`IORING_FEAT_SINGLE_MMAP`** (kernel 5.4+): one shared mapping for SQ+CQ rings, second mapping for the SQE array (`IORING_OFF_SQ_RING`, `IORING_OFF_SQES`).

## Mapping

```
mmap(ring_fd, IORING_OFF_SQ_RING)  → head/tail/mask/flags + SQ array + CQEs
mmap(ring_fd, IORING_OFF_SQES)     → []IO_Uring_SQE
```

Local `sqe_head` / `sqe_tail` batch array updates; `ring_submit` / `ring_wait` flush the kernel SQ tail with release semantics (liburing-compatible).

## Ops

| API | Opcode | `user_data` |
|-----|--------|-------------|
| `submit_nop` | `NOP` | dense op id |
| `submit_accept` | `ACCEPT` | dense op id (`CLOEXEC\|NONBLOCK` on new fd) |
| `submit_recv` | `RECV` | dense op id |
| `submit_send` | `SEND` | dense op id |
| `submit_writev` | `WRITEV` | dense op id |
| `submit_sendfile` | soft_cq / POLL | dense op id (see below) |
| `submit_close` | `CLOSE` | dense op id |

Op slab lives in `Ring.ops`; free list recycles ids. CQ harvest fills `Completion{op_id, result, flags}`; `complete_apply` writes `Op.result` / `.Completed`.

### Sendfile soft-complete (Linux)

Linux `submit_sendfile` is **not** a pure io_uring opcode for file→socket. The façade runs synchronous `sendfile(2)` in a short drive loop, posts progress via **`soft_cq`**, and on **EAGAIN** arms **`POLL_ADD` (POLLOUT)** then retries before completing. Host (`http/wire.odin`) owns remaining progress via `file_send_*` and resubmits until the region is done. **SIGPIPE** is ignored at `serve` so a client disconnect mid-sendfile returns `-EPIPE` instead of killing the process (exit 141). `connection_close` defers while `wire == .Sendfile` so the op user and `file_send_*` stay valid for the soft CQE.

**Hard rules**

- **Buffers stay valid until CQE.** For `submit_recv` / `submit_send` / `submit_writev`, the caller-owned buffers (and Connection `exec_bufs` / `iovecs`) must remain live and unchanged from SQE prep until the matching completion is harvested (and applied). Freeing or reusing the buffer earlier is undefined.
- **`op_free` only after Idle / Completed / Cancelled.** Never free a `.Submitted` (in-flight) op; the free list would recycle `user_data` while a CQE can still arrive.

## Enter / wait

- **`ring_submit`:** flush SQ → `io_uring_enter(to_submit, 0, …)`.
- **`ring_wait`:** harvest ready CQEs; if need more, flush + enter with `GETEVENTS`. `wait_nr` is `max(0, min_complete − already_harvested)`, clamped to remaining `out` capacity. Positive `timeout_ms` uses `io_uring_enter2` + **`EXT_ARG`** + `Time_Spec` **only when `IORING_FEAT_EXT_ARG` is present**; without that feature, a positive timeout does not arm a kernel wait timeout (enter still runs, but may block on `wait_nr` without a deadline).
- **`ring_peek`:** `min_complete=0`, `timeout_ms=0` (non-blocking harvest; still submits pending SQEs when useful).

### `DEFER_TASKRUN`

When setup kept `DEFER_TASKRUN` (preferred flag set on modern kernels), completions are not fully processed until the application enters with **`IORING_ENTER_GETEVENTS`**. Therefore:

- Even a **peek** (`min_complete=0`) still does enter+`GETEVENTS` when the CQ is empty (or more generally when no early harvest satisfied the request), so deferred task work can post CQEs.
- Hosts should prefer **`ring_wait(min_complete=1)`** (blocking, or with timeout) as the primary idle path rather than spinning only on `ring_peek`, so task work and completions progress under `DEFER_TASKRUN`.

## Platforms

See `docs/PROACTR.md` for the full multi-OS matrix. This file documents the **Linux io_uring** engine only.

| OS | File | Behavior |
|----|------|----------|
| Linux | `platform_linux.odin` | io_uring (this doc) |
| Windows | `platform_windows.odin` | IOCP |
| Darwin/BSD | `platform_kqueue.odin` | kqueue façade |
| Other | `platform_stub.odin` | `ring_init` → `.Unsupported` |

## Smoke

```text
odin run examples/ring_smoke
# OK on linux (io_uring), darwin/bsd (kqueue), windows (iocp)
```
