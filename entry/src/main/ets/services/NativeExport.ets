/*
 * Export job manager.
 *
 * Owns the `window.openreel.export` contract. The desktop build streams raw RGBA
 * frames into an FFmpeg sidecar over a MessagePort
 * (apps/desktop/src/main/sidecar/export-job.ts). Here the same frames are muxed
 * by the platform's own H.264/AAC encoders (src/main/cpp/reel_export.c).
 *
 * Transport note: frames do NOT travel over a WebMessagePort. ArkWeb's
 * createWebMessagePorts + WebviewController.postMessage handoff does not deliver
 * to the page on this kernel — the native call succeeds but the page listener
 * never fires — so the renderer would wait forever on a channel that never
 * arrives. Instead the page-side adapter (rawfile/web/reel_bridge.js) shims a
 * MessagePort over this JSON bridge and base64-encodes each frame, which is
 * slower than a transferred ArrayBuffer but is the transport verified to work in
 * both directions. Credits and completion travel back the same way.
 */

import { util } from '@kit.ArkTS';
import { ReelNative, ExportJob, ExportEvent, ExportStartArgs as NativeExportStartArgs } from './ReelNative';

export interface ExportStartArgs {
  width: number;
  height: number;
  frameRate: number;
  codec: string;
  format: string;
  bitrateKbps: number;
  outputPath: string;
  totalFrames: number;
  audioSampleRate: number;
  audioChannels: number;
  encodeMode?: string;
  quality?: number;
  proresProfile?: string;
}

/** Result handed back to the renderer when a job starts. */
export interface ExportSession {
  jobId: string;
}

export interface FrameArgs {
  jobId: string;
  ts: number;
  data: string;
}

export interface AudioArgs {
  jobId: string;
  data: string;
}

export interface JobArgs {
  jobId: string;
}

/** Event kinds mirrored to the renderer as ExportPortMessage. */
const EVENT_CREDIT = 0;
const EVENT_DONE = 2;
const EVENT_ERROR = 3;

/**
 * Mime strings for the media framework.
 *
 * OH_AVCODEC_MIMETYPE_VIDEO_AVC / _AUDIO_AAC are declared as `extern const char *`
 * but the platform libraries export them as *functions* rather than data, so
 * reading them through the pointer yields a code address instead of a string.
 * The literal values are used instead.
 */
const REEL_MIME_AVC = 'video/avc';
const REEL_MIME_AAC = 'audio/mpeg';

interface Job {
  id: string;
  handle: ExportJob;
  outputPath: string;
  finished: boolean;
  audioBytes: number;
  frameCount: number;
}

/** Receives credit/done/error so they can be pushed into the page. */
export type ExportEventSink = (jobId: string, message: string) => void;

export class NativeExport {
  private jobs: Map<string, Job> = new Map();
  private sink: ExportEventSink | undefined = undefined;

  setEventSink(sink: ExportEventSink): void {
    this.sink = sink;
  }

