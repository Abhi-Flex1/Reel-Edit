/*
 * Shared bridge types.
 *
 * ArkTS forbids anonymous object literal type declarations, so every shape that
 * crosses the bridge is declared here as an explicit interface.
 */

import { http } from '@kit.NetworkKit';
import { BridgeHolder } from './BridgeHolder';

export interface SaveDialogOptions {
  defaultPath?: string;
  filters?: FileFilter[];
}

export interface OpenDialogOptions {
  filters?: FileFilter[];
}

export interface FileFilter {
  name: string;
  extensions: string[];
}

export interface WriteChunkArgs {
  handleId: string;
  data: string;
  position: number;
}

export interface HandleArgs {
  handleId: string;
}

export interface PathArgs {
  path: string;
}

export interface TempPathArgs {
  ext: string;
}

export interface WriteFileArgs {
  path: string;
  data: string;
}

export interface Base64Result {
  base64: string;
}

export interface SecretArgs {
  id: string;
  value: string;
}

export interface JobArgs {
  jobId: string;
}

export interface AudioChunkArgs {
  jobId: string;
  position: number;
  length: number;
}

export interface UrlArgs {
  url: string;
  maxBytes?: number;
}

export interface CloudFetchArgs {
  service: string;
  path: string;
  url: string;
  headers?: Record<string, string>;
  method?: string;
}

export interface CpuInfo {
  model: string;
  physicalCores: number;
  logicalCores: number;
}

export interface MemoryInfo {
  totalBytes: number;
  freeBytes: number;
}

export interface HardwareInfo {
  cpu: CpuInfo;
  memory: MemoryInfo;
  gpus: string[];
  encoders: string[];
  platform: string;
  arch: string;
}

export interface AudioStreamInfo {
  index: number;
  codec: string;
  channels: number;
  sampleRate: number;
}

export interface AudioStreamsResult {
  streams: AudioStreamInfo[];
}

export interface ProxyArgs {
  srcPath: string;
  preset: string;
}

export interface TranscodeArgs {
  srcPath: string;
  container?: string;
  videoBitrateKbps?: number;
  audioBitrateKbps?: number;
}

export interface ExtractAudioArgs {
  srcPath: string;
  streamIndex?: number;
}

export interface OutPathResult {
  outPath: string;
}

export interface FetchResult {
  ok: boolean;
  status: number;
  statusText: string;
  contentType: string;
  body: Base64Result;
  error?: string;
}

export interface CloudFetchResult {
  status: number;
  statusText: string;
  headers: Record<string, string>;
  body: string;
}

export interface BridgeRequest {
  /** Correlates the pushed reply with the page's pending promise. */
  id: number;
  method: string;
  payload?: string;
}

export interface BridgeResponse {
  ok: boolean;
  result?: string;
  error?: string;
}

/** Request options for the AI-provider proxy call. */
export interface CloudRequestOptions {
  method: http.RequestMethod;
  header: Record<string, string>;
  expectDataType: http.HttpDataType;
  connectTimeout: number;
  readTimeout: number;
}

/** Request options for a binary asset download. */
export interface MediaRequestOptions {
  method: http.RequestMethod;
  expectDataType: http.HttpDataType;
  connectTimeout: number;
  readTimeout: number;
}

/** Body returned when a cloud request fails before a response arrives. */
export interface CloudErrorBody {
  error: CloudErrorDetail;
}

export interface CloudErrorDetail {
  message: string;
}

/** Object registered into the page as `window.openreelNative`. */
export interface NativeProxy {
  invoke(request: string): void;
}

/**
 * Concrete proxy passed to registerJavaScriptProxy.
 *
 * ArkTS requires registered objects to be real class instances rather than object
 * literals. The method only forwards the request; the reply is delivered later
 * through window.__openreelResolve (see OpenReelBridge.invoke).
 */
export class NativeBridgeProxy implements NativeProxy {
  invoke(request: string): void {
    BridgeHolder.invoke(request);
  }
}
