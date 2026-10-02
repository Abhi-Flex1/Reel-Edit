/*
 * The window.openreel bridge.
 *
 * This is the whole native surface the editor needs. The desktop build defines
 * it in apps/desktop/src/preload/index.ts over Electron IPC; here it is a single
 * ArkTS entry point registered into the page with registerJavaScriptProxy, so
 * every call site in apps/web/src runs unchanged — the renderer only checks
 * `window.openreel.platform === "desktop"` (see apps/web/src/main.tsx).
 *
 * Two marshalling constraints shape the design:
 *
 *  - registerJavaScriptProxy only carries JSON-serialisable values, so every call
 *    and result travels as a JSON string, and binary results come back base64.
 *    Export frames never take this path at all; they stream over a
 *    WebMessagePort instead (see NativeExport).
 *
 *  - The lifecycle handlers are push-style callbacks on the desktop. They are
 *    modelled here as native calls the page answers with JSON, keeping the same
 *    onQueryUnsaved/onFlush registration shape without a reverse proxy.
 */

import { webview } from '@kit.ArkWeb';
import { window } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NativeFs } from './NativeFs';
import { NativeHardware } from './NativeHardware';
import { NativeKeychain } from './NativeKeychain';
import { NativeMedia } from './NativeMedia';
import { NativeExport, ExportStartArgs, ExportSession } from './NativeExport';
import type { AudioArgs, FrameArgs } from './NativeExport';
import {
  AudioChunkArgs,
  Base64Result,
  BridgeRequest,
  BridgeResponse,
  CloudFetchArgs,
  CloudFetchResult,
  CloudErrorBody,
  CloudErrorDetail,
  CloudRequestOptions,
  ExtractAudioArgs,
  HandleArgs,
  JobArgs,
  OpenDialogOptions,
  PathArgs,
  ProxyArgs,
  SaveDialogOptions,
  SecretArgs,
  TempPathArgs,
  TranscodeArgs,
  UrlArgs,
  WriteChunkArgs,
  WriteFileArgs
} from './BridgeTypes';

/** Reserved request id used by the page-load bridge self-check. */
const PROBE_REQUEST_ID = 9999;

export class OpenReelBridge {
  private fs: NativeFs = new NativeFs();
  private hardware: NativeHardware = new NativeHardware();
  private keychain: NativeKeychain = new NativeKeychain();
  private media: NativeMedia = new NativeMedia();
  private exporter: NativeExport = new NativeExport();

  private context: common.UIAbilityContext | undefined = undefined;
  private controller: webview.WebviewController | undefined = undefined;
  private windowStage: window.WindowStage | undefined = undefined;
  private darkMode: boolean = false;

  async init(context: common.UIAbilityContext, windowStage: window.WindowStage): Promise<void> {
    this.context = context;
    this.windowStage = windowStage;
    this.fs.setContext(context);
    this.media.setContext(context);
    // Record the colour mode the device is already in; the page applies it once
    // it loads, and onConfigurationUpdate keeps it in step from then on.
    this.darkMode = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    // Encoder credits/done/error are pushed into the page, which settles the
    // renderer's MessagePort-shaped export channel.
    this.exporter.setEventSink((jobId: string, message: string) => {
      this.pushExportEvent(jobId, message);
    });
    await this.keychain.init(context);
  }

  private pushExportEvent(jobId: string, message: string): void {
    if (this.controller === undefined) {
      return;
    }
    const encoded: string = encodeURIComponent(message);
    this.controller.runJavaScript(
      `window.__openreelPush(${JSON.stringify(jobId)}, decodeURIComponent("${encoded}"));`
    ).catch((err: Error) => {
      console.warn(`[Bridge] export event push failed: ${err.message}`);
    });
  }

  /** Re-applies the recorded colour mode to the now-loaded page. */
  applyColorMode(): void {
    this.setDarkMode(this.darkMode);
  }