  /** Starts the native encoder for one export. */
  async start(args: ExportStartArgs): Promise<ExportSession> {
    const jobId: string = `job-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    console.info(
      `[NativeExport] start ${args.width}x${args.height}@${args.frameRate} -> ${args.outputPath}`
    );

    const startArgs: NativeExportStartArgs = {
      outputPath: args.outputPath,
      width: args.width,
      height: args.height,
      frameRate: args.frameRate,
      bitrateKbps: args.bitrateKbps,
      totalFrames: args.totalFrames,
      audioSampleRate: args.audioSampleRate,
      audioChannels: args.audioChannels
    };

    const job: Job = {
      id: jobId,
      handle: ReelNative.startExport(startArgs),
      outputPath: args.outputPath,
      finished: false,
      audioBytes: 0,
      frameCount: 0
    };
    this.jobs.set(jobId, job);

    /*
     * A startup failure (bad params, unsupported codec) is reported immediately
     * so the renderer rejects instead of waiting for credits that never come.
     * A device with no H.264 encoder — which includes the 2in1 emulator image —
     * gets a message that says so plainly rather than a generic failure.
     */
    if (codecVideo() === null) {
      this.emit(
        job,
        JSON.stringify({
          type: 'error',
          message: 'This device has no H.264 encoder, so MP4 export is unavailable. ' +
            'Export needs a device with hardware or system video encoding.'
        })
      );
      job.finished = true;
      return { jobId: jobId };
    }
    this.pumpEvents(job);
    return { jobId: jobId };
  }

  /** Submits one RGBA frame. Returns false once the job is finished. */
  pushFrame(args: FrameArgs): boolean {
    const job: Job | undefined = this.jobs.get(args.jobId);
    if (job === undefined || job.finished) {
      return false;
    }
    const rgba: Uint8Array = base64ToBytes(args.data);
    const rc: number = ReelNative.pushFrame(job.handle, rgba, args.ts);
    if (rc === 0) {
      job.frameCount += 1;
    }
    this.pumpEvents(job);
    return rc === 0;
  }

  /** Submits one PCM chunk (s16le, WAV header already stripped). */
  pushAudio(args: AudioArgs): boolean {
    const job: Job | undefined = this.jobs.get(args.jobId);
    if (job === undefined || job.finished) {
      return false;
    }
    const pcm: Uint8Array = base64ToBytes(args.data);
    ReelNative.pushAudio(job.handle, pcm);
    job.audioBytes += pcm.length;
    return true;
  }

  /** Flushes both encoders and finalises the container. */
  finish(jobId: string): void {
    const job: Job | undefined = this.jobs.get(jobId);
    if (job === undefined || job.finished) {
      return;
    }
    job.finished = true;
    ReelNative.finishExport(job.handle);
    // finishExport emits the final done/error from inside the native call.
    this.pumpEvents(job);
    console.info(
      `[NativeExport] finished ${jobId} frames=${job.frameCount} audio=${job.audioBytes}B`
    );
  }

  async cancel(jobId: string): Promise<void> {
    const job: Job | undefined = this.jobs.get(jobId);
    if (job === undefined) {
      return;
    }
    job.finished = true;
    ReelNative.cancelExport(job.handle);
    this.emit(job, JSON.stringify({ type: 'error', message: 'Export cancelled' }));
  }

  /** Forwards encoder events to the page; credits drive the renderer's throttle. */
  private pumpEvents(job: Job): void {
    const events: ExportEvent[] = ReelNative.takeEvents(job.handle);
    for (const event of events) {
      if (event.kind === EVENT_CREDIT) {
        this.emit(job, JSON.stringify({ type: 'credit', credits: event.credits }));
      } else if (event.kind === EVENT_DONE) {
        this.emit(job, JSON.stringify({ type: 'done' }));
      } else if (event.kind === EVENT_ERROR) {
        console.error(`[NativeExport] ${event.message}`);
        this.emit(job, JSON.stringify({ type: 'error', message: event.message }));
      }
    }
  }

  private emit(job: Job, message: string): void {
    if (this.sink) {
      this.sink(job.id, message);
    }
  }

  releaseAll(): void {
    this.jobs.forEach((job) => {
      ReelNative.destroyExport(job.handle);
    });
    this.jobs.clear();
  }
}

function base64ToBytes(value: string): Uint8Array {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.decodeSync(value);
}

/** Cached encoder availability; probing creates and destroys a codec. */
let cachedVideo: string | null | undefined = undefined;
let cachedAudio: string | null | undefined = undefined;

function codecVideo(): string | null {
  if (cachedVideo === undefined) {
    cachedVideo = probeVideo();
  }
  return cachedVideo;
}

function codecAudio(): string | null {
  if (cachedAudio === undefined) {
    cachedAudio = probeAudio();
  }
  return cachedAudio;
}

function probeVideo(): string | null {
  try {
    return ReelNative.codecs().video;
  } catch (err) {
    return REEL_MIME_AVC;
  }
}

function probeAudio(): string | null {
  try {
    return ReelNative.codecs().audio;
  } catch (err) {
    return REEL_MIME_AAC;
  }
}
