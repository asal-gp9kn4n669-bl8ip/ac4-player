#include "AC4Bridge.h"

#include <ctype.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(AC4_ENABLE_NATIVE_LIBREMPEG) && AC4_ENABLE_NATIVE_LIBREMPEG

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/channel_layout.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/mathematics.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/samplefmt.h"
#include "libswresample/swresample.h"

static pthread_once_t g_av_log_once = PTHREAD_ONCE_INIT;

static void init_av_log_quiet(void) {
    av_log_set_level(AV_LOG_ERROR);
}

static void ensure_av_initialized(void) {
    pthread_once(&g_av_log_once, init_av_log_quiet);
}

static void copy_cstr(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return;
    if (!src) {
        dst[0] = '\0';
        return;
    }
    size_t len = strlen(src);
    if (len >= cap) len = cap - 1;
    memcpy(dst, src, len);
    dst[len] = '\0';
}

static void parse_slash_pair(const char *val, int *out_first, int *out_second) {
    if (!val) return;
    char *end1 = NULL;
    long a = strtol(val, &end1, 10);
    if (end1 != val && a > 0 && out_first) {
        *out_first = (int)a;
    }
    if (end1 && *end1 == '/') {
        char *end2 = NULL;
        long b = strtol(end1 + 1, &end2, 10);
        if (end2 != (end1 + 1) && b > 0 && out_second) {
            *out_second = (int)b;
        }
    }
}

static const char *dict_get_any(const AVDictionary *dict, const char *const *keys) {
    if (!dict || !keys) return NULL;
    for (size_t i = 0; keys[i] != NULL; i++) {
        AVDictionaryEntry *e = av_dict_get(dict, keys[i], NULL, AV_DICT_IGNORE_SUFFIX);
        if (e && e->value && e->value[0] != '\0') {
            if (strcasecmp(e->key, keys[i]) == 0) {
                return e->value;
            }
        }
    }
    return NULL;
}

static inline float sanitize_sample(float x) {
    if (!isfinite(x)) return 0.0f;
    if (x > 4.0f) return 4.0f;
    if (x < -4.0f) return -4.0f;
    return x;
}

/* Raw AC-4 syncframe helpers (handles standalone .ac4 files even when CONFIG_AC4_DEMUXER == 0) */
static const int k_ac4_frame_len_48k[16] = {
    2048, 2048, 2048, 1920, 1920, 1024, 1024, 1024,
    960, 960, 512, 512, 480, 2048, 2048, 2048
};
static const int k_ac4_num[16] = {
    25025, 25, 15, 25025, 25, 25025, 25, 15,
    25025, 25, 15, 25025, 25, 1, 1, 1
};
static const int k_ac4_den[16] = {
    24000, 24, 16, 24000, 24, 24000, 24, 16,
    24000, 24, 16, 24000, 24, 1, 1, 1
};

typedef struct RawAC4HeaderInfo {
    int sample_rate;
    int frame_samples;
    int is_iframe;
} RawAC4HeaderInfo;

static int parse_raw_ac4_toc_brief(const uint8_t *buf, int len, RawAC4HeaderInfo *out) {
    if (!buf || len < 4 || !out) return 0;
    size_t bit_pos = 0;
    size_t total_bits = (size_t)len * 8;

    #define READ_BITS(nbits, dst) do { \
        int _v = 0; \
        if (bit_pos + (size_t)(nbits) > total_bits) return 0; \
        for (int _b = 0; _b < (nbits); _b++) { \
            size_t _idx = bit_pos++; \
            _v = (_v << 1) | ((buf[_idx >> 3] >> (7 - (_idx & 7))) & 1); \
        } \
        (dst) = _v; \
    } while (0)

    int ver = 0;
    READ_BITS(2, ver);
    if (ver == 3) {
        int more = 1;
        while (more) {
            int dummy = 0;
            READ_BITS(2, dummy);
            (void)dummy;
            READ_BITS(1, more);
        }
    }
    int seq = 0;
    READ_BITS(10, seq);
    (void)seq;

    int wait_frames = 0;
    READ_BITS(1, wait_frames);
    if (wait_frames) {
        int nwf = 0;
        READ_BITS(3, nwf);
        if (nwf > 0) {
            int skip2 = 0;
            READ_BITS(2, skip2);
            (void)skip2;
        }
    }

    int fs_idx = 0, fri = 0, iframe = 0;
    READ_BITS(1, fs_idx);
    READ_BITS(4, fri);
    READ_BITS(1, iframe);
    #undef READ_BITS

    int base_sr = fs_idx ? 48000 : 44100;
    long long sr = ((long long)base_sr * k_ac4_den[fri & 15]) / k_ac4_num[fri & 15];
    out->sample_rate = (sr >= 8000 && sr <= 384000) ? (int)sr : 48000;
    out->frame_samples = k_ac4_frame_len_48k[fri & 15];
    out->is_iframe = iframe;
    return 1;
}

