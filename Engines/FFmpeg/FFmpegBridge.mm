#ifndef FFMPEG_ENABLED
/* Compile-out: the app is built without FFmpeg. */
typedef void FFpegContext;
typedef struct FFpegStreamInfo FFpegStreamInfo;
typedef struct FFpegConversionOptions FFpegConversionOptions;
typedef struct FFpegProgress FFpegProgress;
typedef void (*FFpegProgressCallback)(void *, const struct FFpegProgress *);
const char *ffpeg_version_string(void) { return "disabled"; }
FFpegContext *ffpeg_context_create(void) { return 0; }
void ffpeg_context_destroy(FFpegContext *ctx) { (void)ctx; }
int ffpeg_analyze(FFpegContext *ctx, const char *p, FFpegStreamInfo **o, int *c) { (void)ctx; (void)p; (void)o; (void)c; return -1; }
void ffpeg_free_streams(FFpegStreamInfo *s, int c) { (void)s; (void)c; }
int ffpeg_convert(FFpegContext *ctx, const char *i, const char *o, const FFpegConversionOptions *op, FFpegProgressCallback cb, void *ud) { (void)ctx; (void)i; (void)o; (void)op; (void)cb; (void)ud; return -1; }
void ffpeg_cancel(FFpegContext *ctx) { (void)ctx; }
const char *ffpeg_last_error(FFpegContext *ctx) { (void)ctx; return "FFmpeg not enabled"; }
#else

#import "FFmpegBridge.h"
#import <Foundation/Foundation.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <libavutil/rational.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

namespace {

std::string ffErrorString(int code) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buf, sizeof(buf));
    return std::string(buf);
}

int64_t rescalePts(int64_t pts, const AVRational &src, const AVRational &dst) {
    if (pts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return av_rescale_q(pts, src, dst);
}

struct EncState {
    int inIndex = -1;
    int outIndex = -1;
    bool copyStream = false;
    bool isVideo = false;
    bool isAudio = false;
    AVCodecContext *dec = nullptr;
    AVCodecContext *enc = nullptr;
    AVStream *outStream = nullptr;
    SwsContext *sws = nullptr;
    SwrContext *swr = nullptr;
    AVFrame *frame = nullptr;
    AVFrame *scaled = nullptr;
    AVPacket *decPkt = nullptr;
    AVRational inTB { 0, 1 };
    AVRational outTB { 0, 1 };
    int64_t lastOutPts = AV_NOPTS_VALUE;
    int64_t inputStartPts = 0;
};

struct FFpegContext {
    std::string lastError;
    std::atomic<int> cancelled { 0 };
    AVFormatContext *input = nullptr;
    AVFormatContext *output = nullptr;
};

int openDecoder(EncState &s, AVStream *inStream, std::string &error) {
    const AVCodec *codec = avcodec_find_decoder(inStream->codecpar->codec_id);
    if (!codec) {
        error = "no decoder for stream " + std::to_string(s.inIndex);
        return AVERROR_DECODER_NOT_FOUND;
    }
    s.dec = avcodec_alloc_context3(codec);
    if (!s.dec) {
        error = "out of memory";
        return AVERROR(ENOMEM);
    }
    int ret = avcodec_parameters_to_context(s.dec, inStream->codecpar);
    if (ret < 0) {
        error = "decoder parameters: " + ffErrorString(ret);
        return ret;
    }
    ret = avcodec_open2(s.dec, codec, nullptr);
    if (ret < 0) {
        error = "decoder open: " + ffErrorString(ret);
        return ret;
    }
    return 0;
}

int openEncoder(EncState &s, const FFpegConversionOptions *options, const AVCodecParameters *inParams,
                std::string &error) {
    const char *name = nullptr;
    if (s.isVideo) {
        switch (options->videoCodecId) {
            /* Native h264/hevc encoders were removed in FFmpeg 5+; use libx264/libx265. */
            case 0: name = "libx264"; break;
            case 1: name = "libx265"; break;
            case 2: name = "libvpx-vp9"; break;
            case 3: name = "libaom-av1"; break;
            case 4: name = "mpeg4"; break;
            case 5: name = "libvpx"; break;
            default: error = "unsupported video encoder"; return AVERROR(EINVAL);
        }
    } else if (s.isAudio) {
        switch (options->audioCodecId) {
            case 0: name = "aac"; break;
            case 1: name = "libopus"; break;
            case 2: name = "flac"; break;
            case 3: name = "libmp3lame"; break;
            case 4: name = "pcm_s16le"; break;
            case 5: name = "alac"; break;
            default: error = "unsupported audio encoder"; return AVERROR(EINVAL);
        }
    }
    const AVCodec *codec = name ? avcodec_find_encoder_by_name(name) : nullptr;
    if (!codec) {
        error = std::string("encoder unavailable: ") + (name ? name : "?");
        return AVERROR_ENCODER_NOT_FOUND;
    }
    s.enc = avcodec_alloc_context3(codec);
    if (!s.enc) {
        error = "out of memory";
        return AVERROR(ENOMEM);
    }
    if (s.isVideo) {
        s.enc->width = options->width > 0 ? options->width : inParams->width;
        s.enc->height = options->height > 0 ? options->height : inParams->height;
        if (options->videoBitrate > 0) s.enc->bit_rate = options->videoBitrate;
        if (options->frameRate > 0) {
            s.enc->time_base = AVRational { 1, (int)std::lround(options->frameRate) };
            s.enc->framerate = AVRational { (int)std::lround(options->frameRate), 1 };
        } else if (inParams->framerate.num > 0) {
            s.enc->framerate = inParams->framerate;
            s.enc->time_base = av_inv_q(inParams->framerate);
        } else {
            s.enc->time_base = AVRational { 1, 30 };
            s.enc->framerate = AVRational { 30, 1 };
        }
        s.enc->gop_size = 60;
        s.enc->pix_fmt = AV_PIX_FMT_YUV420P;
    } else {
        s.enc->sample_rate = options->sampleRate > 0 ? options->sampleRate : (inParams->sample_rate > 0 ? inParams->sample_rate : 48000);
        av_channel_layout_default(&s.enc->ch_layout, options->channels > 0 ? options->channels : 2);
        s.enc->bit_rate = options->audioBitrate > 0 ? options->audioBitrate : 128000;
        s.enc->sample_fmt = codec->sample_fmts ? codec->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;
        s.enc->time_base = AVRational { 1, s.enc->sample_rate };
    }
    int ret = avcodec_open2(s.enc, codec, nullptr);
    if (ret < 0) {
        error = std::string("encoder open (") + name + "): " + ffErrorString(ret);
        return ret;
    }
    return 0;
}

void closeState(EncState &s) {
    if (s.dec) { avcodec_free_context(&s.dec); }
    if (s.enc) { avcodec_free_context(&s.enc); }
    if (s.sws) { sws_freeContext(s.sws); s.sws = nullptr; }
    if (s.swr) { swr_free(&s.swr); }
    if (s.frame) { av_frame_free(&s.frame); }
    if (s.scaled) { av_frame_free(&s.scaled); }
    if (s.decPkt) { av_packet_free(&s.decPkt); }
}

} // namespace

