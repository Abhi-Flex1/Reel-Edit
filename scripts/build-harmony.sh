#!/usr/bin/env bash
#
# Builds Reel-Edit for HarmonyOS PC (2in1): web bundle -> staged rawfile -> HAP.
#
# The editor is a web app, so the HarmonyOS build is three ordered steps:
#
#   1. the engine's WASM modules (FFT / WAV / beat detection), which are built
#      from AssemblyScript and are not checked in;
#   2. the desktop-mode web bundle, which inlines fonts and rewrites asset URLs
#      so the app works with no network;
#   3. hvigor, which packages that bundle into the HAP alongside the ArkTS
#      module and the native encoder.
#
# OPENREEL_HARMONY=1 additionally removes window.VideoEncoder from the bundle:
# export runs through the platform's native encoder, so the in-page WebCodecs
# fast path must not be offered.
#
# Usage: scripts/build-harmony.sh
set -euo pipefail

cd "$(dirname "$0")/.."

: "${DEVECO_SDK_HOME:=$HOME/Developer/command-line-tools/sdk}"
export DEVECO_SDK_HOME

echo "==> Building engine WASM modules"
pnpm --filter @openreel/core build:wasm

echo "==> Typechecking the web app"
pnpm --filter @openreel/web exec tsc --noEmit

echo "==> Building the web bundle (offline desktop mode)"
(cd apps/web && OPENREEL_DESKTOP=1 OPENREEL_HARMONY=1 pnpm exec vite build)

echo "==> Staging the bundle into the HAP rawfile"
node scripts/build-web-for-harmony.mjs

echo "==> Packaging the HAP"
hvigorw assembleApp

echo
echo "Built:"
echo "  entry/build/default/outputs/default/entry-default-unsigned.hap"
echo "  build/outputs/default/Reel-Edit-default-unsigned.app"
