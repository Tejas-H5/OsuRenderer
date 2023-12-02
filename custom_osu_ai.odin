package main

import "af"
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

    switch hit_object.type {
    case .Circle:
        return get_start_position_on_object(hit_object, circle_radius), false
    case .Spinner:
        angle := get_spinner_angle(hit_object, beatmap_time)
        return get_spinner_cursor_pos(angle), true
    case .Slider:
        stack_offset := osu.get_hit_object_stack_offset(hit_object, circle_radius)
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
    replay:              [dynamic]OsuPlayerInput,
    replay_seek_from:    int,
    last_object_started: int,

    // only used by functions that are physics-based.
    velocity:            osu.Vec2,
    accel_params:        AccelParams,
}


AccelParams :: struct {
    max_accel_circle:     f32,
    max_accel_slider:     f32,
    use_max_accel:        bool,
    overshoot_multuplier: f32,
    axis_count:           int,
    stop_distance:        f32,
    lazy_factor_circle:   f32,
    lazy_factor_slider:   f32,

    // computed
    stop_distance_rad:    f32,
    max_accel:            f32,
}


get_replay_duration :: proc(replay: [dynamic]osu.Vec2) -> f64 {
    return f64(len(replay)) * AI_REPLAY_DT
}

OsuPlayerInput :: struct {
    left_click:  bool,
    right_click: bool,
    pos:         af.Vec2,
}

OsuAIMovementProc ::
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
    movement_fn: (OsuAIMovementProc),
) -> OsuPlayerInput {
    if len(beatmap.hit_objects) == 0 {
        return {pos = PLAYFIELD_CENTER}
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
            append(&ai_replay.replay, OsuPlayerInput{pos = first_pos})
            continue
        }

        t_i := f64(i) * AI_REPLAY_DT
        ai_replay.last_object_started = osu.beatmap_get_last_visible(
            beatmap,
            t_i,
            ai_replay.last_object_started,
        )

        next_point := movement_fn(
            ai_replay,
            beatmap,
            t_i,
            circle_radius,
            ai_replay.last_object_started,
        )

        // TODO: left_click, right_click
        input := OsuPlayerInput {
            pos = next_point,
        }

        append(&ai_replay.replay, input)
    }

    if (len(ai_replay.replay) == 0) {
        return {pos = PLAYFIELD_CENTER}
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

    res := ai_replay.replay[ai_replay.replay_seek_from]
    p1 := ai_replay.replay[ai_replay.replay_seek_from + 1].pos

    res.pos = linalg.lerp(res.pos, p1, f32(lerp_t))
    return res
}


reset_ai_replay :: proc(ai_replay: ^AIReplay) {
    clear(&ai_replay.replay)
    ai_replay.velocity = {}
    ai_replay.replay_seek_from = 0
    ai_replay.last_object_started = 0
}