static int read_next_raw_ac4_frame(FILE *fp, uint8_t **buf, size_t *buf_cap, int *out_size) {
    uint8_t hdr[4];
    size_t got = fread(hdr, 1, 4, fp);
    if (got == 0) return 0; /* clean EOF */
    if (got < 4) return -1;

    uint16_t sync = ((uint16_t)hdr[0] << 8) | (uint16_t)hdr[1];
    if (sync != 0xAC40 && sync != 0xAC41) {
        return -1;
    }

    int size = ((int)hdr[2] << 8) | (int)hdr[3];
    if (size == 0xFFFF) {
        uint8_t ext[3];
        if (fread(ext, 1, 3, fp) != 3) return -1;
        size = ((int)ext[0] << 16) | ((int)ext[1] << 8) | (int)ext[2];
    }
    if (size < 8 || size > 1024 * 1024) return -1;

    if ((size_t)size > *buf_cap) {
        size_t new_cap = (size_t)size + 4096;
        uint8_t *nb = (uint8_t *)realloc(*buf, new_cap);
        if (!nb) return -1;
        *buf = nb;
        *buf_cap = new_cap;
    }

    if (fread(*buf, 1, (size_t)size, fp) != (size_t)size) return -1;

    if (sync == 0xAC41) {
        if (fseeko(fp, 2, SEEK_CUR) != 0) return -1;
    }

    *out_size = size;
    return 1;
}

static int is_raw_ac4_sync_file(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return 0;
    uint8_t hdr[4];
    size_t got = fread(hdr, 1, 4, fp);
    fclose(fp);
    if (got < 4) return 0;
    uint16_t sync = ((uint16_t)hdr[0] << 8) | (uint16_t)hdr[1];
    return (sync == 0xAC40 || sync == 0xAC41) ? 1 : 0;
}

static int probe_raw_ac4_file(const char *path, AC4ProbeInfo *out_info) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return 0;

    if (fseeko(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return 0;
    }
    off_t file_size = ftello(fp);
    if (fseeko(fp, 0, SEEK_SET) != 0 || file_size < 12) {
        fclose(fp);
        return 0;
    }

    uint8_t *scratch = NULL;
    size_t scratch_cap = 0;
    int pkt_size = 0;
    int first_rc = read_next_raw_ac4_frame(fp, &scratch, &scratch_cap, &pkt_size);
    if (first_rc != 1) {
        free(scratch);
        fclose(fp);
        return 0;
    }

    RawAC4HeaderInfo hinfo = { 48000, 2048, 1 };
    parse_raw_ac4_toc_brief(scratch, pkt_size, &hinfo);
    free(scratch);

    /* Fast syncframe header walk for exact duration without decoding audio */
    if (fseeko(fp, 0, SEEK_SET) == 0) {
        int64_t total_frames = 0;
        while (total_frames < 2000000) {
            uint8_t hdr[4];
            if (fread(hdr, 1, 4, fp) != 4) break;
            uint16_t sync = ((uint16_t)hdr[0] << 8) | (uint16_t)hdr[1];
            if (sync != 0xAC40 && sync != 0xAC41) break;
            int sz = ((int)hdr[2] << 8) | (int)hdr[3];
            if (sz == 0xFFFF) {
                uint8_t ext[3];
                if (fread(ext, 1, 3, fp) != 3) break;
                sz = ((int)ext[0] << 16) | ((int)ext[1] << 8) | (int)ext[2];
            }
            if (sz < 4 || sz > 1024 * 1024) break;
            off_t skip = (off_t)sz + (sync == 0xAC41 ? 2 : 0);
            if (fseeko(fp, skip, SEEK_CUR) != 0) break;
            total_frames++;
        }
        if (total_frames > 0 && hinfo.sample_rate > 0) {
            double dur = ((double)total_frames * (double)hinfo.frame_samples) / (double)hinfo.sample_rate;
            out_info->duration_seconds = dur;
            if (dur > 0.25 && file_size > 0) {
                out_info->bitrate_kbps = (int)llround(((double)file_size * 8.0) / dur / 1000.0);
            }
        }
    }

    fclose(fp);

    out_info->is_valid = 1;
    out_info->is_ac4 = 1;
    out_info->audio_stream_index = 0;
    out_info->sample_rate = hinfo.sample_rate;
    out_info->channels = 2;
    copy_cstr(out_info->codec_name, sizeof(out_info->codec_name), "AC-4 IMS");
    return 1;
}

