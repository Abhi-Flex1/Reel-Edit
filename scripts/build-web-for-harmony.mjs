#!/usr/bin/env node
/*
 * Stages the built editor into the HAP's rawfile directory.
 *
 * The web bundle is built with OPENREEL_DESKTOP=1 (see the root package.json),
 * which switches asset URLs to relative paths and prunes the web fonts down to
 * the curated set. That makes the bundle fully offline, which is what the
 * ArkWeb host needs: it serves these files over a virtual origin instead of the
 * network.
 *
 * Usage: node scripts/build-web-for-harmony.mjs
 */

import { cp, mkdir, rm, writeFile, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");

const webDist = path.join(repoRoot, "apps", "web", "dist");
const rawfileDir = path.join(repoRoot, "entry", "src", "main", "resources", "rawfile", "web");

/**
 * Injects the bridge adapter so it runs before the app bundle.
 *
 * registerJavaScriptProxy only installs its object once the page loads, so the
 * adapter has to be present before the editor's first render — the app bundle
 * reads window.openreel during startup. It is therefore placed ahead of the
 * first <script type="module"> tag and given a plain (non-defer) script tag so
 * it executes in document order.
 */
async function injectBridge(html) {
  const tag = '<script src="./reel_bridge.js"></script>';
  if (html.includes("reel_bridge.js")) {
    return html;
  }
  const moduleTag = html.match(/<script[^>]*type="module"[^>]*><\/script>/);
  if (moduleTag && moduleTag.index !== undefined) {
    const at = moduleTag.index;
    return `${html.slice(0, at)}  ${tag}\n  ${html.slice(at)}`;
  }
  if (html.includes("</head>")) {
    return html.replace("</head>", `  ${tag}\n  </head>`);
  }
  return `${tag}\n${html}`;
}

async function main() {
  if (!existsSync(webDist)) {
    console.error(
      `[harmony-web] missing ${webDist}. Run: pnpm --filter @openreel/web exec vite build (with OPENREEL_DESKTOP=1)`,
    );
    process.exitCode = 1;
    return;
  }

  // reel_bridge.js is hand-written and lives beside the staged output, so it is
  // preserved across the wipe that replaces the directory with the fresh build.
  const adapterSource = path.join(rawfileDir, "reel_bridge.js");
  let adapterBackup = null;
  if (existsSync(adapterSource)) {
    adapterBackup = path.join(repoRoot, ".harmony-web-cache", "reel_bridge.js");
    await mkdir(path.dirname(adapterBackup), { recursive: true });
    await cp(adapterSource, adapterBackup);
  }

  await rm(rawfileDir, { recursive: true, force: true });
  await mkdir(rawfileDir, { recursive: true });
  await cp(webDist, rawfileDir, { recursive: true });

  if (adapterBackup) {
    await cp(adapterBackup, adapterSource);
    await rm(path.join(repoRoot, ".harmony-web-cache"), { recursive: true, force: true });
  }

  const indexPath = path.join(rawfileDir, "index.html");
  const html = await readFile(indexPath, "utf8");
  await writeFile(indexPath, await injectBridge(html), "utf8");

  console.log(`[harmony-web] staged editor into ${path.relative(repoRoot, rawfileDir)}`);
  console.log(`[harmony-web] bridge adapter: ${adapterBackup ? "restored" : "MISSING"}`);
}

await main();
