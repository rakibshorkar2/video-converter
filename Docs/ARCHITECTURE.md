# Architecture

## Layout

```
App/VideoConverterApp.swift      @main; scene phase handling, deep-link import
App/AppContainer.swift           Observable dependency container (settings, thermal,
                                 capabilities, diagnostics, history, queue)

UI/                              SwiftUI only, no business logic
Core/Models/                     Value types (Codable): configuration, metadata, job…
Core/Conversion/                 Queue, router, validation, persistence, diagnostics
Media/                           AVFoundation read/analysis helpers (pure functions)
Engines/                         Conversion engine implementations
Storage/                         FileManager/Photos/bookmark helpers
System/                          DeviceCapabilityManager, ThermalMonitor, StorageMonitor
```

## Conversion pipeline

```
User imports video
   └─ ConversionQueueManager.importURL()
       copies into Documents/Imports (kept if "Keep Imported Files")
       applies default preset + settings
       shows ConversionSettingsView (per-job configuration)

QueueManager.start(job)
   └─ analyze (MediaAnalyzer; FFmpeg fallback when native read fails)
   └─ stream-copy compatibility check (FormatCapabilities.canStreamCopy)
   └─ storage pre-check (SizeEstimator + StorageMonitor)
   └─ ConversionEngineRouter.selectEngine(request)
         streamCopy → StreamCopyEngine
         else      → AVFoundationEngine (hardware requested, software retry)
         explicit  → VideoToolboxEngine / FFmpegEngine (when FFMPEG_ENABLED)
   └─ engine.convert(…) with progress + cancellation
   └─ OutputValidator.validate(…)  (duration/codec/file sanity)
   └─ save: Photos | Documents/Converted | bookmarked custom folder
   └─ history entry + job status update + queue.json persistence
```

## Engines

All engines implement `ConversionEngine` and report progress via
`ConversionProgress` (stage, fraction, speed, ETA).

| Engine | Technique | Use |
|---|---|---|
| `StreamCopyEngine` | AVAssetReader/Writer, `.copy` tracks | Lossless preset; container change only |
| `AVFoundationEngine` | AVAssetReader/Writer transcode | Default path; hw encoder, software fallback |
| `VideoToolboxEngine` | VTDecompressionSession → VTCompressionSession | No-scaling requests with explicit preference; pixel-perfect passthrough |
| `FFmpegEngine` | ObjC++ bridge over libav* | FFmpeg-enabled builds only |

`MediaPump` drives readers with `requestMediaDataWhenReady` continuations and
applies frame-rate conversion. `ProgressThrottler` caps UI updates (~10/s).

## Concurrency

- `ConversionQueueManager` is `@MainActor`; conversion work runs off-main
  (engine internals use their own queues/tasks).
- Cancellation is cooperative: `CancellationToken` is polled between frames;
  AVFoundation APIs are cancelled via the token while the pump drains.
- Thermal monitor cancels active jobs when the device reaches a critical
  state; the queue parks queued jobs while thermal state is `serious`.
- Backgrounding pauses the queue; jobs are marked interrupted and restored
  on next launch from `Documents/queue.json`.

## Persistence

| Data | Location |
|---|---|
| Queue | `Documents/queue.json` (StoredJob) |
| History | `Documents/history.json` |
| Imports | `Documents/Imports/` |
| Output (Files) | `Documents/Converted/` |
| Diagnostics, settings | `UserDefaults` |
| Temp | `tmp/VideoConverter/` (cleaned at launch and after jobs) |

## Notes

- All user-facing strings live in `UI/L10n.swift`; never hardcode literals in
  business logic.
- FFmpeg code is strictly behind `#if FFMPEG_ENABLED` in Swift and
  `#if` in `FFmpegBridge.mm`; a plain build never touches FFmpeg.
- Job model (`ConversionJob`) is `@MainActor`-isolated and referenced by
  SwiftUI directly; engines receive plain value types.