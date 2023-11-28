package osu

import "../af"
import "core:math"

slider_path_buffer_temp := [dynamic]af.Vec2{}

recalculate_object_end_time :: proc(beatmap: ^Beatmap, hit_object_index: int) {
    hit_object := beatmap.hit_objects[hit_object_index]

    if hit_object.type == .Slider {
        // get the most recent sv. TODO: optimize
        sv: f64 = 1
        last_sv_index := -1
        for i in 0 ..< len(beatmap.timing_points) - 1 {
            tp := beatmap.timing_points[i]
            if tp.is_bpm_change == 1 {
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
            if tp.is_bpm_change != 1 {
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

recalculate_object_end_position :: proc(beatmap: ^Beatmap, i: int, slider_lod: f32) {
    hit_object := beatmap.hit_objects[i]
    switch hit_object.type {
    case .Spinner:
        beatmap.hit_objects[i].start_position = {-100, -100}
        beatmap.hit_objects[i].end_position = {-100, -100}
    case .Slider:
        beatmap.hit_objects[i].end_position =
            hit_object.slider_path[len(hit_object.slider_path) - 1]
    case .Circle:
        beatmap.hit_objects[i].end_position = beatmap.hit_objects[i].start_position
    }
}

// call calculate_object_end_time on the object at least once beforehand
calculate_opacity :: proc(
    beatmap: ^Beatmap,
    hit_object: HitObject,
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

recalculate_combo_numbers :: proc(beatmap: ^Beatmap, starting_from: int) {
    hit_objects := beatmap.hit_objects

    i := beatmap_get_new_combo_start(beatmap, starting_from)
    current_number := 1
    for ; i < len(hit_objects); i += 1 {
        if hit_object_is_new_combo(hit_objects[i]) {
            current_number = 1
        }
        hit_objects[i].combo_number = current_number
        current_number += 1
    }
}

// recalculates the following for objects:
//  end_position
//  end_time
recalculate_object_values :: proc(beatmap: ^Beatmap, hit_object_index: int, slider_lod: f32) {
    recalculate_combo_numbers(beatmap, 0)
    recalculate_object_end_time(beatmap, hit_object_index)
    recalculate_object_end_position(beatmap, hit_object_index, slider_lod)
}

recalculate_slider_path :: proc(beatmap: ^Beatmap, hit_object_index: int, lod: f32) {
    hit_object := &beatmap.hit_objects[hit_object_index]
    if hit_object.type != .Slider {
        return
    }

    generate_slider_path(
        hit_object.slider_nodes,
        &hit_object.slider_path,
        &slider_path_buffer_temp,
        hit_object.slider_length,
        lod,
    )
}
