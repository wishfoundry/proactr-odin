#!/usr/bin/env bash
# Fail if this host cannot run io_uring-backed peers.
set -euo pipefail

ok=1

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "FAIL: not Linux ($(uname -s)); io_uring peers are Linux-only"
  exit 1
fi

echo "kernel: $(uname -r)"

if [[ -r /proc/sys/kernel/io_uring_disabled ]]; then
  v=$(cat /proc/sys/kernel/io_uring_disabled)
  echo "io_uring_disabled=$v"
  if [[ "$v" != "0" ]]; then
    echo "FAIL: io_uring disabled via sysctl (want 0)"
    ok=0
  fi
else
  echo "WARN: no /proc/sys/kernel/io_uring_disabled (old kernel?)"
fi

if [[ -r /boot/config-$(uname -r) ]]; then
  if grep -q '^CONFIG_IO_URING=y' /boot/config-$(uname -r); then
    echo "CONFIG_IO_URING=y"
  else
    echo "FAIL: CONFIG_IO_URING not y in /boot/config-$(uname -r)"
    ok=0
  fi
fi

# Probe syscall availability via python if present
if command -v python3 >/dev/null; then
  python3 - <<'PY' || ok=0
import ctypes, ctypes.util, os, sys
# io_uring_setup = 425 on x86_64
NR = 425
libc = ctypes.CDLL(None, use_errno=True)
# negative size should fail with EINVAL if syscall exists, ENOSYS if not
class Params(ctypes.Structure):
    _fields_ = [("sq_entries", ctypes.c_uint), ("cq_entries", ctypes.c_uint),
                ("flags", ctypes.c_uint), ("sq_thread_cpu", ctypes.c_uint),
                ("sq_thread_idle", ctypes.c_uint), ("features", ctypes.c_uint),
                ("wq_fd", ctypes.c_uint), ("resv", ctypes.c_uint * 3),
                ("sq_off", ctypes.c_uint * 10), ("cq_off", ctypes.c_uint * 10)]
# Just check ENOSYS via raw syscall with null params carefully — use os.syscall if available
try:
    # syscall(io_uring_setup, 0, NULL) → EINVAL or EFAULT if present
    libc.syscall.restype = ctypes.c_long
    r = libc.syscall(NR, 0, None)
    err = ctypes.get_errno()
    if r < 0 and err == 38:  # ENOSYS
        print("FAIL: io_uring_setup ENOSYS")
        sys.exit(1)
    print(f"io_uring_setup probe: ret={r} errno={err} (syscall present)")
except Exception as e:
    print("WARN: probe failed:", e)
PY
fi

if command -v pkg-config >/dev/null && pkg-config --exists liburing; then
  echo "liburing: $(pkg-config --modversion liburing)"
elif [[ -f /usr/include/liburing.h ]]; then
  echo "liburing.h: present"
else
  echo "WARN: liburing headers not found (needed for Asio -luring builds)"
fi

if [[ "$ok" -ne 1 ]]; then
  exit 1
fi
echo "OK: io_uring available"
