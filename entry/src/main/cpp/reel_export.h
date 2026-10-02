/*
 * Reel-Edit native export + device-spec bridge.
 *
 * Loaded from ArkTS through nodeapi (libreel_napi.so). The ArkTS side owns the
 * WebMessagePort that receives renderer frames; this library owns encoding and
 * muxing, and reports progress back through a callback.
 */

#ifndef REEL_EXPORT_H
#define REEL_EXPORT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Event kinds reported back to ArkTS while an export runs. */
typedef enum ReelExportEventKind {
  REEL_EXPORT_EVENT_CREDIT = 0,
  REEL_EXPORT_EVENT_PROGRESS = 1,
  REEL_EXPORT_EVENT_DONE = 2,
  REEL_EXPORT_EVENT_ERROR = 3
} ReelExportEventKind;

typedef struct ReelExportEvent {
  ReelExportEventKind kind;
  int32_t frame;
  int32_t credits;
  const char *message;
} ReelExportEvent;

/* Mirrors the renderer's OpenReelExportStartArgs. */
typedef struct ReelExportStartArgs {
  const char *output_path;
  int32_t width;
  int32_t height;
  int32_t frame_rate;
  int32_t bitrate_kbps;
  int32_t total_frames;
  int32_t audio_sample_rate;
  int32_t audio_channels;
} ReelExportStartArgs;

typedef struct ReelDeviceSpec {
  int32_t logical_cores;
  int32_t physical_cores;
  int64_t total_memory_bytes;
  int64_t free_memory_bytes;
} ReelDeviceSpec;

typedef struct ReelExportJob ReelExportJob;

typedef void (*ReelExportCallback)(const ReelExportEvent *event, void *ctx);

ReelExportJob *OHReelExportStart(const ReelExportStartArgs *args, ReelExportCallback callback, void *ctx);
int OHReelExportPushFrame(ReelExportJob *job, const uint8_t *rgba, int64_t pts_us);
int OHReelExportPushAudio(ReelExportJob *job, const uint8_t *pcm, int64_t size);
int OHReelExportFinish(ReelExportJob *job);
void OHReelExportCancel(ReelExportJob *job);
void OHReelExportDestroy(ReelExportJob *job);

void OHReelDeviceSpecs(ReelDeviceSpec *out);

/* Returns the H.264 mime the device supports, or NULL when it has no encoder. */
const char *OHReelVideoCodecName(void);

/* Returns the AAC mime the device supports, or NULL when it has no encoder. */
const char *OHReelAudioCodecName(void);

#ifdef __cplusplus
}
#endif

#endif /* REEL_EXPORT_H */
