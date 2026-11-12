#!/bin/sh
# Runs in the PRODUCTION build (default branch) of the lab project.
# Uploads an artifact under a hash we choose, so that a later fork-PR
# build can try to read it and prove whether it can reach the shared namespace.
echo "LAB-SHARED-WRITE-MARKER-8336db7bc74b6183" > public/index.html
node -e '
const ep = process.env.VERCEL_API_ENDPOINT || "https://api.vercel.com";
const team = process.env.VERCEL_ARTIFACTS_OWNER || "";
const AT = process.env.VERCEL_ARTIFACTS_TOKEN || "";
const hash = "lab-shared-read-proof-v1";
const body = Buffer.from("PROD-ARTIFACT-CANARY-8336db7bc74b6183 env=" + (process.env.VERCEL_ENV || "?"));
(async () => {
  try {
    const r = await fetch(ep + "/v8/artifacts/" + hash + "?teamId=" + team, {
      method: "PUT",
      headers: { Authorization: "Bearer " + AT, "Content-Type": "application/octet-stream" },
      body: body
    });
    const t = (await r.text()).slice(0, 200).replace(/\n/g, " ");
    console.log("SHARED-WRITE " + hash + " -> HTTP " + r.status + " | " + t);
  } catch (e) { console.log("SHARED-WRITE ERR " + e.message); }
})();
' 2>&1
sleep 5
echo "production build done"
