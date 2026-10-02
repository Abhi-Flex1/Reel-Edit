/*
 * Node-API bridge between ArkTS and the native export library.
 *
 * ArkTS drives the export through these calls; everything else (encoder setup,
 * muxing, credit accounting) stays in reel_export.c. Each export job is an
 * external handle owned by ArkTS so it can be started, fed and torn down across
 * the WebMessagePort message stream.
 *
 * Encoder events (credit / progress / done / error) are reported by polling
 * reel_takeEvents, which drains a mutex-protected queue the native encoder
 * appends to. ArkTS calls it from its message loop, so no threadsafe-function
 * machinery is needed.
 */

#include <string.h>
#include <stdlib.h>
#include <pthread.h>

#include "napi/native_api.h"
#include "reel_export.h"

#define REEL_NAPI_CALL(env, call)                        \
  do {                                                   \
    napi_status _status = (call);                        \
    if (_status != napi_ok) {                            \
      napi_throw_error((env), NULL, "napi call failed"); \
      return NULL;                                       \
    }                                                    \
  } while (0)

#define REEL_MAX_PENDING_EVENTS 64

typedef struct ReelPendingEvent {
  int32_t kind;
  int32_t frame;
  int32_t credits;
  char message[256];
} ReelPendingEvent;

typedef struct ReelEventQueue {
  ReelPendingEvent items[REEL_MAX_PENDING_EVENTS];
  int32_t head;
  int32_t tail;
  pthread_mutex_t lock;
} ReelEventQueue;

typedef struct ReelJobHandle {
  ReelExportJob *job;
  ReelEventQueue *queue;
} ReelJobHandle;

/* Appends one encoder event; called from the encoder thread. */
static void reel_export_event(const ReelExportEvent *event, void *ctx) {
  ReelJobHandle *handle = (ReelJobHandle *)ctx;
  if (handle == NULL || handle->queue == NULL || event == NULL) {
    return;
  }
  ReelEventQueue *queue = handle->queue;
  pthread_mutex_lock(&queue->lock);
  int32_t next = (queue->tail + 1) % REEL_MAX_PENDING_EVENTS;
  if (next != queue->head) {
    ReelPendingEvent *slot = &queue->items[queue->tail];
    slot->kind = (int32_t)event->kind;
    slot->frame = event->frame;
    slot->credits = event->credits;
    slot->message[0] = '\0';
    if (event->message != NULL) {
      strncpy(slot->message, event->message, sizeof(slot->message) - 1);
      slot->message[sizeof(slot->message) - 1] = '\0';
    }
    queue->tail = next;
  }
  pthread_mutex_unlock(&queue->lock);
}

/* ------------------------------------------------------------------ */
/* JS entry points                                                     */
/* ------------------------------------------------------------------ */

static napi_value reel_start_export(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  REEL_NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, NULL, NULL));

  ReelExportStartArgs args;
  memset(&args, 0, sizeof(args));

  napi_value output_path;
  REEL_NAPI_CALL(env, napi_get_named_property(env, argv[0], "outputPath", &output_path));
  char path_buffer[1024] = {0};
  size_t path_len = 0;
  REEL_NAPI_CALL(env, napi_get_value_string_utf8(env, output_path, path_buffer,
                                                 sizeof(path_buffer), &path_len));
  args.output_path = path_buffer;

  int32_t values[7];
  const char *keys[7] = {"width", "height", "frameRate", "bitrateKbps",
                         "totalFrames", "audioSampleRate", "audioChannels"};
  for (int i = 0; i < 7; i++) {
    napi_value prop;
    REEL_NAPI_CALL(env, napi_get_named_property(env, argv[0], keys[i], &prop));
    REEL_NAPI_CALL(env, napi_get_value_int32(env, prop, &values[i]));
  }
  args.width = values[0];
  args.height = values[1];
  args.frame_rate = values[2];
  args.bitrate_kbps = values[3];
  args.total_frames = values[4];
  args.audio_sample_rate = values[5];
  args.audio_channels = values[6];

  ReelJobHandle *handle = (ReelJobHandle *)calloc(1, sizeof(ReelJobHandle));
  if (handle == NULL) {
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }
  handle->queue = (ReelEventQueue *)calloc(1, sizeof(ReelEventQueue));
  if (handle->queue == NULL) {
    free(handle);
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }
  pthread_mutex_init(&handle->queue->lock, NULL);

  handle->job = OHReelExportStart(&args, reel_export_event, handle);

  napi_value result;
  REEL_NAPI_CALL(env, napi_create_external(env, handle, NULL, NULL, &result));
  return result;
}

