/*
 * Reel-Edit native support library (OpenHarmony NDK).
 *
 * Provides the two capabilities the ArkTS layer cannot reach:
 *
 *  1. Device specs (core count, physical memory) via sysconf, so the renderer's
 *     device-capability tiering matches the real machine instead of defaulting
 *     to "low" and disabling exports.
 *
 *  2. The MP4 export encoder: H.264 (OH_VideoEncoder) + AAC (OH_AudioEncoder)
 *     feeding OH_AVMuxer. This replaces the desktop FFmpeg sidecar — the
 *     renderer streams raw RGBA frames and PCM audio and this library muxes
 *     them into a real MP4 using the platform's own codecs.
 *
 * Buffer handling follows the API 24 codec interface: QueryInputBuffer /
 * GetInputBuffer / PushInputData(index, attr) to submit, and
 * QueryOutputBuffer / GetOutputBuffer / FreeOutputBuffer to drain.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <pthread.h>

#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_averrors.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_audioencoder.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include <hilog/log.h>

#include "reel_export.h"

/*
 * Mime strings for the media framework.
 *
 * OH_AVCODEC_MIMETYPE_VIDEO_AVC / _AUDIO_AAC are declared as `extern const char *`
 * but the platform libraries export them as *functions* rather than data, so
 * reading them through the pointer yields a code address instead of a string
 * and every encoder/muxer call fails with AV_ERR_INVALID_VAL. The literal mime
 * values are used instead.
 */
#define REEL_MIME_AVC "video/avc"
#define REEL_MIME_AVC_ALT "video/H264"
#define REEL_MIME_AAC "audio/mpeg"

#define REEL_LOG_DOMAIN 0xD002B
#define REEL_LOG_TAG "ReelExport"

#define REEL_FRAME_CREDITS_MAX 8
#define REEL_AUDIO_SAMPLE_RATE_DEFAULT 48000
#define REEL_AUDIO_CHANNELS_DEFAULT 2
#define REEL_AUDIO_CHUNK_BYTES 4096

/* Output-buffer flags used to mark codec data and end of stream. */
#define REEL_BUFFER_FLAG_EOF 0x2

struct ReelExportJob {
  char *output_path;
  int32_t width;
  int32_t height;
  int32_t frame_rate;
  int32_t bitrate_kbps;
  int32_t total_frames;
  int32_t audio_sample_rate;
  int32_t audio_channels;

  OH_AVMuxer *muxer;
  int32_t video_track;
  int32_t audio_track;

  OH_AVCodec *video_encoder;
  OH_AVCodec *audio_encoder;

  int32_t frames_written;
  int64_t audio_bytes_written;
  uint8_t *audio_pcm;
  size_t audio_pcm_capacity;
  size_t audio_pcm_length;

  int32_t credits;
  int32_t started;
  int32_t cancelled;
  int32_t failed;
  int32_t finished;

  pthread_mutex_t lock;
  ReelExportCallback callback;
  void *callback_ctx;
};

/* ------------------------------------------------------------------ */
/* Codec probe                                                         */
/* ------------------------------------------------------------------ */

/*
 * Reports which encoders the device actually provides. The 2in1 emulator image
 * ships without an H.264 encoder, so the export path has to be able to say so
 * precisely instead of failing with a generic "unsupported" error later on.
 */
const char *OHReelVideoCodecName(void) {
  OH_AVCodec *probe = OH_VideoEncoder_CreateByMime(REEL_MIME_AVC);
  if (probe != NULL) {
    OH_VideoEncoder_Destroy(probe);
    return REEL_MIME_AVC;
  }
  probe = OH_VideoEncoder_CreateByMime(REEL_MIME_AVC_ALT);
  if (probe != NULL) {
    OH_VideoEncoder_Destroy(probe);
    return REEL_MIME_AVC_ALT;
  }
  return NULL;
}

const char *OHReelAudioCodecName(void) {
  OH_AVCodec *probe = OH_AudioEncoder_CreateByMime(REEL_MIME_AAC);
  if (probe != NULL) {
    OH_AudioEncoder_Destroy(probe);
    return REEL_MIME_AAC;
  }
  return NULL;
}

