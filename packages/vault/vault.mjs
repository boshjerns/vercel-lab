// Deterministic build task: writes a fixed marker into the declared output dir.
// The content is a constant so that the uploaded cache blob is byte-predictable.
import { writeFileSync, mkdirSync } from 'node:fs';
mkdirSync('out', { recursive: true });
writeFileSync('out/payload.txt', 'PROD-PAYLOAD-MARKER-7c31\n');
console.log('vault: wrote out/payload.txt in ' + (process.env.VERCEL_ENV || '?') + ' build');
