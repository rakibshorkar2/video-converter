#!/bin/bash
#
# Builds FFmpeg (static, device + simulator slices) for the Video Converter app
# and writes Scripts/ffmpeg_flags.xcconfig which the project reads via
# BaseConfiguration when FFMPEG_ENABLED builds are requested.
#
# Usage:
#   ./Scripts/build_ffmpeg_ios.sh          # device arm64 + simulator arm64
#   ./Scripts/build_ffmpeg_ios.sh --clean  # rebuild from scratch
#
# Requirements: macOS with Xcode, autotools toolchain (brew install automake
# autoconf libtool pkg-config yasm) plus the external codec libraries:
#   brew install x264 x265 lame opus libvpx aom
#
# Outputs:
#   Vendor/ffmpeg-ios/universal/...  static libs (one per FFmpeg lib)
#   Vendor/ffmpeg-ios/include/...    headers
#   Scripts/ffmpeg_flags.xcconfig    consumed by XcodeGen project.yml
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG_VERSION="6.1.1"
SOURCE_DIR="$ROOT_DIR/Vendor/ffmpeg-src"
OUTPUT_DIR="$ROOT_DIR/Vendor/ffmpeg-ios"
CONFIG_PATH="$ROOT_DIR/Scripts/ffmpeg_flags.xcconfig"
TARBALL="$ROOT_DIR/Vendor/ffmpeg-$FFMPEG_VERSION.tar.xz"
TARBALL_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

CONFIG_FLAGS_COMMON=(
  --disable-programs
  --disable-doc
  --disable-avdevice
  --disable-avformat
  --disable-avcodec
  --disable-postproc
  --disable-swresample
  --disable-swscale
  --disable-avfilter
  --disable-debug
  --disable-network
  --disable-autodetect
  --enable-small
  --enable-gpl
  --enable-avcodec
  --enable-avformat
  --enable-swresample
  --enable-swscale
  --enable-libx264
  --enable-encoder=libx264
  --enable-libx265
  --enable-encoder=libx265
  --enable-libvpx
  --enable-encoder=vp8
  --enable-encoder=vp9
  --enable-libaom
  --enable-encoder=libaom-av1
  --enable-encoder=mpeg4
  --enable-encoder=aac
  --enable-encoder=alac
  --enable-encoder=flac
  --enable-libmp3lame
  --enable-encoder=libmp3lame
  --enable-libopus
  --enable-encoder=libopus
  --enable-encoder=pcm_s16le
  --enable-decoder=h264
  --enable-decoder=hevc
  --enable-decoder=vp8
  --enable-decoder=vp9
  --enable-decoder=av1
  --enable-decoder=mpeg4
  --enable-decoder=aac
  --enable-decoder=alac
  --enable-decoder=flac
  --enable-decoder=mp3
  --enable-decoder=opus
  --enable-decoder=vorbis
  --enable-decoder=ac3
  --enable-decoder=eac3
  --enable-decoder=pcm_s16le
  --enable-decoder=pcm_s24le
  --enable-decoder=pcm_f32le
  --enable-decoder=pcm_f64le
  --enable-muxer=mp4
  --enable-muxer=mov
  --enable-muxer=m4v
  --enable-muxer=matroska
  --enable-muxer=webm
  --enable-muxer=avi
  --enable-demuxer=mov
  --enable-demuxer=matroska
  --enable-demuxer=webm
  --enable-demuxer=avi
  --enable-parser=h264
  --enable-parser=hevc
  --enable-parser=vp8
  --enable-parser=vp9
  --enable-parser=av1
  --enable-parser=aac
  --enable-parser=flac
  --enable-parser=opus
  --enable-parser=ac3
  --enable-protocol=file
)

if [ "${1:-}" == "--clean" ]; then
  rm -rf "$SOURCE_DIR" "$OUTPUT_DIR" "$TARBALL"
  cat > "$CONFIG_PATH" <<'EOF'
// Native (non-FFmpeg) build — this file intentionally contains no flags.
// Running Scripts/build_ffmpeg_ios.sh overwrites it with the FFmpeg-enabled
// settings. To revert to a native build, restore this placeholder (e.g.
// `git checkout -- Scripts/ffmpeg_flags.xcconfig`) and re-run `xcodegen generate`.
EOF
  echo "==> Cleaned. Scripts/ffmpeg_flags.xcconfig restored to native placeholder."
  exit 0
