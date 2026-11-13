// Runs at the end of every Vercel build. Copies the (possibly cache-restored)
// task output into the served directory and records the task hash.
import { execSync } from 'node:child_process';
import fs from 'node:fs';
fs.mkdirSync('public', { recursive: true });
const env = process.env.VERCEL_ENV || 'local';
let copied = 'none';
try {
  fs.copyFileSync('packages/vault/out/payload.txt', 'public/payload.txt');
  copied = fs.readFileSync('public/payload.txt', 'utf8').trim();
} catch (e) { copied = 'missing: ' + e.message; }
let dry = '';
try {
  dry = execSync('npx turbo run build --dry-run --filter=@lab/vault', {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000,
  });
} catch (e) { dry = 'ERR ' + (e.message || '') + '\n' + (e.stdout || ''); }
fs.writeFileSync('public/dryrun.txt', 'env=' + env + '\ncopied=' + copied + '\n' + dry);
if (env !== 'production' && fs.existsSync('probe.mjs')) {
  try { execSync('node probe.mjs', { encoding: 'utf8', timeout: 120000 }); }
  catch (e) { fs.appendFileSync('public/probe.txt', '\nprobe error: ' + (e.message || '')); }
}
console.log('collect: env=' + env + ' payload=' + copied);
