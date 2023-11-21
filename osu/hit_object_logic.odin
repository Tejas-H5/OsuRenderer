package osu

import "core:math"


calculate_object_end_time :: proc(beatmap: ^Beatmap, hit_object_index: int) {
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

            if tp.time > hit_object.time {
                break
            }

            last_sv_index = i
        }
        if last_sv_index != -1 {
            sv = beatmap.timing_points[last_sv_index].sv
        }

        // get the most recent bpm. TODO: optimize
        bpm: f64 = 1
        last_bpm_index := -1
        for i in 0 ..< len(beatmap.timing_points) - 1 {
            tp := beatmap.timing_points[i]
            if tp.bpm < 0 {
                continue
            }

            if tp.time > hit_object.time {
                break
            }

            last_bpm_index = i
        }
        if last_bpm_index != -1 {
            bpm = beatmap.timing_points[last_bpm_index].bpm
        }

        sv_real := sv * 100 * f64(beatmap.SliderMultiplier)
        beat_length_real := 60 / bpm
        duration := (f64(hit_object.slider_length) / sv_real) * beat_length_real
        repeats := hit_object.slider_repeats

        beatmap.hit_objects[hit_object_index].end_time = hit_object.time + duration * f64(repeats)
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

    if current_time <= hit_object.time {
        t := min(1, max(0, (hit_object.time - current_time) / fade_in))
        return f32(math.lerp(one, zero, t))
    }

    end_time := hit_object.end_time
    if current_time <= end_time {
        return 1
    }

    t := min(1, max(0, (current_time - end_time) / fade_out))
    return f32(math.lerp(one, zero, t))
}
