package main

import "core:math"
import "core:math/linalg"
import "osu"

PLAYFIELD_WIDTH :: 512
PLAYFIELD_HEIGHT :: 384

// get the current object the player is supposed to be moving towards or interacting with.
// TODO: the second index should return other clickable objects along a slider for 2b maps
beatmap_get_current_object :: proc(beatmap: ^osu.Beatmap, t: f64, seek_from: int) -> (int, int) {
    hit_objects := beatmap.hit_objects
    for i in seek_from ..< len(hit_objects) {
        if hit_objects[i].end_time < t {
            continue
        }

        return i, -1
    }

    return len(hit_objects), -1
}

get_spinner_angle :: proc(hit_object: osu.HitObject, beatmap_time: f64) -> f32 {
    elapsed := beatmap_time - hit_object.start_time
    total := hit_object.end_time - hit_object.start_time

    RPM :: 477
    return f32(RPM / 60 * min(elapsed, total)) * math.TAU
}

get_spinner_cursor_pos :: proc(angle: f32) -> osu.Vec2 {
    spin_radius :: 100

    center := osu.Vec2{PLAYFIELD_WIDTH / 2, PLAYFIELD_HEIGHT / 2}
    return center + angle_vec(angle, spin_radius)
}

// assumes that you've already generated the slider path using generate_slider_path as needed.
// try to avoid regenreating comlex sliders over and over again
get_position_on_object :: proc(
    hit_object: osu.HitObject,
    beatmap_time: f64,
    circle_radius: f32,
    slider_path_buffer: ^[dynamic]osu.Vec2,
) -> (
    osu.Vec2,
    bool,
) {
    if beatmap_time < hit_object.start_time || beatmap_time > hit_object.end_time {
        return {}, false
    }

    stack_offset := osu.get_hit_object_stack_offset(hit_object, circle_radius)

    switch hit_object.type {
    case .Circle:
        return hit_object.start_position + stack_offset, true
    case .Spinner:
        angle := get_spinner_angle(hit_object, beatmap_time)
        return get_spinner_cursor_pos(angle), true
    case .Slider:
        pos, _, _ := osu.get_slider_ball_pos(slider_path_buffer^, hit_object, beatmap_time)
        return pos + stack_offset, true
    }

    return {}, false
}

get_start_position_on_object :: proc(hit_object: osu.HitObject, circle_radius: f32) -> osu.Vec2 {
    stack_offset := osu.get_hit_object_stack_offset(hit_object, circle_radius)

    switch hit_object.type {
    case .Circle, .Slider:
        return hit_object.start_position + stack_offset
    case .Spinner:
        angle := get_spinner_angle(hit_object, hit_object.start_time)
        return get_spinner_cursor_pos(angle)
    }

    return {}
}


get_end_position_on_object :: proc(hit_object: osu.HitObject, circle_radius: f32) -> osu.Vec2 {
    stack_offset := osu.get_hit_object_stack_offset(hit_object, circle_radius)

    switch hit_object.type {
    case .Circle:
        return hit_object.end_position + stack_offset
    case .Slider:
        if hit_object.slider_repeats % 2 == 1 {
            return hit_object.end_position + stack_offset
        } else {
            return hit_object.start_position + stack_offset
        }
    case .Spinner:
        angle := get_spinner_angle(hit_object, hit_object.end_time)
        return get_spinner_cursor_pos(angle)
    }

    return {}
}


// this is my recreation of what I think the AUTO mod is doing.
get_cursor_pos_automod_ai :: proc(
    beatmap: ^osu.Beatmap,
    t: f64,
    slider_path_buffer, slider_path_buffer_temp: ^[dynamic]osu.Vec2,
    last_generated_slider: ^int,
    circle_radius: f32,
    seek_from: int,
) -> osu.Vec2 {
    hit_objects := beatmap.hit_objects

    default_pos := osu.Vec2{PLAYFIELD_WIDTH / 2, PLAYFIELD_HEIGHT / 2}
    if len(hit_objects) == 0 {
        return default_pos
    }

    i, _ := beatmap_get_current_object(beatmap, t, seek_from)
    if i >= len(hit_objects) {
        i = len(hit_objects) - 1
    }

    curr := hit_objects[i]
    curr_pos := curr.start_position + osu.get_hit_object_stack_offset(curr, circle_radius)

    isBetweenObjects := i > 0 && t > curr.start_time
    if isBetweenObjects {
        if curr.type == .Slider && last_generated_slider^ != i {
            osu.generate_slider_path(
                curr.slider_nodes,
                slider_path_buffer,
                slider_path_buffer_temp,
                curr.slider_length,
                SLIDER_LOD,
            )

            last_generated_slider^ = i
        }

        pos, ok := get_position_on_object(curr, t, circle_radius, slider_path_buffer)

        if ok {
            return pos
        }

        return default_pos
    }

    if i == 0 && len(hit_objects) > 0 {
        return curr_pos
    }

    if i > 0 {
        prev := hit_objects[i - 1]
        if t >= prev.end_time && t <= curr.start_time {
            prev_pos := get_end_position_on_object(prev, circle_radius)
            curr_pos := get_start_position_on_object(curr, circle_radius)

            t := inv_lerp(prev.end_time, curr.start_time, t)
            return linalg.lerp(prev_pos, curr_pos, f32(t))
        }
    }

    return default_pos
}


analyze_ai :: proc() {

}
