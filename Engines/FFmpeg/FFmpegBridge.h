#ifndef FFmpegBridge_h
#define FFmpegBridge_h

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FFpegContext FFpegContext;

typedef struct FFpegStreamInfo {
    int index;
    int type;             /* 0 = video, 1 = audio, 2 = subtitle */
    const char *codecName;
    int64_t bitrate;
    int64_t durationMicros;
    double frameRate;
    int width;
    int height;
    int sampleRate;
    int channels;
} FFpegStreamInfo;

typedef struct FFpegConversionOptions {
    int videoStreamIndex;   /* -1 = copy video, >=0 = encode that stream */
    int audioStreamIndex;   /* -1 = copy audio, -2 = remove audio, >=0 = encode */
    int videoCodecId;       /* 0 h264, 1 hevc, 2 vp9, 3 av1, 4 mpeg4, 5 vp8 */
    int audioCodecId;       /* 0 aac, 1 opus, 2 flac, 3 mp3, 4 pcm, 5 alac */
    int useHardwareVideo;   /* prefer the videotoolbox encoder */
    int64_t videoBitrate;   /* bits per second, 0 = auto */
    int64_t audioBitrate;
    int width;              /* 0 = keep source */
    int height;
    double frameRate;       /* 0 = keep source */
    int sampleRate;         /* 0 = keep source */
    int channels;           /* 0 = keep source */
    int copyMetadata;
    int fastStart;
    int copyOnlyFirstAudioStream;
} FFpegConversionOptions;

typedef struct FFpegProgress {
    double fraction;
    int64_t processedMicros;
    int64_t totalMicros;
    const char *stage;
    int errorCode;
    const char *errorMessage;
} FFpegProgress;

typedef void (*FFpegProgressCallback)(void *userData, const FFpegProgress *progress);

const char *ffpeg_version_string(void);
FFpegContext *ffpeg_context_create(void);
void ffpeg_context_destroy(FFpegContext *ctx);
int ffpeg_analyze(FFpegContext *ctx, const char *inputPath, FFpegStreamInfo **outStreams, int *outCount);
void ffpeg_free_streams(FFpegStreamInfo *streams, int count);
int ffpeg_convert(FFpegContext *ctx, const char *inputPath, const char *outputPath, const FFpegConversionOptions *options, FFpegProgressCallback callback, void *userData);
void ffpeg_cancel(FFpegContext *ctx);
const char *ffpeg_last_error(FFpegContext *ctx);

#ifdef __cplusplus
}
#endif

#endif /* FFmpegBridge_h */