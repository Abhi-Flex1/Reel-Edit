/*
 * Process-wide bridge holder.
 *
 * The ArkWeb proxy is registered from the page (it needs the
 * WebviewController), but the bridge needs the UIAbilityContext and the
 * WindowStage, which only EntryAbility has. This holder lets EntryAbility
 * publish the initialised bridge for the page's proxy to delegate to.
 *
 * The WebviewController is deliberately *not* required here: it only becomes
 * available after the page mounts, and the export path attaches to it at the
 * moment a job starts (see OpenReelBridge.attachController).
 */

import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { OpenReelBridge } from './OpenReelBridge';

let instance: OpenReelBridge | undefined = undefined;

export class BridgeHolder {
  static async create(
    context: common.UIAbilityContext,
    windowStage: window.WindowStage
  ): Promise<void> {
    instance = new OpenReelBridge();
    await instance.init(context, windowStage);
  }

  static isReady(): boolean {
    return instance !== undefined;
  }

  /** Publishes the live controller once the Web component mounts. */
  static attachController(controller: webview.WebviewController): void {
    if (instance) {
      instance.attachController(controller);
    }
  }

  /** Applies the system colour mode to the hosted page. */
  static setDarkMode(dark: boolean): void {
    if (instance) {
      instance.setDarkMode(dark);
    }
  }

  /**
   * Re-applies the colour mode recorded at ability start. Called once the page
   * has loaded so the initial scheme matches the device without waiting for the
   * first configuration change.
   */
  static applyColorMode(): void {
    if (instance) {
      instance.applyColorMode();
    }
  }

  /**
   * Hands a request from the page to the bridge. The reply is delivered later by
   * the bridge through window.__openreelResolve, so this returns immediately.
   */
  static invoke(request: string): void {
    if (instance) {
      instance.invoke(request);
    }
  }

  static release(): void {
    if (instance) {
      instance.releaseAll();
    }
    instance = undefined;
  }
}
