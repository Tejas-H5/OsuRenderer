package osu

import "../af"
import "core:math"

recalculate_object_end_time :: proc(beatmap: ^Beatmap, hit_object_index: int) {
    hit_object := beatmap.hit_objects[hit_object_index]

    if hit_object.type == .Slider {
        // get the most recent sv and bpm
        // TODO: optimize. the recalculate_object_end_time should just take in the SV and BPM to use,
        // Which should make the use-case of recalculating all objects in a for-loop faster
        sv: f64 = 1
        bpm: f64 = 120
        found_bpm := false
        for tp in beatmap.timing_points {
            if tp.time > hit_object.start_time {
                break
            }

            if tp.is_bpm_change == 1 {
                found_bpm = true
                bpm = tp.bpm
                sv = 1
            } else {
                sv = tp.sv
            }
        }

        if !found_bpm {
            af.debug_warning("beatmaps must have at least 1 bpm timing point to be valid")
        }

        beat_length_real := f64(60 / bpm)

        duration :=
            f64(hit_object.slider_length) /
            (sv * 100 * f64(beatmap.SliderMultiplier)) *
            beat_length_real
            
        repeats := hit_object.slider_repeats

        beatmap.hit_objects[hit_object_index].bpm = bpm
        beatmap.hit_objects[hit_object_index].sv = sv
        beatmap.hit_objects[hit_object_index].sm = f64(beatmap.SliderMultiplier)
        beatmap.hit_objects[hit_object_index].end_time =
            hit_object.start_time + duration * f64(repeats)
    }
}

recalculate_object_end_position :: proc(beatmap: ^Beatmap, i: int, slider_lod: f32) {
    hit_object := beatmap.hit_objects[i]
    switch hit_object.type {
    case .Spinner:
        beatmap.hit_objects[i].start_position_unstacked = {-100, -100}
        beatmap.hit_objects[i].end_position_unstacked = {-100, -100}
    case .Slider:
        end_pos := beatmap.hit_objects[i].start_position_unstacked
        if len(hit_object.slider_path) != 0 {
            // some maps have zero length sliders, apparently
            end_pos = hit_object.slider_path[len(hit_object.slider_path) - 1]
        }

        beatmap.hit_objects[i].end_position_unstacked = end_pos
    case .Circle:
        beatmap.hit_objects[i].end_position_unstacked =
            beatmap.hit_objects[i].start_position_unstacked
    }
}


inv_lerp_f64 :: proc(a, b, val: f64) -> (f64, bool) {
    in_range := a <= val && val <= b
    if !in_range {
        return 0, false
    }

    return (val - a) / (b - a), true
}

// call calculate_object_end_time on the object at least once beforehand
calculate_opacity :: proc(
    beatmap: ^Beatmap,
    start_time, end_time, current_time: f64,
    preempt: f64,
    fade_in, fade_out: f64,
) -> f32 {
    zero: f64 = 0
    one: f64 = 1

    fade_in_start := start_time - preempt
    fade_in_end := start_time - preempt + fade_in

    t: f64
    ok: bool
    t, ok = inv_lerp_f64(fade_in_start, fade_in_end, current_time)
    if ok {
        return f32(math.lerp(zero, one, t))
    }

    fade_out_start := end_time
    fade_out_end := end_time + fade_out

    if fade_in_end <= current_time && current_time <= fade_out_start {
        return 1
    }

    t, ok = inv_lerp_f64(fade_out_start, fade_out_end, current_time)
    if ok {
        return f32(math.lerp(one, zero, t))
    }

    return 0
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
        hit_object.slider_length,
        lod,
    )
}
