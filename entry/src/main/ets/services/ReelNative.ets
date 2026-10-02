/*
 * ArkTS binding for libreeledit.so (the native MP4 encoder + device probe).
 *
 * Thin typed wrapper over the Node-API surface so the rest of the ArkTS bridge
 * never touches raw napi values.
 */

import nativeModule from 'libreeledit.so';

export interface DeviceSpec {
  logicalCores: number;
  physicalCores: number;
  totalMemoryBytes: number;
  freeMemoryBytes: number;
}

export interface ExportEvent {
  /** 0 = credit, 1 = progress, 2 = done, 3 = error */
  kind: number;
  frame: number;
  credits: number;
  message: string;
}

export interface ExportStartArgs {
  outputPath: string;
  width: number;
  height: number;
  frameRate: number;
  bitrateKbps: number;
  totalFrames: number;
  audioSampleRate: number;
  audioChannels: number;
}

/** Encoders the device actually provides; null means unsupported. */
export interface CodecSupport {
  video: string | null;
  audio: string | null;
}

/** Opaque native job handle. */
export type ExportJob = ESObject;

/** Typed view of the libreeledit Node-API surface. */
interface NativeModule {
  startExport(args: ExportStartArgs): ExportJob;
  pushFrame(job: ExportJob, rgba: Uint8Array, ptsSeconds: number): number;
  pushAudio(job: ExportJob, pcm: Uint8Array): number;
  finishExport(job: ExportJob): number;
  cancelExport(job: ExportJob): void;
  destroyExport(job: ExportJob): void;
  takeEvents(job: ExportJob): ExportEvent[];
  deviceSpecs(): DeviceSpec;
  codecs(): CodecSupport;
}

const native: NativeModule = nativeModule as NativeModule;

export class ReelNative {
  /**
   * Reads real core/memory counts. ArkTS exposes no public memory API, so these
   * come from the NDK (sysconf) and keep the renderer's device tiering accurate.
   */
  static deviceSpec(): DeviceSpec {
    return native.deviceSpecs();
  }

  static startExport(args: ExportStartArgs): ExportJob {
    return native.startExport(args);
  }

  /** Returns 0 on success, -2 when no frame credit is available. */
  static pushFrame(job: ExportJob, rgba: Uint8Array, ptsSeconds: number): number {
    return native.pushFrame(job, rgba, ptsSeconds);
  }

  static pushAudio(job: ExportJob, pcm: Uint8Array): number {
    return native.pushAudio(job, pcm);
  }

  static finishExport(job: ExportJob): number {
    return native.finishExport(job);
  }

  static cancelExport(job: ExportJob): void {
    native.cancelExport(job);
  }

  static destroyExport(job: ExportJob): void {
    native.destroyExport(job);
  }

  static takeEvents(job: ExportJob): ExportEvent[] {
    return native.takeEvents(job);
  }

  /** Reports which encoders this device provides. */
  static codecs(): CodecSupport {
    return native.codecs();
  }
}