/* ------------------------------------------------------------------ */
/* Device specs                                                        */
/* ------------------------------------------------------------------ */

void OHReelDeviceSpecs(ReelDeviceSpec *out) {
  if (out == NULL) {
    return;
  }
  memset(out, 0, sizeof(*out));

  long cores = sysconf(_SC_NPROCESSORS_ONLN);
  if (cores < 1) {
    cores = sysconf(_SC_NPROCESSORS_CONF);
  }
  out->logical_cores = cores > 0 ? (int32_t)cores : 1;
  /* OpenHarmony exposes no CPU topology, so physical and logical cores carry
   * the same signal; the renderer only tiers on the logical count. */
  out->physical_cores = out->logical_cores;

  long page_size = sysconf(_SC_PAGESIZE);
  if (page_size < 1) {
    page_size = 4096;
  }
  long total_pages = sysconf(_SC_PHYS_PAGES);
  if (total_pages > 0) {
    out->total_memory_bytes = (int64_t)total_pages * (int64_t)page_size;
  }
  long avail_pages = sysconf(_SC_AVPHYS_PAGES);
  if (avail_pages > 0) {
    out->free_memory_bytes = (int64_t)avail_pages * (int64_t)page_size;
  } else {
    out->free_memory_bytes = out->total_memory_bytes;
  }
}

/* ------------------------------------------------------------------ */
/* Callbacks                                                           */
/* ------------------------------------------------------------------ */

static void emit(ReelExportJob *job, ReelExportEventKind kind, int32_t credits, const char *message) {
  if (job->callback == NULL) {
    return;
  }
  ReelExportEvent event;
  event.kind = kind;
  event.frame = job->frames_written;
  event.credits = credits;
  event.message = message;
  job->callback(&event, job->callback_ctx);
}

static void notify_error(ReelExportJob *job, const char *message) {
  job->failed = 1;
  emit(job, REEL_EXPORT_EVENT_ERROR, 0, message);
}

/* ------------------------------------------------------------------ */
/* Encoder setup                                                       */
/* ------------------------------------------------------------------ */

static int configure_video_encoder(ReelExportJob *job) {
  job->video_encoder = OH_VideoEncoder_CreateByMime(REEL_MIME_AVC);
  if (job->video_encoder == NULL) {
    /* Fall back to the other AVC spellings the framework accepts, so a device
     * that only registers one of them still exports. */
    job->video_encoder = OH_VideoEncoder_CreateByMime(REEL_MIME_AVC_ALT);
  }
  if (job->video_encoder == NULL) {
    notify_error(job, "No H.264 video encoder is available on this device");
    return -1;
  }

  OH_AVFormat *format = OH_AVFormat_Create();
  if (format == NULL) {
    notify_error(job, "Failed to allocate video encoder format");
    return -1;
  }

  OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, job->width);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, job->height);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, job->frame_rate);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, job->bitrate_kbps * 1000);
  /* The renderer reads frames back from a 2D canvas as tightly packed RGBA. */
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_RGBA);

  OH_AVErrCode err = OH_VideoEncoder_Configure(job->video_encoder, format);
  OH_AVFormat_Destroy(format);
  if (err != AV_ERR_OK) {
    notify_error(job, "Failed to configure H.264 video encoder");
    return -1;
  }
  return 0;
}

static int configure_audio_encoder(ReelExportJob *job) {
  job->audio_encoder = OH_AudioEncoder_CreateByMime(REEL_MIME_AAC);
  if (job->audio_encoder == NULL) {
    notify_error(job, "Failed to create AAC audio encoder (unsupported on this device)");
    return -1;
  }

  OH_AVFormat *format = OH_AVFormat_Create();
  if (format == NULL) {
    notify_error(job, "Failed to allocate audio encoder format");
    return -1;
  }

  OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, job->audio_sample_rate);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, job->audio_channels);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, 128000);
  OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);

  OH_AVErrCode err = OH_AudioEncoder_Configure(job->audio_encoder, format);
  OH_AVFormat_Destroy(format);
  if (err != AV_ERR_OK) {
    notify_error(job, "Failed to configure AAC audio encoder");
    return -1;
  }
  return 0;
}