static ReelJobHandle *resolve_handle(napi_env env, napi_value value) {
  void *data = NULL;
  if (napi_get_value_external(env, value, &data) != napi_ok) {
    return NULL;
  }
  return (ReelJobHandle *)data;
}

/* pushFrame(handle, rgba, ptsSeconds) */
static napi_value reel_push_frame(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  REEL_NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, NULL, NULL));

  ReelJobHandle *handle = resolve_handle(env, argv[0]);
  if (handle == NULL || handle->job == NULL) {
    napi_value result;
    REEL_NAPI_CALL(env, napi_create_int32(env, -1, &result));
    return result;
  }

  void *data = NULL;
  size_t length = 0;
  napi_typedarray_type type;
  REEL_NAPI_CALL(env, napi_get_typedarray_info(env, argv[1], &type, &length, &data, NULL, NULL));

  double ts_seconds = 0;
  REEL_NAPI_CALL(env, napi_get_value_double(env, argv[2], &ts_seconds));

  int rc = OHReelExportPushFrame(handle->job, (const uint8_t *)data,
                                 (int64_t)(ts_seconds * 1000000.0));
  napi_value result;
  REEL_NAPI_CALL(env, napi_create_int32(env, rc, &result));
  return result;
}

/* pushAudio(handle, pcmBytes) */
static napi_value reel_push_audio(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  REEL_NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, NULL, NULL));

  ReelJobHandle *handle = resolve_handle(env, argv[0]);
  if (handle == NULL || handle->job == NULL) {
    napi_value result;
    REEL_NAPI_CALL(env, napi_create_int32(env, -1, &result));
    return result;
  }

  void *data = NULL;
  size_t length = 0;
  napi_typedarray_type type;
  REEL_NAPI_CALL(env, napi_get_typedarray_info(env, argv[1], &type, &length, &data, NULL, NULL));

  int rc = OHReelExportPushAudio(handle->job, (const uint8_t *)data, (int64_t)length);
  napi_value result;
  REEL_NAPI_CALL(env, napi_create_int32(env, rc, &result));
  return result;
}

static napi_value reel_finish_export(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  REEL_NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, NULL, NULL));

  ReelJobHandle *handle = resolve_handle(env, argv[0]);
  int rc = -1;
  if (handle != NULL && handle->job != NULL) {
    rc = OHReelExportFinish(handle->job);
  }
  napi_value result;
  REEL_NAPI_CALL(env, napi_create_int32(env, rc, &result));
  return result;
}

static napi_value reel_cancel_export(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  REEL_NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, NULL, NULL));

  ReelJobHandle *handle = resolve_handle(env, argv[0]);
  if (handle != NULL && handle->job != NULL) {
    OHReelExportCancel(handle->job);
  }
  napi_value result;
  REEL_NAPI_CALL(env, napi_get_undefined(env, &result));
  return result;
}

static napi_value reel_destroy_export(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  REEL_NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, NULL, NULL));

  ReelJobHandle *handle = resolve_handle(env, argv[0]);
  if (handle != NULL) {
    if (handle->job != NULL) {
      OHReelExportDestroy(handle->job);
      handle->job = NULL;
    }
    if (handle->queue != NULL) {
      pthread_mutex_destroy(&handle->queue->lock);
      free(handle->queue);
      handle->queue = NULL;
    }
    free(handle);
  }
  napi_value result;
  REEL_NAPI_CALL(env, napi_get_undefined(env, &result));
  return result;
}

