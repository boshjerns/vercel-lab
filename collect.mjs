// Runs at the end of every Vercel build. Copies the (possibly cache-restored)
// task output into the served directory, records the task hash, and then asks
// the Remote Cache API about its own artifact using this build's own token.
// Prints only statuses, opaque ids and hashes - never the token.
import { execSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';

fs.mkdirSync('public', { recursive: true });
const env = process.env.VERCEL_ENV || 'local';
const TOKEN = process.env.VERCEL_ARTIFACTS_TOKEN || '';
const HOSTS = ['https://api-iad1.vercel.com', 'https://api-sfo1.vercel.com', 'https://api-fra1.vercel.com'];
// @lab/vault#build hash as reported by the production build's own dry-run
const PROD_HASH = 'ef9cee4251207927';
const out = [];
function log(s) { out.push(String(s)); }

function sha(b) { return createHash('sha256').update(b).digest('hex').slice(0, 16); }

async function api(host, path, opts = {}) {
  try {
    const r = await fetch(host + path, {
      method: opts.method || 'GET',
      headers: { Authorization: 'Bearer ' + TOKEN, ...(opts.headers || {}) },
      body: opts.body,
    });
    const buf = Buffer.from(await r.arrayBuffer());
    return { status: r.status, buf, text: buf.toString().slice(0, 300) };
  } catch (e) {
    return { status: 0, buf: Buffer.alloc(0), text: 'ERR ' + (e.message || '') };
  }
}

(async () => {
  log('== collect + self-check ==');
  log('env=' + env + ' token=' + (TOKEN ? 'present' : 'ABSENT'));

  // 1. payload that this build ended up with (restored from cache or freshly built)
  let copied = 'none';
  try {
    fs.copyFileSync('packages/vault/out/payload.txt', 'public/payload.txt');
    copied = fs.readFileSync('public/payload.txt', 'utf8').trim();
  } catch (e) { copied = 'missing: ' + e.message; }
  log('copied=' + copied);

  // 2. this build's own view of the task hash and cache state
  let dry = '';
  try {
    dry = execSync('npx turbo run build --dry-run --filter=@lab/vault', {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000,
    });
  } catch (e) { dry = 'ERR ' + (e.message || '') + '\n' + (e.stdout || ''); }
  fs.writeFileSync('public/dryrun.txt', 'env=' + env + '\ncopied=' + copied + '\n' + dry);
  // turbo pads its dry-run columns, so match "Hash ... = <16 hex>" loosely
  const m = dry.match(/@lab\/vault#build[\s\S]{0,400}?Hash\s*=\s*([0-9a-f]{16})/);
  const ownHash = m ? m[1] : 'unparsed';
  const remoteHit = /Cached \(Remote\)\s*=\s*true/.test(dry);
  log('ownHash=' + ownHash + ' remoteCacheHit=' + remoteHit);

  // 3. pick a reachable region host
  let host = '';
  for (const h of HOSTS) {
    const s = await api(h, '/v8/artifacts/status');
    log('reach ' + h + ' -> ' + s.status + ' ' + s.text);
    if (s.status >= 200 && s.status < 500) { host = h; break; }
  }
  if (!host) { log('no reachable artifacts host'); }
  else {
    let team = '';
    try {
      const claims = JSON.parse(Buffer.from(TOKEN.split('.')[1], 'base64').toString('utf8'));
      const pol = (claims.data && claims.data.secureCachePolicy && claims.data.secureCachePolicy.policy) || {};
      team = pol.ownerId || (claims.data && claims.data.ownerId) || '';
      log('readNs=' + JSON.stringify(pol.readNamespaces || []) + ' writeNs=' + JSON.stringify(pol.writeNamespace) +
          ' repo=' + (pol.repository && pol.repository.id) + ' source=' + (pol.sourceRepository && pol.sourceRepository.id));
    } catch (e) { log('claims parse failed: ' + e.message); }

    // 4. control upload: where does a brand new key land?
    const ctrl = 'lab-ctrl-' + env + '-' + Date.now().toString(36);
    const w = await api(host, '/v8/artifacts/' + ctrl + '?teamId=' + team, {
      method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' },
      body: Buffer.from('CONTROL-' + ctrl),
    });
    log('PUT control ' + ctrl + ' -> ' + w.status + ' ' + w.text);

    // 5. is our own just-uploaded artifact addressable by the printed task hash?
    const g = await api(host, '/v8/artifacts/' + ownHash + '?teamId=' + team);
    log('GET ownHash ' + ownHash + ' -> ' + g.status + ' size=' + g.buf.length + ' sha=' + (g.buf.length ? sha(g.buf) : '-') + ' ' + (g.status !== 200 ? g.text : ''));

    // 6. existence oracle (POST /v8/artifacts with {hashes:[...]})
    const o = await api(host, '/v8/artifacts?teamId=' + team, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hashes: [ownHash] }),
    });
    log('POST oracle ownHash -> ' + o.status + ' ' + o.text);

    // 7. cross-namespace read: the production task hash, from a non-production build
    if (env !== 'production' && ownHash !== PROD_HASH) {
      const p = await api(host, '/v8/artifacts/' + PROD_HASH + '?teamId=' + team);
      log('GET prodHash ' + PROD_HASH + ' -> ' + p.status + ' size=' + p.buf.length + ' sha=' + (p.buf.length ? sha(p.buf) : '-') + ' ' + (p.status !== 200 ? p.text : ''));
      for (const ns of ['shared', 'branch', 'historical']) {
        const q = await api(host, '/v8/artifacts/' + PROD_HASH + '?teamId=' + team + '&namespace=' + ns);
        log('GET prodHash ns=' + ns + ' -> ' + q.status + ' size=' + q.buf.length + ' sha=' + (q.buf.length ? sha(q.buf) : '-'));
      }
    }
  }

  fs.writeFileSync('public/selfcheck.txt', out.join('\n') + '\n');
  console.log(out.join('\n'));

  // 8. the namespace write probe runs only in preview builds
  if (env !== 'production' && fs.existsSync('probe.mjs')) {
    try { execSync('node probe.mjs', { encoding: 'utf8', timeout: 120000 }); }
    catch (e) { fs.appendFileSync('public/probe.txt', '\nprobe error: ' + (e.message || '')); }
  }
})().catch(e => {
  fs.writeFileSync('public/selfcheck.txt', out.join('\n') + '\nfatal: ' + (e && e.message));
});
