package audio

import "../af"
import ma "vendor:miniaudio"

AudioContext :: struct {
    current_music: ^Music,
    is_playing:    bool,
}

Music :: struct {
    decoder: ma.decoder,
}

audio_context: AudioContext
device: ma.device
has_device := false

AudioError :: struct {
    ErrorMessage:    string,
    MiniaudioResult: ma.result,
}

initialize :: proc() -> AudioError {
    // does nothing at the moment.

    return {"", .SUCCESS}
}

un_initialize :: proc() {
    clear_device()
}

@(private)
clear_device :: proc() {
    if has_device {
        ma.device_uninit(&device)
        has_device = false
    }
}

set_music :: proc(music: ^Music) -> AudioError {
    clear_device()

    audio_context.current_music = music

    if (music == nil) {
        return {"", .SUCCESS}
    }

    device_config := ma.device_config_init(ma.device_type.playback)
    device_config.playback.format = music.decoder.outputFormat
    device_config.playback.channels = music.decoder.outputChannels
    device_config.sampleRate = music.decoder.outputSampleRate
    device_config.pUserData = &audio_context
    device_config.dataCallback =
    proc "c" (device: ^ma.device, output, _input: rawptr, frameCount: u32) {
        ctx := cast(^AudioContext)device.pUserData
        if ctx == nil {
            return
        }

        if ctx.current_music == nil {
            return
        }

        if !ctx.is_playing {
            return
        }

        ma.decoder_read_pcm_frames(&ctx.current_music.decoder, output, u64(frameCount), nil)
    }

    result: ma.result


    result = ma.device_init(nil, &device_config, &device)
    has_device = true
    if result != .SUCCESS {
        clear_device()
        return {"Failed to open playback device", result}
    }

    result = ma.device_start(&device)
    if result != .SUCCESS {
        clear_device()
        return {"Failed to start playback device", result}
    }

    return {"", .SUCCESS}
}

set_playing :: proc(state: bool) {
    audio_context.is_playing = state
}


@(private)
pcm_frames_to_seconds :: proc(decoder: ^ma.decoder, cursor: u64) -> f64 {
    cursor := cursor
    seconds: f64 =
        f64(cursor / u64(decoder.outputSampleRate)) +
        (f64(cursor % u64(decoder.outputSampleRate)) / f64(decoder.outputSampleRate))

    return seconds
}

get_playback_seconds :: proc() -> (f64, AudioError) {
    if audio_context.current_music == nil {
        return 0, {"", .SUCCESS}
    }

    decoder := &audio_context.current_music.decoder
    cursor: u64
    res := ma.decoder_get_cursor_in_pcm_frames(decoder, &cursor)
    if res != .SUCCESS {
        return 0, {"Failed to get playback position", res}
    }

    return pcm_frames_to_seconds(decoder, cursor), {"", .SUCCESS}
}

// NOTE: Do NOT call this every frame. It looks like this is being done by seeking through a file-stream on another thread,
// because seeking forwards works without a hitch, but seeking backwards tanks the framerate.
set_playback_seconds :: proc(seconds: f64) -> AudioError {
    if audio_context.current_music == nil {
        return {"", .SUCCESS}
    }

    seconds := max(0, seconds)

    decoder := &audio_context.current_music.decoder
    cursor := u64(seconds * f64(decoder.outputSampleRate))

    res := ma.decoder_seek_to_pcm_frame(decoder, cursor)
    if res != .SUCCESS {
        return {"Failed to seek to frame", res}
    }

    return {"", .SUCCESS}
}

get_duration_seconds :: proc() -> (f64, AudioError) {
    if audio_context.current_music == nil {
        return 0, {"", .SUCCESS}
    }

    decoder := &audio_context.current_music.decoder
    length: u64
    res := ma.decoder_get_length_in_pcm_frames(decoder, &length)
    if res != .SUCCESS {
        return 0, {"Failed to get decoder length", res}
    }

    return pcm_frames_to_seconds(decoder, length), {"", .SUCCESS}
}

new_music :: proc(filepath: cstring) -> (^Music, AudioError) {
    result: ma.result

    // NOTE: initializing this on the stack and then returning it with new_clone breaks this library, so we aren't doing that here
    music := new(Music)
    result = ma.decoder_init_file(filepath, nil, &music.decoder)
    if result != .SUCCESS {
        ma.decoder_uninit(&music.decoder)
        free(music)
        return nil, {"failed to decode file", result}
    }

    return music, {"", .SUCCESS}
}

free_music :: proc(music: ^Music) {
    if audio_context.current_music == music {
        set_playing(false)
        set_music(nil)
    }

    ma.decoder_uninit(&music.decoder)
    free(music)
}

is_playing :: proc() -> bool {
    return audio_context.is_playing
}