static int select_audio_stream(AVFormatContext *fmt, int preferred_audio_idx, int *out_audio_ord) {
    int audio_ord = 0;
    int preferred_stream = -1;
    int preferred_ord = 0;
    int first_ac4_stream = -1;
    int first_ac4_ord = 0;
    int first_decodable_stream = -1;
    int first_decodable_ord = 0;

    for (unsigned int i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (!st || !st->codecpar || st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
            continue;
        }
        const int has_dec = (avcodec_find_decoder(st->codecpar->codec_id) != NULL);
        if (st->codecpar->codec_id == AV_CODEC_ID_AC4 && first_ac4_stream < 0) {
            first_ac4_stream = (int)i;
            first_ac4_ord = audio_ord;
        }
        if (has_dec && first_decodable_stream < 0) {
            first_decodable_stream = (int)i;
            first_decodable_ord = audio_ord;
        }
        if (audio_ord == preferred_audio_idx) {
            preferred_stream = (int)i;
            preferred_ord = audio_ord;
        }
        audio_ord++;
    }

    if (preferred_stream >= 0 && avcodec_find_decoder(fmt->streams[preferred_stream]->codecpar->codec_id) != NULL) {
        if (out_audio_ord) *out_audio_ord = preferred_ord;
        return preferred_stream;
    }
    if (first_ac4_stream >= 0 && avcodec_find_decoder(AV_CODEC_ID_AC4) != NULL) {
        if (out_audio_ord) *out_audio_ord = first_ac4_ord;
        return first_ac4_stream;
    }
    if (first_decodable_stream >= 0) {
        if (out_audio_ord) *out_audio_ord = first_decodable_ord;
        return first_decodable_stream;
    }
    if (preferred_stream >= 0) {
        if (out_audio_ord) *out_audio_ord = preferred_ord;
        return preferred_stream;
    }
    return -1;
}

int ac4_native_is_available(void) {
    ensure_av_initialized();
    return avcodec_find_decoder(AV_CODEC_ID_AC4) != NULL ? 1 : 0;
}

const char *ac4_native_version_string(void) {
    return "LibreMPEG in-process (libavcodec " AV_STRINGIFY(LIBAVCODEC_VERSION_MAJOR) "." AV_STRINGIFY(LIBAVCODEC_VERSION_MINOR) " · 32-bit Float)";
}

int ac4_native_can_decode_file(const char *path, int preferred_audio_stream_index) {
    if (!path || path[0] != '/') return 0;
    ensure_av_initialized();

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) == 0) {
        int ok = 0;
        if (avformat_find_stream_info(fmt, NULL) >= 0) {
            int st_idx = select_audio_stream(fmt, preferred_audio_stream_index, NULL);
            if (st_idx >= 0) {
                enum AVCodecID cid = fmt->streams[st_idx]->codecpar->codec_id;
                ok = (avcodec_find_decoder(cid) != NULL) ? 1 : 0;
            }
        }
        avformat_close_input(&fmt);
        return ok;
    }

    if (avcodec_find_decoder(AV_CODEC_ID_AC4) != NULL && is_raw_ac4_sync_file(path)) {
        return 1;
    }
    return 0;
}

