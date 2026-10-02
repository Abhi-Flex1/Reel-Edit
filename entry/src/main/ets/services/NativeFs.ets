/*
 * Native filesystem bridge.
 *
 * Reimplements the `window.openreel.fs` contract from the Electron main process
 * (apps/desktop/src/main/ipc/fs.ts) on top of the HarmonyOS file-access
 * framework. The editor streams project media, waveform data and export frames
 * through these calls, so write handles are tracked and positioned writes are
 * supported exactly as in the desktop app.
 */

import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FileFilter, OpenDialogOptions, SaveDialogOptions } from './BridgeTypes';

interface WriteHandle {
  file: fs.File;
  path: string;
}

/** Positional write options; fs.write takes offset/length, not position. */
interface PositionalWriteOptions {
  offset: number;
  length: number;
}

const writeHandles: Map<string, WriteHandle> = new Map();

/*
 * HarmonyOS allows only one document picker UI on screen. The export flow asks
 * for a path more than once in quick succession (the video file, then the audio
 * WAV), and overlapping calls make the picker reject. Chaining them keeps the
 * per-call contract identical while the UI is effectively single-instance.
 */
let pickerChain: Promise<void> = Promise.resolve();

function serializePicker<T>(task: () => Promise<T>): Promise<T> {
  const next: Promise<T> = pickerChain.then(task, task);
  pickerChain = next.then(() => undefined, () => undefined);
  return next;
}

export class NativeFs {
  private context: common.UIAbilityContext | undefined = undefined;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  private cacheDir(): string {
    return this.context?.cacheDir ?? '/data/storage/el2/base/cache';
  }

  /**
   * DocumentViewPicker returns a `file://docs/...` URI (or a `content://` URI),
   * while the desktop bridge works in plain filesystem paths — the renderer
   * opens, reads and writes these directly.
   *
   * `file://docs/<rest>` addresses the app sandbox, so it maps onto filesDir;
   * anything outside the sandbox keeps its own path so the renderer can still
   * hand it to the media framework.
   */
  private toPath(uri: string): string {
    if (uri.startsWith('file://docs/')) {
      /*
       * FileUri resolves the sandbox scheme to a virtual path such as
       * /storage/Users/currentUser/clip.mp4. That path is what fileIo and the
       * native encoder can actually open, so it is used verbatim; prefixing it
       * with filesDir would point at a directory that does not exist.
       */
      try {
        const resolved: string = new fileUri.FileUri(uri).path;
        if (resolved.length > 1) {
          return resolved;
        }
      } catch (err) {
        const e = err as BusinessError;
        console.warn(`[NativeFs] FileUri failed for ${uri}: ${e.code} ${e.message}`);
      }
      return uri;
    }
    if (uri.startsWith('content://')) {
      // <authority>/<path> -> /<path>
      const withoutScheme: string = uri.substring('content://'.length);
      const slash: number = withoutScheme.indexOf('/');
      return slash === -1 ? uri : withoutScheme.substring(slash);
    }
    if (uri.startsWith('file://')) {
      return uri.substring('file://'.length);
    }
    return uri;
  }

  /** Builds `Name|ext1,ext2` filter strings from the desktop filter list. */
  private buildSuffixFilters(filters?: FileFilter[]): string[] {
    if (filters === undefined || filters.length === 0) {
      return [];
    }
    const out: string[] = [];
    for (const filter of filters) {
      const suffixes: string[] = [];
      for (const ext of filter.extensions) {
        const normalized: string = ext.startsWith('.') ? ext.substring(1) : ext;
        if (normalized.length > 0 && !suffixes.includes(normalized)) {
          suffixes.push(normalized);
        }
      }
      if (suffixes.length === 0) {
        continue;
      }
      out.push(`${filter.name.length > 0 ? filter.name : 'Files'}|${suffixes.join(',')}`);
    }
    return out;
  }

  private createPicker(): picker.DocumentViewPicker {
    if (this.context !== undefined) {
      return new picker.DocumentViewPicker(this.context);
    }
    return new picker.DocumentViewPicker();
  }

