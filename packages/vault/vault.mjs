import { writeFileSync, mkdirSync } from 'node:fs';
const secret = process.env.LAB_PROD_ONLY || 'MISSING';
mkdirSync('out', { recursive: true });
writeFileSync('out/secret.txt',
  'PROD-ONLY-SECRET=' + secret + ' env=' + (process.env.VERCEL_ENV || '?') + '\n');
console.log('vault: wrote out/secret.txt during ' + (process.env.VERCEL_ENV || '?') + ' build');