int ac4_native_probe_file(const char *path, AC4ProbeInfo *out_info) {
    if (!path || !out_info || path[0] != '/') return 0;
    memset(out_info, 0, sizeof(*out_info));
    ensure_av_initialized();

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) != 0) {
        if (is_raw_ac4_sync_file(path)) {
            return probe_raw_ac4_file(path, out_info);
        }
        return 0;
    }

    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        return 0;
    }

    int audio_ord = 0;
    int st_idx = select_audio_stream(fmt, 0, &audio_ord);
    if (st_idx < 0) {
        avformat_close_input(&fmt);
        return 0;
    }

    AVStream *st = fmt->streams[st_idx];
    AVCodecParameters *par = st->codecpar;

    out_info->is_valid = 1;
    out_info->audio_stream_index = audio_ord;
    out_info->is_ac4 = (par->codec_id == AV_CODEC_ID_AC4) ? 1 : 0;
    out_info->sample_rate = par->sample_rate > 0 ? par->sample_rate : (out_info->is_ac4 ? 48000 : 0);
    out_info->channels = par->ch_layout.nb_channels > 0 ? par->ch_layout.nb_channels : (out_info->is_ac4 ? 2 : 0);

    if (par->bit_rate > 0) {
        out_info->bitrate_kbps = (int)(par->bit_rate / 1000);
    } else if (fmt->bit_rate > 0) {
        out_info->bitrate_kbps = (int)(fmt->bit_rate / 1000);
    }

    if (st->duration > 0 && st->time_base.den > 0) {
        out_info->duration_seconds = (double)st->duration * av_q2d(st->time_base);
    } else if (fmt->duration > 0) {
        out_info->duration_seconds = (double)fmt->duration / (double)AV_TIME_BASE;
    }

    if (out_info->is_ac4) {
        copy_cstr(out_info->codec_name, sizeof(out_info->codec_name), "AC-4 IMS");
    } else {
        const char *cname = avcodec_get_name(par->codec_id);
        copy_cstr(out_info->codec_name, sizeof(out_info->codec_name), cname ? cname : "AUDIO");
        for (size_t i = 0; out_info->codec_name[i] != '\0'; i++) {
            out_info->codec_name[i] = (char)toupper((unsigned char)out_info->codec_name[i]);
        }
    }

    const AVDictionary *md = fmt->metadata ? fmt->metadata : st->metadata;
    static const char *const k_title[] = { "title", NULL };
    static const char *const k_artist[] = { "artist", NULL };
    static const char *const k_album_artist[] = { "album_artist", "albumartist", NULL };
    static const char *const k_album[] = { "album", NULL };
    static const char *const k_date[] = { "date", "year", NULL };
    static const char *const k_track[] = { "track", "tracknumber", NULL };
    static const char *const k_disc[] = { "disc", "discnumber", NULL };

    copy_cstr(out_info->title, sizeof(out_info->title), dict_get_any(md, k_title));
    copy_cstr(out_info->artist, sizeof(out_info->artist), dict_get_any(md, k_artist));
    copy_cstr(out_info->album_artist, sizeof(out_info->album_artist), dict_get_any(md, k_album_artist));
    copy_cstr(out_info->album, sizeof(out_info->album), dict_get_any(md, k_album));

    const char *date_str = dict_get_any(md, k_date);
    if (date_str) {
        copy_cstr(out_info->year, 5, date_str);
    }
    parse_slash_pair(dict_get_any(md, k_track), &out_info->track_number, &out_info->track_total);
    parse_slash_pair(dict_get_any(md, k_disc), &out_info->disc_number, &out_info->disc_total);

    avformat_close_input(&fmt);
    return 1;
}

typedef struct OutputResampler {
    SwrContext *swr;
    int src_rate;
    int src_format;
    AVChannelLayout src_layout;
    int dst_rate;
    float *interleaved_buf;
    int interleaved_cap_frames;
} OutputResampler;