  /** Mirrors Electron's dialog.showSaveDialog: returns null when cancelled. */
  async showSaveDialog(options: SaveDialogOptions): Promise<string | null> {
    return serializePicker(() => this.runSaveDialog(options));
  }

  private async runSaveDialog(options: SaveDialogOptions): Promise<string | null> {
    console.info(`[NativeFs] showSaveDialog called: ${JSON.stringify(options)}`);
    try {
      const pickerOptions = new picker.DocumentSaveOptions();
      const suffixFilters: string[] = this.buildSuffixFilters(options.filters);
      if (suffixFilters.length > 0) {
        pickerOptions.fileSuffixChoices = suffixFilters;
      }
      const defaultPath: string | undefined = options.defaultPath;
      if (defaultPath !== undefined && defaultPath.length > 0) {
        const slash: number = defaultPath.lastIndexOf('/');
        if (slash > 0) {
          pickerOptions.newFileNames = [defaultPath.substring(slash + 1)];
        }
      }
      const result: string[] = await this.createPicker().save(pickerOptions);
      console.info(`[NativeFs] saveDialog returned ${result.length} entries`);
      if (result.length === 0) {
        return null;
      }
      const path: string = this.toPath(result[0]);
      console.info(`[NativeFs] saveDialog -> ${result[0]} => ${path}`);
      this.reportFile(path);
      return path;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[NativeFs] showSaveDialog threw code=${e.code} msg=${e.message}`);
      reportPickerFailure(e);
      return null;
    }
  }

  async showOpenDialog(options: OpenDialogOptions): Promise<string | null> {
    return serializePicker(() => this.runOpenDialog(options));
  }

  private async runOpenDialog(options: OpenDialogOptions): Promise<string | null> {
    try {
      const pickerOptions = new picker.DocumentSelectOptions();
      const suffixFilters: string[] = this.buildSuffixFilters(options.filters);
      if (suffixFilters.length > 0) {
        pickerOptions.fileSuffixFilters = suffixFilters;
      }
      pickerOptions.maxSelectNumber = 1;
      const result: string[] = await this.createPicker().select(pickerOptions);
      if (result.length === 0) {
        return null;
      }
      return this.toPath(result[0]);
    } catch (err) {
      reportPickerFailure(err as BusinessError);
      return null;
    }
  }

  async readFile(path: string): Promise<string> {
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = fs.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      return decodeUtf8(buffer);
    } finally {
      fs.closeSync(file.fd);
    }
  }

  async readFileBytes(path: string): Promise<ArrayBuffer> {
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = fs.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      return buffer;
    } finally {
      fs.closeSync(file.fd);
    }
  }

  async tempFilePath(ext: string): Promise<string> {
    const suffix: string = ext.startsWith('.') ? ext : `.${ext}`;
    return `${this.cacheDir()}/openreel-${Date.now()}-${Math.floor(Math.random() * 1000000)}${suffix}`;
  }

  async writeFile(path: string, data: string): Promise<void> {
    const file: fs.File = fs.openSync(
      path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
    );
    try {
      fs.writeSync(file.fd, data);
    } finally {
      fs.closeSync(file.fd);
    }
  }

  async openWrite(path: string): Promise<string> {
    this.ensureParentDir(path);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    const handleId: string = `w-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    const handle: WriteHandle = { file: file, path: path };
    writeHandles.set(handleId, handle);
    return handleId;
  }

  /**
   * Creates the directory a write target lives in.
   *
   * The save picker hands back a path under the app's files area whose folder
   * may not exist yet, and opening a file inside a missing directory fails with
   * ENOENT, so it is created on demand.
   */
  private ensureParentDir(path: string): void {
    const slash: number = path.lastIndexOf('/');
    if (slash <= 0) {
      return;
    }
    const dir: string = path.substring(0, slash);
    try {
      if (fs.accessSync(dir)) {
        return;
      }
      fs.mkdirSync(dir, true);
    } catch (err) {
      // Already existing, or not creatable; openSync reports the real problem.
    }
  }

  async writeChunk(handleId: string, data: ArrayBuffer, position: number): Promise<void> {
    const handle: WriteHandle | undefined = writeHandles.get(handleId);
    if (handle === undefined) {
      throw new Error(`Unknown write handle: ${handleId}`);
    }
    const options: PositionalWriteOptions = { offset: position, length: data.byteLength };
    await fs.write(handle.file.fd, data, options);
  }

  async closeWrite(handleId: string): Promise<void> {
    const handle: WriteHandle | undefined = writeHandles.get(handleId);
    if (handle === undefined) {
      return;
    }
    writeHandles.delete(handleId);
    fs.closeSync(handle.file.fd);
  }

  async abortWrite(handleId: string): Promise<void> {
    const handle: WriteHandle | undefined = writeHandles.get(handleId);
    if (handle === undefined) {
      return;
    }
    writeHandles.delete(handleId);
    try {
      fs.closeSync(handle.file.fd);
    } catch (err) {
      // ignore close errors on an aborted write
    }
    try {
      fs.unlinkSync(handle.path);
    } catch (err) {
      // best effort cleanup
    }
  }

  /**
   * The desktop build reveals the artifact in the OS file manager. HarmonyOS
   * exposes no equivalent to a HAP, so the export UI surfaces the saved path
   * instead; kept so the bridge contract stays complete.
   */
  async revealInFolder(path: string): Promise<void> {
    return;
  }

  /**
   * Confirms the chosen path is actually writable and reports the resulting
   * file's size once the export finishes. A zero-byte result means the renderer
   * never wrote to the path it was given, so it is worth surfacing in logs.
   */
  private reportFile(path: string): void {
    setTimeout(() => {
      try {
        const stat: fs.Stat = fs.statSync(path);
        console.info(`[NativeFs] output ${path} size=${stat.size}`);
      } catch (err) {
        const e = err as BusinessError;
        console.warn(`[NativeFs] output not found at ${path}: ${e.code} ${e.message}`);
      }
      // Report the sandbox layout once, so a wrong docs/files mapping is obvious
      // from the log rather than needing a debugger.
      console.info(`[NativeFs] sandbox filesDir=${this.context?.filesDir ?? 'unset'}`);
      console.info(`[NativeFs] sandbox cacheDir=${this.context?.cacheDir ?? 'unset'}`);
      console.info(`[NativeFs] sandbox databaseDir=${this.context?.databaseDir ?? 'unset'}`);
    }, 20000);
  }

  releaseAll(): void {
    writeHandles.forEach((handle) => {
      try {
        fs.closeSync(handle.file.fd);
      } catch (err) {
        // ignore
      }
    });
    writeHandles.clear();
  }
}

/** Decodes UTF-8 without relying on TextDecoder, which ArkTS does not expose. */
function decodeUtf8(buffer: ArrayBuffer): string {
  const bytes: Uint8Array = new Uint8Array(buffer);
  let result: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const byte: number = bytes[i];
    if (byte < 0x80) {
      result += String.fromCharCode(byte);
      i += 1;
    } else if (byte < 0xe0) {
      result += String.fromCharCode(((byte & 0x1f) << 6) | (bytes[i + 1] & 0x3f));
      i += 2;
    } else if (byte < 0xf0) {
      result += String.fromCharCode(
        ((byte & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f)
      );
      i += 3;
    } else {
      // Astral plane: emit the surrogate pair directly.
      const codePoint: number =
        ((byte & 0x07) << 18) |
        ((bytes[i + 1] & 0x3f) << 12) |
        ((bytes[i + 2] & 0x3f) << 6) |
        (bytes[i + 3] & 0x3f);
      const adjusted: number = codePoint - 0x10000;
      result += String.fromCharCode(0xd800 + (adjusted >> 10), 0xdc00 + (adjusted & 0x3ff));
      i += 4;
    }
  }
  return decodeURIComponent(escape(result));
}

/** Cancels are an ordinary outcome, not an error worth surfacing. */
function reportPickerFailure(err: BusinessError): void {
  if (err.code !== 13900042 && err.code !== 13900012) {
    console.warn(`[NativeFs] picker failed: ${err.code} ${err.message}`);
  }
}