static int add_tracks(ReelExportJob *job) {
  OH_AVFormat *video_format = OH_AVFormat_Create();
  if (video_format == NULL) {
    return -1;
  }
  OH_AVFormat_SetStringValue(video_format, OH_MD_KEY_CODEC_MIME, REEL_MIME_AVC);
  /* The muxer validates the track format, and it reads the dimensions from the
   * generic width/height keys; the *_VIDEO_PIC_* pair is what the encoder
   * configures with. Both are set so either lookup finds them. */
  OH_AVFormat_SetIntValue(video_format, OH_MD_KEY_WIDTH, job->width);
  OH_AVFormat_SetIntValue(video_format, OH_MD_KEY_HEIGHT, job->height);
  OH_AVFormat_SetIntValue(video_format, OH_MD_KEY_VIDEO_PIC_WIDTH, job->width);
  OH_AVFormat_SetIntValue(video_format, OH_MD_KEY_VIDEO_PIC_HEIGHT, job->height);
  OH_AVFormat_SetIntValue(video_format, OH_MD_KEY_FRAME_RATE, job->frame_rate);
  OH_AVErrCode err = OH_AVMuxer_AddTrack(job->muxer, &job->video_track, video_format);
  OH_AVFormat_Destroy(video_format);
  if (err != AV_ERR_OK) {
    return -(int32_t)(err + 1000);
  }

  OH_AVFormat *audio_format = OH_AVFormat_Create();
  if (audio_format == NULL) {
    return -1;
  }
  OH_AVFormat_SetStringValue(audio_format, OH_MD_KEY_CODEC_MIME, REEL_MIME_AAC);
  OH_AVFormat_SetIntValue(audio_format, OH_MD_KEY_AUD_SAMPLE_RATE, job->audio_sample_rate);
  OH_AVFormat_SetIntValue(audio_format, OH_MD_KEY_AUD_CHANNEL_COUNT, job->audio_channels);
  err = OH_AVMuxer_AddTrack(job->muxer, &job->audio_track, audio_format);
  OH_AVFormat_Destroy(audio_format);
  if (err != AV_ERR_OK) {
    return -(int32_t)(err + 2000);
  }
  OH_LOG_Print(LOG_APP, LOG_INFO, REEL_LOG_DOMAIN, REEL_LOG_TAG, "tracks video=%d audio=%d",
               (int32_t)job->video_track, (int32_t)job->audio_track);
  return 0;
}

/* ------------------------------------------------------------------ */
/* Frame / audio submission                                            */
/* ------------------------------------------------------------------ */

/* Copies the encoder's finished samples into the muxer for one track.
 * The video and audio codecs expose the same buffer protocol under different
 * prefixes, so both call sites funnel through these helpers. */
static void drain_video(OH_AVCodec *encoder, OH_AVMuxer *muxer, int32_t track) {
  for (;;) {
    uint32_t index = 0;
    /* A zero timeout keeps this non-blocking; whatever is ready is drained. */
    if (OH_VideoEncoder_QueryOutputBuffer(encoder, &index, 0) != AV_ERR_OK) {
      return;
    }
    OH_AVBuffer *out = OH_VideoEncoder_GetOutputBuffer(encoder, index);
    if (out == NULL) {
      return;
    }
    OH_AVCodecBufferAttr attr;
    memset(&attr, 0, sizeof(attr));
    if (OH_AVBuffer_GetBufferAttr(out, &attr) == AV_ERR_OK && attr.size > 0) {
      OH_AVMuxer_WriteSampleBuffer(muxer, (uint32_t)track, out);
    }
    OH_VideoEncoder_FreeOutputBuffer(encoder, index);
  }
}

