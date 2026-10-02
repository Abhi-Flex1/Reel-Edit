import type { JSX } from "react";
import type React from "react";
import { ToolcraftIconButton as IconButton } from "@openreel/ui";
import { Icon } from "@/icons/Icon";

/**
 * In-app window controls.
 *
 * These are only drawn when the shell owns the window chrome. On HarmonyOS the
 * platform draws its own minimise / maximise / close buttons on the window, so
 * rendering ours as well produced two sets of controls. `window.openreel.win`
 * therefore reports no API on that platform and this returns null — see
 * entry/src/main/resources/rawfile/web/reel_bridge.js, where `win` is omitted.
 *
 * On desktop (Electron) the API is present and the controls render as before.
 */
export function WindowControls({ platform }: { platform: string }): JSX.Element | null {
  if (platform === "darwin") return null;
  const api = typeof window !== "undefined" ? window.openreel?.win : undefined;
  if (!api) return null;
  return (
    <div className="flex items-center" style={{ WebkitAppRegion: "no-drag" } as React.CSSProperties}>
      <IconButton
        label="Minimize"
        icon={<Icon name="minus" size={14} />}
        variant="ghost"
        size="lg"
        className="grid h-10 w-11 place-items-center text-fg-2 hover:bg-hover"
        onClick={() => void api.minimize()}
      />
      <IconButton
        label="Maximize"
        icon={<Icon name="square.on.square" size={13} />}
        variant="ghost"
        size="lg"
        className="grid h-10 w-11 place-items-center text-fg-2 hover:bg-hover"
        onClick={() => void api.toggleMaximize()}
      />
      <IconButton
        label="Close"
        icon={<Icon name="xmark" size={14} />}
        variant="ghost"
        size="lg"
        className="grid h-10 w-11 place-items-center text-fg-2 hover:bg-red-600 hover:text-white"
        onClick={() => void api.close()}
      />
    </div>
  );
}