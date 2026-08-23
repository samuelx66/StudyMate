#include "CSpeechRuntime.h"

#include <whisper/whisper.h>

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct MABWhisperContext {
    struct whisper_context *value;
};

struct MABVADContext {
    struct whisper_vad_context *value;
};

struct MABCancellationToken {
    atomic_bool cancelled;
};

typedef struct {
    MABCancellationToken *cancellation_token;
    MABProgressCallback progress_callback;
    void *progress_user_data;
} MABCallbackState;

static void mab_set_error(char *buffer, size_t capacity, const char *message) {
    if (buffer == NULL || capacity == 0) {
        return;
    }
    snprintf(buffer, capacity, "%s", message == NULL ? "Unknown speech runtime error" : message);
}

static char *mab_copy_string(const char *source) {
    if (source == NULL) {
        source = "";
    }
    size_t length = strlen(source);
    char *copy = (char *) malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, source, length + 1);
    return copy;
}

static bool mab_abort_callback(void *user_data) {
    MABCallbackState *state = (MABCallbackState *) user_data;
    return state != NULL
        && state->cancellation_token != NULL
        && atomic_load_explicit(&state->cancellation_token->cancelled, memory_order_relaxed);
}

static bool mab_encoder_begin_callback(
    struct whisper_context *context,
    struct whisper_state *state,
    void *user_data
) {
    (void) context;
    (void) state;
    return !mab_abort_callback(user_data);
}

static void mab_progress_callback(
    struct whisper_context *context,
    struct whisper_state *state,
    int progress,
    void *user_data
) {
    (void) context;
    (void) state;
    MABCallbackState *callback_state = (MABCallbackState *) user_data;
    if (callback_state != NULL && callback_state->progress_callback != NULL) {
        callback_state->progress_callback((double) progress / 100.0, callback_state->progress_user_data);
    }
}

static struct whisper_vad_params mab_vad_params(MABVADConfig config) {
    struct whisper_vad_params params = whisper_vad_default_params();
    params.threshold = config.threshold;
    params.min_speech_duration_ms = config.min_speech_duration_ms;
    params.min_silence_duration_ms = config.min_silence_duration_ms;
    params.max_speech_duration_s = config.max_speech_duration_s;
    params.speech_pad_ms = config.speech_pad_ms;
    params.samples_overlap = config.samples_overlap_s;
    return params;
}

MABCancellationToken *mab_cancellation_token_create(void) {
    MABCancellationToken *token = (MABCancellationToken *) calloc(1, sizeof(MABCancellationToken));
    if (token != NULL) {
        atomic_init(&token->cancelled, false);
    }
    return token;
}

void mab_cancellation_token_cancel(MABCancellationToken *token) {
    if (token != NULL) {
        atomic_store_explicit(&token->cancelled, true, memory_order_relaxed);
    }
}

bool mab_cancellation_token_is_cancelled(const MABCancellationToken *token) {
    return token != NULL && atomic_load_explicit(&token->cancelled, memory_order_relaxed);
}

void mab_cancellation_token_free(MABCancellationToken *token) {
    free(token);
}

MABWhisperContext *mab_whisper_create(
    const char *model_path,
    bool use_gpu,
    char *error_buffer,
    size_t error_capacity
) {
    if (model_path == NULL || model_path[0] == '\0') {
        mab_set_error(error_buffer, error_capacity, "Whisper model path is empty");
        return NULL;
    }

    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = use_gpu;
    params.flash_attn = true;

    struct whisper_context *raw_context = whisper_init_from_file_with_params(model_path, params);
    if (raw_context == NULL) {
        mab_set_error(error_buffer, error_capacity, "Unable to load the Whisper model");
        return NULL;
    }

    MABWhisperContext *context = (MABWhisperContext *) calloc(1, sizeof(MABWhisperContext));
    if (context == NULL) {
        whisper_free(raw_context);
        mab_set_error(error_buffer, error_capacity, "Unable to allocate the Whisper context");
        return NULL;
    }
    context->value = raw_context;
    return context;
}

void mab_whisper_free(MABWhisperContext *context) {
    if (context == NULL) {
        return;
    }
    if (context->value != NULL) {
        whisper_free(context->value);
    }
    free(context);
}

