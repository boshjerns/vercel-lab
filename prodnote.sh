#!/bin/sh
# Runs in EVERY build (v2) (production and preview). Writes a marker whose name
# contains the environment, so a later build can tell whether it inherited
# another environment's build-cache snapshot.
mkdir -p build-notes public
echo "MARKER env=${VERCEL_ENV:-unset} build=${VERCEL_DEPLOYMENT_ID:-unset} secret=${LAB_PROD_ONLY:-MISSING}" > "build-notes/marker-${VERCEL_ENV:-unset}.txt"
echo "MARKER env=${VERCEL_ENV:-unset} build=${VERCEL_DEPLOYMENT_ID:-unset}" > "public/marker-${VERCEL_ENV:-unset}.txt"