/* Drains queued encoder events into a flat JS array of objects. */
static napi_value reel_take_events(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  REEL_NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, NULL, NULL));

  ReelJobHandle *handle = resolve_handle(env, argv[0]);
  napi_value result;
  if (handle == NULL || handle->queue == NULL) {
    REEL_NAPI_CALL(env, napi_create_array_with_length(env, 0, &result));
    return result;
  }

  ReelEventQueue *queue = handle->queue;
  napi_value events;
  REEL_NAPI_CALL(env, napi_create_array(env, &events));

  uint32_t out_index = 0;
  pthread_mutex_lock(&queue->lock);
  while (queue->head != queue->tail) {
    ReelPendingEvent *pending = &queue->items[queue->head];
    queue->head = (queue->head + 1) % REEL_MAX_PENDING_EVENTS;

    napi_value event;
    napi_create_object(env, &event);

    napi_value kind;
    napi_create_int32(env, pending->kind, &kind);
    napi_set_named_property(env, event, "kind", kind);

    napi_value frame;
    napi_create_int32(env, pending->frame, &frame);
    napi_set_named_property(env, event, "frame", frame);

    napi_value credits;
    napi_create_int32(env, pending->credits, &credits);
    napi_set_named_property(env, event, "credits", credits);

    napi_value message;
    napi_create_string_utf8(env, pending->message, NAPI_AUTO_LENGTH, &message);
    napi_set_named_property(env, event, "message", message);

    napi_set_element(env, events, out_index++, event);
  }
  pthread_mutex_unlock(&queue->lock);

  return events;
}

/* Real core/memory counts so the renderer's device tiering matches the machine. */
static napi_value reel_device_specs(napi_env env, napi_callback_info info) {
  ReelDeviceSpec spec;
  OHReelDeviceSpecs(&spec);

  napi_value result;
  napi_create_object(env, &result);

  napi_value cores;
  napi_create_int32(env, spec.logical_cores, &cores);
  napi_set_named_property(env, result, "logicalCores", cores);

  napi_value physical;
  napi_create_int32(env, spec.physical_cores, &physical);
  napi_set_named_property(env, result, "physicalCores", physical);

  napi_value total;
  napi_create_int64(env, spec.total_memory_bytes, &total);
  napi_set_named_property(env, result, "totalMemoryBytes", total);

  napi_value avail;
  napi_create_int64(env, spec.free_memory_bytes, &avail);
  napi_set_named_property(env, result, "freeMemoryBytes", avail);

  return result;
}

/* Reports the encoders the device provides, so the UI can explain an
 * unsupported export precisely instead of failing opaquely. */
static napi_value reel_codecs(napi_env env, napi_callback_info info) {
  napi_value result;
  napi_create_object(env, &result);

  const char *video = OHReelVideoCodecName();
  const char *audio = OHReelAudioCodecName();

  napi_value video_value;
  if (video == NULL) {
    napi_get_null(env, &video_value);
  } else {
    napi_create_string_utf8(env, video, NAPI_AUTO_LENGTH, &video_value);
  }
  napi_set_named_property(env, result, "video", video_value);

  napi_value audio_value;
  if (audio == NULL) {
    napi_get_null(env, &audio_value);
  } else {
    napi_create_string_utf8(env, audio, NAPI_AUTO_LENGTH, &audio_value);
  }
  napi_set_named_property(env, result, "audio", audio_value);

  return result;
}

static napi_value init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"startExport", NULL, reel_start_export, NULL, NULL, NULL, napi_default, NULL},
      {"pushFrame", NULL, reel_push_frame, NULL, NULL, NULL, napi_default, NULL},
      {"pushAudio", NULL, reel_push_audio, NULL, NULL, NULL, napi_default, NULL},
      {"finishExport", NULL, reel_finish_export, NULL, NULL, NULL, napi_default, NULL},
      {"cancelExport", NULL, reel_cancel_export, NULL, NULL, NULL, napi_default, NULL},
      {"destroyExport", NULL, reel_destroy_export, NULL, NULL, NULL, napi_default, NULL},
      {"takeEvents", NULL, reel_take_events, NULL, NULL, NULL, napi_default, NULL},
      {"deviceSpecs", NULL, reel_device_specs, NULL, NULL, NULL, napi_default, NULL},
      {"codecs", NULL, reel_codecs, NULL, NULL, NULL, napi_default, NULL},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = init,
    .nm_modname = "reeledit",
    .nm_priv = NULL,
    .reserved = {0},
};

__attribute__((constructor)) void RegisterEntryModule(void) { napi_module_register(&g_module); }