void mab_transcription_result_free(MABTranscriptionResult *result) {
    if (result == NULL) {
        return;
    }
    if (result->tokens != NULL) {
        for (int32_t index = 0; index < result->token_count; ++index) {
            free(result->tokens[index].text);
        }
        free(result->tokens);
    }
    free(result->voice_segments);
    free(result->detected_language);
    memset(result, 0, sizeof(MABTranscriptionResult));
}

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
) {
    if (result == NULL) {
        mab_set_error(error_buffer, error_capacity, "Transcription result pointer is null");
        return -1;
    }
    memset(result, 0, sizeof(MABTranscriptionResult));
    if (context == NULL || context->value == NULL || samples == NULL || sample_count <= 0) {
        mab_set_error(error_buffer, error_capacity, "Invalid Whisper transcription input");
        return -1;
    }

    MABCallbackState callback_state = {
        .cancellation_token = cancellation_token,
        .progress_callback = progress_callback,
        .progress_user_data = progress_user_data,
    };

    enum whisper_sampling_strategy strategy = config.beam_size > 1
        ? WHISPER_SAMPLING_BEAM_SEARCH
        : WHISPER_SAMPLING_GREEDY;
    struct whisper_full_params params = whisper_full_default_params(strategy);
    params.n_threads = config.thread_count > 0 ? config.thread_count : 4;
    params.translate = false;
    params.no_context = false;
    params.no_timestamps = false;
    params.single_segment = false;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.token_timestamps = true;
    params.thold_pt = 0.01f;
    params.thold_ptsum = 0.01f;
    params.max_len = 0;
    params.split_on_word = true;
    params.max_tokens = 0;
    params.tdrz_enable = config.enable_tinydiarize;
    params.language = language == NULL ? "auto" : language;
    params.detect_language = params.language[0] == '\0' || strcmp(params.language, "auto") == 0;
    params.suppress_blank = true;
    params.suppress_nst = config.suppress_non_speech_tokens;
    params.no_speech_thold = config.no_speech_threshold;
    if (strategy == WHISPER_SAMPLING_BEAM_SEARCH) {
        params.beam_search.beam_size = config.beam_size;
        params.beam_search.patience = 1.0f;
    }
    params.progress_callback = mab_progress_callback;
    params.progress_callback_user_data = &callback_state;
    params.encoder_begin_callback = mab_encoder_begin_callback;
    params.encoder_begin_callback_user_data = &callback_state;
    params.abort_callback = mab_abort_callback;
    params.abort_callback_user_data = &callback_state;

    if (vad_model_path != NULL && vad_model_path[0] != '\0') {
        params.vad = true;
        params.vad_model_path = vad_model_path;
        params.vad_params = mab_vad_params(config.vad);
    }

    int run_status = whisper_full(context->value, params, samples, sample_count);
    if (run_status != 0) {
        if (mab_cancellation_token_is_cancelled(cancellation_token)) {
            mab_set_error(error_buffer, error_capacity, "Speech recognition was cancelled");
            return -2;
        }
        mab_set_error(error_buffer, error_capacity, "Whisper inference failed");
        return run_status;
    }

    int segment_count = whisper_full_n_segments(context->value);
    int token_capacity = 0;
    for (int segment_index = 0; segment_index < segment_count; ++segment_index) {
        token_capacity += whisper_full_n_tokens(context->value, segment_index);
    }

    if (token_capacity > 0) {
        result->tokens = (MABSpeechToken *) calloc((size_t) token_capacity, sizeof(MABSpeechToken));
        if (result->tokens == NULL) {
            mab_set_error(error_buffer, error_capacity, "Unable to allocate token results");
            return -3;
        }
    }

    whisper_token end_of_text = whisper_token_eot(context->value);
    int32_t output_index = 0;
    for (int segment_index = 0; segment_index < segment_count; ++segment_index) {
        int segment_token_count = whisper_full_n_tokens(context->value, segment_index);
        bool speaker_turn = whisper_full_get_segment_speaker_turn_next(context->value, segment_index);
        int32_t segment_output_start = output_index;
        for (int token_index = 0; token_index < segment_token_count; ++token_index) {
            whisper_token token_id = whisper_full_get_token_id(context->value, segment_index, token_index);
            const char *text = whisper_full_get_token_text(context->value, segment_index, token_index);
            int64_t t0 = whisper_full_get_token_t0(context->value, segment_index, token_index);
            int64_t t1 = whisper_full_get_token_t1(context->value, segment_index, token_index);
            if (token_id >= end_of_text || text == NULL || text[0] == '\0' || t0 < 0 || t1 < t0) {
                continue;
            }

            MABSpeechToken *output = &result->tokens[output_index];
            output->text = mab_copy_string(text);
            if (output->text == NULL) {
                mab_transcription_result_free(result);
                mab_set_error(error_buffer, error_capacity, "Unable to copy token text");
                return -3;
            }
            output->start_time = (double) t0 / 100.0;
            output->end_time = (double) t1 / 100.0;
            output->confidence = whisper_full_get_token_p(context->value, segment_index, token_index);
            output->segment_index = segment_index;
            output->speaker_turn_after = false;
            output_index += 1;
        }
        if (speaker_turn && output_index > segment_output_start) {
            result->tokens[output_index - 1].speaker_turn_after = true;
        }
    }
    result->token_count = output_index;

    int vad_segment_count = whisper_full_n_vad_segments(context->value);
    if (vad_segment_count > 0) {
        result->voice_segments = (MABVoiceActivitySegment *) calloc(
            (size_t) vad_segment_count,
            sizeof(MABVoiceActivitySegment)
        );
        if (result->voice_segments == NULL) {
            mab_transcription_result_free(result);
            mab_set_error(error_buffer, error_capacity, "Unable to allocate VAD results");
            return -3;
        }
        for (int index = 0; index < vad_segment_count; ++index) {
            result->voice_segments[index].start_time =
                (double) whisper_full_get_vad_segment_t0(context->value, index) / 100.0;
            result->voice_segments[index].end_time =
                (double) whisper_full_get_vad_segment_t1(context->value, index) / 100.0;
            result->voice_segments[index].confidence = 1.0f;
        }
        result->voice_segment_count = vad_segment_count;
    }

    const char *detected_language = whisper_lang_str(whisper_full_lang_id(context->value));
    result->detected_language = mab_copy_string(detected_language == NULL ? "" : detected_language);
    if (result->detected_language == NULL) {
        mab_transcription_result_free(result);
        mab_set_error(error_buffer, error_capacity, "Unable to copy detected language");
        return -3;
    }

    return 0;
}