  /**
   * Publishes the WebviewController once the Web component mounts. Export jobs
   * need it to hand the renderer half of a message port, and nothing else in the
   * bridge does, so it is attached late rather than at ability start.
   */
  attachController(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  /**
   * Tells the hosted page which colour scheme the system is using.
   *
   * The Web component is declared with WebDarkMode.Auto so the kernel tracks the
   * system setting by itself; this pushes the value into the page as well so the
   * CSS media query re-evaluates immediately, which is what the editor's theme
   * tokens key off. Setting color-scheme on the document root is enough for
   * prefers-color-scheme to follow.
   */
  setDarkMode(dark: boolean): void {
    this.darkMode = dark;
    if (this.controller === undefined) {
      return;
    }
    const scheme: string = dark ? 'dark' : 'light';
    try {
      this.controller.runJavaScript(
        `document.documentElement.style.colorScheme='${scheme}';` +
        `window.dispatchEvent(new Event('reel-theme'));`
      ).catch((err: Error) => {
        console.warn(`[Bridge] colour mode push failed: ${err.message}`);
      });
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[Bridge] colour mode push failed: ${e.code} ${e.message}`);
    }
  }

  /**
   * Hands one request to the page.
   *
   * ArkWeb's async JS proxy does not marshal a returned Promise reliably: the
   * page observes an empty result while the real value only arrives much later.
   * The proxy is therefore registered as synchronous and returns nothing, and
   * the answer is pushed into the page afterwards through __openreelResolve,
   * which settles the promise the page adapter created for this request id.
   */
  invoke(requestJson: string): void {
    let request: BridgeRequest;
    try {
      request = JSON.parse(requestJson) as BridgeRequest;
    } catch (err) {
      return;
    }

    this.dispatch(request).then((result: string) => {
      const response: BridgeResponse = { ok: true, result: result };
      // A reserved id is the startup self-check; log it so the bridge round-trip
      // is observable without instrumenting the editor.
      if (request.id === PROBE_REQUEST_ID) {
        console.info(`[Bridge] probeHardware reply: ${result}`);
      }
      this.deliver(request.id, JSON.stringify(response));
    }).catch((err: Error) => {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`[Bridge] ${request.method} failed: ${message}`);
      const response: BridgeResponse = { ok: false, error: message };
      this.deliver(request.id, JSON.stringify(response));
    });
  }

  /** Pushes a JSON envelope back into the page for the given request id. */
  private deliver(id: number, payload: string): void {
    if (this.controller === undefined) {
      return;
    }
    const encoded: string = encodeURIComponent(payload);
    this.controller.runJavaScript(
      `window.__openreelResolve(${id}, decodeURIComponent("${encoded}"));`
    ).catch((err: Error) => {
      console.warn(`[Bridge] deliver failed: ${err.message}`);
    });
  }

  private async dispatch(request: BridgeRequest): Promise<string> {
    switch (request.method) {
      case 'probeHardware':
        return JSON.stringify(await this.hardware.probe());

      /* ---- filesystem ---- */
      case 'fs.showSaveDialog':
        return JSON.stringify(
          await this.fs.showSaveDialog(JSON.parse(request.payload!) as SaveDialogOptions)
        );
      case 'fs.showOpenDialog':
        return JSON.stringify(await this.fs.showOpenDialog(JSON.parse(request.payload!) as OpenDialogOptions));
      case 'fs.readFile': {
        const args = JSON.parse(request.payload!) as PathArgs;
        return await this.fs.readFile(args.path);
      }
      case 'fs.readFileBytes': {
        const args = JSON.parse(request.payload!) as PathArgs;
        const encoded: Base64Result = {
          base64: this.toBase64(await this.fs.readFileBytes(args.path))
        };
        return JSON.stringify(encoded);
      }
      case 'fs.tempFilePath': {
        const args = JSON.parse(request.payload!) as TempPathArgs;
        return JSON.stringify(await this.fs.tempFilePath(args.ext));
      }
      case 'fs.writeFile': {
        const args = JSON.parse(request.payload!) as WriteFileArgs;
        await this.fs.writeFile(args.path, args.data);
        return '';
      }
      case 'fs.openWrite': {
        const args = JSON.parse(request.payload!) as PathArgs;
        return JSON.stringify(await this.fs.openWrite(args.path));
      }
      case 'fs.writeChunk': {
        const args = JSON.parse(request.payload!) as WriteChunkArgs;
        await this.fs.writeChunk(args.handleId, this.fromBase64(args.data), args.position);
        return '';
      }
      case 'fs.closeWrite': {
        const args = JSON.parse(request.payload!) as HandleArgs;
        await this.fs.closeWrite(args.handleId);
        return '';
      }
      case 'fs.abortWrite': {
        const args = JSON.parse(request.payload!) as HandleArgs;
        await this.fs.abortWrite(args.handleId);
        return '';
      }
      case 'fs.revealInFolder': {
        const args = JSON.parse(request.payload!) as PathArgs;
        await this.fs.revealInFolder(args.path);
        return '';
      }

      /* ---- secrets ---- */
      case 'keychain.get': {
        const args = JSON.parse(request.payload!) as SecretArgs;
        return JSON.stringify(await this.keychain.get(args.id));
      }
      case 'keychain.set': {
        const args = JSON.parse(request.payload!) as SecretArgs;
        await this.keychain.set(args.id, args.value);
        return '';
      }
      case 'keychain.delete': {
        const args = JSON.parse(request.payload!) as SecretArgs;
        await this.keychain.delete(args.id);
        return '';
      }

      /* ---- export ---- */
      case 'export.start': {
        const args = JSON.parse(request.payload!) as ExportStartArgs;
        const session: ExportSession = await this.exporter.start(args);
        return JSON.stringify(session);
      }
      case 'export.pushFrame': {
        const args = JSON.parse(request.payload!) as FrameArgs;
        return JSON.stringify(this.exporter.pushFrame(args));
      }
      case 'export.pushAudio': {
        const args = JSON.parse(request.payload!) as AudioArgs;
        return JSON.stringify(this.exporter.pushAudio(args));
      }
      case 'export.finish': {
        const args = JSON.parse(request.payload!) as JobArgs;
        this.exporter.finish(args.jobId);
        return '';
      }
      case 'export.writeAudioChunk': {
        /* The WAV header carries no samples; the body reaches the encoder as
         * export.pushAudio, so this only records the offset. */
        return '';
      }
      case 'export.finishAudio':
        return '';
      case 'export.cancel': {
        const args = JSON.parse(request.payload!) as JobArgs;
        await this.exporter.cancel(args.jobId);
        return '';
      }

      /* ---- media ---- */
      case 'media.generateProxy':
        return JSON.stringify(await this.media.generateProxy(JSON.parse(request.payload!) as ProxyArgs));
      case 'media.transcode':
        return JSON.stringify(await this.media.transcode(JSON.parse(request.payload!) as TranscodeArgs));
      case 'media.extractAudioWav':
        return JSON.stringify(await this.media.extractAudioWav(JSON.parse(request.payload!) as ExtractAudioArgs));
      case 'media.probeAudioStreams':
        return JSON.stringify(await this.media.probeAudioStreams(JSON.parse(request.payload!) as ExtractAudioArgs));
      case 'media.fetchUrl': {
        const args = JSON.parse(request.payload!) as UrlArgs;
        return JSON.stringify(await this.media.fetchUrl(args));
      }

      /* ---- cloud (AI provider calls) ---- */
      case 'cloud.fetch': {
        const args = JSON.parse(request.payload!) as CloudFetchArgs;
        const result: CloudFetchResult = await this.cloudFetch(args);
        return JSON.stringify(result);
      }

      /* ---- window controls ----
       * HarmonyOS exposes minimise and maximise on Window but has no restore or
       * close call, so toggling always maximises and closing goes through
       * terminateSelf() on the ability. The editor's title-bar buttons drive
       * these.
       */
      case 'win.minimize': {
        const main = this.windowStage?.getMainWindowSync();
        if (main !== undefined) {
          await main.minimize();
        }
        return '';
      }
      case 'win.toggleMaximize': {
        const main = this.windowStage?.getMainWindowSync();
        if (main !== undefined) {
          await main.maximize();
        }
        return '';
      }
      case 'win.close': {
        const context = this.context;
        if (context !== undefined) {
          context.terminateSelf();
        }
        return '';
      }
      case 'win.isMaximized': {
        // HarmonyOS does not expose a maximised flag; report the desktop-style
        // "restored" state so the title bar renders a consistent control.
        return JSON.stringify(false);
      }

      /* ---- lifecycle (queried by the host, answered by the page) ---- */
      case 'lifecycle.queryUnsaved': {
        if (this.controller === undefined) {
          return JSON.stringify(false);
        }
        const answer = await this.controller.runJavaScript(
          'window.__openreelHostQueryUnsaved ? window.__openreelHostQueryUnsaved() : false'
        );
        return JSON.stringify(answer === 'true');
      }
      case 'lifecycle.flush': {
        if (this.controller === undefined) {
          return '';
        }
        await this.controller.runJavaScript(
          'window.__openreelHostFlush ? window.__openreelHostFlush() : Promise.resolve()'
        );
        return '';
      }

      default:
        throw new Error(`Unknown bridge method: ${request.method}`);
    }
  }

  /**
   * Proxies the AI provider calls the editor makes (OpenAI, Anthropic, and
   * compatible endpoints). The desktop build has the Electron main process do
   * the same through CHANNELS.cloudFetch; here @ohos.net.http fills that role so
   * the page can reach the provider directly.
   */
  private async cloudFetch(args: CloudFetchArgs): Promise<CloudFetchResult> {
    const request = http.createHttp();
    try {
      const isPost: boolean = (args.method ?? 'GET').toUpperCase() === 'POST';
      const options: CloudRequestOptions = {
        method: isPost ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: args.headers ?? {},
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 30000,
        readTimeout: 120000
      };
      const response = await request.request(args.url, options);

      const headers: Record<string, string> = response.header as Record<string, string>;
      return {
        status: response.responseCode,
        statusText: String(response.responseCode),
        headers: headers,
        body: response.result as string
      };
    } catch (err) {
      const e = err as BusinessError;
      const detail: CloudErrorDetail = { message: e.message ?? 'Network error' };
      const errorBody: CloudErrorBody = { error: detail };
      return {
        status: 0,
        statusText: 'Network error',
        headers: {},
        body: JSON.stringify(errorBody)
      };
    } finally {
      try {
        request.destroy();
      } catch (err) {
        // already destroyed
      }
    }
  }

  /* ---- base64 helpers (the JSON proxy has no binary channel) ---- */
  private toBase64(buffer: ArrayBuffer): string {
    const helper: util.Base64Helper = new util.Base64Helper();
    const encoded: Uint8Array = helper.encodeSync(new Uint8Array(buffer));
    let out: string = '';
    for (let i = 0; i < encoded.length; i++) {
      out += String.fromCharCode(encoded[i]);
    }
    return out;
  }

  private fromBase64(value: string): ArrayBuffer {
    const helper: util.Base64Helper = new util.Base64Helper();
    const bytes: Uint8Array = helper.decodeSync(value);
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  }

  releaseAll(): void {
    this.exporter.releaseAll();
    this.fs.releaseAll();
  }
}