static void resampler_free(OutputResampler *r) {
    if (!r) return;
    if (r->swr) {
        swr_free(&r->swr);
    }
    av_channel_layout_uninit(&r->src_layout);
    free(r->interleaved_buf);
    r->interleaved_buf = NULL;
    r->interleaved_cap_frames = 0;
}

static int ensure_interleaved_cap(OutputResampler *r, int needed_frames) {
    if (needed_frames <= r->interleaved_cap_frames) return 0;
    int new_cap = needed_frames + 1024;
    float *nb = (float *)realloc(r->interleaved_buf, (size_t)new_cap * 2 * sizeof(float));
    if (!nb) return AVERROR(ENOMEM);
    r->interleaved_buf = nb;
    r->interleaved_cap_frames = new_cap;
    return 0;
}

/* Returns: 1 = continue, 0 = cancelled by caller, < 0 = error */
static int emit_decoded_frame(
    AVFrame *frame,
    OutputResampler *r,
    double frame_start_sec,
    double *io_seek_target_sec,
    ac4_pcm_write_cb write_cb,
    void *userdata
) {
    const int nb_in = frame->nb_samples;
    if (nb_in <= 0) return 1;

    const int in_rate = frame->sample_rate > 0 ? frame->sample_rate : r->dst_rate;
    const int in_ch = frame->ch_layout.nb_channels;
    int out_frames = 0;

    if (frame->format == AV_SAMPLE_FMT_FLTP && in_rate == r->dst_rate && (in_ch == 2 || in_ch == 1)) {
        if (ensure_interleaved_cap(r, nb_in) < 0) return AVERROR(ENOMEM);
        const float *left = (const float *)frame->extended_data[0];
        const float *right = (in_ch >= 2 && frame->extended_data[1])
            ? (const float *)frame->extended_data[1]
            : left;
        if (!left) return 1;

        float *dst = r->interleaved_buf;
        for (int i = 0; i < nb_in; i++) {
            dst[i * 2]     = sanitize_sample(left[i]);
            dst[i * 2 + 1] = sanitize_sample(right[i]);
        }
        out_frames = nb_in;
    } else {
        if (!r->swr
            || r->src_rate != in_rate
            || r->src_format != frame->format
            || av_channel_layout_compare(&r->src_layout, &frame->ch_layout) != 0) {
            if (r->swr) swr_free(&r->swr);
            av_channel_layout_uninit(&r->src_layout);

            AVChannelLayout in_layout = { 0 };
            if (frame->ch_layout.nb_channels > 0) {
                av_channel_layout_copy(&in_layout, &frame->ch_layout);
            } else {
                av_channel_layout_default(&in_layout, 2);
            }

            AVChannelLayout stereo_layout = AV_CHANNEL_LAYOUT_STEREO;
            int ret = swr_alloc_set_opts2(
                &r->swr,
                &stereo_layout,
                AV_SAMPLE_FMT_FLT,
                r->dst_rate,
                &in_layout,
                (enum AVSampleFormat)frame->format,
                in_rate,
                0,
                NULL
            );
            if (ret < 0 || !r->swr || swr_init(r->swr) < 0) {
                av_channel_layout_uninit(&in_layout);
                return AVERROR_EXTERNAL;
            }
            r->src_rate = in_rate;
            r->src_format = frame->format;
            r->src_layout = in_layout;
        }

        int max_out = swr_get_out_samples(r->swr, nb_in);
        if (max_out < nb_in) max_out = nb_in;
        max_out += 256;
        if (ensure_interleaved_cap(r, max_out) < 0) return AVERROR(ENOMEM);

        uint8_t *out_planes[1] = { (uint8_t *)r->interleaved_buf };
        int converted = swr_convert(
            r->swr,
            out_planes,
            max_out,
            (const uint8_t **)frame->extended_data,
            nb_in
        );
        if (converted < 0) return converted;
        for (int i = 0; i < converted * 2; i++) {
            r->interleaved_buf[i] = sanitize_sample(r->interleaved_buf[i]);
        }
        out_frames = converted;
    }

    if (out_frames <= 0) return 1;

    /* Trim pre-seek preroll samples after keyframe seek */
    int skip_frames = 0;
    if (*io_seek_target_sec > 0.0005 && frame_start_sec >= 0.0) {
        double frame_dur = (double)out_frames / (double)r->dst_rate;
        if (frame_start_sec + frame_dur <= *io_seek_target_sec) {
            return 1;
        }
        if (frame_start_sec < *io_seek_target_sec) {
            long long sk = llround((*io_seek_target_sec - frame_start_sec) * (double)r->dst_rate);
            if (sk >= out_frames) return 1;
            if (sk > 0) skip_frames = (int)sk;
        }
        *io_seek_target_sec = 0.0;
    }

    const int emit_count = out_frames - skip_frames;
    if (emit_count > 0) {
        if (!write_cb(r->interleaved_buf + (size_t)skip_frames * 2, emit_count, userdata)) {
            return 0; /* cancelled */
        }
    }
    return 1;
}

