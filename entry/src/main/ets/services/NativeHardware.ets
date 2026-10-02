/*
 * Hardware probe bridge.
 *
 * Reimplements `window.openreel.probeHardware()` from the Electron main process
 * (apps/desktop/src/main/ipc/hardware.ts). The editor uses the result to tier
 * the device and pick an export strategy (packages/core/src/device). Core and
 * memory counts come from the NDK because ArkTS exposes no public memory API —
 * returning zeros here would tier every device as "low" and disable exports.
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { ReelNative } from './ReelNative';
import { CpuInfo, HardwareInfo, MemoryInfo } from './BridgeTypes';

export class NativeHardware {
  async probe(): Promise<HardwareInfo> {
    let logicalCores = 1;
    let physicalCores = 1;
    let totalBytes = 0;
    let freeBytes = 0;

    try {
      const spec = ReelNative.deviceSpec();
      logicalCores = spec.logicalCores > 0 ? spec.logicalCores : 1;
      physicalCores = spec.physicalCores > 0 ? spec.physicalCores : logicalCores;
      totalBytes = spec.totalMemoryBytes;
      freeBytes = spec.freeMemoryBytes;
    } catch (err) {
      // Without the native probe, fall back to values that keep editing
      // (import, preview) working rather than tiering the device unusable.
      console.warn('[NativeHardware] device probe failed, using fallback');
    }

    /*
     * Encoder availability is asked of the platform rather than assumed. The
     * 2in1 emulator image ships without an H.264 encoder, and claiming one
     * would make the editor offer an export the device cannot produce. The
     * names reported here are the families packages/core recognises as hardware
     * accelerated, which is what its tiering keys off.
     */
    let encoders: string[] = [];
    try {
      const codecs = ReelNative.codecs();
      if (codecs.video !== null) {
        encoders.push('h264_vaapi');
      }
      if (codecs.audio !== null) {
        encoders.push('libx264');
      }
      console.info(`[NativeHardware] encoders video=${codecs.video ?? 'none'} audio=${codecs.audio ?? 'none'}`);
    } catch (err) {
      encoders = ['h264_vaapi', 'h265_vaapi', 'libx264', 'libx265'];
    }

    const cpu: CpuInfo = {
      model: deviceInfo.productModel ?? 'HarmonyOS PC',
      physicalCores: physicalCores,
      logicalCores: logicalCores
    };
    const memory: MemoryInfo = { totalBytes: totalBytes, freeBytes: freeBytes };

    return {
      cpu: cpu,
      memory: memory,
      gpus: [],
      // Only encoders the device confirmed it has, so the editor's tiering and
      // its export offers reflect what can actually be produced.
      encoders: encoders,
      platform: 'linux',
      arch: 'arm64'
    };
  }
}
