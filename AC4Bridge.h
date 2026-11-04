#ifndef AC4_BRIDGE_H
#define AC4_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AC4ProbeInfo {
    int is_valid;
    int is_ac4;
    int audio_stream_index;
    int sample_rate;
    int channels;
    int bitrate_kbps;
    double duration_seconds;
    char codec_name[64];
    char title[256];
    char artist[256];
    char album_artist[256];
    char album[256];
    char year[16];
    int track_number;
    int track_total;
    int disc_number;
    int disc_total;
} AC4ProbeInfo;

/// Callback invoked with interleaved stereo Float32 PCM frames `[L0, R0, L1, R1, ...]`.
/// Return 1 to continue decoding, or 0 to abort immediately (e.g. on stop or seek).
typedef int (*ac4_pcm_write_cb)(const float *interleaved_stereo, int frame_count, void *userdata);

/// Returns 1 if LibreMPEG's native `ac4` decoder is statically linked into this binary, 0 otherwise.
int ac4_native_is_available(void);

/// Human-readable version string of the linked LibreMPEG decoder.
const char *ac4_native_version_string(void);

/// Returns 1 if the linked LibreMPEG libraries can demux and decode the given file.
int ac4_native_can_decode_file(const char *path, int preferred_audio_stream_index);

/// Probes container/bitstream metadata and duration in-process without spawning a child process.
int ac4_native_probe_file(const char *path, AC4ProbeInfo *out_info);

/// Decodes an audio stream in-process into 32-bit float stereo at `target_sample_rate` (e.g. 48000 Hz).
/// Returns 0 on clean EOF or caller-requested cancellation, or negative error code on decode failure.
int ac4_native_stream_file(
    const char *path,
    int preferred_audio_stream_index,
    double seek_seconds,
    int target_sample_rate,
    ac4_pcm_write_cb write_cb,
    void *userdata,
    char *err_buf,
    size_t err_buf_len
);

#ifdef __cplusplus
}
#endif

#endif /* AC4_BRIDGE_H */

