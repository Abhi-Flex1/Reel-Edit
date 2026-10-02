import type { JSX } from "react";
import type React from "react";
import { WindowControls } from "./WindowControls";

/**
 * Desktop title bar.
 *
 * The editor's product branding is intentionally absent: the app ships under its
 * own name and the window already carries the HarmonyOS/DevEco app label and
 * icon. What remains is the same drag region and the right-aligned actions the
 * desktop build had, so the layout is unchanged.
 *
 * WindowControls renders nothing when window.openreel.win is absent, which is
 * how HarmonyOS avoids a second set of buttons next to the platform's own.
 */
export function DesktopTitleBar({ platform, children }: { platform: string; children?: React.ReactNode }): JSX.Element {
  const isMac = platform === "darwin";
  return (
    <header
      className="flex h-10 shrink-0 items-center justify-between border-b border-border bg-bg-1 text-fg"
      style={{ WebkitAppRegion: "drag" } as React.CSSProperties}
    >
      <div className="flex items-center gap-2" style={{ paddingLeft: isMac ? 76 : 12 }} />
      <div className="flex items-center" style={{ WebkitAppRegion: "no-drag" } as React.CSSProperties}>
        {children}
      </div>
      <WindowControls platform={platform} />
    </header>
  );
}