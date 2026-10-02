/*
 * ArkWeb host page.
 *
 * Hosts the editor bundle from rawfile over a virtual https origin. The bundle
 * is served through onInterceptRequest rather than file:// or resource://,
 * because ArkWeb blocks cross-origin sub-resource loads for those protocols and
 * the built app fetches its JS chunks, fonts and WASM from its own origin.
 *
 * Request handling:
 *   - /reel_bridge.js and every bundle asset resolve to files in
 *     resources/rawfile/web;
 *   - mime types are set explicitly, since the kernel has no extension table for
 *     intercepted rawfile responses and .wasm/.woff2 in particular must not be
 *     served as text or the module loader rejects them.
 */

import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { BridgeHolder } from '../services/BridgeHolder';
import { NativeBridgeProxy } from '../services/BridgeTypes';

const HOST: string = 'openreel.harmony.local';
const MIME_BY_EXTENSION: Record<string, string> = {
  'html': 'text/html',
  'js': 'application/javascript',
  'mjs': 'application/javascript',
  'css': 'text/css',
  'json': 'application/json',
  'wasm': 'application/wasm',
  'map': 'application/json',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'svg': 'image/svg+xml',
  'webp': 'image/webp',
  'ico': 'image/x-icon',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'txt': 'text/plain'
};

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  private response: WebResourceResponse = new WebResourceResponse();

  /**
   * Resolves an intercepted request against the staged bundle. Returns null for
   * anything that is not one of our own files so the kernel handles it normally.
   */
  private resolveAsset(url: string): string | null {
    if (!url.startsWith(`https://${HOST}`)) {
      return null;
    }
    let path: string = url.substring(`https://${HOST}`.length);
    if (path === '' || path === '/') {
      path = '/index.html';
    }
    // Drop any query/hash and refuse traversal outside the staged bundle.
    path = path.split('?')[0].split('#')[0];
    if (path.includes('..')) {
      return null;
    }
    try {
      // Touch the entry so a missing file throws here rather than mid-response.
      const resource: Resource = $rawfile(`web${path}`);
      if (!resource) {
        return null;
      }
      return `web${path}`;
    } catch (err) {
      return null;
    }
  }

  build() {
    Column() {
      Web({ src: `https://${HOST}/index.html`, controller: this.controller })
        .domStorageAccess(true)
        .databaseAccess(true)
        .fileAccess(true)
        .mediaPlayGestureAccess(false)
        .horizontalScrollBarAccess(false)
        .verticalScrollBarAccess(false)
        .overviewModeAccess(false)
        .zoomAccess(false)
        .darkMode(WebDarkMode.Auto)
        .cacheMode(CacheMode.Default)
        .mixedMode(MixedMode.None)
        .layoutMode(WebLayoutMode.NONE)
        .onControllerAttached(() => {
          this.registerBridge();
        })
        .onPageEnd(() => {
          this.probeBridge();
        })
        .onInterceptRequest((event) => {
          const requestUrl: string = event.request.getRequestUrl();
          const key: string | null = this.resolveAsset(requestUrl);
          if (key === null) {
            return null;
          }
          const cleanUrl: string = requestUrl.split('?')[0];
          const dot: number = cleanUrl.lastIndexOf('.');
          const ext: string = dot >= 0 ? cleanUrl.substring(dot + 1).toLowerCase() : '';
          // WebResourceResponse reads the rawfile entry and serves its bytes.
          this.response.setResponseData($rawfile(key));
          this.response.setResponseMimeType(MIME_BY_EXTENSION[ext] ?? 'application/octet-stream');
          this.response.setResponseCode(200);
          this.response.setReasonMessage('OK');
          this.response.setResponseEncoding('utf-8');
          return this.response;
        })
        .width('100%')
        .height('100%')
        .backgroundColor('#111318')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.host_background'))
  }

  /**
   * Confirms the bridge is wired end to end: asks the page whether
   * window.openreel exists, and round-trips a real hardware probe through the
   * native encoder binding. This is the single most important integration point,
   * so it is asserted on every load rather than left to manual testing.
   */
  private probeBridge(): void {
    // Apply the system colour mode before probing, so the first paint already
    // matches the device instead of flashing the wrong scheme.
    BridgeHolder.applyColorMode();
    // The editor mounts asynchronously, so the theme check retries until the
    // root element exists; the rest is reported immediately.
    this.probeThemeWhenMounted(10);
    const script: string =
      'JSON.stringify({' +
      '  hasOpenreel: typeof window.openreel === "object" && window.openreel !== null,' +
      '  platform: window.openreel ? window.openreel.platform : null,' +
      '  hasNative: typeof window.openreelNative === "object",' +
      '  hasWinApi: !!(window.openreel && window.openreel.win),' +
      '  prefersDark: window.matchMedia("(prefers-color-scheme: dark)").matches' +
      '});';
    this.controller.runJavaScript(script).then((result: string) => {
      console.info(`[ReelEdit] bridge probe: ${result}`);
      // The bridge replies by pushing into the page, so this only verifies the
      // request reaches ArkTS and a native probe can round-trip.
      const request: string = JSON.stringify({ id: 9999, method: 'probeHardware' });
      BridgeHolder.invoke(request);
    }).catch((err: Error) => {
      console.error(`[ReelEdit] bridge probe failed: ${err.message}`);
    });
  }

  /**
   * Waits for the editor root to mount, then reports the resolved theme token so
   * the applied colour scheme can be verified on a real device.
   */
  private probeThemeWhenMounted(attempt: number): void {
    const script: string =
      '(function () {' +
      '  var el = document.querySelector(".openreel-desktop");' +
      '  if (!el) { return null; }' +
      '  return JSON.stringify({' +
      '    prefersDark: window.matchMedia("(prefers-color-scheme: dark)").matches,' +
      '    bg: getComputedStyle(el).getPropertyValue("--bg").trim(),' +
      '    fg: getComputedStyle(el).getPropertyValue("--fg").trim()' +
      '  });' +
      '})()';
    this.controller.runJavaScript(script).then((result: string) => {
      if (result && result !== 'null') {
        console.info(`[ReelEdit] theme probe: ${result}`);
        return;
      }
      if (attempt > 0) {
        setTimeout(() => this.probeThemeWhenMounted(attempt - 1), 700);
      }
    }).catch(() => {
      // The page may still be navigating; the next load will probe again.
    });
  }

  /** Installs the native bridge so the page can call into ArkTS. */
  private registerBridge(): void {
    const proxy: NativeBridgeProxy = new NativeBridgeProxy();
    try {
      /*
       * `invoke` is registered as a synchronous proxy method: it only hands the
       * request over, and the bridge pushes the reply into the page through
       * window.__openreelResolve. Registering it as async makes the page observe
       * an empty result long before the real value arrives.
       */
      this.controller.registerJavaScriptProxy(
        proxy,
        'openreelNative',
        ['invoke'],
        [],
        `${HOST}/*`
      );
      BridgeHolder.attachController(this.controller);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Index] registerJavaScriptProxy failed: ${e.code} ${e.message}`);
    }
  }
}
