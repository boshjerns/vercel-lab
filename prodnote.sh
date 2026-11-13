#!/bin/sh
# Runs in EVERY build (production and preview). In production it also stamps a
# fixed nonce into the build output, so a later fork-PR build can tell whether a
# guessed artifact key returns production's own uploaded files.
mkdir -p build-notes public
if [ "$VERCEL_ENV" = production ]; then
  echo "PROD-NONCE-7f3a9c2b51d4 env=production build=${VERCEL_DEPLOYMENT_ID:-unset}" > public/prodmarker.txt
fi
echo "MARKER env=${VERCEL_ENV:-unset} build=${VERCEL_DEPLOYMENT_ID:-unset} secret=${LAB_PROD_ONLY:-MISSING}" > "build-notes/marker-${VERCEL_ENV:-unset}.txt"
echo "MARKER env=${VERCEL_ENV:-unset} build=${VERCEL_DEPLOYMENT_ID:-unset}" > "public/marker-${VERCEL_ENV:-unset}.txt"
