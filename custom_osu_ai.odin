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


get_position_on_object :: proc(
    hit_object: osu.HitObject,
    beatmap_time: f64,
    circle_radius: f32,
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
        pos, _, _ := osu.get_slider_ball_pos(hit_object, beatmap_time)
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
get_expected_cursor_pos :: proc(
    beatmap: ^osu.Beatmap,
    t: f64,
    circle_radius: f32,
    seek_from: int,
    should_lerp_between_objects: bool = true,
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

    if curr.start_time <= t && t <= curr.end_time {
        pos, ok := get_position_on_object(curr, t, circle_radius)
        if ok {
            return pos, i
        }

        return default_pos, i
    }

    if i == 0 {
        return curr_pos, i
    }

    prev := hit_objects[i - 1]
    if prev.end_time <= t && t <= curr.start_time {
        if should_lerp_between_objects {
            prev_pos := get_end_position_on_object(prev, circle_radius)
            curr_pos := get_start_position_on_object(curr, circle_radius)

            t := inv_lerp(prev.end_time, curr.start_time, t)
            return linalg.lerp(prev_pos, curr_pos, f32(t)), i
        }

        return curr_pos, i
    }

    return default_pos, i
}


// 0.008 s = 120fps
AI_REPLAY_DT :: 0.008
AIReplay :: struct {
    replay:              [dynamic]osu.Vec2,
    replay_seek_from:    int,
    last_object_started: int,

    // only used by functions that are physics-based.
    velocity:            osu.Vec2,
    max_accel:           f32,
}

get_replay_duration :: proc(replay: [dynamic]osu.Vec2) -> f64 {
    return f64(len(replay)) * AI_REPLAY_DT
}

CursorMotionStragetgyProc ::
    (proc(
            ai_replay: ^AIReplay,
            beatmap: ^osu.Beatmap,
            t: f64,
            circle_radius: f32,
            seek_from: int,
        ) -> osu.Vec2)

get_ai_replay_cursor_pos :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
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
    ai_replay.velocity = {}
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
    circle_radius: f32,
    seek_from: int,
) -> osu.Vec2 {
    // doesn't need a history of points to extrapolate itself, so it is very nice in that sense
    pos, _ := get_expected_cursor_pos(
        beatmap,
        t,
        circle_radius,
        seek_from,
        should_lerp_between_objects = true,
    )

    return pos
}


// dont move from a particular spot unless we are going to stray too far away from automod.
// The logic is very similar to how Blender's smooth stroke brush works
cursor_strategy_lazy_position :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
    circle_radius: f32,
    seek_from: int,
) -> osu.Vec2 {
    pos, _ := get_cursor_pos_smoothed_automod_ai(
        ai_replay,
        beatmap,
        t,
        circle_radius,
        seek_from,
        0.7,
        2,
    )
    return pos
}

// dont move from a particular spot unless we are going to stray too far away from automod.
// The logic is very similar to how Blender's smooth stroke brush works
get_cursor_pos_smoothed_automod_ai :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
    circle_radius: f32,
    seek_from: int,
    circle_slack, slider_slack: f32,
    should_lerp_between_objects := true,
) -> (
    osu.Vec2,
    int,
) {
    required_position, idx := get_expected_cursor_pos(
        beatmap,
        t,
        circle_radius,
        seek_from,
        should_lerp_between_objects = should_lerp_between_objects,
    )

    current_position := ai_replay_last_pos(ai_replay)

    dir := current_position - required_position
    dir_len := linalg.length(dir)

    // only move if we have to, and only move as little as we need to
    max_allowable_dir_len := (circle_radius * circle_slack)

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

            max_allowable_dir_len = math.lerp(
                (circle_radius * circle_slack),
                (circle_radius * slider_slack),
                f32(lerp_t),
            )
        }
    }

    if dir_len < 0.1 {
        // also, dir_len==0 causes all sorts of nan issues when normalizing
        return current_position, idx
    }

    if dir_len < max_allowable_dir_len {
        // move a little closer to the center, while we're here
        CENTER_SPEED :: 15
        new_dir_len := move_towards(dir_len, 0, CENTER_SPEED * AI_REPLAY_DT)
        return required_position + (linalg.normalize(dir) * new_dir_len), idx
    }

    return required_position + (linalg.normalize(dir) * max_allowable_dir_len), idx
}


