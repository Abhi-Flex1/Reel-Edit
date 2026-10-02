import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const css = readFileSync(fileURLToPath(new URL("./desktop-theme.css", import.meta.url)), "utf8");

/**
 * Extracts the variable declarations of one scheme block so the light and dark
 * palettes can be compared token by token, which is what makes the two blocks
 * genuinely interchangeable.
 */
function schemeBlock(kind: "light" | "dark"): string {
  const start = css.indexOf(`@media (prefers-color-scheme: ${kind}) {`);
  expect(start, `missing ${kind} block`).toBeGreaterThan(-1);
  const other = css.indexOf(
    `@media (prefers-color-scheme: ${kind === "light" ? "dark" : "light"}) {`,
    start,
  );
  return other === -1 ? css.slice(start) : css.slice(start, other);
}

function tokens(block: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const match of block.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)) {
    out.set(match[1], match[2].trim());
  }
  return out;
}

describe("desktop-theme.css schemes", () => {
  const light = tokens(schemeBlock("light"));
  const dark = tokens(schemeBlock("dark"));

  it("defines the same token set in both schemes", () => {
    expect([...light.keys()].sort()).toEqual([...dark.keys()].sort());
  });

  it("gives the light scheme genuinely light surfaces and dark text", () => {
    expect(light.get("--bg")).toMatch(/^oklch\(0\.9/);
    expect(light.get("--bg-1")).toMatch(/^oklch\(0\.9/);
    expect(light.get("--fg")).toMatch(/^oklch\(0\.[12]/);
    expect(light.get("--border")).toMatch(/^oklch\(0\.8/);
  });

  it("gives the dark scheme genuinely dark surfaces and light text", () => {
    expect(dark.get("--bg")).toMatch(/^oklch\(0\.1/);
    expect(dark.get("--fg")).toMatch(/^oklch\(0\.9/);
    expect(dark.get("--border")).toMatch(/^oklch\(0\.[23]/);
  });

  it("does not reuse identical surface colours across the two schemes", () => {
    // A copy/paste that left the light palette identical to the dark one would
    // still "work" but would render the app dark on a light desktop.
    const surfaceTokens = ["--bg", "--bg-1", "--bg-2", "--bg-3", "--fg", "--fg-2", "--border"];
    for (const token of surfaceTokens) {
      expect(light.get(token), `${token} must differ between schemes`).not.toBe(dark.get(token));
    }
  });

  it("keeps the emerald accent hue in both schemes", () => {
    for (const scheme of [light, dark]) {
      expect(scheme.get("--accent")).toMatch(/16[0-9]/);
      expect(scheme.get("--accent-strong")).toMatch(/16[0-9]/);
    }
  });

  it("keeps shadows subtle in light and stronger in dark", () => {
    expect(light.get("--shadow-lg")).not.toBe(dark.get("--shadow-lg"));
    // Dark surfaces need an opaque shadow to read; light ones do not.
    expect(dark.get("--shadow-lg")).toMatch(/oklch\(0 0 0/);
  });
});