static void drain_audio(OH_AVCodec *encoder, OH_AVMuxer *muxer, int32_t track) {
  for (;;) {
    uint32_t index = 0;
    if (OH_AudioCodec_QueryOutputBuffer(encoder, &index, 0) != AV_ERR_OK) {
      return;
    }
    OH_AVBuffer *out = OH_AudioCodec_GetOutputBuffer(encoder, index);
    if (out == NULL) {
      return;
    }
    OH_AVCodecBufferAttr attr;
    memset(&attr, 0, sizeof(attr));
    if (OH_AVBuffer_GetBufferAttr(out, &attr) == AV_ERR_OK && attr.size > 0) {
      OH_AVMuxer_WriteSampleBuffer(muxer, (uint32_t)track, out);
    }
    OH_AudioCodec_FreeOutputBuffer(encoder, index);
  }
}

int OHReelExportPushFrame(ReelExportJob *job, const uint8_t *rgba, int64_t pts_us) {
  if (job == NULL || rgba == NULL || !job->started || job->failed || job->cancelled) {
    return -1;
  }

  pthread_mutex_lock(&job->lock);
  if (job->credits <= 0) {
    pthread_mutex_unlock(&job->lock);
    return -2;
  }

  const size_t frame_size = (size_t)job->width * (size_t)job->height * 4;

  uint32_t index = 0;
  OH_AVErrCode err = OH_VideoEncoder_QueryInputBuffer(job->video_encoder, &index, 10000000);
  if (err != AV_ERR_OK) {
    pthread_mutex_unlock(&job->lock);
    notify_error(job, "Timed out waiting for a video input buffer");
    return -1;
  }

  OH_AVBuffer *buffer = OH_VideoEncoder_GetInputBuffer(job->video_encoder, index);
  if (buffer == NULL) {
    pthread_mutex_unlock(&job->lock);
    notify_error(job, "Failed to acquire video input buffer");
    return -1;
  }

  memcpy(OH_AVBuffer_GetAddr(buffer), rgba, frame_size);

  OH_AVCodecBufferAttr attr;
  memset(&attr, 0, sizeof(attr));
  attr.pts = pts_us;
  attr.size = (int32_t)frame_size;
  attr.offset = 0;
  attr.flags = 0;
  OH_AVBuffer_SetBufferAttr(buffer, &attr);

  err = OH_VideoEncoder_PushInputBuffer(job->video_encoder, index);
  if (err != AV_ERR_OK) {
    pthread_mutex_unlock(&job->lock);
    notify_error(job, "Failed to submit video frame to encoder");
    return -1;
  }

  job->frames_written += 1;
  /* One credit is spent here and one is returned immediately, so the renderer
   * keeps a small rolling window in flight instead of stalling per frame. */
  pthread_mutex_unlock(&job->lock);

  pthread_mutex_lock(&job->lock);
  drain_video(job->video_encoder, job->muxer, job->video_track);
  pthread_mutex_unlock(&job->lock);

  emit(job, REEL_EXPORT_EVENT_CREDIT, 1, NULL);
  emit(job, REEL_EXPORT_EVENT_PROGRESS, 0, NULL);
  return 0;
}

int OHReelExportPushAudio(ReelExportJob *job, const uint8_t *pcm, int64_t size) {
  if (job == NULL || pcm == NULL || size <= 0 || job->failed || job->cancelled) {
    return -1;
  }

  pthread_mutex_lock(&job->lock);
  if (job->audio_pcm_length + (size_t)size > job->audio_pcm_capacity) {
    size_t required = job->audio_pcm_length + (size_t)size;
    size_t capacity = job->audio_pcm_capacity == 0 ? (1024 * 1024) : job->audio_pcm_capacity;
    while (capacity < required) {
      capacity *= 2;
    }
    uint8_t *grown = (uint8_t *)realloc(job->audio_pcm, capacity);
    if (grown == NULL) {
      pthread_mutex_unlock(&job->lock);
      notify_error(job, "Failed to grow audio buffer");
      return -1;
    }
    job->audio_pcm = grown;
    job->audio_pcm_capacity = capacity;
  }
  memcpy(job->audio_pcm + job->audio_pcm_length, pcm, (size_t)size);
  job->audio_pcm_length += (size_t)size;
  job->audio_bytes_written += size;
  pthread_mutex_unlock(&job->lock);
  return 0;
}