// Accelerate to the current position with a large yet finite amount of force.
// still needs some polishing imo, but looks quite realistic as it is purely physics-sim based
cursor_strategy_physical_accelerator :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
    circle_radius: f32,
    seek_from: int,
) -> osu.Vec2 {
    hit_objects := beatmap.hit_objects

    // This is a hack to get 32x more delta-time resolution without saving 32 more frames per replay.
    // It is extremely effective
    ITERATIONS :: 32
    real_dt: f32 = AI_REPLAY_DT / ITERATIONS
    current_pos := ai_replay_last_pos(ai_replay)

    for i in 0 ..< ITERATIONS {

        if len(hit_objects) == 0 {
            return PLAYFIELD_CENTER
        }

        i, _ := beatmap_get_current_object(beatmap, t, seek_from)
        if i >= len(hit_objects) {
            i = len(hit_objects) - 1
        }

        target_pos, next_target_pos: osu.Vec2
        time_to_target, time_to_next_target: f32
        next_target_handled := false
        if hit_objects[i].start_time <= t && t <= hit_objects[i].end_time {
            // we are on a slider or a spinner

            SLIDER_LOOKAHEAD :: 0.1

            target_pos, _ = get_position_on_object(
                hit_objects[i],
                t + SLIDER_LOOKAHEAD,
                circle_radius,
            )
            time_to_target = SLIDER_LOOKAHEAD

            ok: bool

            next_target_pos, ok = get_position_on_object(
                hit_objects[i],
                t + SLIDER_LOOKAHEAD * 2,
                circle_radius,
            )
            if ok {
                next_target_handled = true
                time_to_next_target = SLIDER_LOOKAHEAD
            }
        } else {
            // we are on a circle
            target_pos = get_start_position_on_object(hit_objects[i], circle_radius)
            time_to_target = f32(hit_objects[i].start_time - t)
        }

        if !next_target_handled {
            if i + 1 < len(hit_objects) {
                next_target_pos = get_start_position_on_object(hit_objects[i + 1], circle_radius)
            } else {
                HARDCODED_TIME :: 0.5
                next_target_pos = PLAYFIELD_CENTER
                time_to_next_target = f32(hit_objects[len(hit_objects) - 1].end_time + 0.5 - t)
            }
        }

        accel := get_cursor_acceleration(
            current_pos,
            ai_replay.velocity,
            target_pos,
            next_target_pos,
            time_to_target,
            time_to_next_target,
            ai_replay.max_accel,
            use_dynamic_axis = false,
            braking_distance_overestimate_factor = 1,
        )

        integrate_motion(&ai_replay.velocity, &current_pos, accel, real_dt)
    }

    return current_pos
}

integrate_motion :: proc(vel, pos: ^osu.Vec2, accel: osu.Vec2, dt: f32) {
    vel^ += accel * dt
    pos^ += vel^ * dt
    vel^ += accel * dt
}


// TODO: right now our axes are the x and y global. But we could just as easily use a coordinate system that is aligned with 
// pos->target, right?
get_cursor_acceleration :: proc(
    pos, velocity: osu.Vec2,
    target, next_target: osu.Vec2,
    time_to_target, time_to_next_target: f32,
    max_accel: f32,
    use_dynamic_axis: bool,
    braking_distance_overestimate_factor: f32,
) -> osu.Vec2 {
    axis_1 := osu.Vec2{1, 0}
    dynamic_axis := next_target - target
    if use_dynamic_axis && linalg.length(dynamic_axis) > 0.0001 {
        axis_1 = linalg.normalize(dynamic_axis)
    }

    axis_2 := osu.Vec2{-axis_1.y, axis_1.x}

    a1 := get_cursor_acceleration_axis(
        pos,
        velocity,
        target,
        next_target,
        time_to_target,
        time_to_next_target,
        axis_1,
        max_accel,
        braking_distance_overestimate_factor,
    )
    a2 := get_cursor_acceleration_axis(
        pos,
        velocity,
        target,
        next_target,
        time_to_target,
        time_to_next_target,
        axis_2,
        max_accel,
        braking_distance_overestimate_factor,
    )
    a_vec := a1 * axis_1 + a2 * axis_2

    // af.set_draw_color({1, 1, 0, 1})
    // af.draw_line(af.im, pos, pos + (a1 * axis_1), 10, .None)
    // af.draw_line(af.im, pos, pos + (a2 * axis_2), 10, .None)

    return a_vec

    get_cursor_acceleration_axis :: proc(
        pos, velocity: osu.Vec2,
        target, next_target: osu.Vec2,
        time_to_target, time_to_next_target: f32,
        axis: osu.Vec2,
        max_accel: f32,
        braking_distance_overestimate_factor: f32,
    ) -> f32 {
        s := linalg.dot(pos, axis)
        s1 := linalg.dot(target, axis)
        s2 := linalg.dot(next_target, axis)
        v := linalg.dot(velocity, axis)

        accel_constant_accel :: proc(s, v0, t: f32) -> f32 {
            return 2 * (s - v0 * t) / (t * t)
        }

        dist := s1 - s
        max_accel := max_accel
        if time_to_target > 0.01 {
            // max_accel = min(max_accel, abs(accel_constant_accel(dist, v, time_to_target)))
            max_accel = abs(accel_constant_accel(dist, v, time_to_target))
        }
        accel_sign := math.sign(dist)
        accel := accel_sign * max_accel
        rt1, rt2 := quadratic_equation(0.5 * accel, v, -dist)
        time_remaining_with_full_accel := max(rt1, rt2)

        // A reminder that * is just 1-dimensional dot product, and that dot(normal_vector, other_vec) 
        // is the distance of other_vec projected onto normal_vector.
        // This eliminates a lot of sign-based branching code like: `if (accel > 0 && dist > 0) || (accel < 0 && dist < 0) {` for example.
        if accel * dist > 0 {
            decel := -accel_sign * max_accel

            wanted_end_velocity: f32 = 0
            dist_to_next := s2 - s1
            if dist * dist_to_next > 0 {
                // they are in a line. we don't need to slow all the way down, we can slow to a constant velocity.
                // TODO: implement flow-aim code, wanted_end_velocity = dist_to_next / (p2_t - p1_t)
            }

            braking_time :=
                braking_distance_overestimate_factor * abs(v - wanted_end_velocity) / abs(decel)
            distance_constant_accel :: proc(a, v0, t: f32) -> f32 {
                t := abs(t)
                return 0.5 * a * t * t + v0 * t
            }

            braking_distance := distance_constant_accel(decel, v, braking_time)
            TOLERANCE :: 10
            if (dist < 0 && braking_distance - TOLERANCE <= dist) ||
               (dist > 0 && braking_distance + TOLERANCE >= dist) {
                return decel
            }

            return accel
        }

        return accel
    }
}
