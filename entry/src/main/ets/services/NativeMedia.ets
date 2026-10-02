/*
 * Media bridge.
 *
 * Reimplements `window.openreel.media` from the Electron main process, where
 * each call shells out to FFmpeg (apps/desktop/src/main/sidecar/media-job.ts).
 * HarmonyOS ships no FFmpeg, so each operation maps onto the platform's own
 * media framework:
 *
 *   generateProxy / transcode -> AVTranscoder
 *   probeAudioStreams        -> AVMetadataExtractor
 *   fetchUrl                 -> @ohos.net.http
 *
 * Audio extraction to WAV is not offered by the ArkTS media API on this SDK, so
 * `extractAudioWav` reports an explicit failure: the desktop build treats the WAV
 * as an acceleration for waveform/beat analysis and the editor falls back to
 * decoding the original media in the browser when it is absent.
 */

import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  AudioStreamInfo,
  AudioStreamsResult,
  ExtractAudioArgs,
  FetchResult,
  MediaRequestOptions,
  OutPathResult,
  ProxyArgs,
  TranscodeArgs,
  UrlArgs
} from './BridgeTypes';

/* ContainerFormatType.CFT_MPEG_4 in the media SDK. */
const CONTAINER_MP4: media.ContainerFormatType = media.ContainerFormatType.CFT_MPEG_4;
/* Fallbacks for streams the ArkTS metadata extractor cannot describe. */
const DEFAULT_AUDIO_CHANNELS = 2;
const DEFAULT_AUDIO_SAMPLE_RATE = 48000;

interface TranscodeOptions {
  srcPath: string;
  videoBitrate: number;
  audioBitrate: number;
}

export class NativeMedia {
  private tempCounter = 0;
  private context: common.UIAbilityContext | undefined = undefined;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  private tempPath(ext: string): string {
    this.tempCounter += 1;
    const cacheDir: string = this.context?.cacheDir ?? '/data/storage/el2/base/cache';
    return `${cacheDir}/openreel-${Date.now()}-${this.tempCounter}.${ext}`;
  }

  /**
   * Builds an editable proxy. AVTranscoder cannot write to its input, so the
   * output lands in the cache and the renderer receives that path.
   */
  async generateProxy(args: ProxyArgs): Promise<OutPathResult> {
    const preset: string = args.preset;
    const bitrate = preset === 'low' ? 800000 : preset === 'medium' ? 2000000 : 5000000;
    return this.runTranscode({
      srcPath: args.srcPath,
      videoBitrate: bitrate,
      audioBitrate: 128000
    });
  }

  async transcode(args: TranscodeArgs): Promise<OutPathResult> {
    return this.runTranscode({
      srcPath: args.srcPath,
      videoBitrate: (args.videoBitrateKbps ?? 4000) * 1000,
      audioBitrate: (args.audioBitrateKbps ?? 128) * 1000
    });
  }

  private async runTranscode(options: TranscodeOptions): Promise<OutPathResult> {
    const outPath = this.tempPath('mp4');
    let transcoder: media.AVTranscoder | null = null;
    try {
      transcoder = await media.createAVTranscoder();
      if (transcoder === null) {
        throw new Error('Transcoder unavailable');
      }

      // The transcoder takes descriptors as instance properties, not config.
      const srcFile: fs.File = fs.openSync(options.srcPath, fs.OpenMode.READ_ONLY);
      const dstFile: fs.File = fs.openSync(outPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      const source: media.AVFileDescriptor = { fd: srcFile.fd, offset: 0, length: -1 };
      transcoder.fdSrc = source;
      transcoder.fdDst = dstFile.fd;
      try {
        const config: media.AVTranscoderConfig = {
          fileFormat: CONTAINER_MP4,
          videoBitrate: options.videoBitrate,
          audioBitrate: options.audioBitrate
        };
        await transcoder.prepare(config);
        await transcoder.start();
      } finally {
        fs.closeSync(srcFile.fd);
        fs.closeSync(dstFile.fd);
      }
      /* Transcoding continues on the platform after start(); the renderer picks
       * up the returned path once the file is readable. */
      return { outPath: outPath };
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[NativeMedia] transcode failed: ${e.code} ${e.message}`);
      const reason = err instanceof Error ? err.message : `code ${e.code}`;
      throw new Error(`Transcode unavailable on this device (${reason})`);
    } finally {
      if (transcoder !== null) {
        try {
          await transcoder.release();
        } catch (err) {
          // already released
        }
      }
    }
  }

  /**
   * WAV extraction is not exposed by the ArkTS media API, so this reports the
   * capability as unavailable. The editor falls back to in-browser decoding for
   * waveforms and beat detection when this is absent.
   */
  async extractAudioWav(args: ExtractAudioArgs): Promise<OutPathResult> {
    throw new Error('Audio WAV extraction is not supported by the HarmonyOS media API');
  }

  /**
   * Reports the audio stream layout so the editor can pick channels/sample rate.
   *
   * The ArkTS metadata extractor exposes container-level tags rather than per-track
   * codec details, so a single stream is described from those tags. The desktop
   * build shells out to ffprobe for exact values; the editor treats this as a
   * hint and falls back to the media element's own decoded values.
   */
  async probeAudioStreams(args: ExtractAudioArgs): Promise<AudioStreamsResult> {
    const streams: AudioStreamInfo[] = [];
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      extractor = await media.createAVMetadataExtractor();
      extractor.setUrlSource(args.srcPath);
      const metadata: media.AVMetadata = await extractor.fetchMetadata();
      const hasAudio: boolean = (metadata.hasAudio ?? 'false') === 'true';
      if (hasAudio) {
        const stream: AudioStreamInfo = {
          index: 0,
          codec: metadata.mimeType ?? 'aac',
          channels: DEFAULT_AUDIO_CHANNELS,
          sampleRate: DEFAULT_AUDIO_SAMPLE_RATE
        };
        streams.push(stream);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[NativeMedia] probeAudioStreams failed: ${e.code} ${e.message}`);
    } finally {
      if (extractor !== null) {
        try {
          await extractor.release();
        } catch (err) {
          // already released
        }
      }
    }
    return { streams: streams };
  }

  /** Downloads a remote asset (motion assets, imported media) for the editor. */
  async fetchUrl(args: UrlArgs): Promise<FetchResult> {
    const request = http.createHttp();
    try {
      const options: MediaRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000
      };
      const response = await request.request(args.url, options);

      let body: ArrayBuffer = response.result as ArrayBuffer;
      const maxBytes = args.maxBytes;
      if (maxBytes !== undefined && body.byteLength > maxBytes) {
        body = body.slice(0, maxBytes);
      }

      return {
        ok: response.responseCode === 200,
        status: response.responseCode,
        statusText: String(response.responseCode),
        contentType: response.header['content-type'] ?? '',
        body: { base64: toBase64(body) }
      };
    } catch (err) {
      const e = err as BusinessError;
      return {
        ok: false,
        status: 0,
        statusText: 'Network error',
        contentType: '',
        body: { base64: '' },
        error: e.message ?? 'Network error'
      };
    } finally {
      try {
        request.destroy();
      } catch (err) {
        // already destroyed
      }
    }
  }
}

function toBase64(buffer: ArrayBuffer): string {
  const helper: util.Base64Helper = new util.Base64Helper();
  const encoded: Uint8Array = helper.encodeSync(new Uint8Array(buffer));
  return String.fromCharCode(...encoded);
}