#pragma mark - Public API

const char *ffpeg_version_string(void) {
    return av_version_info();
}

FFpegContext *ffpeg_context_create(void) {
    return new FFpegContext();
}

void ffpeg_context_destroy(FFpegContext *ctx) {
    if (!ctx) return;
    if (ctx->input) avformat_close_input(&ctx->input);
    if (ctx->output) avformat_free_context(ctx->output);
    delete ctx;
}

int ffpeg_analyze(FFpegContext *ctx, const char *inputPath, FFpegStreamInfo **outStreams, int *outCount) {
    ctx->lastError.clear();
    *outStreams = nullptr;
    *outCount = 0;
    int ret = avformat_open_input(&ctx->input, inputPath, nullptr, nullptr);
    if (ret < 0) {
        ctx->lastError = "open input: " + ffErrorString(ret);
        return ret;
    }
    ret = avformat_find_stream_info(ctx->input, nullptr);
    if (ret < 0) {
        ctx->lastError = "stream info: " + ffErrorString(ret);
        return ret;
    }
    int count = 0;
    for (unsigned i = 0; i < ctx->input->nb_streams; i++) {
        AVStream *st = ctx->input->streams[i];
        if (!st || !st->codecpar) continue;
        enum AVMediaType type = st->codecpar->codec_type;
        if (type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO || type == AVMEDIA_TYPE_SUBTITLE) count++;
    }
    FFpegStreamInfo *info = (FFpegStreamInfo *)av_calloc(count > 0 ? count : 1, sizeof(FFpegStreamInfo));
    if (!info) return AVERROR(ENOMEM);
    int n = 0;
    for (unsigned i = 0; i < ctx->input->nb_streams && n < count; i++) {
        AVStream *st = ctx->input->streams[i];
        if (!st || !st->codecpar) continue;
        enum AVMediaType type = st->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO && type != AVMEDIA_TYPE_SUBTITLE) continue;
        FFpegStreamInfo &it = info[n];
        it.index = (int)i;
        it.type = (type == AVMEDIA_TYPE_VIDEO) ? 0 : (type == AVMEDIA_TYPE_AUDIO ? 1 : 2);
        const char *codecName = avcodec_get_name(st->codecpar->codec_id);
        it.codecName = av_strdup(codecName ? codecName : "unknown");
        it.bitrate = st->codecpar->bit_rate;
        if (st->duration != AV_NOPTS_VALUE) {
            it.durationMicros = av_rescale_q(st->duration, st->time_base, AV_TIME_BASE_Q);
        } else if (ctx->input->duration != AV_NOPTS_VALUE) {
            it.durationMicros = ctx->input->duration;
        }
        if (type == AVMEDIA_TYPE_VIDEO) {
            it.width = st->codecpar->width;
            it.height = st->codecpar->height;
            if (st->r_frame_rate.num > 0 && st->r_frame_rate.den > 0) {
                it.frameRate = av_q2d(st->r_frame_rate);
            }
        } else if (type == AVMEDIA_TYPE_AUDIO) {
            it.sampleRate = st->codecpar->sample_rate;
            it.channels = st->codecpar->ch_layout.nb_channels;
        }
        n++;
    }
    *outStreams = info;
    *outCount = n;
    return 0;
}

