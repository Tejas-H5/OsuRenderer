package main

import "core:math"
import "core:math/linalg"
import "osu"

PLAYFIELD_WIDTH :: 512
PLAYFIELD_HEIGHT :: 384

PLAYFIELD_CENTER :: osu.Vec2{PLAYFIELD_WIDTH / 2, PLAYFIELD_HEIGHT / 2}

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
    if beatmap_time < hit_object.start_time {
        return get_start_position_on_object(hit_object, circle_radius), false
    }

    if beatmap_time > hit_object.end_time {
        return get_end_position_on_object(hit_object, circle_radius), false
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

    return PLAYFIELD_CENTER, false
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
) -> (
    osu.Vec2,
    int,
) {
    hit_objects := beatmap.hit_objects

    default_pos := PLAYFIELD_CENTER
    if len(hit_objects) == 0 {
        return default_pos, 0
    }

    i, _ := beatmap_get_current_object(beatmap, t, seek_from)
    if i >= len(hit_objects) {
        i = len(hit_objects) - 1
    }

    curr := hit_objects[i]
    curr_pos := curr.start_position + osu.get_hit_object_stack_offset(curr, circle_radius)

    if t > curr.start_time && t < curr.end_time {
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
            return pos, i
        }

        return default_pos, i
    }

    if i == 0 && len(hit_objects) > 0 {
        return curr_pos, i
    }

    if i > 0 {
        prev := hit_objects[i - 1]
        if t >= prev.end_time && t <= curr.start_time {
            prev_pos := get_end_position_on_object(prev, circle_radius)
            curr_pos := get_start_position_on_object(curr, circle_radius)

            t := inv_lerp(prev.end_time, curr.start_time, t)
            return linalg.lerp(prev_pos, curr_pos, f32(t)), i
        }
    }

    return default_pos, i
}


// 0.008 s = 120fps
AI_REPLAY_DT :: 0.008
AIReplay :: struct {
    replay:              [dynamic]osu.Vec2,
    replay_seek_from:    int,
    last_object_started: int,
}

get_replay_duration :: proc(replay: [dynamic]osu.Vec2) -> f64 {
    return f64(len(replay)) * AI_REPLAY_DT
}

CursorMotionStragetgyProc ::
    (proc(
            ai_replay: ^AIReplay,
            beatmap: ^osu.Beatmap,
            t: f64,
            slider_path_buffer, slider_path_buffer_temp: ^[dynamic]osu.Vec2,
            last_generated_slider: ^int,
            circle_radius: f32,
            seek_from: int,
        ) -> osu.Vec2)

// this is my recreation of what I think the AUTO mod is doing.
get_cursor_pos_for_replay_ai :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
    slider_path_buffer, slider_path_buffer_temp: ^[dynamic]osu.Vec2,
    last_generated_slider: ^int,
    circle_radius: f32,
    seek_from: int,
    cursor_motion_strategy: (CursorMotionStragetgyProc),
) -> osu.Vec2 {
    if len(beatmap.hit_objects) == 0 {
        return PLAYFIELD_CENTER
    }

    // TODO: optimize
    for AI_REPLAY_DT * f64(ai_replay.replay_seek_from) < t {
        ai_replay.replay_seek_from += 1
    }

    // TODO: optimize
    for AI_REPLAY_DT * f64(ai_replay.replay_seek_from) > t {
        ai_replay.replay_seek_from -= 1
    }


    // generate the rest of the replay as needed. if we have already generated what we need, then 
    // this just gets skipped. This is the only way to make a seekable physics-based replay (that I could think of)
    for i := len(ai_replay.replay); i < ai_replay.replay_seek_from + 2; i += 1 {
        if i == 0 {
            first_object := beatmap.hit_objects[0]
            first_pos := get_start_position_on_object(first_object, circle_radius)
            append(&ai_replay.replay, first_pos)
            continue
        }

        t_i := f64(i) * AI_REPLAY_DT
        ai_replay.last_object_started = osu.beatmap_get_last_visible(
            beatmap,
            t_i,
            ai_replay.last_object_started,
        )

        next_point := cursor_motion_strategy(
            ai_replay,
            beatmap,
            t_i,
            slider_path_buffer,
            slider_path_buffer_temp,
            last_generated_slider,
            circle_radius,
            ai_replay.last_object_started,
        )

        append(&ai_replay.replay, next_point)
    }

    if (len(ai_replay.replay) == 0) {
        return PLAYFIELD_CENTER
    }

    if (len(ai_replay.replay) == 1) {
        return ai_replay.replay[0]
    }

    if ai_replay.replay_seek_from >= len(ai_replay.replay) {
        ai_replay.replay_seek_from = len(ai_replay.replay) - 1
    }

    if ai_replay.replay_seek_from < 0 {
        ai_replay.replay_seek_from = 0
    }

    lerp_t := inv_lerp(
        AI_REPLAY_DT * f64(ai_replay.replay_seek_from),
        AI_REPLAY_DT * f64(ai_replay.replay_seek_from + 1),
        t,
    )

    return linalg.lerp(
        ai_replay.replay[ai_replay.replay_seek_from],
        ai_replay.replay[ai_replay.replay_seek_from + 1],
        f32(lerp_t),
    )
}