ai_replay_last_pos :: proc(ai_replay: ^AIReplay) -> osu.Vec2 {
    return ai_replay.replay[len(ai_replay.replay) - 1].pos
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
        return required_position + (linalg.normalize0(dir) * new_dir_len), idx
    }

    return required_position + (linalg.normalize0(dir) * max_allowable_dir_len), idx
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
        target_handled, next_target_handled: bool
        slider_aim: bool
        if hit_objects[i].start_time <= t && t <= hit_objects[i].end_time {
            ok: bool
            target_pos, next_target_pos, ok = get_target_positions(
                hit_objects[i],
                t,
                circle_radius,
            )
            if ok {
                target_handled = true
                next_target_handled = true
                if hit_objects[i].type == .Slider {
                    slider_aim = true
                }
            } else {
                i += 1
            }

            get_target_positions :: proc(
                hit_object: osu.HitObject,
                t: f64,
                circle_radius: f32,
            ) -> (
                osu.Vec2,
                osu.Vec2,
                bool,
            ) {
                if hit_object.type == .Spinner {
                    pos_on_spinner, _ := get_position_on_object(hit_object, t, circle_radius)
                    next_pos_on_spinner, ok := get_position_on_object(hit_object, t, circle_radius)
                    if !ok {
                        next_pos_on_spinner = get_end_position_on_object(hit_object, circle_radius)
                    }

                    return pos_on_spinner, next_pos_on_spinner, true
                }

                if hit_object.type != .Slider {
                    return {}, {}, false
                }

                SLIDER_LENIENCY_SECONDS :: 0.01

                next_pos_on_slider, has_next_pos_on_slider := get_position_on_object(
                    hit_object,
                    t + SLIDER_LENIENCY_SECONDS,
                    circle_radius,
                )

                if !has_next_pos_on_slider {
                    return {}, {}, false
                }

                pos_on_slider, _ := get_position_on_object(hit_object, t, circle_radius)
                if !has_next_pos_on_slider {
                    next_pos_on_slider = get_end_position_on_object(hit_object, circle_radius)
                }

                return pos_on_slider, next_pos_on_slider, true
            }
        }

        if i >= len(hit_objects) {
            i = len(hit_objects) - 1
        }

        if !target_handled {
            // we are on a circle
            target_pos = get_start_position_on_object(hit_objects[i], circle_radius)
            time_to_target = f32(hit_objects[i].start_time - t)
        }

        if !next_target_handled && i < len(hit_objects) - 1 {
            next_target_pos = get_start_position_on_object(hit_objects[i + 1], circle_radius)
        }

        ai_replay.accel_params.stop_distance_rad =
            circle_radius * ai_replay.accel_params.stop_distance

        SLIDER_ACCEL_FADE_TIME :: 0.1

        lazy_factor: f32
        slider_lazy_factor := ai_replay.accel_params.lazy_factor_slider
        circle_lazy_factor := ai_replay.accel_params.lazy_factor_circle
        slider_accel := ai_replay.accel_params.max_accel_slider
        circle_accel := ai_replay.accel_params.max_accel_circle
        if hit_objects[i].type == .Circle {
            ai_replay.accel_params.max_accel = circle_accel
            lazy_factor = circle_lazy_factor
        } else if hit_objects[i].type == .Slider {
            t := fade_in_fade_out_curve(
                hit_objects[i].start_time,
                hit_objects[i].end_time,
                t,
                SLIDER_ACCEL_FADE_TIME,
                SLIDER_ACCEL_FADE_TIME,
            )

            ai_replay.accel_params.max_accel = math.lerp(circle_accel, slider_accel, f32(t))
            lazy_factor = math.lerp(circle_lazy_factor, slider_lazy_factor, f32(t))
        }

        if linalg.length(target_pos - current_pos) > circle_radius * abs(lazy_factor) {
            target_pos =
                target_pos +
                linalg.normalize0(current_pos - target_pos) * lazy_factor * circle_radius
        } else {
            // slowly move towards the center while we're here
            target_pos = linalg.lerp(current_pos, target_pos, 0.2 * AI_REPLAY_DT)
        }

        accel := get_cursor_acceleration(
            current_pos,
            ai_replay.velocity,
            target_pos,
            next_target_pos,
            time_to_target,
            time_to_next_target,
            ai_replay.accel_params,
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


get_cursor_acceleration :: proc(
    pos, velocity: osu.Vec2,
    target, next_target: osu.Vec2,
    time_to_target, time_to_next_target: f32,
    accel_params: AccelParams,
) -> osu.Vec2 {
    axis_1 := osu.Vec2{1, 0}
    pos_to_target := target - pos
    target := target
    segments_angle: f32 = math.PI / f32(accel_params.axis_count)
    dynamic_axis := angle_vec(
        math.floor(math.atan2(pos_to_target.y, pos_to_target.x) / segments_angle) *
            segments_angle +
        (math.PI / 2),
        1,
    )

    if linalg.length(dynamic_axis) > 0.0001 {
        // Use a dynamic acceleration coordinalte system axis that angle-snaps to segment_angle increments. 
        // This works a lot better than just using target - pos which is prone to orbitals, or using just the usual {0, 1} and {1, 0}.
        axis_1 = linalg.normalize(dynamic_axis)
    }

    axis_2 := osu.Vec2{-axis_1.y, axis_1.x}

    a1, t1 := get_cursor_acceleration_axis(
        pos,
        velocity,
        target,
        next_target,
        time_to_target,
        time_to_next_target,
        axis_1,
        accel_params,
    )

    a2, t2 := get_cursor_acceleration_axis(
        pos,
        velocity,
        target,
        next_target,
        time_to_target,
        time_to_next_target,
        axis_2,
        accel_params,
    )

    if t1 > t2 {
        a2, _ = get_cursor_acceleration_axis(
            pos,
            velocity,
            target,
            next_target,
            t1,
            time_to_next_target,
            axis_2,
            accel_params,
        )
    } else {
        a1, _ = get_cursor_acceleration_axis(
            pos,
            velocity,
            target,
            next_target,
            t2,
            time_to_next_target,
            axis_1,
            accel_params,
        )
    }

    a_vec := a1 * axis_1 + a2 * axis_2

    // af.set_draw_color({1, 1, 0, 1})
    // af.draw_line(af.im, pos, pos + (a1 * axis_1), 10, .None)
    // af.draw_line(af.im, pos, pos + (a2 * axis_2), 10, .None)

    // overshoot the acceleration on purpose, so we get there on time
    return a_vec * accel_params.overshoot_multuplier

    get_cursor_acceleration_axis :: proc(
        pos, velocity: osu.Vec2,
        target, next_target: osu.Vec2,
        time_to_target, time_to_next_target: f32,
        axis: osu.Vec2,
        accel_params: AccelParams,
    ) -> (
        f32,
        f32,
    ) {
        // A reminder that multiply (*) is just 1-dimensional dot product, and that dot(normal_vector, other_vec) 
        // is the distance of other_vec projected onto normal_vector.
        // This eliminates a lot of sign-based branching code like: `if (accel > 0 && dist > 0) || (accel < 0 && dist < 0) {` for example.

        s := linalg.dot(pos, axis)
        s1 := linalg.dot(target, axis)
        s2 := linalg.dot(next_target, axis)
        v := linalg.dot(velocity, axis)

        accel := get_cursor_acceleration_axis_1d(
            s,
            s1,
            s2,
            v,
            time_to_target,
            time_to_next_target,
            accel_params,
        )

        t := time_constant_accel(accel, v, s1 - s)

        return accel, max(t, 0)
    }

    get_cursor_acceleration_axis_1d :: proc(
        s, s1, s2, v: f32,
        time_to_target, time_to_next_target: f32,
        accel_params: AccelParams,
    ) -> f32 {
        dist := s1 - s
        accel_amount := accel_params.max_accel
        accel_sign := math.sign(dist)

        if v * dist < 0 && abs(dist) < accel_params.stop_distance_rad {
            // always accelerate at full throttle if we are going the wrong way
            return accel_sign * accel_amount
        }

        TOLERANCE :: 0.1

        if abs(dist) < TOLERANCE {
            return 0
        }

        wanted_end_velocity: f32 = 0
        dist_to_next := s2 - s1
        if dist * dist_to_next > 0 {
            // they are in a line. we don't need to slow all the way down, we can slow to a constant velocity. (this is the flow-aim code)
            // TODO: this doesnt seem to work at all...
            // wanted_end_velocity = dist_to_next / time_to_next_target
        }


        decel := -accel_sign * accel_params.max_accel
        breaking_time := abs(v - wanted_end_velocity) / abs(decel)
        breaking_distance := distance_constant_accel(decel, v, breaking_time)
        if (dist < 0 && breaking_distance - TOLERANCE <= dist) ||
           (dist > 0 && breaking_distance + TOLERANCE >= dist) {
            // break if we are going to overshoot
            return decel
        }

        if time_to_target < 0.001 {
            return accel_amount * accel_sign
        }

        // this is not accurate on it's own, as it does not take breaking into account.
        // accel_amount = accel_constant_accel(dist, v, time_to_target)
        // return abs(accel_amount) * accel_sign

        accel_amount = accel_constant_accel(dist, v, time_to_target)
        return min(accel_params.max_accel, abs(accel_amount)) * accel_sign
    }
}

accel_constant_accel :: proc(s, v0, t: f32) -> f32 {
    // given a distance, initial velocity, and time, returns how fast the acceleration is
    return 2 * (s - v0 * t) / (t * t)
}

distance_constant_accel :: proc(a, v0, t: f32) -> f32 {
    // given an acceleration, initial velocity and time, returns the distance travelled
    return 0.5 * a * t * t + v0 * t
}

time_constant_accel :: proc(a, v, s: f32) -> f32 {
    rt1, rt2 := quadratic_equation(0.5 * a, v, -s)
    return max(rt1, rt2)
}


cursor_strategy_manual_input :: proc(
    ai_replay: ^AIReplay,
    beatmap: ^osu.Beatmap,
    t: f64,
    circle_radius: f32,
    seek_from: int,
) -> osu.Vec2 {
    cursor_pos := af.get_mouse_pos()
    cursor_pos_osu := view_to_osu(cursor_pos)

    return cursor_pos_osu
}