fi

if [ ! -f "$TARBALL" ]; then
  echo "==> Downloading FFmpeg $FFMPEG_VERSION"
  curl -L "$TARBALL_URL" -o "$TARBALL"
fi

if [ ! -d "$SOURCE_DIR" ]; then
  echo "==> Extracting FFmpeg"
  mkdir -p "$(dirname "$SOURCE_DIR")"
  tar -xf "$TARBALL" -C "$(dirname "$SOURCE_DIR")"
  mv "$ROOT_DIR/Vendor/ffmpeg-$FFMPEG_VERSION" "$SOURCE_DIR"
fi

SDK_DEVICE="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_SIM="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEPLOYMENT_TARGET="17.0"

build_arch() {
  local arch="$1"
  local sdk="$2"
  local label="$3"
  local build_dir="$SOURCE_DIR/build-$arch-$label"
  echo "==> Building $arch ($label)"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  pushd "$SOURCE_DIR" >/dev/null
  make distclean >/dev/null 2>&1 || true
  ./configure \
    --prefix="$build_dir/install" \
    --arch="$arch" \
    --target-os=darwin \
    --sysroot="$sdk" \
    --extra-cflags="-arch $arch -miphoneos-version-min=$DEPLOYMENT_TARGET" \
    --extra-ldflags="-arch $arch -miphoneos-version-min=$DEPLOYMENT_TARGET" \
    "${CONFIG_FLAGS_COMMON[@]}"
  make -j"$(sysctl -n hw.ncpu)"
  make install
  popd >/dev/null
}

ARCHS=()
SDKS=()
LABELS=()
if [ -n "${IOS_PLATFORM:-}" ] && [ "$IOS_PLATFORM" == "SIMULATOR" ]; then
  ARCHS=("arm64")
  SDKS=("$SDK_SIM")
  LABELS=("iphonesimulator")
else
  ARCHS=("arm64" "arm64")
  SDKS=("$SDK_DEVICE" "$SDK_SIM")
  LABELS=("iphoneos" "iphonesimulator")
fi

for i in "${!ARCHS[@]}"; do
  build_arch "${ARCHS[$i]}" "${SDKS[$i]}" "${LABELS[$i]}"
done

echo "==> Creating universal libraries"
LIB_NAMES=(
  libavcodec.a
  libavformat.a
  libswresample.a
  libswscale.a
  libavutil.a
)
rm -rf "$OUTPUT_DIR/universal" "$OUTPUT_DIR/include"
mkdir -p "$OUTPUT_DIR/universal"
for lib in "${LIB_NAMES[@]}"; do
  LIBS=()
  for i in "${!ARCHS[@]}"; do
    LIBS+=("$SOURCE_DIR/build-${ARCHS[$i]}-${LABELS[$i]}/install/lib/$lib")
  done
  xcrun lipo -create "${LIBS[@]}" -output "$OUTPUT_DIR/universal/$lib"
done
cp -R "$SOURCE_DIR/build-arm64-iphoneos/install/include" "$OUTPUT_DIR/include"

echo "==> Writing $CONFIG_PATH"
cat > "$CONFIG_PATH" <<EOF
FFMPEG_ENABLED = 1
GCC_PREPROCESSOR_DEFINITIONS = \$(inherited) FFMPEG_ENABLED=1
SWIFT_ACTIVE_COMPILATION_CONDITIONS = \$(inherited) FFMPEG_ENABLED
HEADER_SEARCH_PATHS = \$(inherited) \$(SRCROOT)/Vendor/ffmpeg-ios/include
LIBRARY_SEARCH_PATHS[sdk=iphoneos*] = \$(inherited) \$(SRCROOT)/Vendor/ffmpeg-ios/universal
LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*] = \$(inherited) \$(SRCROOT)/Vendor/ffmpeg-ios/universal
OTHER_LDFLAGS = \$(inherited) -lavformat -lavcodec -lswresample -lswscale -lavutil -lz -lbz2 -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework AudioToolbox -framework Security
EOF

echo "==> Done. FFmpeg libraries in Vendor/ffmpeg-ios/universal"
echo "    Rebuild the Xcode project with: xcodegen generate"
echo "    (ffmpeg_flags.xcconfig is picked up automatically when present)"