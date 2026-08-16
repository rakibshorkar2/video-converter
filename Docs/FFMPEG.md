# FFmpeg Support

FFmpeg support is **optional** and disabled by default. The standard build
targets only the three native engines (Stream Copy, AVFoundation,
VideoToolbox) and the MP4/MOV/M4V containers. When enabled, MKV/WebM/AVI
output and VP8/VP9/AV1/MPEG-4 encoding become available.

## Enabling

```sh
./Scripts/build_ffmpeg_ios.sh   # downloads FFmpeg 6.1.1, builds device+simulator
xcodegen generate               # re-generates the project
```

The script writes `Scripts/ffmpeg_flags.xcconfig` with:

```
FFMPEG_ENABLED = 1
SWIFT_ACTIVE_COMPILATION_CONDITIONS = FFMPEG_ENABLED
GCC_PREPROCESSOR_DEFINITIONS = FFMPEG_ENABLED=1
HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS / OTHER_LDFLAGS
```

`project.yml` applies this file via `configFiles` for Debug and Release.
A placeholder version of the file is committed, so the native build works
out of the box; the build script overwrites it with the FFmpeg flags.

> Note: to revert to the native build, restore the placeholder
> (`git checkout -- Scripts/ffmpeg_flags.xcconfig` or `./Scripts/build_ffmpeg_ios.sh --clean`),
> delete `Vendor/ffmpeg-ios`, remove `VideoConverter.xcodeproj` and re-run
> `xcodegen generate` so stale linker flags disappear.

## How the app uses it

- `Engines/FFmpeg/FFmpegBridge.h/.mm` — ObjC++ wrapper around libavformat/
  libavcodec/libswscale/libswresample. Exposes `ffpeg_convert` (remux or
  transcode with a progress callback, cancellation, thumbnail extraction)
  and `ffpeg_probe` (metadata via `avformat_find_stream_info`).
- `Engines/FFmpeg/FFmpegEngine.swift` — Swift engine conforming to
  `ConversionEngine`; gated by `#if FFMPEG_ENABLED`.
- `FormatCapabilities` (Media/) — availability of containers/codecs follows
  `FFMPEG_ENABLED`, so the UI hides FFmpeg-only options in native builds.
- `ConversionQueueManager` falls back to `FFmpegEngine.analyze` when
  AVFoundation cannot read a source (e.g. VP9-only WebM).

## What is included

- Encoders: H.264, HEVC, VP8, VP9, AV1, MPEG-4, AAC, ALAC, FLAC, MP3, Opus, PCM
- Decoders: H.264, HEVC, VP8, VP9, AV1, MPEG-4, AAC, ALAC, FLAC, MP3, Opus,
  Vorbis, AC-3, E-AC-3, PCM
- Muxers/demuxers: MP4/MOV/M4V, Matroska (MKV), WebM, AVI
- No networking, no filters, no subtitles burning — lean static build.

## Limitations

- `preserveMetadata` copies global metadata (title/creation time) via
  `av_dict_copy`; track-level metadata is not copied.
- HDR tone mapping is not performed: HDR sources keep 10-bit HEVC encoding
  when `preserveHDR` is on; otherwise the pipeline converts to SDR
  (BT.709 conversion for native engines; FFmpeg keeps the color tags).
- FFmpeg conversion is software-only (no VideoToolbox integration into
  FFmpeg). Use the native engines for maximum speed on H.264/HEVC.
- Build time: ~5–10 minutes on an Apple Silicon Mac.
- GitHub Actions: trigger the `workflow_dispatch` build with
  `with_ffmpeg: true` for a CI FFmpeg build.