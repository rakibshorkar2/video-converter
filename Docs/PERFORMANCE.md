# Performance & Quality

## Engine selection

```
Auto (default)
  streamCopy preset → StreamCopyEngine
  anything else     → AVFoundationEngine
Explicit preferences
  videoToolbox → VideoToolboxEngine (no-scaling requests only, else AVFoundation)
  ffmpeg       → FFmpegEngine (FFMPEG_ENABLED builds only)
```

The router tries hardware encoding first; `AVFoundationEngine` retries with
software encoding when the hardware encoder rejects the configuration
(e.g. unusual resolutions with HEVC on some devices).

## Presets

| Preset | Quality factor | Notes |
|---|---|---|
| Lossless | — | Stream copy, no re-encoding. Container must accept source codecs. |
| Maximum | 1.0 | Near-transparent re-encode; large files. |
| High | 0.85 | Visually transparent for most content. |
| Balanced | 0.65 | Default. |
| Smaller | 0.45 | Also caps resolution at 1080p when source is larger. |
| Custom | — | Manual resolution/framerate/bitrate controls. |

Quality factor maps to:

- **AVFoundation**: `AVVideoAverageBitRateKey` scaled by resolution and
  framerate (≈0.12 bit/pixel at factor 1.0, 24 fps)
- **VideoToolbox**: `kVTCompressionPropertyKey_AverageBitRate` (same model)
- **FFmpeg**: `crf` (18 + (1 − factor) × 17, roughly)

## What affects speed

- **Stream copy** — near-instant, I/O-bound.
- **Hardware encode** — 5–30× realtime for H.264, 3–15× for HEVC on modern
  devices; thermal throttling reduces this over long encodes.
- **Software encode** — 0.5–3× realtime; used only as fallback.
- **Resolution downscale** — the dominant cost; encoding fewer pixels is the
  single best way to speed up and shrink output.
- **Frame-rate conversion** — duplicates/drops frames via the MediaPump;
  negligible cost.

## Storage checks

`SizeEstimator` predicts output size from bitrate model × duration, then
`StorageMonitor` verifies the destination has space for the output plus the
temp file. Storage is re-checked in the queue before each job.

## Thermal & battery

- `ThermalMonitor` observes `ProcessInfo.thermalState`.
- `.serious` → queued jobs wait (`waitingForResources`), UI shows status.
- `.critical` → active job is cancelled (job becomes retryable).
- Low-power mode is surfaced but not forced.

## Diagnostics

With "Record Diagnostics" enabled, each job logs engine selection, source
codec → target codec, duration, and outcome. Copy the log from Settings →
Diagnostics for bug reports.