static int stream_raw_ac4_file(
    const char *path,
    double seek_seconds,
    int target_sample_rate,
    ac4_pcm_write_cb write_cb,
    void *userdata,
    char *err_buf,
    size_t err_buf_len
) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_AC4);
    if (!codec) {
        copy_cstr(err_buf, err_buf_len, "Built-in AC-4 decoder is not available.");
        return -1;
    }

    FILE *fp = fopen(path, "rb");
    if (!fp) {
        copy_cstr(err_buf, err_buf_len, "Could not open .ac4 file for reading.");
        return -1;
    }

    AVCodecContext *dec = avcodec_alloc_context3(codec);
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    OutputResampler resampler;
    memset(&resampler, 0, sizeof(resampler));
    resampler.dst_rate = target_sample_rate > 0 ? target_sample_rate : 48000;

    uint8_t *raw_buf = NULL;
    size_t raw_cap = 0;
    int status = 0;

    if (!dec || !pkt || !frame || avcodec_open2(dec, codec, NULL) < 0) {
        copy_cstr(err_buf, err_buf_len, "Failed to initialize AC-4 decoder context.");
        status = -1;
        goto cleanup;
    }

    /* Fast syncframe seek to the last AC-4 I-frame at or before seek_seconds */
    double current_time_sec = 0.0;
    if (seek_seconds > 0.05) {
        off_t last_iframe_offset = 0;
        double last_iframe_sec = 0.0;
        double scan_sec = 0.0;

        while (1) {
            off_t frame_off = ftello(fp);
            int pkt_sz = 0;
            int rrc = read_next_raw_ac4_frame(fp, &raw_buf, &raw_cap, &pkt_sz);
            if (rrc != 1) break;

            RawAC4HeaderInfo hinfo = { 48000, 2048, 0 };
            parse_raw_ac4_toc_brief(raw_buf, pkt_sz, &hinfo);
            if (hinfo.is_iframe) {
                last_iframe_offset = frame_off;
                last_iframe_sec = scan_sec;
            }
            double dur = (double)hinfo.frame_samples / (double)hinfo.sample_rate;
            if (scan_sec + dur > seek_seconds) {
                break;
            }
            scan_sec += dur;
        }
        fseeko(fp, last_iframe_offset, SEEK_SET);
        current_time_sec = last_iframe_sec;
    }

    double remaining_seek_target = seek_seconds;

    while (1) {
        int pkt_sz = 0;
        int rrc = read_next_raw_ac4_frame(fp, &raw_buf, &raw_cap, &pkt_sz);
        if (rrc <= 0) break;

        if (av_new_packet(pkt, pkt_sz) < 0) {
            status = -1;
            copy_cstr(err_buf, err_buf_len, "Out of memory allocating AC-4 packet.");
            break;
        }
        memcpy(pkt->data, raw_buf, (size_t)pkt_sz);

        int send_rc = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (send_rc < 0 && send_rc != AVERROR(EAGAIN)) {
            /* Skip transient damaged frames cleanly unless fatal */
            continue;
        }

        while (avcodec_receive_frame(dec, frame) == 0) {
            int in_sr = frame->sample_rate > 0 ? frame->sample_rate : 48000;
            double fdur = (double)frame->nb_samples / (double)in_sr;
            int erc = emit_decoded_frame(frame, &resampler, current_time_sec, &remaining_seek_target, write_cb, userdata);
            current_time_sec += fdur;
            av_frame_unref(frame);
            if (erc == 0) {
                status = 0;
                goto cleanup;
            } else if (erc < 0) {
                copy_cstr(err_buf, err_buf_len, "Audio sample conversion failed.");
                status = -1;
                goto cleanup;
            }
        }
    }

