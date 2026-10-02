/*
 * Secret storage bridge.
 *
 * Reimplements `window.openreel.keychain` from the Electron main process. It
 * backs the AI provider keys the user connects in Settings (OpenAI, Anthropic,
 * compatible endpoints) — see apps/web/src/services/secure-storage.ts.
 *
 * The desktop build hands these to the OS keychain. HarmonyOS offers no
 * equivalent that is available to an unsigned debug HAP, so secrets are kept in
 * the app's private preferences file: same get/set/delete contract, scoped to
 * the sandbox and never readable by other apps.
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const STORE_NAME = 'openreel_secrets';

export class NativeKeychain {
  private store: preferences.Preferences | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      this.store = await preferences.getPreferences(context, { name: STORE_NAME });
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[NativeKeychain] failed to open store: ${e.code} ${e.message}`);
    }
  }

  async get(id: string): Promise<string | null> {
    if (!this.store) {
      return null;
    }
    try {
      const value = await this.store.get(id, '');
      if (typeof value === 'string' && value.length > 0) {
        return value;
      }
      return null;
    } catch (err) {
      console.warn(`[NativeKeychain] get failed for ${id}`);
      return null;
    }
  }

  async set(id: string, value: string): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put(id, value);
      await this.store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[NativeKeychain] set failed for ${id}: ${e.code}`);
    }
  }

  async delete(id: string): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.delete(id);
      await this.store.flush();
    } catch (err) {
      console.warn(`[NativeKeychain] delete failed for ${id}`);
    }
  }
}
