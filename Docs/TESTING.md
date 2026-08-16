# Testing

There is no unit-test target in the generated project yet; all verification
is manual on device/simulator. Build via XcodeGen (`xcodegen generate`), or
grab the unsigned artifact from GitHub Actions.

## Smoke test checklist

1. **Import**
   - Photos: pick 1 and many videos → queue populated, settings sheet opens.
   - Files: import from Files app and via drag-and-drop onto the list.
   - Share sheet: share a video into the app (uses `onOpenURL`/Inbox).
2. **Analysis**
   - Info shows duration/resolution/codec; thumbnail appears.
   - HEVC, H.264, and an unusual source (e.g. MKV/VP9 if FFmpeg build) all analyze.
3. **Conversion paths**
   - Stream Copy to a compatible container (e.g. MOV) — near instant.
   - H.264 → H.264 re-encode at Balanced.
   - HEVC source → HEVC output; verify hardware acceleration on/off.
   - Downscale 4K → 1080p; verify output resolution in Photos/Files.
   - Audio-only change (AAC 128k → 256k) with video stream copy.
4. **Quality & sanity**
   - Output plays in the built-in preview and in the Photos app.
   - Output duration matches source; size matches `SizeEstimator` ballpark.
   - Metadata preserved (title/creation date in the destination app).
5. **Lifecycle & resilience**
   - Background the app mid-conversion → job becomes "Interrupted", Retry works.
   - Kill the app mid-conversion → relaunch shows interrupted job, Retry works.
   - Toggle airplane mode/keep screen locked — nothing needed; verify no crash.
6. **Errors**
   - Corrupt a file (rename a text file to .mov) → clear error, no crash.
   - Force low storage → pre-check error with required/available sizes.
   - Deny Photos permission → clear message suggesting Files destination.
7. **Thermal**
   - Convert a long 4K video; watch for waiting state when the device gets hot.
8. **Settings**
   - Change defaults → new imports pick them up.
   - Custom folder bookmark survives app restart (iCloud Drive folder).
   - Diagnostics log: enable, run a job, copy text, paste elsewhere.
9. **History**
   - Completed jobs appear with input → output, sizes, Share link.
   - Clear History works; disabled when empty.
10. **Dark mode + Dynamic Type** — no clipped text; colors legible.

## FFmpeg build specifics

Run the same checklist plus:

- MKV and WebM output from H.264 sources (transcode and stream copy).
- VP9 source → MP4 (AAC) and → WebM (Opus).
- AVI output from an MPEG-4 source.
- `ffmpeg_flags.xcconfig` build vs native build difference (UI must hide
  MKV/WebM/AVI and VP9/AV1 in the native build).

## Reporting bugs

Enable Settings → Diagnostics → Record Diagnostics, reproduce, then
Settings → Diagnostics → Copy Log and include it with the report, plus the
source file details (codec/resolution) from the job's settings screen.