cleanup:
    free(raw_buf);
    resampler_free(&resampler);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    fclose(fp);
    return status;
}

int ac4_native_stream_file(
    const char *path,
    int preferred_audio_stream_index,
    double seek_seconds,
    int target_sample_rate,
    ac4_pcm_write_cb write_cb,
    void *userdata,
    char *err_buf,
    size_t err_buf_len
) {
    if (err_buf && err_buf_len > 0) err_buf[0] = '\0';
    if (!path || !write_cb || path[0] != '/') {
        copy_cstr(err_buf, err_buf_len, "Invalid audio file path.");
        return -1;
    }

    ensure_av_initialized();

    AVFormatContext *fmt = NULL;
    int ret = avformat_open_input(&fmt, path, NULL, NULL);
    if (ret < 0) {
        if (is_raw_ac4_sync_file(path)) {
            return stream_raw_ac4_file(path, seek_seconds, target_sample_rate, write_cb, userdata, err_buf, err_buf_len);
        }
        char av_err[192];
        av_strerror(ret, av_err, sizeof(av_err));
        snprintf(err_buf, err_buf_len, "Could not open container: %s", av_err);
        return -1;
    }

    if ((ret = avformat_find_stream_info(fmt, NULL)) < 0) {
        avformat_close_input(&fmt);
        copy_cstr(err_buf, err_buf_len, "Could not parse container stream info.");
        return -1;
    }

    int st_idx = select_audio_stream(fmt, preferred_audio_stream_index, NULL);
    if (st_idx < 0) {
        avformat_close_input(&fmt);
        copy_cstr(err_buf, err_buf_len, "No audio stream found in file.");
        return -1;
    }

    AVStream *st = fmt->streams[st_idx];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        avformat_close_input(&fmt);
        copy_cstr(err_buf, err_buf_len, "Unsupported audio codec in built-in LibreMPEG.");
        return -1;
    }

    AVCodecContext *dec = avcodec_alloc_context3(codec);
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    OutputResampler resampler;
    memset(&resampler, 0, sizeof(resampler));
    resampler.dst_rate = target_sample_rate > 0 ? target_sample_rate : 48000;

    int status = 0;
    int decoded_any_frame = 0;
    int last_decode_err = 0;

    if (!dec || !pkt || !frame) {
        copy_cstr(err_buf, err_buf_len, "Out of memory initializing decoder.");
        status = -1;
        goto cleanup;
    }

    if ((ret = avcodec_parameters_to_context(dec, st->codecpar)) < 0
        || (ret = avcodec_open2(dec, codec, NULL)) < 0) {
        char av_err[192];
        av_strerror(ret, av_err, sizeof(av_err));
        snprintf(err_buf, err_buf_len, "Decoder open failed: %s", av_err);
        status = -1;
        goto cleanup;
    }

    const int64_t start_ts = (st->start_time != AV_NOPTS_VALUE) ? st->start_time : 0;
    const double tb_sec = (st->time_base.den > 0) ? av_q2d(st->time_base) : (1.0 / 48000.0);
    double remaining_seek_target = (seek_seconds > 0.02) ? seek_seconds : 0.0;
    double fallback_clock_sec = 0.0;

    if (remaining_seek_target > 0.0) {
        int64_t target_ts = start_ts + (int64_t)llround(remaining_seek_target / tb_sec);
        if (av_seek_frame(fmt, st_idx, target_ts, AVSEEK_FLAG_BACKWARD) >= 0) {
            avcodec_flush_buffers(dec);
            fallback_clock_sec = remaining_seek_target;
        } else {
            remaining_seek_target = 0.0;
        }
    }

    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != st_idx) {
            av_packet_unref(pkt);
            continue;
        }

        ret = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            last_decode_err = ret;
            if (ret == AVERROR_PATCHWELCOME) {
                copy_cstr(err_buf, err_buf_len, "AC-4 object-coded (AJOC) stream is not supported by LibreMPEG (IMS / channel-coded AC-4 required).");
                status = -1;
                goto cleanup;
            }
            continue;
        }

        while ((ret = avcodec_receive_frame(dec, frame)) == 0) {
            decoded_any_frame = 1;
            double frame_sec = fallback_clock_sec;
            if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
                frame_sec = (double)(frame->best_effort_timestamp - start_ts) * tb_sec;
                if (frame_sec < 0.0) frame_sec = 0.0;
            }
            int in_sr = frame->sample_rate > 0 ? frame->sample_rate : resampler.dst_rate;
            fallback_clock_sec = frame_sec + ((double)frame->nb_samples / (double)in_sr);

            int erc = emit_decoded_frame(frame, &resampler, frame_sec, &remaining_seek_target, write_cb, userdata);
            av_frame_unref(frame);
            if (erc == 0) {
                status = 0;
                goto cleanup;
            } else if (erc < 0) {
                copy_cstr(err_buf, err_buf_len, "Audio sample format conversion failed.");
                status = -1;
                goto cleanup;
            }
        }
    }

    /* Flush decoder */
    avcodec_send_packet(dec, NULL);
    while (avcodec_receive_frame(dec, frame) == 0) {
        decoded_any_frame = 1;
        int erc = emit_decoded_frame(frame, &resampler, fallback_clock_sec, &remaining_seek_target, write_cb, userdata);
        av_frame_unref(frame);
        if (erc <= 0) {
            status = (erc == 0) ? 0 : -1;
            goto cleanup;
        }
    }

    /* Flush any delayed samples in SwrContext */
    if (resampler.swr) {
        int delayed = swr_get_out_samples(resampler.swr, 0);
        if (delayed > 0 && ensure_interleaved_cap(&resampler, delayed + 64) == 0) {
            uint8_t *out_planes[1] = { (uint8_t *)resampler.interleaved_buf };
            int flushed = swr_convert(resampler.swr, out_planes, delayed + 64, NULL, 0);
            if (flushed > 0) {
                for (int i = 0; i < flushed * 2; i++) {
                    resampler.interleaved_buf[i] = sanitize_sample(resampler.interleaved_buf[i]);
                }
                write_cb(resampler.interleaved_buf, flushed, userdata);
            }
        }
    }

    if (!decoded_any_frame && last_decode_err < 0) {
        char av_err[192];
        av_strerror(last_decode_err, av_err, sizeof(av_err));
        snprintf(err_buf, err_buf_len, "Decode failed: %s", av_err);
        status = -1;
    }

