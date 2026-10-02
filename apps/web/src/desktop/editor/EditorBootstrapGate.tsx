import type { JSX } from "react";
import type React from "react";

import { useDesktopEditorBootstrap } from "./useDesktopEditorBootstrap";

export function EditorBootstrapGate({
  children,
}: {
  children: React.ReactNode;
}): JSX.Element {
  const { ready, error } = useDesktopEditorBootstrap();
  if (error) {
    return (
      <div className="grid h-full place-items-center bg-bg p-4 text-sm text-red-300">
        Editor failed to start: {error.message}
      </div>
    );
  }
  if (!ready) {
    return (
      <div className="grid h-full place-items-center bg-bg">
        <div className="flex flex-col items-center gap-4">
          {/* Neutral progress ring: the product mark is not used as a spinner. */}
          <span
            aria-hidden
            className="block size-12 animate-spin rounded-full border-4 border-accent/25 border-t-accent"
          />
          <span className="text-sm text-fg-muted">Loading editor…</span>
        </div>
      </div>
    );
  }
  return <>{children}</>;
}
