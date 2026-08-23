#ifndef C_SPEECH_RUNTIME_H
#define C_SPEECH_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MABWhisperContext MABWhisperContext;
typedef struct MABVADContext MABVADContext;
typedef struct MABCancellationToken MABCancellationToken;

typedef struct {
    float threshold;
    int32_t min_speech_duration_ms;
    int32_t min_silence_duration_ms;
    float max_speech_duration_s;
    int32_t speech_pad_ms;
    float samples_overlap_s;
} MABVADConfig;

typedef struct {
    int32_t thread_count;
    int32_t beam_size;
    float no_speech_threshold;
    bool suppress_non_speech_tokens;
    bool enable_tinydiarize;
    MABVADConfig vad;
} MABWhisperConfig;

typedef struct {
    char *text;
    double start_time;
    double end_time;
    float confidence;
    int32_t segment_index;
    bool speaker_turn_after;
} MABSpeechToken;

typedef struct {
    double start_time;
    double end_time;
    float confidence;
} MABVoiceActivitySegment;

typedef struct {
    MABSpeechToken *tokens;
    int32_t token_count;
    MABVoiceActivitySegment *voice_segments;
    int32_t voice_segment_count;
    char *detected_language;
} MABTranscriptionResult;

typedef void (*MABProgressCallback)(double progress, void *user_data);

MABCancellationToken *mab_cancellation_token_create(void);
void mab_cancellation_token_cancel(MABCancellationToken *token);
bool mab_cancellation_token_is_cancelled(const MABCancellationToken *token);
void mab_cancellation_token_free(MABCancellationToken *token);

MABWhisperContext *mab_whisper_create(
    const char *model_path,
    bool use_gpu,
    char *error_buffer,
    size_t error_capacity
);

void mab_whisper_free(MABWhisperContext *context);

int32_t mab_whisper_transcribe(
    MABWhisperContext *context,
    const char *vad_model_path,
    const float *samples,
    int32_t sample_count,
    const char *language,
    MABWhisperConfig config,
    MABCancellationToken *cancellation_token,
    MABProgressCallback progress_callback,
    void *progress_user_data,
    MABTranscriptionResult *result,
    char *error_buffer,
    size_t error_capacity
);

void mab_transcription_result_free(MABTranscriptionResult *result);

MABVADContext *mab_vad_create(
    const char *model_path,
    bool use_gpu,
    int32_t thread_count,
    char *error_buffer,
    size_t error_capacity
);

void mab_vad_free(MABVADContext *context);

int32_t mab_vad_detect(
    MABVADContext *context,
    const float *samples,
    int32_t sample_count,
    MABVADConfig config,
    MABCancellationToken *cancellation_token,
    MABVoiceActivitySegment **segments,
    int32_t *segment_count,
    char *error_buffer,
    size_t error_capacity
);

void mab_voice_activity_segments_free(MABVoiceActivitySegment *segments);

#ifdef __cplusplus
}
#endif

#endif