cleanup:
    resampler_free(&resampler);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return status;
}

#else /* !AC4_ENABLE_NATIVE_LIBREMPEG */

int ac4_native_is_available(void) {
    return 0;
}

const char *ac4_native_version_string(void) {
    return "";
}

int ac4_native_can_decode_file(const char *path, int preferred_audio_stream_index) {
    (void)path;
    (void)preferred_audio_stream_index;
    return 0;
}

int ac4_native_probe_file(const char *path, AC4ProbeInfo *out_info) {
    (void)path;
    if (out_info) {
        memset(out_info, 0, sizeof(*out_info));
    }
    return 0;
}

int ac4_native_stream_file(
    const char *path,
    int preferred_audio_stream_index,
    double seek_seconds,
    int target_sample_rate,
    ac4_pcm_write_cb write_cb,
    void *userdata,
    char *err_buf,
    size_t err_buf_len
) {
    (void)path;
    (void)preferred_audio_stream_index;
    (void)seek_seconds;
    (void)target_sample_rate;
    (void)write_cb;
    (void)userdata;
    if (err_buf && err_buf_len > 0) {
        snprintf(err_buf, err_buf_len, "Built-in LibreMPEG is not compiled into this shareable build.");
    }
    return -1;
}

#endif /* AC4_ENABLE_NATIVE_LIBREMPEG */

