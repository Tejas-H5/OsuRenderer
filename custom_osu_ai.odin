package main

import "af"
import "core:fmt"
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
        return get_start_position_on_object(hit_object, circle_radius), true
    case .Spinner:
        angle := get_spinner_angle(hit_object, beatmap_time)
        return get_spinner_cursor_pos(angle), true
    case .Slider:
        stack_offset := osu.get_hit_object_stack_offset(hit_object, circle_radius)
        pos, _, _ := osu.get_slider_ball_pos_unstacked(hit_object, beatmap_time)
        return pos + stack_offset, true
    }

    return PLAYFIELD_CENTER, false
}

get_start_position_on_object :: proc(hit_object: osu.HitObject, circle_radius: f32) -> osu.Vec2 {
    stack_offset := osu.get_hit_object_stack_offset(hit_object, circle_radius)

    switch hit_object.type {
    case .Circle, .Slider:
        return hit_object.start_position_unstacked + stack_offset
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
        return hit_object.end_position_unstacked + stack_offset
    case .Slider:
        if hit_object.slider_repeats % 2 == 1 {
            return hit_object.end_position_unstacked + stack_offset
        } else {
            return hit_object.start_position_unstacked + stack_offset
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
    curr_pos :=
        curr.start_position_unstacked + osu.get_hit_object_stack_offset(curr, circle_radius)

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
    hit_results:         []ObjectHitResult,
    last_hit_object:     int,
    hits, misses:        int,
    replay_seek_from:    int,
    last_object_started: int,

    // only used by functions that are physics-based.
    velocity:            osu.Vec2,
    acceleration:        osu.Vec2,
    accel_params:        AccelParams,
}


AccelParams :: struct {
    max_accel_circle:          f32,
    max_accel_slider:          f32,
    overshoot_multuplier:      f32,

    // values less than 2 are somewhat unstable
    delta_accel_factor:        f32,
    axis_count:                int,
    stop_distance:             f32,
    lazy_factor_circle:        f32,
    use_alternate_accelerator: bool,
    lazy_factor_slider:        f32,
    use_time_sync:             bool,
    use_flow_aim:              bool,
    use_flow_aim_always:       bool,
    use_dynamic_axis:          bool,
    responsiveness:            f32,
    arrive_before_percent:     f32,

    // computed
    stop_distance_rad:         f32,
    max_accel:                 f32,

    // debug vars, delete later
    predicted_distance:        af.Vec2,
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
    beatmap_time: f64,
    circle_radius: f32,
    seek_from: int,
    movement_fn: (OsuAIMovementProc),
) -> OsuPlayerInput {
    hit_objects := beatmap.hit_objects
    if len(hit_objects) == 0 {
        return {pos = PLAYFIELD_CENTER}
    }

    for AI_REPLAY_DT * f64(ai_replay.replay_seek_from) < beatmap_time {
        ai_replay.replay_seek_from += 1
    }

    for AI_REPLAY_DT * f64(ai_replay.replay_seek_from) > beatmap_time {
        ai_replay.replay_seek_from -= 1
    }

    // generate the rest of the replay as needed. if we have already generated what we need, then 
    // this just gets skipped. This is the only way to make a seekable physics-based replay (that I could think of)
    for i := len(ai_replay.replay); i < ai_replay.replay_seek_from + 2; i += 1 {
        if i == 0 {
            first_object := hit_objects[0]
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

        input := OsuPlayerInput {
            pos = next_point,
        }

        can_click :: proc(
            hit_object: osu.HitObject,
            circle_radius: f32,
            cursor_pos: osu.Vec2,
            t: f64,
            window: f64,
        ) -> bool {
            stack_offset := osu.get_hit_object_stack_offset(hit_object, circle_radius)
            hit_obj_pos := hit_object.start_position_unstacked + stack_offset
            if linalg.length(cursor_pos - hit_obj_pos) < circle_radius {
                if hit_object.start_time - window < t && t < hit_object.start_time + window {
                    return true
                }
            }

            return false
        }

        // auto-click. this will be moved out later
        if ai_replay.last_hit_object < len(hit_objects) {
            obj := hit_objects[ai_replay.last_hit_object]
            hit_window_300 := osu.get_hit_window_300(beatmap)
            if can_click(obj, circle_radius, next_point, t_i, hit_window_300) {
                input.left_click = true
            }
        }

        // iterate past all the objects we missed
        for ai_replay.last_hit_object < len(hit_objects) {
            obj := hit_objects[ai_replay.last_hit_object]
            if obj.type == .Spinner {
                ai_replay.last_hit_object += 1
                continue
            }

            hit_window_50 := osu.get_hit_window_50(beatmap)
            object_was_missed :=
                hit_objects[ai_replay.last_hit_object].start_time + hit_window_50 < t_i
            if object_was_missed {
                ai_replay.hit_results[ai_replay.last_hit_object].is_miss = true
                ai_replay.hit_results[ai_replay.last_hit_object].time = obj.start_time
                ai_replay.misses += 1
                ai_replay.last_hit_object += 1
                continue
            }

            break
        }

        // check if we hit the current object
        if input.left_click || input.right_click {
            obj := hit_objects[ai_replay.last_hit_object]
            hit_window_50 := osu.get_hit_window_50(beatmap)
            if can_click(obj, circle_radius, next_point, t_i, hit_window_50) {
                ai_replay.hit_results[ai_replay.last_hit_object].delta = f32(t_i - obj.start_time)
                ai_replay.hit_results[ai_replay.last_hit_object].is_miss = false
                ai_replay.hit_results[ai_replay.last_hit_object].time = obj.start_time
                ai_replay.last_hit_object += 1
                ai_replay.hits += 1
            }
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
        beatmap_time,
    )

    res := ai_replay.replay[ai_replay.replay_seek_from]
    p1 := ai_replay.replay[ai_replay.replay_seek_from + 1].pos

    res.pos = linalg.lerp(res.pos, p1, f32(lerp_t))
    return res
}


reset_ai_replay :: proc(ai_replay: ^AIReplay, beatmap: ^osu.Beatmap) {
    clear(&ai_replay.replay)
    ai_replay.velocity = {}
    ai_replay.acceleration = {}
    ai_replay.replay_seek_from = 0
    ai_replay.last_object_started = 0

    delete(ai_replay.hit_results)
    ai_replay.hit_results = make([]ObjectHitResult, len(beatmap.hit_objects))
    ai_replay.last_hit_object = 0
    ai_replay.hits = 0
    ai_replay.misses = 0

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
        is_on_hit_object := hit_objects[i].start_time <= t && t <= hit_objects[i].end_time
        if is_on_hit_object {
            ok: bool

            target_pos, time_to_target, next_target_pos, time_to_next_target, ok =
                get_target_positions(hit_objects[i], t, circle_radius)

            if ok {
                target_handled = true
                next_target_handled = true
                if hit_objects[i].type == .Slider {
                    slider_aim = true
                }
            } else {
                i += 1
            }

            // doesn't handle circle, since is_on_hit_object is never true for those
            get_target_positions :: proc(
                hit_object: osu.HitObject,
                t: f64,
                circle_radius: f32,
            ) -> (
                osu.Vec2,
                f32,
                osu.Vec2,
                f32,
                bool,
            ) {
                if hit_object.type == .Spinner {
                    SPINNER_LOOK_AHEAD :: 0.05
                    pos_on_spinner, _ := get_position_on_object(
                        hit_object,
                        t + SPINNER_LOOK_AHEAD,
                        circle_radius,
                    )
                    next_pos_on_spinner, ok := get_position_on_object(
                        hit_object,
                        t + 2 * SPINNER_LOOK_AHEAD,
                        circle_radius,
                    )
                    if !ok {
                        next_pos_on_spinner = get_end_position_on_object(hit_object, circle_radius)
                    }

                    return pos_on_spinner,
                        SPINNER_LOOK_AHEAD,
                        next_pos_on_spinner,
                        2 * SPINNER_LOOK_AHEAD,
                        true
                }

                if hit_object.type != .Slider {
                    return {}, 0, {}, 0, false
                }

                SLIDER_LENIENCY_SECONDS :: 0.025

                pos_on_slider, has_pos_on_slider := get_position_on_object(
                    hit_object,
                    t + SLIDER_LENIENCY_SECONDS,
                    circle_radius,
                )

                if !has_pos_on_slider {
                    return {}, 0, {}, 0, false
                }

                SLIDER_AIM_LOOKAHEAD :: SLIDER_LENIENCY_SECONDS / 2

                pos_on_slider, _ = get_position_on_object(
                    hit_object,
                    t + SLIDER_AIM_LOOKAHEAD,
                    circle_radius,
                )

                next_pos_on_slider, _ := get_position_on_object(
                    hit_object,
                    t + 2 * SLIDER_AIM_LOOKAHEAD,
                    circle_radius,
                )
                time_to_next_pos: f32 = 2 * SLIDER_AIM_LOOKAHEAD

                return pos_on_slider,
                    SLIDER_LENIENCY_SECONDS,
                    next_pos_on_slider,
                    time_to_next_pos,
                    true
            }
        }

        if i >= len(hit_objects) {
            i = len(hit_objects) - 1
        }

        if !target_handled {
            // we are on a circle
            target_pos = get_start_position_on_object(hit_objects[i], circle_radius)
            time_to_target = f32(hit_objects[i].start_time - t)
            time_to_target -= ai_replay.accel_params.arrive_before_percent * time_to_target

            if i < len(hit_objects) - 1 {
                time_to_next_target = f32(
                    hit_objects[i + 1].start_time - hit_objects[i].start_time,
                )
            }
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

        wanted_accel := get_cursor_acceleration(
            current_pos,
            ai_replay.velocity,
            ai_replay.acceleration,
            target_pos,
            next_target_pos,
            time_to_target,
            time_to_next_target,
            &ai_replay.accel_params,
        )

        ai_replay.acceleration = move_towards(
            wanted_accel,
            ai_replay.acceleration,
            linalg.length(wanted_accel - ai_replay.acceleration) *
            (1.0 / ai_replay.accel_params.responsiveness) *
            real_dt,
        )
        integrate_motion(&ai_replay.velocity, &current_pos, ai_replay.acceleration, real_dt)
    }

    return current_pos
}

integrate_motion :: proc(vel, pos: ^osu.Vec2, accel: osu.Vec2, dt: f32) {
    vel^ += 0.5 * accel * dt
    pos^ += vel^ * dt
    vel^ += 0.5 * accel * dt
}


get_cursor_acceleration :: proc(
    pos, velocity, accel: osu.Vec2,
    target, next_target: osu.Vec2,
    time_to_target, time_to_next_target: f32,
    accel_params: ^AccelParams,
) -> osu.Vec2 {
    if accel_params.use_alternate_accelerator {
        return get_cursor_acceleration_orignal_alternalte(
            pos,
            velocity,
            accel,
            target,
            next_target,
            time_to_target,
            time_to_next_target,
            accel_params,
        )
    }

    axis_1 := osu.Vec2{1, 0}
    pos_to_target := target - pos
    target := target
    segments_angle: f32 = math.PI / f32(accel_params.axis_count)

    // dynamic_axis := next_target - target
    if accel_params.use_dynamic_axis {
        // Use a dynamic acceleration coordinalte system axis that angle-snaps to segment_angle increments. 
        // This works a lot better than just using target - pos which is prone to orbitals, or using just the usual {0, 1} and {1, 0}.
        dynamic_axis := angle_vec(
            math.floor(math.atan2(pos_to_target.y, pos_to_target.x) / segments_angle) *
                segments_angle +
            (math.PI / 2),
            1,
        )

        if linalg.length(dynamic_axis) > 0.0001 {
            axis_1 = linalg.normalize(dynamic_axis)
        }
    }

    axis_2 := osu.Vec2{-axis_1.y, axis_1.x}

    a1, t1 := get_cursor_acceleration_axis(
        pos,
        velocity,
        accel,
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
        accel,
        target,
        next_target,
        time_to_target,
        time_to_next_target,
        axis_2,
        accel_params,
    )

    if accel_params.use_time_sync {
        // use_time_sync is no longer a good idea, now that I've implemented acceleration a bit better
        if t1 > t2 {
            a2, _ = get_cursor_acceleration_axis(
                pos,
                velocity,
                accel,
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
                accel,
                target,
                next_target,
                t2,
                time_to_next_target,
                axis_1,
                accel_params,
            )
        }
    }

    a_vec := a1 * axis_1 + a2 * axis_2

    // overshoot the acceleration on purpose, so we get there on time
    a_vec = a_vec * accel_params.overshoot_multuplier

    if linalg.length(a_vec) > accel_params.max_accel {
        a_vec = linalg.normalize(a_vec) * accel_params.max_accel
    }

    return a_vec

    get_cursor_acceleration_axis :: proc(
        pos, velocity: osu.Vec2,
        accel: osu.Vec2,
        target, next_target: osu.Vec2,
        time_to_target, time_to_next_target: f32,
        axis: osu.Vec2,
        accel_params: ^AccelParams,
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

        // TODO: move up
        angle := angle_between(pos, target, next_target)
        // use_flow_aim :=
        //     accel_params.use_flow_aim_always ||
        //     (accel_params.use_flow_aim && abs(angle) > math.PI / 2)
        use_flow_aim := false

        accel := get_cursor_acceleration_axis_1d_2(
            s,
            s1,
            s2,
            v,
            time_to_target,
            time_to_next_target,
            use_flow_aim,
            accel_params,
        )

        t := accel_equation_t(accel, v, s1 - s)

        return accel, max(t, 0)
    }


    get_cursor_acceleration_axis_1d_2 :: proc(
        current, target, next_target, v_curr: f32,
        time_to_target, time_to_next_target: f32,
        use_flow_aim: bool,
        accel_params: ^AccelParams,
    ) -> f32 {
        curr_to_target := target - current
        target_to_next_target := next_target - target

        v_target: f32 = 0
        if use_flow_aim {
            // This doesn't quite work. 
            // This is because if max_decel_time starts varying between axes, the to axes won't be synchronized, and the angle ends up changing.
            // This is really bad, because it affects the flow aim/snap aim calculation. 
            // Also, the cursor won't be heading in a straight line from where it was to where it should go
            // TODO: make this also return max_decel_time, and then in the calling function, override it with the min of both axes. 
            // or figure something else out idk
            v_target = target_to_next_target / time_to_next_target
        }

        // For now, let's just think optimally accelerating and then stopping at the target. 
        // We also want it to look like flow aim, so no overshooting and then accelerating back around.
        // Most likely we may have to make this seperate from flow aim.
        // TODO: make this method return the 

        max_decel_time := math.INF_F32
        curr_to_target_s := math.sign(curr_to_target)
        if curr_to_target_s * v_curr > 0.0000001 {
            // You can infer this by thinking of a line on a v_curr against time graph going through (v_curr, t_curr) -> (0, t_end).
            // We can construct a triangle such that if we decelerate at this pace at a constant rate, we will have travelled the distance curr_to_target (area under the triangle).
            // It would have a height of v_curr and a width of t, with the distance travelled being 0.5 * v_curr * t = curr_to_target.
            // Rearrange for t, and we get:
            // max_decel_time = 2 * curr_to_target / v_curr
            // A similar way of thinking can be used to generalize this for any v_target. TODO: document this

            /* max_decel_time = 2 * curr_to_target / (v_curr + v_target)
            if max_decel_time < time_to_target {
                // we can't decelerate any slower than this, otherwise we will overshoot the distance and have to wrap back around.
                // Which is doable, but unnatural. (Well, it is a bit natural, but I will add that in later)
                return (v_target - v_curr) / max_decel_time
            } */

            // this is a simpler approach. maybe it also works?
            distance_to_target_velocity := 0.5 * (math.abs(v_curr) + v_target) * time_to_target
            if distance_to_target_velocity > math.abs(curr_to_target) {
                return (v_target - v_curr) / time_to_target
            }
        }

        // we want to accelerate some amount, and then decelerate some amount over a given amount of time, 
        // in order to reach a standstill with the optimal amount of acceleration.
        // How do we figure it out?
        // When you are at a standstill, you will want to accelerate at a particular velocity for half the time, 
        // and then decelerate at that exact velocity for the other half.
        // On the velocity/time graph, this creates a perfect triangle. 
        // However, when v_curr is zero, what do we do?
        // This algorithm will halve v_curr, and see what acceleration we would need to reach curr_to_target within time_to_target.
        // However, this assumes a cosntant acceleration instead of an acceleration and  a deceleration.
        // We want  to accelerate for half the time, then decelereate for the other half, which requires precicely 2x accel and decel. 
        // We will instead double the acceleration that this function returns, while passing in half the current velocity.
        // The max_decel_time sohuld automatically take care of slowing down for us.
        // This thing seems to be mostly working at the moment.
        // If v_taget was zero, our equation would be:
        // accel_required := 2 * accel_constant_accel(curr_to_target, 0.5 * v_curr, time_to_target)
        // We can generalize to any v_target similar to above, by performing this scaling/unscaling relative to the target velocity.
        v_target_to_v_curr := v_curr - v_target
        accel_required :=
            2 *
            accel_equation_a(curr_to_target, v_target + 0.5 * v_target_to_v_curr, time_to_target)

        return accel_required
    }
}

get_cursor_acceleration_orignal_alternalte :: proc(
    pos, velocity: osu.Vec2,
    accel: osu.Vec2,
    target, next_target: osu.Vec2,
    time_to_target, time_to_next_target: f32,
    accel_params: ^AccelParams,
) -> osu.Vec2 {
    pos_to_target := target - pos

    accel_params.predicted_distance = 0

    // axis_1 := linalg.normalize0(pos_to_target)
    axis_1 := osu.Vec2{1, 0}
    axis_2 := osu.Vec2{-axis_1.y, axis_1.x}

    // The code works by trying to modulate the velocity according to the graph below, where we 
    // accelerate as fast as we can until half the distance, after which we slow down as fast as we can.
    // We want the area under the curve to be equal to S, where S = 0.5 * 2 * v * t.
    // We already know `t` (the time to the next object) and `s` (the distance to the next object).
    // Since the velocity curve is symmetric, we know that the midpoint must be t/2.
    //
    //       |
    //  2v --|       |
    //       |     _/|\_
    //   v --|   _/  |  \_
    //       | _/    |    \_
    //       |/      |      \
    //   0 --|---------------|--
    //       0      t/2      t
    //
    // With an acceleration of a, if we overshoot our target, we need to decelerate at a rate of a.
    // We can accelerate a little faster actually, so that we'll always reach our target in time.
    // In 2d, we'll need to apply this along two axes.
    get_acceleration_along_axis :: proc(
        axis: osu.Vec2,
        pos, velocity: osu.Vec2,
        accel: osu.Vec2,
        target, next_target: osu.Vec2,
        time_to_target, time_to_next_target: f32,
        accel_params: ^AccelParams,
    ) -> (
        return_accel: osu.Vec2,
    ) {
        if (time_to_target < 0.001) {
            return {0, 0}
        }

        pos_to_target := target - pos
        target_to_next := next_target - target
        s_to_target := linalg.dot(axis, pos_to_target)
        v_to_target := linalg.dot(axis, velocity)

        // keep our numbers positive and then flip the axis, so that we don't have to think too hard
        axis := axis
        if s_to_target <= 0 {
            axis = -axis
            s_to_target = -s_to_target
            v_to_target = -v_to_target
        }

        pos_to_target_norm := linalg.normalize0(pos_to_target)
        wanted_v_vec :=
            max(0, linalg.dot(pos_to_target_norm, target_to_next / time_to_next_target)) *
            pos_to_target_norm
        wanted_v := linalg.dot(axis, wanted_v_vec)

        if 0.5 * (v_to_target + wanted_v) * time_to_target > s_to_target {
            decel := (wanted_v - v_to_target) / time_to_target
            return decel * axis
        }

        // Something smart - we pass in half our current velocity to this function, and then 
        // double the acceleration that we get back. 
        // However, this assumes the target velocity and the starting velocity are both zero.
        // The solution may be good enough for other velocities, but it isn't optimal.
        the_lie :: 2
        a := the_lie * accel_equation_a(s_to_target, v_to_target / the_lie, time_to_target)
        return a * axis
    }

    a1 := get_acceleration_along_axis(
        axis_1,
        pos,
        velocity,
        accel,
        target,
        next_target,
        time_to_target,
        time_to_next_target,
        accel_params,
    )
    a2 := get_acceleration_along_axis(
        axis_2,
        pos,
        velocity,
        accel,
        target,
        next_target,
        time_to_target,
        time_to_next_target,
        accel_params,
    )

    return linalg.clamp_length(a1 + a2, accel_params.max_accel)
}

// given a distance, initial velocity, and time, returns how fast the acceleration is
// s = 0.5at^2 + v0t
// => (s - v0t) / 0.5t^2 = a
// => a = 2(s - v0t) / t^2
accel_equation_a :: proc(s, v0, t: f32) -> f32 {
    return 2 * (s - v0 * t) / (t * t)
}

// given an acceleration, initial velocity, and time, returns the velocity after that much time
// a = v0 + a * t
accel_equation_v :: proc(a, v0, t: f32) -> f32 {
    return v0 + a * t
}

// given an acceleration, initial velocity and time, returns the distance travelled
// s = 0.5at^2 + v0t
accel_equation_s :: proc(a, v0, t: f32) -> f32 {
    return 0.5 * a * t * t + v0 * t
}

// given an acceleration, initial velocity and distance, returns the time taken
// s = 0.5at^2 + v0t
// solve for t with quadratic, discard negative value
accel_equation_t :: proc(a, v, s: f32) -> f32 {
    rt1, rt2 := quadratic_equation(0.5 * a, v, -s)
    return max(rt1, rt2)
}

// solves for x when ax^2 + bx + c = 0. 
quadratic_equation :: proc(a, b, c: f32) -> (f32, f32) {
    sqrt_part := math.sqrt(b * b - 4 * a * c)

    return (-b + sqrt_part) / (2 * a), (-b - sqrt_part) / (2 * a)
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
