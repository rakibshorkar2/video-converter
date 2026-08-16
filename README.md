# Video Converter (iOS)

A native iOS video converter built with SwiftUI, AVFoundation and VideoToolbox.
No video is ever uploaded — everything is processed locally on the device.

- Native hardware-accelerated conversion (H.264 / HEVC) via AVFoundation and VideoToolbox
- Lossless Stream Copy mode (no re-encoding, quality preserved)
- Optional FFmpeg fallback for MKV / WebM / VP9 / AV1 (compile-time flag, see [FFMPEG.md](Docs/FFMPEG.md))
- Import from Photos or Files (including drag-and-drop in-app), save to Photos, Documents or a custom iCloud/Files folder
- Resume queue, thermal protection, low-storage protection, conversion history, full diagnostics log
- iOS 17+, built with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (no `.xcodeproj` in the repo)

## Building

Prerequisites: macOS with Xcode, XcodeGen.

```sh
brew install xcodegen
xcodegen generate          # creates VideoConverter.xcodeproj
open VideoConverter.xcodeproj
```

### Building with FFmpeg (optional)

```sh
./Scripts/build_ffmpeg_ios.sh   # downloads + builds FFmpeg, writes ffmpeg_flags.xcconfig
xcodegen generate
```

The FFmpeg-enabled build adds MKV, WebM and AVI output and VP8/VP9/AV1/MPEG-4 encoding.
Without the script, the app builds native-only (MP4/MOV/M4V).

### Building unsigned (no Apple Developer account)

```sh
xcodebuild -project VideoConverter.xcodeproj -scheme VideoConverter \
  -sdk iphoneos -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

To install the unsigned `.app` on your own device, follow the standard
`xcrun devicectl` (or Xcode's Devices window) procedure, or the
[futsal](https://github.com/jasudev/futsal)/`ldid` signing approach.

A GitHub Actions workflow ([`.github/workflows/build.yml`](.github/workflows/build.yml))
builds and uploads the unsigned app bundle on every push; a `workflow_dispatch`
run with `with_ffmpeg: true` produces the FFmpeg build.

## Documentation

- [ARCHITECTURE.md](Docs/ARCHITECTURE.md) — code layout, engine pipeline, data flow
- [PERFORMANCE.md](Docs/PERFORMANCE.md) — speed/fidelity trade-offs and how engines are chosen
- [FFMPEG.md](Docs/FFMPEG.md) — the FFmpeg bridge, build script, and limitations
- [TESTING.md](Docs/TESTING.md) — how to test on-device

## Project layout

```
App/            app entry + dependency container
UI/             SwiftUI views (home, job card, settings, history, preview)
Core/
  Models/       job, configuration, metadata, settings, history
  Conversion/   queue manager, engine router, validator, diagnostics, stores
Media/          AVFoundation analysis, thumbnails, format capabilities, size estimation
Engines/        StreamCopy, AVFoundation, VideoToolbox, FFmpeg (bridged C++)
Storage/        files, bookmarks, temp management, Photos export
System/         device capabilities, thermal + storage monitoring
Scripts/        FFmpeg build script + generated xcconfig
Support/        Info.plist, bridging header
```