reset_ai_replay :: proc(ai_replay: ^AIReplay) {
    clear(&ai_replay.replay)
    ai_replay.replay_seek_from = 0
    ai_replay.last_object_started = 0
}

ai_replay_last_pos :: proc(ai_replay: ^AIReplay) -> osu.Vec2 {
    return ai_replay.replay[len(ai_replay.replay) - 1]
}

cursor_motion_strategy_automod :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
    slider_path_buffer, slider_path_buffer_temp: ^[dynamic]osu.Vec2,
    last_generated_slider: ^int,
    circle_radius: f32,
    seek_from: int,
) -> osu.Vec2 {
    // doesn't need a history of points to extrapolate itself, so it is very nice in that sense
    pos, _ := get_cursor_pos_automod_ai(
        beatmap,
        t,
        slider_path_buffer,
        slider_path_buffer_temp,
        last_generated_slider,
        circle_radius,
        seek_from,
    )

    return pos
}

// dont move from a particular spot unless we are going to stray too far away from automod.
// The logic is very similar to how Blender's smooth stroke brush works
cursor_strategy_lazy_position :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
    slider_path_buffer, slider_path_buffer_temp: ^[dynamic]osu.Vec2,
    last_generated_slider: ^int,
    circle_radius: f32,
    seek_from: int,
) -> osu.Vec2 {
    required_position, idx := get_cursor_pos_automod_ai(
        beatmap,
        t,
        slider_path_buffer,
        slider_path_buffer_temp,
        last_generated_slider,
        circle_radius,
        seek_from,
    )

    current_position := ai_replay_last_pos(ai_replay)

    SLACK :: 0.75
    SLIDER_SLACK :: 1.5

    // only move if we have to, and only move as little as we need to
    max_allowable_distance := (circle_radius * SLACK)

    // the allowable distance should be larger when we are tracking a slider ball.
    // we also need to make this distance expand and then shrink back down in a continuous curve rather than a sudden step, so
    // that the replay will be a continuous path without any sudden jumps
    if idx > 0 && idx < len(beatmap.hit_objects) {
        current_object := beatmap.hit_objects[idx]
        if current_object.type == .Slider &&
           current_object.start_time < t &&
           current_object.end_time > t {
            fade_in :: 0.05
            lerp_t := fade_in_fade_out_curve(
                current_object.start_time,
                current_object.end_time,
                t,
                fade_in,
                fade_in,
            )

            max_allowable_distance = math.lerp(
                (circle_radius * SLACK),
                (circle_radius * SLIDER_SLACK),
                f32(lerp_t),
            )
        }
    }

    dir := current_position - required_position
    dir_len := linalg.length(dir)

    if dir_len < 0.1 {
        // also, dir_len==0 causes all sorts of nan issues when normalizing
        return current_position
    }

    if dir_len < max_allowable_distance {
        // move a little closer to the center, while we're here
        CENTER_SPEED :: 15
        new_dir_len := move_towards(dir_len, 0, CENTER_SPEED * AI_REPLAY_DT)
        return required_position + (linalg.normalize(dir) * new_dir_len)
    }

    return required_position + (linalg.normalize(dir) * max_allowable_distance)
}


// cling to the current position with a large yet finite amount of force
cursor_strategy_spring_joint :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
    slider_path_buffer, slider_path_buffer_temp: ^[dynamic]osu.Vec2,
    last_generated_slider: ^int,
    circle_radius: f32,
    seek_from: int,
) -> osu.Vec2 {
    required_position, idx := get_cursor_pos_automod_ai(
        beatmap,
        t,
        slider_path_buffer,
        slider_path_buffer_temp,
        last_generated_slider,
        circle_radius,
        seek_from,
    )

    current_position := ai_replay_last_pos(ai_replay)

    // TODO


    return current_position
}