/* Feeds buffered PCM through the AAC encoder and writes the track samples. */
static int flush_audio(ReelExportJob *job) {
  if (job->audio_pcm_length == 0) {
    return 0;
  }
  const uint8_t *data = job->audio_pcm;
  size_t remaining = job->audio_pcm_length;
  const int64_t bytes_per_second = (int64_t)job->audio_sample_rate * job->audio_channels * 2;
  int64_t pts_us = 0;

  while (remaining > 0 && !job->cancelled && !job->failed) {
    size_t take = remaining < REEL_AUDIO_CHUNK_BYTES ? remaining : REEL_AUDIO_CHUNK_BYTES;

    uint32_t index = 0;
    if (OH_AudioCodec_QueryInputBuffer(job->audio_encoder, &index, 10000000) != AV_ERR_OK) {
      return -1;
    }
    OH_AVBuffer *buffer = OH_AudioCodec_GetInputBuffer(job->audio_encoder, index);
    if (buffer == NULL) {
      return -1;
    }
    memcpy(OH_AVBuffer_GetAddr(buffer), data, take);

    OH_AVCodecBufferAttr attr;
    memset(&attr, 0, sizeof(attr));
    attr.pts = pts_us;
    attr.size = (int32_t)take;
    attr.offset = 0;
    attr.flags = 0;
    OH_AVBuffer_SetBufferAttr(buffer, &attr);

    if (OH_AudioCodec_PushInputBuffer(job->audio_encoder, index) != AV_ERR_OK) {
      return -1;
    }

    /* Give the encoder a chance to emit output for this chunk. */
    drain_audio(job->audio_encoder, job->muxer, job->audio_track);

    pts_us += (int64_t)((take * 1000000) / bytes_per_second);
    data += take;
    remaining -= take;
  }
  return remaining > 0 ? -1 : 0;
}

int OHReelExportFinish(ReelExportJob *job) {
  if (job == NULL || !job->started) {
    return -1;
  }
  pthread_mutex_lock(&job->lock);

  if (flush_audio(job) != 0) {
    pthread_mutex_unlock(&job->lock);
    notify_error(job, "Failed to encode the audio track");
    return -1;
  }

  /* Signal end of stream so both encoders flush their remaining frames. */
  OH_AVCodecBufferAttr eof;
  memset(&eof, 0, sizeof(eof));
  eof.pts = -1;
  eof.size = 0;
  eof.offset = 0;
  eof.flags = REEL_BUFFER_FLAG_EOF;

  uint32_t index = 0;
  if (OH_VideoEncoder_QueryInputBuffer(job->video_encoder, &index, 10000000) == AV_ERR_OK) {
    OH_AVBuffer *buffer = OH_VideoEncoder_GetInputBuffer(job->video_encoder, index);
    if (buffer != NULL) {
      OH_AVBuffer_SetBufferAttr(buffer, &eof);
      OH_VideoEncoder_PushInputBuffer(job->video_encoder, index);
    }
  }
  if (OH_AudioCodec_QueryInputBuffer(job->audio_encoder, &index, 10000000) == AV_ERR_OK) {
    OH_AVBuffer *buffer = OH_AudioCodec_GetInputBuffer(job->audio_encoder, index);
    if (buffer != NULL) {
      OH_AVBuffer_SetBufferAttr(buffer, &eof);
      OH_AudioCodec_PushInputBuffer(job->audio_encoder, index);
    }
  }

  drain_video(job->video_encoder, job->muxer, job->video_track);
  drain_audio(job->audio_encoder, job->muxer, job->audio_track);

  OH_VideoEncoder_Stop(job->video_encoder);
  OH_AudioEncoder_Stop(job->audio_encoder);
  OH_AVMuxer_Stop(job->muxer);
  pthread_mutex_unlock(&job->lock);

  job->finished = 1;
  emit(job, REEL_EXPORT_EVENT_DONE, 0, NULL);
  return 0;
}

void OHReelExportCancel(ReelExportJob *job) {
  if (job == NULL) {
    return;
  }
  job->cancelled = 1;
}