void ffpeg_free_streams(FFpegStreamInfo *streams, int count) {
    if (!streams) return;
    for (int i = 0; i < count; i++) {
        if (streams[i].codecName) av_free((void *)streams[i].codecName);
    }
    av_free(streams);
}

void ffpeg_cancel(FFpegContext *ctx) {
    ctx->cancelled.store(1, std::memory_order_relaxed);
}

const char *ffpeg_last_error(FFpegContext *ctx) {
    return ctx->lastError.c_str();
}

int ffpeg_convert(FFpegContext *ctx, const char *inputPath, const char *outputPath,
                  const FFpegConversionOptions *options, FFpegProgressCallback callback, void *userData) {
    ctx->lastError.clear();
    ctx->cancelled.store(0, std::memory_order_relaxed);
    std::vector<EncState> states;

    int ret = avformat_open_input(&ctx->input, inputPath, nullptr, nullptr);
    if (ret < 0) { ctx->lastError = "open input: " + ffErrorString(ret); return ret; }
    ret = avformat_find_stream_info(ctx->input, nullptr);
    if (ret < 0) { ctx->lastError = "stream info: " + ffErrorString(ret); return ret; }

    const AVOutputFormat *fmt = av_guess_format(nullptr, outputPath, nullptr);
    if (!fmt) { ctx->lastError = "unsupported output container"; return AVERROR(EINVAL); }
    ret = avformat_alloc_output_context2(&ctx->output, fmt, nullptr, outputPath);
    if (ret < 0 || !ctx->output) { ctx->lastError = "output context: " + ffErrorString(ret); return ret; }

    int videoStreamIndex = options->videoStreamIndex;
    int audioStreamIndex = options->audioStreamIndex;
    bool audioCopyConsumed = false;

    for (unsigned i = 0; i < ctx->input->nb_streams; i++) {
        AVStream *inStream = ctx->input->streams[i];
        if (!inStream || !inStream->codecpar) continue;
        enum AVMediaType type = inStream->codecpar->codec_type;

        bool copyThis = false;
        bool encodeThis = false;
        if (type == AVMEDIA_TYPE_VIDEO) {
            copyThis = (videoStreamIndex == -1);
            encodeThis = (videoStreamIndex == (int)i);
        } else if (type == AVMEDIA_TYPE_AUDIO) {
            copyThis = (audioStreamIndex == -1);
            encodeThis = (audioStreamIndex == (int)i);
            if (copyThis && options->copyOnlyFirstAudioStream && audioCopyConsumed) copyThis = false;
            if (copyThis) audioCopyConsumed = true;
        }
        if (!copyThis && !encodeThis) continue;

        EncState s;
        s.inIndex = (int)i;
        s.isVideo = (type == AVMEDIA_TYPE_VIDEO);
        s.isAudio = (type == AVMEDIA_TYPE_AUDIO);
        s.copyStream = copyThis;
        s.inTB = inStream->time_base;
        s.inputStartPts = (inStream->start_time != AV_NOPTS_VALUE) ? inStream->start_time : 0;

        if (copyThis) {
            AVStream *out = avformat_new_stream(ctx->output, nullptr);
            if (!out) { ctx->lastError = "out of memory"; ret = AVERROR(ENOMEM); goto fail; }
            out->id = (int)i;
            out->time_base = inStream->time_base;
            ret = avcodec_parameters_copy(out->codecpar, inStream->codecpar);
            if (ret < 0) { ctx->lastError = ffErrorString(ret); goto fail; }
            out->codecpar->codec_tag = 0;
            s.outStream = out;
            s.outTB = out->time_base;
            states.push_back(s);
            continue;
        }

        ret = openDecoder(s, inStream, ctx->lastError);
        if (ret < 0) goto fail;
        s.decPkt = av_packet_alloc();
        if (!s.decPkt) { ctx->lastError = "out of memory"; ret = AVERROR(ENOMEM); goto fail; }

        ret = openEncoder(s, options, inStream->codecpar, ctx->lastError);
        if (ret < 0) goto fail;

        AVStream *out = avformat_new_stream(ctx->output, nullptr);
        if (!out) { ctx->lastError = "out of memory"; ret = AVERROR(ENOMEM); goto fail; }
        out->id = (int)i;
        out->time_base = s.enc->time_base;
        ret = avcodec_parameters_from_context(out->codecpar, s.enc);
        if (ret < 0) { ctx->lastError = ffErrorString(ret); goto fail; }
        out->codecpar->codec_tag = 0;
        s.outStream = out;
        s.outTB = out->time_base;

        s.frame = av_frame_alloc();
        s.scaled = av_frame_alloc();
        if (!s.frame || !s.scaled) { ctx->lastError = "out of memory"; ret = AVERROR(ENOMEM); goto fail; }
        states.push_back(s);
    }

    if (states.empty()) { ctx->lastError = "no streams to write"; ret = AVERROR(EINVAL); goto fail; }

    if (options->copyMetadata) {
        av_dict_copy(&ctx->output->metadata, ctx->input->metadata, 0);
    }

    ret = avio_open(&ctx->output->pb, outputPath, AVIO_FLAG_WRITE);
    if (ret < 0) { ctx->lastError = "open output: " + ffErrorString(ret); goto fail; }

    {
        AVDictionary *opts = nullptr;
        if (options->fastStart) av_dict_set(&opts, "movflags", "faststart", 0);
        ret = avformat_write_header(ctx->output, &opts);
        av_dict_free(&opts);
        if (ret < 0) { ctx->lastError = "write header: " + ffErrorString(ret); goto fail; }
    }

    int64_t totalMicros = ctx->input->duration;
    if (totalMicros == AV_NOPTS_VALUE || totalMicros <= 0) totalMicros = 0;
    int64_t lastCallback = 0;
    int64_t maxPtsMicros = 0;

    {
        AVPacket *pkt = av_packet_alloc();
        if (!pkt) { ctx->lastError = "out of memory"; ret = AVERROR(ENOMEM); goto fail; }

        while (1) {
            if (ctx->cancelled.load(std::memory_order_relaxed)) {
                av_packet_free(&pkt);
                ctx->lastError = "cancelled";
                ret = AVERROR_EXIT;
                goto fail;
            }
            ret = av_read_frame(ctx->input, pkt);
            if (ret < 0) break;

            EncState *target = nullptr;
            for (auto &s : states) {
                if (s.inIndex == pkt->stream_index) { target = &s; break; }
            }
            if (!target) { av_packet_unref(pkt); continue; }

            if (target->copyStream) {
                pkt->pts = rescalePts(pkt->pts, target->inTB, target->outTB);
                pkt->dts = rescalePts(pkt->dts, target->inTB, target->outTB);
                pkt->duration = (pkt->duration != AV_NOPTS_VALUE) ? av_rescale_q(pkt->duration, target->inTB, target->outTB) : 0;
                pkt->stream_index = target->outStream->index;
                if (pkt->pts != AV_NOPTS_VALUE && pkt->pts < 0) pkt->pts = 0;
                if (pkt->dts != AV_NOPTS_VALUE && pkt->dts < 0) pkt->dts = 0;
                ret = av_interleaved_write_frame(ctx->output, pkt);
                if (ret < 0) { av_packet_unref(pkt); ctx->lastError = "write: " + ffErrorString(ret); av_packet_free(&pkt); goto fail; }
                if (pkt->pts != AV_NOPTS_VALUE) {
                    int64_t us = av_rescale_q(pkt->pts, target->outTB, AV_TIME_BASE_Q);
                    if (us > maxPtsMicros) maxPtsMicros = us;
                }
                av_packet_unref(pkt);
                continue;
            }

            ret = avcodec_send_packet(target->dec, pkt);
            av_packet_unref(pkt);
            if (ret < 0) {
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) continue;
                ctx->lastError = "decode: " + ffErrorString(ret);
                av_packet_free(&pkt);
                goto fail;
            }

            while (ret >= 0) {
                ret = avcodec_receive_frame(target->dec, target->frame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
                if (ret < 0) {
                    ctx->lastError = "decode frame: " + ffErrorString(ret);
                    av_packet_free(&pkt);
                    goto fail;
                }
                target->frame->pts = rescalePts(target->frame->pts, target->inTB, target->outTB);
                if (target->frame->pts != AV_NOPTS_VALUE && target->lastOutPts != AV_NOPTS_VALUE) {
                    target->frame->pts = FFMAX(target->frame->pts, target->lastOutPts + 1);
                }

                if (target->isVideo) {
                    AVFrame *toEncode = target->frame;
                    if (target->sws == nullptr &&
                        (target->frame->format != AV_PIX_FMT_YUV420P ||
                         target->frame->width != target->enc->width ||
                         target->frame->height != target->enc->height)) {
                        target->sws = sws_getContext(target->frame->width, target->frame->height,
                                                     (AVPixelFormat)target->frame->format,
                                                     target->enc->width, target->enc->height, AV_PIX_FMT_YUV420P,
                                                     SWS_BILINEAR, nullptr, nullptr, nullptr);
                        if (!target->sws) { ctx->lastError = "scaler init failed"; av_packet_free(&pkt); goto fail; }
                    }
                    if (target->sws) {
                        av_frame_unref(target->scaled);
                        target->scaled->format = AV_PIX_FMT_YUV420P;
                        target->scaled->width = target->enc->width;
                        target->scaled->height = target->enc->height;
                        av_frame_get_buffer(target->scaled, 32);
                        sws_scale(target->sws, (const uint8_t *const *)target->frame->data, target->frame->linesize,
                                  0, target->frame->height, target->scaled->data, target->scaled->linesize);
                        target->scaled->pts = target->frame->pts;
                        toEncode = target->scaled;
                    }
                    ret = avcodec_send_frame(target->enc, toEncode);
                } else {
                    if (target->swr == nullptr) {
                        target->swr = swr_alloc();
                        av_opt_set_int(target->swr, "in_sample_fmt", target->frame->format, 0);
                        av_opt_set_int(target->swr, "out_sample_fmt", target->enc->sample_fmt, 0);
                        av_opt_set_int(target->swr, "in_sample_rate", target->frame->sample_rate, 0);
                        av_opt_set_int(target->swr, "out_sample_rate", target->enc->sample_rate, 0);
                        av_opt_set_chlayout(target->swr, "in_chlayout", &target->frame->ch_layout, 0);
                        av_opt_set_chlayout(target->swr, "out_chlayout", &target->enc->ch_layout, 0);
                        if (swr_init(target->swr) < 0) { ctx->lastError = "resampler init failed"; av_packet_free(&pkt); goto fail; }
                    }
                    AVFrame *af = av_frame_alloc();
                    if (!af) { ctx->lastError = "out of memory"; av_packet_free(&pkt); goto fail; }
                    af->format = target->enc->sample_fmt;
                    af->sample_rate = target->enc->sample_rate;
                    av_channel_layout_copy(&af->ch_layout, &target->enc->ch_layout);
                    af->nb_samples = target->enc->frame_size > 0 ? target->enc->frame_size
                                                                  : av_rescale_rnd(swr_get_delay(target->swr, target->frame->sample_rate) + target->frame->nb_samples,
                                                                                    target->enc->sample_rate, target->frame->sample_rate, AV_ROUND_UP);
                    if (av_frame_get_buffer(af, 0) < 0) {
                        av_frame_free(&af);
                        ctx->lastError = "audio buffer alloc failed";
                        av_packet_free(&pkt);
                        goto fail;
                    }
                    int converted = swr_convert(target->swr, af->data, af->nb_samples,
                                                (const uint8_t **)target->frame->extended_data, target->frame->nb_samples);
                    if (converted < 0) {
                        av_frame_free(&af);
                        ctx->lastError = "resample failed";
                        av_packet_free(&pkt);
                        goto fail;
                    }
                    af->nb_samples = converted;
                    af->pts = target->frame->pts;
                    if (af->pts != AV_NOPTS_VALUE && target->lastOutPts != AV_NOPTS_VALUE) {
                        af->pts = FFMAX(af->pts, target->lastOutPts + 1);
                    }
                    ret = avcodec_send_frame(target->enc, af);
                    av_frame_free(&af);
                }

                if (ret < 0 && ret != AVERROR(EAGAIN)) {
                    ctx->lastError = "encode: " + ffErrorString(ret);
                    av_packet_free(&pkt);
                    goto fail;
                }

                while (1) {
                    int eRet = avcodec_receive_packet(target->enc, target->decPkt);
                    if (eRet == AVERROR(EAGAIN) || eRet == AVERROR_EOF) break;
                    if (eRet < 0) { ctx->lastError = "encode packet: " + ffErrorString(eRet); av_packet_free(&pkt); goto fail; }
                    av_packet_rescale_ts(target->decPkt, target->enc->time_base, target->outTB);
                    target->decPkt->stream_index = target->outStream->index;
                    if (target->decPkt->pts != AV_NOPTS_VALUE) {
                        target->lastOutPts = target->decPkt->pts;
                        int64_t us = av_rescale_q(target->decPkt->pts, target->outTB, AV_TIME_BASE_Q);
                        if (us > maxPtsMicros) maxPtsMicros = us;
                    }
                    int wRet = av_interleaved_write_frame(ctx->output, target->decPkt);
                    if (wRet < 0) { ctx->lastError = "write: " + ffErrorString(wRet); av_packet_free(&pkt); goto fail; }
                }
                av_frame_unref(target->frame);
            }
            av_frame_unref(target->frame);

            int64_t now = av_gettime();
            if (callback && (now - lastCallback) > 250000) {
                lastCallback = now;
                FFpegProgress p;
                p.fraction = totalMicros > 0 ? (double)FFMIN(maxPtsMicros, totalMicros) / (double)totalMicros : 0.0;
                p.processedMicros = maxPtsMicros;
                p.totalMicros = totalMicros;
                p.stage = "encoding";
                p.errorCode = 0;
                p.errorMessage = nullptr;
                callback(userData, &p);
            }
        }

        /* flush decoders + encoders */
        for (auto &s : states) {
            if (s.copyStream) continue;
            avcodec_send_packet(s.dec, nullptr);
            while (1) {
                int r = avcodec_receive_frame(s.dec, s.frame);
                if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) break;
                if (r < 0) break;
                s.frame->pts = rescalePts(s.frame->pts, s.inTB, s.outTB);
                avcodec_send_frame(s.enc, s.frame);
                while (1) {
                    int eRet = avcodec_receive_packet(s.enc, s.decPkt);
                    if (eRet == AVERROR(EAGAIN) || eRet == AVERROR_EOF) break;
                    if (eRet < 0) break;
                    av_packet_rescale_ts(s.decPkt, s.enc->time_base, s.outTB);
                    s.decPkt->stream_index = s.outStream->index;
                    av_interleaved_write_frame(ctx->output, s.decPkt);
                }
                av_frame_unref(s.frame);
            }
            avcodec_send_frame(s.enc, nullptr);
            while (1) {
                int eRet = avcodec_receive_packet(s.enc, s.decPkt);
                if (eRet == AVERROR(EAGAIN) || eRet == AVERROR_EOF) break;
                if (eRet < 0) break;
                av_packet_rescale_ts(s.decPkt, s.enc->time_base, s.outTB);
                s.decPkt->stream_index = s.outStream->index;
                av_interleaved_write_frame(ctx->output, s.decPkt);
            }
        }
        av_packet_free(&pkt);
    }

    ret = av_write_trailer(ctx->output);
    if (ret < 0) { ctx->lastError = "write trailer: " + ffErrorString(ret); goto fail; }

    if (callback) {
        FFpegProgress p;
        p.fraction = 1.0;
        p.processedMicros = totalMicros;
        p.totalMicros = totalMicros;
        p.stage = "finalizing";
        p.errorCode = 0;
        p.errorMessage = nullptr;
        callback(userData, &p);
    }

fail:
    for (auto &s : states) closeState(s);
    avformat_close_input(&ctx->input);
    if (ctx->output) {
        avformat_free_context(ctx->output);
        ctx->output = nullptr;
    }
    if (ret < 0) return ret;
    return 0;
}

#endif /* FFMPEG_ENABLED */