MABVADContext *mab_vad_create(
    const char *model_path,
    bool use_gpu,
    int32_t thread_count,
    char *error_buffer,
    size_t error_capacity
) {
    if (model_path == NULL || model_path[0] == '\0') {
        mab_set_error(error_buffer, error_capacity, "Silero VAD model path is empty");
        return NULL;
    }
    struct whisper_vad_context_params params = whisper_vad_default_context_params();
    params.use_gpu = use_gpu;
    params.n_threads = thread_count > 0 ? thread_count : 4;
    struct whisper_vad_context *raw_context = whisper_vad_init_from_file_with_params(model_path, params);
    if (raw_context == NULL) {
        mab_set_error(error_buffer, error_capacity, "Unable to load the Silero VAD model");
        return NULL;
    }
    MABVADContext *context = (MABVADContext *) calloc(1, sizeof(MABVADContext));
    if (context == NULL) {
        whisper_vad_free(raw_context);
        mab_set_error(error_buffer, error_capacity, "Unable to allocate the Silero VAD context");
        return NULL;
    }
    context->value = raw_context;
    return context;
}

void mab_vad_free(MABVADContext *context) {
    if (context == NULL) {
        return;
    }
    if (context->value != NULL) {
        whisper_vad_free(context->value);
    }
    free(context);
}

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
) {
    if (segments == NULL || segment_count == NULL) {
        mab_set_error(error_buffer, error_capacity, "VAD result pointer is null");
        return -1;
    }
    *segments = NULL;
    *segment_count = 0;
    if (context == NULL || context->value == NULL || samples == NULL || sample_count <= 0) {
        mab_set_error(error_buffer, error_capacity, "Invalid VAD input");
        return -1;
    }
    if (mab_cancellation_token_is_cancelled(cancellation_token)) {
        mab_set_error(error_buffer, error_capacity, "Voice activity detection was cancelled");
        return -2;
    }

    struct whisper_vad_segments *raw_segments = whisper_vad_segments_from_samples(
        context->value,
        mab_vad_params(config),
        samples,
        sample_count
    );
    if (raw_segments == NULL) {
        mab_set_error(error_buffer, error_capacity, "Silero VAD inference failed");
        return -3;
    }

    if (mab_cancellation_token_is_cancelled(cancellation_token)) {
        whisper_vad_free_segments(raw_segments);
        mab_set_error(error_buffer, error_capacity, "Voice activity detection was cancelled");
        return -2;
    }

    int count = whisper_vad_segments_n_segments(raw_segments);
    if (count > 0) {
        MABVoiceActivitySegment *output = (MABVoiceActivitySegment *) calloc(
            (size_t) count,
            sizeof(MABVoiceActivitySegment)
        );
        if (output == NULL) {
            whisper_vad_free_segments(raw_segments);
            mab_set_error(error_buffer, error_capacity, "Unable to allocate VAD results");
            return -4;
        }
        for (int index = 0; index < count; ++index) {
            output[index].start_time = whisper_vad_segments_get_segment_t0(raw_segments, index);
            output[index].end_time = whisper_vad_segments_get_segment_t1(raw_segments, index);
            output[index].confidence = 1.0f;
        }
        *segments = output;
        *segment_count = count;
    }
    whisper_vad_free_segments(raw_segments);
    return 0;
}

void mab_voice_activity_segments_free(MABVoiceActivitySegment *segments) {
    free(segments);
}
