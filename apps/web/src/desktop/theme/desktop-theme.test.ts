import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const css = readFileSync(fileURLToPath(new URL("./desktop-theme.css", import.meta.url)), "utf8");

describe("desktop-theme.css", () => {
  it("scopes overrides under .openreel-desktop", () => {
    expect(css).toContain(".openreel-desktop");
  });
  it("retints the accent to emerald and surfaces to charcoal", () => {
    expect(css).toMatch(/--accent:\s*oklch\([^)]*16[0-9]/);
    expect(css).toMatch(/--bg:\s*oklch\(0\.1[0-9]/);
  });
  it("defines the full surface ramp + border tokens it overrides", () => {
    for (const token of ["--bg", "--bg-1", "--bg-2", "--bg-3", "--border", "--accent", "--accent-strong"]) {
      expect(css).toContain(`${token}:`);
    }
  });

  /*
   * Both schemes must live in explicit prefers-color-scheme blocks. An
   * unconditional dark block placed later in the cascade overrides the light
   * one and pins the editor to dark regardless of the device setting, which is
   * what this guards against.
   */
  it("defines both schemes inside prefers-color-scheme blocks", () => {
    const lightBlock = css.match(/@media \(prefers-color-scheme: light\) \{/);
    const darkBlock = css.match(/@media \(prefers-color-scheme: dark\) \{/);
    expect(lightBlock).not.toBeNull();
    expect(darkBlock).not.toBeNull();
  });

  it("keeps color-scheme in sync with each block's appearance", () => {
    // One declaration per scheme, matching their media query.
    expect(css.match(/color-scheme: light;/g)?.length).toBe(1);
    expect(css.match(/color-scheme: dark;/g)?.length).toBe(1);
  });

  it("does not declare an unconditional .openreel-desktop token block", () => {
    // Every ".openreel-desktop {" occurrence must sit inside a media query,
    // so no scheme can win purely by source order.
    const blocks = [...css.matchAll(/\.openreel-desktop \{/g)];
    expect(blocks.length).toBe(2);
    for (const block of blocks) {
      const before = css.slice(0, block.index);
      const lastLight = before.lastIndexOf("@media (prefers-color-scheme: light)");
      const lastDark = before.lastIndexOf("@media (prefers-color-scheme: dark)");
      expect(Math.max(lastLight, lastDark)).toBeGreaterThan(-1);
    }
  });

  it("defines the light scheme as a light palette, not the dark one", () => {
    const light = css.slice(css.indexOf("@media (prefers-color-scheme: light)"));
    const darkStart = light.indexOf("@media (prefers-color-scheme: dark)");
    const lightOnly = darkStart === -1 ? light : light.slice(0, darkStart);
    // Light surfaces sit above 0.9 luminance; the dark set below 0.3.
    expect(lightOnly).toMatch(/--bg:\s*oklch\(0\.9[0-9]/);
    expect(lightOnly).toMatch(/--fg:\s*oklch\(0\.2[0-9]/);
  });
});
