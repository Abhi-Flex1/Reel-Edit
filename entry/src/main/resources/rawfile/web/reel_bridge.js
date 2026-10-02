/*
 * Page-side adapter that materialises window.openreel.
 *
 * The editor source (apps/web/src) is unmodified upstream code: it expects a
 * `window.openreel` object with the exact shape the Electron preload exposes
 * (apps/desktop/src/preload/index.ts). The ArkTS side only offers one JSON
 * bridge method plus a binary message port, so this file rebuilds the desktop
 * object on top of both:
 *
 *   - control calls go through the registered `openreelNative.invoke` proxy,
 *     marshalled as JSON strings because registerJavaScriptProxy only carries
 *     JSON-serialisable values;
 *   - export frames travel over the WebMessagePort handed to us through the
 *     `__openreelExportPort` message, which carries ArrayBuffers natively.
 *
 * This file is served from the HAP's rawfile directory and is injected into the
 * built web bundle before the app scripts run.
 */
(function () {
  'use strict';

  if (window.openreel) {
    return;
  }

  var native = window.openreelNative;
  if (!native || typeof native.invoke !== 'function') {
    console.error('[reel-bridge] native proxy missing; editor cannot start');
    return;
  }

  /* ------------------------------------------------------------------ */
  /* JSON bridge                                                         */
  /* ------------------------------------------------------------------ */

  function base64ToArrayBuffer(value) {
    var binary = atob(value || '');
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }

  /*
   * ArkWeb's async JS proxy does not marshal a returned Promise reliably across
   * the boundary: on this kernel the page observes an empty result and a failure
   * while the real value only arrives seconds later. So `invoke` is registered as
   * a *synchronous* proxy method that only hands the request over; the ArkTS side
   * answers later by calling window.__openreelResolve(id, payload) via
   * runJavaScript, and the promise here resolves from that callback.
   */
  var pending = {};
  var nextRequestId = 0;

  /*
   * Settles one pending request. The ArkTS side always sends a JSON envelope
   * ({ok, result|error}), so success and failure are decided here rather than by
   * which callback the entry happens to carry.
   */
  window.__openreelResolve = function (id, payload) {
    var entry = pending[id];
    if (!entry) {
      return;
    }
    delete pending[id];

    var response;
    try {
      response = JSON.parse(payload);
    } catch (err) {
      entry.reject(new Error('Bridge returned malformed JSON'));
      return;
    }
    if (!response.ok) {
      entry.reject(new Error(response.error || 'Bridge call failed'));
      return;
    }
    entry.resolve(response.result === undefined ? null : response.result);
  };

  function invoke(method, payload) {
    var id = ++nextRequestId;
    return new Promise(function (resolve, reject) {
      pending[id] = { resolve: resolve, reject: reject };
      var request = { id: id, method: method };
      if (payload !== undefined) {
        request.payload = JSON.stringify(payload);
      }
      try {
        native.invoke(JSON.stringify(request));
      } catch (err) {
        delete pending[id];
        reject(err);
      }
    });
  }

  /*
   * Unwraps a bridge result that is itself JSON.
   *
   * Most bridge methods return a JSON document as their `result` string, which
   * invokeJson parses. Scalar results (a path, a handle id, "true") are *also*
   * valid JSON strings, so a plain JSON.parse would turn "true" into a boolean
   * and "\"abc\"" into "abc" — and a handle id would silently change type.
   * These callers want the raw scalar, so they opt out of parsing here.
   */
  function invokeRaw(method, payload) {
    return invoke(method, payload).then(function (result) {
      if (result === null || result === undefined) {
        return null;
      }
      // Only a quoted JSON string is unwrapped; everything else is used as-is.
      if (result.length >= 2 && result.charAt(0) === '"' && result.charAt(result.length - 1) === '"') {
        try {
          return JSON.parse(result);
        } catch (err) {
          return result;
        }
      }
      return result;
    });
  }

  /* Unwrap the JSON envelope used for object/array results. */
  function invokeJson(method, payload) {
    return invoke(method, payload).then(function (result) {
      if (result === null || result === undefined) {
        return null;
      }
      try {
        return JSON.parse(result);
      } catch (err) {
        return result;
      }
    });
  }

  /* ------------------------------------------------------------------ */
  /* Export channel                                                     */
  /* ------------------------------------------------------------------ */

  /*
   * Export channel.
   *
   * ArkWeb's postMessage port handoff (createWebMessagePorts +
   * WebviewController.postMessage) does not deliver to the page on this kernel:
   * the native call succeeds but the page listener never fires, which left the
   * renderer waiting on a channel that never arrived.
   *
   * The renderer (NativeFFmpegBackend) does not use the bridge's port at all —
   * it waits for its own `__openreelExportPort` window message and sets
   * `port.onmessage` on whatever arrives. So a real MessageChannel is created
   * here and port2 is handed to the renderer exactly as the desktop preload
   * does; port1 is the side this adapter drives. Frames are base64 encoded on
   * the JSON bridge, which is slower than a transferred ArrayBuffer but is the
   * transport verified to work in both directions.
   *
   * Credits and the done/error signals come back through __openreelPush, so the
   * renderer's backpressure loop is unchanged.
   */
  var exportChannelPort = null;

  function ensureExportChannel() {
    if (exportChannelPort) {
      return exportChannelPort;
    }
    var channel = new MessageChannel();
    // Hand the renderer's end over through the marker the desktop preload uses.
    window.postMessage({ __openreelExportPort: true }, '*', [channel.port2]);
    exportChannelPort = channel.port1;
    // Frames the renderer posts to its port are forwarded onto the JSON bridge.
    exportChannelPort.onmessage = function (event) {
      forwardExportMessage(event.data);
    };
    exportChannelPort.start();
    return exportChannelPort;
  }

  var currentJobId = null;

  /** Moves one ExportPortMessage from the renderer to the native encoder. */
  function forwardExportMessage(payload) {
    if (!payload || !currentJobId) {
      return;
    }
    if (payload.type === 'finish') {
      invoke('export.finish', { jobId: currentJobId });
      return;
    }
    if (payload.type === 'frame') {
      invoke('export.pushFrame', {
        jobId: currentJobId,
        ts: payload.ts,
        data: arrayBufferToBase64(payload.buffer)
      });
    }
  }

  /** Called from the host to deliver credit / done / error to the renderer. */
  window.__openreelPush = function (jobId, messageJson) {
    var message;
    try {
      message = JSON.parse(messageJson);
    } catch (err) {
      return;
    }
    if (exportChannelPort) {
      exportChannelPort.postMessage(message);
    }
  };

  function arrayBufferToBase64(buffer) {
    var bytes = new Uint8Array(buffer);
    var binary = '';
    var chunk = 0x8000;
    for (var i = 0; i < bytes.length; i += chunk) {
      var end = Math.min(i + chunk, bytes.length);
      var slice = bytes.subarray(i, end);
      for (var j = 0; j < slice.length; j++) {
        binary += String.fromCharCode(slice[j]);
      }
    }
    return btoa(binary);
  }

  function base64ToArrayBuffer(value) {
    var binary = atob(value || '');
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }

  /* ------------------------------------------------------------------ */
  /* window.openreel                                                      */
  /* ------------------------------------------------------------------ */

  window.openreel = {
    platform: 'desktop',
    publicOrigin: 'https://app.openreel.video',

    probeHardware: function () {
      return invokeJson('probeHardware');
    },

    /* Native menu actions are driven from the ArkTS host; no-op by default. */
    onMenuAction: function () {
      return function () {};
    },

    fs: {
      showSaveDialog: function (opts) {
        return invokeRaw('fs.showSaveDialog', opts);
      },
      showOpenDialog: function (opts) {
        return invokeRaw('fs.showOpenDialog', opts);
      },
      readFile: function (path) {
        return invoke('fs.readFile', { path: path });
      },
      readFileBytes: function (path) {
        return invokeRaw('fs.readFileBytes', { path: path }).then(function (result) {
          return base64ToArrayBuffer(result ? result.base64 : '');
        });
      },
      tempFilePath: function (ext) {
        return invokeRaw('fs.tempFilePath', { ext: ext });
      },
      writeFile: function (path, data) {
        return invoke('fs.writeFile', { path: path, data: data });
      },
      openWrite: function (path) {
        return invokeRaw('fs.openWrite', { path: path });
      },
      writeChunk: function (handleId, data, position) {
        var buffer = data instanceof Uint8Array ? data.buffer : data;
        return invoke('fs.writeChunk', {
          handleId: handleId,
          data: arrayBufferToBase64(buffer),
          position: position
        });
      },
      closeWrite: function (handleId) {
        return invoke('fs.closeWrite', { handleId: handleId });
      },
      abortWrite: function (handleId) {
        return invoke('fs.abortWrite', { handleId: handleId });
      },
      revealInFolder: function (path) {
        return invoke('fs.revealInFolder', { path: path });
      }
    },

    keychain: {
      get: function (id) {
        return invokeRaw('keychain.get', { id: id });
      },
      set: function (id, value) {
        return invoke('keychain.set', { id: id, value: value });
      },
      delete: function (id) {
        return invoke('keychain.delete', { id: id });
      }
    },

    export: {
      /*
       * Mirrors NativeFFmpegBackend.start: it resolves a job id, and the port is
       * delivered to the renderer through the __openreelExportPort window
       * message that it awaits concurrently.
       */
      start: function (args) {
        return invokeRaw('export.start', args).then(function (session) {
          currentJobId = session.jobId;
          ensureExportChannel();
          return { jobId: session.jobId };
        });
      },
      writeAudioWav: function (jobId, wav) {
        /* Position 0 is the WAV header; the encoder is fed bare PCM. */
        return invoke('export.writeAudioChunk', { jobId: jobId, position: 0, length: wav.byteLength });
      },
      writeAudioChunk: function (jobId, chunk, position) {
        var buffer = chunk instanceof Uint8Array ? chunk.buffer : chunk;
        if (position !== 0) {
          return invoke('export.pushAudio', {
            jobId: jobId,
            data: arrayBufferToBase64(buffer)
          });
        }
        return invoke('export.writeAudioChunk', {
          jobId: jobId,
          position: position,
          length: buffer.byteLength
        });
      },
      finishAudio: function (jobId) {
        return invoke('export.finishAudio', { jobId: jobId });
      },
      cancel: function (jobId) {
        currentJobId = null;
        return invoke('export.cancel', { jobId: jobId });
      }
    },

    cloud: {
      fetch: function (service, path, options) {
        var payload = {
          service: service,
          path: path,
          url: this.buildCloudUrl(service, path, options),
          headers: (options && options.headers) || {}
        };
        return invokeJson('cloud.fetch', payload);
      },
      buildCloudUrl: function (service, path, options) {
        var base = options && options.baseUrl;
        if (!base) {
          throw new Error('A baseUrl is required for cloud requests');
        }
        return base.replace(/\/$/, '') + '/' + String(path).replace(/^\//, '');
      }
    },

    /*
     * No `win` object on HarmonyOS.
     *
     * The platform draws its own minimise / maximise / close buttons on the
     * window, so exposing this API would render a second, redundant set of
     * controls in the editor's title bar. WindowControls() returns null when
     * window.openreel.win is absent, which is exactly the behaviour we want.
     */

    lifecycle: {
      onQueryUnsaved: function (handler) {
        window.__openreelHostQueryUnsaved = function () {
          try {
            return handler() ? 'true' : 'false';
          } catch (err) {
            return 'false';
          }
        };
        return function () {
          delete window.__openreelHostQueryUnsaved;
        };
      },
      onFlush: function (handler) {
        window.__openreelHostFlush = function () {
          return handler();
        };
        return function () {
          delete window.__openreelHostFlush;
        };
      }
    },

    updater: {
      /* HarmonyOS manages app updates through AppGallery; no in-app updater. */
      onStatus: function () {
        return function () {};
      },
      download: function () {
        return Promise.resolve();
      },
      install: function () {
        return Promise.resolve();
      }
    },

    crash: {
      report: function (payload) {
        console.error('[openreel-crash]', payload && payload.message, payload && payload.stack);
      }
    },

    media: {
      generateProxy: function (args) {
        return invokeRaw('media.generateProxy', args);
      },
      transcode: function (args) {
        return invokeRaw('media.transcode', args);
      },
      extractAudioWav: function (args) {
        return invokeRaw('media.extractAudioWav', args);
      },
      probeAudioStreams: function (args) {
        return invokeRaw('media.probeAudioStreams', args);
      },
      fetchUrl: function (args) {
        return invokeJson('media.fetchUrl', args).then(function (result) {
          return {
            ok: result.ok,
            status: result.status,
            statusText: result.statusText,
            contentType: (result.headers && result.headers['content-type']) || '',
            body: base64ToArrayBuffer(result.body ? result.body.base64 : '')
          };
        });
      }
    }
  };

  /*
   * HarmonyOS export goes through the platform's native H.264/AAC encoder
   * (NativeFFmpegBackend), which is driven by this bridge over a message port.
   *
   * The desktop build prefers the in-page WebCodecs backend whenever
   * `VideoEncoder` exists, because a browser can mux to disk cheaply. Here that
   * would bypass the native encoder entirely and produce no file, so the flag is
   * removed before the editor's capability check runs. Removing it makes
   * shouldUseWebCodecs() return false, which is the same code path the desktop
   * build uses for ProRes/AV1 and for its ffmpeg fallback.
   */
  try {
    delete window.VideoEncoder;
  } catch (err) {
    /* non-configurable in some kernels; the native backend still wins below */
  }
  window.__openreelBridgeReady = true;
})();