void OHReelExportDestroy(ReelExportJob *job) {
  if (job == NULL) {
    return;
  }
  if (job->video_encoder != NULL) {
    OH_VideoEncoder_Destroy(job->video_encoder);
  }
  if (job->audio_encoder != NULL) {
    OH_AudioEncoder_Destroy(job->audio_encoder);
  }
  if (job->muxer != NULL) {
    OH_AVMuxer_Destroy(job->muxer);
  }
  free(job->audio_pcm);
  free(job->output_path);
  pthread_mutex_destroy(&job->lock);
  free(job);
}

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

/* Creates every missing parent directory of `path`. The picker can return a
 * nested target such as <filesDir>/storage/Users/currentUser/clip.mp4 whose
 * intermediate folders are absent, and a single mkdir() would not be enough. */
static void ensure_parent_dirs(const char *path) {
  char buffer[1024];
  strncpy(buffer, path, sizeof(buffer) - 1);
  buffer[sizeof(buffer) - 1] = '\0';

  for (char *p = buffer + 1; *p != '\0'; p++) {
    if (*p != '/') {
      continue;
    }
    *p = '\0';
    mkdir(buffer, 0755);
    *p = '/';
  }
}

ReelExportJob *OHReelExportStart(const ReelExportStartArgs *args, ReelExportCallback callback, void *ctx) {
  if (args == NULL) {
    return NULL;
  }

  ReelExportJob *job = (ReelExportJob *)calloc(1, sizeof(ReelExportJob));
  if (job == NULL) {
    return NULL;
  }

  job->output_path = strdup(args->output_path);
  job->width = args->width;
  job->height = args->height;
  job->frame_rate = args->frame_rate > 0 ? args->frame_rate : 30;
  job->bitrate_kbps = args->bitrate_kbps > 0 ? args->bitrate_kbps : 12000;
  job->total_frames = args->total_frames;
  job->audio_sample_rate = args->audio_sample_rate > 0 ? args->audio_sample_rate : REEL_AUDIO_SAMPLE_RATE_DEFAULT;
  job->audio_channels = args->audio_channels > 0 ? args->audio_channels : REEL_AUDIO_CHANNELS_DEFAULT;
  job->callback = callback;
  job->callback_ctx = ctx;
  job->video_track = -1;
  job->audio_track = -1;
  pthread_mutex_init(&job->lock, NULL);

  /* The muxer takes an already-open fd. The save picker can return a path whose
   * parent directories do not exist yet, so create them before opening. */
  ensure_parent_dirs(args->output_path);

  int fd = open(args->output_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    notify_error(job, "Failed to open the output file for writing");
    return job;
  }
  job->muxer = OH_AVMuxer_Create(fd, AV_OUTPUT_FORMAT_MPEG_4);
  close(fd);
  if (job->muxer == NULL) {
    notify_error(job, "Failed to create the MP4 muxer");
    return job;
  }

  int track_rc = add_tracks(job);
  if (track_rc != 0) {
    char message[96];
    snprintf(message, sizeof(message), "MP4 muxer rejected the tracks (code %d)", track_rc);
    notify_error(job, message);
    return job;
  }
  if (configure_video_encoder(job) != 0) {
    return job;
  }
  if (configure_audio_encoder(job) != 0) {
    return job;
  }
  OH_AVErrCode mux_rc = OH_AVMuxer_Start(job->muxer);
  if (mux_rc != AV_ERR_OK) {
    char message[96];
    snprintf(message, sizeof(message), "Muxer start failed (code %d)", (int)mux_rc);
    notify_error(job, message);
    return job;
  }
  OH_AVErrCode venc_rc = OH_VideoEncoder_Start(job->video_encoder);
  if (venc_rc != AV_ERR_OK) {
    char message[96];
    snprintf(message, sizeof(message), "H.264 encoder start failed (code %d)", (int)venc_rc);
    notify_error(job, message);
    return job;
  }
  if (OH_AudioEncoder_Start(job->audio_encoder) != AV_ERR_OK) {
    notify_error(job, "Failed to start the AAC audio encoder");
    return job;
  }

  job->started = 1;
  job->credits = REEL_FRAME_CREDITS_MAX;
  emit(job, REEL_EXPORT_EVENT_CREDIT, REEL_FRAME_CREDITS_MAX, NULL);
  return job;
}
