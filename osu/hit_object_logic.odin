package osu

import "../af"
import "core:math"


recalculate_object_end_time :: proc(beatmap: ^Beatmap, hit_object_index: int) {
    hit_object := beatmap.hit_objects[hit_object_index]

    if hit_object.type == .Slider {
        // get the most recent sv. TODO: optimize
        sv: f64 = 1
        last_sv_index := -1
        for i in 0 ..< len(beatmap.timing_points) - 1 {
            tp := beatmap.timing_points[i]
            if tp.bpm > 0 {
                continue
            }

            if tp.time > hit_object.start_time {
                break
            }

            last_sv_index = i
        }
        if last_sv_index != -1 {
            sv = beatmap.timing_points[last_sv_index].sv
        }

        // get the most recent bpm. TODO: optimize
        bpm: f64 = 120
        last_bpm_index := -1
        for i in 0 ..< len(beatmap.timing_points) - 1 {
            tp := beatmap.timing_points[i]
            if tp.bpm < 0 {
                continue
            }

            if tp.time > hit_object.start_time && last_bpm_index != -1 {
                break
            }

            last_bpm_index = i
        }
        if last_bpm_index == -1 {
            af.debug_warning("beatmaps must have at least 1 bpm timing point to be valid")
        }
        if last_bpm_index != -1 {
            bpm = beatmap.timing_points[last_bpm_index].bpm
        }

        sv_real := sv * 100 * f64(beatmap.SliderMultiplier)
        beat_length_real := 60 / bpm
        duration := (f64(hit_object.slider_length) / sv_real) * beat_length_real
        repeats := hit_object.slider_repeats

        beatmap.hit_objects[hit_object_index].end_time =
            hit_object.start_time + duration * f64(repeats)
    }
}

recalculate_object_end_position :: proc(
    beatmap: ^Beatmap,
    i: int,
    slider_path_buffer_main, slider_path_buffer_temp: ^[dynamic]Vec2,
    slider_lod: f32,
) {
    hit_object := beatmap.hit_objects[i]
    switch hit_object.type {
    case .Spinner:
        beatmap.hit_objects[i].position = {-100, -100}
        beatmap.hit_objects[i].end_position = {-100, -100}
    case .Slider:
        generate_slider_path(
            hit_object.slider_nodes,
            slider_path_buffer_main,
            slider_path_buffer_temp,
            hit_object.slider_length,
            slider_lod,
        )

        if len(slider_path_buffer_main) > 0 {
            beatmap.hit_objects[i].end_position =
                slider_path_buffer_main[len(slider_path_buffer_main) - 1]
        }
    case .Circle:
        beatmap.hit_objects[i].end_position = beatmap.hit_objects[i].position
    }
}

// call calculate_object_end_time on the object at least once beforehand
calculate_opacity :: proc(
    hit_object: HitObject,
    beatmap: ^Beatmap,
    current_time, fade_in, fade_out: f64,
) -> f32 {
    zero: f64 = 0
    one: f64 = 1

    if current_time <= hit_object.start_time {
        t := min(1, max(0, (hit_object.start_time - current_time) / fade_in))
        return f32(math.lerp(one, zero, t))
    }

    end_time := hit_object.end_time
    if current_time <= end_time {
        return 1
    }

    t := min(1, max(0, (current_time - end_time) / fade_out))
    return f32(math.lerp(one, zero, t))
}

// recalculates the following for objects:
//  end_position
//  end_time
recalculate_object_values :: proc(
    beatmap: ^Beatmap,
    hit_object_index: int,
    slider_path_buffer_main, slider_path_buffer_temp: ^[dynamic]Vec2,
    slider_lod: f32,
) {
    recalculate_object_end_time(beatmap, hit_object_index)
    recalculate_object_end_position(
        beatmap,
        hit_object_index,
        slider_path_buffer_main,
        slider_path_buffer_temp,
        slider_lod,
    )
}
