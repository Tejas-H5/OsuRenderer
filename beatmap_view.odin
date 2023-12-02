package main

import "af"
import "audio"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "osu"


beatmap_time: f64 = 0
wanted_music_time: f64 = 0

beatmap_first_visible: int

slider_framebuffer: ^af.Framebuffer
slider_framebuffer_texture: ^af.Texture

music: ^audio.Music
beatmap: ^osu.Beatmap

automod_replay: AIReplay
custom_ai_replay: AIReplay

ais := []AIInfo {
     {
        name = "Accelerator 1",
        ai_fn = cursor_strategy_physical_accelerator,
        replay_state = AIReplay {
            accel_params = AccelParams {
                lazy_factor_circle = 0.5,
                lazy_factor_slider = 1.5,
                max_accel_circle = 120000,
                max_accel_slider = 30000,
                overshoot_multuplier = 1,
                use_max_accel = false,
                axis_count = 6,
                stop_distance = 3,
            },
        },
        color = {0, 1, 0, 1},
    },
     {
        name = "Accelerator 2",
        ai_fn = cursor_strategy_physical_accelerator,
        replay_state = AIReplay {
            accel_params = AccelParams {
                lazy_factor_circle = 0.5,
                lazy_factor_slider = 1.5,
                max_accel_circle = 120000,
                max_accel_slider = 30000,
                overshoot_multuplier = 1,
                use_max_accel = false,
                axis_count = 6,
                stop_distance = 3,
            },
        },
        color = {0, 1, 1, 1},
    },
    //  {
    //     name = "Manual input",
    //     ai_fn = cursor_strategy_manual_input,
    //     replay_state = AIReplay {
    //         accel_params =  {
    //             max_accel = 120000,
    //             overshoot_multuplier = 1,
    //             use_max_accel = true,
    //             axis_count = 3,
    //         },
    //     },
    //     color = {1, 1, 1, 1},
    // },
}

AIInfo :: struct {
    ai_fn:        OsuAIMovementProc,
    replay_state: AIReplay,
    is_hidden:    bool,
    color:        af.Color,
    name:         string,
}


current_beatmap_folder: string
current_beatmap_filename: string
beatmap_view_error: string
beatmap_view_error_audio: audio.AudioError

draw_control_points := false

set_beatmap_view_error :: proc(msg: string, audio_err: audio.AudioError) {
    beatmap_view_error = msg
    beatmap_view_error_audio = audio_err
}


SLIDER_LOD :: 10


OSU_WIDTH :: 512
OSU_HEIGHT :: 384
osu_to_view :: proc(pos: af.Vec2) -> af.Vec2 {
    x := pos.x
    y := pos.y
    return {af.vw() * x / OSU_WIDTH, af.vh() * (1 - y / OSU_HEIGHT)}
}

view_to_osu :: proc(pos: af.Vec2) -> af.Vec2 {
    x := pos.x
    y := pos.y
    return {OSU_WIDTH * x / af.vw(), OSU_HEIGHT * (1 - y / af.vh())}
}

osu_to_view_dir :: proc(dir: af.Vec2) -> af.Vec2 {
    return osu_to_view(dir)
}

draw_hit_object :: proc(beatmap: ^osu.Beatmap, index: int, preempt, fade_in: f64) {
    opacity := osu.calculate_opacity(
        beatmap,
        beatmap.hit_objects[index].start_time,
        beatmap.hit_objects[index].end_time,
        beatmap_time,
        preempt,
        fade_in,
        fade_in,
    )
    start_opacity := osu.calculate_opacity(
        beatmap,
        beatmap.hit_objects[index].start_time,
        beatmap.hit_objects[index].start_time,
        beatmap_time,
        preempt,
        fade_in,
        fade_in,
    )

    preempt_start := beatmap.hit_objects[index].start_time - preempt

    // TODO: move
    hit_object := beatmap.hit_objects[index]
    original_layout_rect := af.layout_rect

    af.set_draw_params()

    if hit_object.type == .Spinner {
        // TODO: draw fan

        spinner_radius_max := min(af.vw(), af.vh()) / 2 - 20
        total := hit_object.end_time - hit_object.start_time
        elapsed := beatmap_time - hit_object.start_time
        t := clamp01(f32(elapsed / total))
        spinner_radius := math.lerp(spinner_radius_max, f32(0), t)

        // TODO: remove this code, and make it driven by user spinning input
        spinner_angle := (477 / 60 * min(elapsed, total)) * math.TAU

        af.set_draw_color({1, 1, 1, opacity})
        center := af.Vec2{af.vw() / 2, af.vh() / 2}
        af.draw_circle_outline(af.im, center, spinner_radius, 64, 20 * t)

        blade_size := spinner_radius_max / 2
        spinner_blade_vec := angle_vec(f32(spinner_angle), blade_size)
        af.draw_line(af.im, center, center + spinner_blade_vec, 50, .Circle)
        af.draw_line(af.im, center, center - spinner_blade_vec, 50, .Circle)

        return
    }

    circle_radius_osu := osu.get_circle_radius(beatmap)
    circle_radius := osu_to_view_dir({circle_radius_osu, 0}).x
    thickness: f32 = circle_radius / 10

    // stack_offset_amount is the stack offset from https://gist.github.com/peppy/1167470
    // NOTE(peppy): ymmv
    stack_offset_osu := (circle_radius_osu / 10) * af.Vec2{1, 1}
    stack_offset_vec := osu.get_hit_object_stack_offset(hit_object, circle_radius_osu)
    circle_pos := osu_to_view(hit_object.start_position + stack_offset_vec)

    if hit_object.type == .Slider {
        // draw slider body

        if draw_control_points {
            // control points. TODO: remove or something
            for i in 1 ..< len(hit_object.slider_nodes) {
                node0 := hit_object.slider_nodes[i - 1]
                node1 := hit_object.slider_nodes[i]
                pos0 := osu_to_view(node0.pos + stack_offset_vec)
                pos1 := osu_to_view(node1.pos + stack_offset_vec)


                af.set_draw_color(color = af.Color{1, 1, 1, 1})
                af.draw_line(af.im, pos0, pos1, thickness, .Circle)

                if node1.type == .RedNode {
                    handle_size :: 20
                    af.draw_rect(
                        af.im,
                         {
                            pos1.x - handle_size,
                            pos1.y - handle_size,
                            handle_size * 2,
                            handle_size * 2,
                        },
                    )
                }
            }
        }

        slider_end_length := hit_object.slider_length
        if beatmap_time < hit_object.start_time {
            slider_end_length = opacity * hit_object.slider_length
        }

        if len(hit_object.slider_path) >= 2 {
            // draw slider end
            slider_path_buffer := hit_object.slider_path

            // draw the slider body to a framebuffer, then blit that framebuffer to the screen with an opacity
            af.resize_framebuffer(
                slider_framebuffer,
                int(af.window_rect.width),
                int(af.window_rect.height),
            )
            af.set_framebuffer(slider_framebuffer)
            af.clear_screen({0, 0, 0, 0})
            stroke_slider_path :: proc(
                slider_path_buffer: [dynamic]af.Vec2,
                thickness: f32,
                slider_end_length: f32,
                stack_offset: af.Vec2,
            ) {
                iter: osu.SliderPathIterator
                for p0, p1 in osu.slider_path_iterator(
                    &iter,
                    slider_path_buffer,
                    0,
                    slider_end_length,
                ) {
                    p0 := osu_to_view(p0 + stack_offset)
                    p1 := osu_to_view(p1 + stack_offset)
                    af.draw_line(af.im, p0, p1, thickness, .Circle)
                }
            }

            af.set_stencil_mode(.WriteOnes)
            af.clear_stencil()
            af.set_draw_params(color = af.Color{.2, .2, .2, 0.5})
            stroke_slider_path(
                slider_path_buffer,
                (circle_radius - thickness) * 2,
                slider_end_length,
                stack_offset_vec,
            )
            af.set_stencil_mode(.DrawOverZeroes)
            af.set_draw_color(color = af.Color{1, 1, 1, 1})
            stroke_slider_path(
                slider_path_buffer,
                circle_radius * 2,
                slider_end_length,
                stack_offset_vec,
            )
            af.set_stencil_mode(.Off)

            af.set_framebuffer(nil)
            af.set_layout_rect(af.window_rect, false)
            af.set_draw_params(color = {1, 1, 1, opacity}, texture = slider_framebuffer_texture)
            af.draw_rect(af.im, af.window_rect)
            af.set_layout_rect(original_layout_rect, false)
            // slider ball
            slider_ball_osu_pos, repeat, has_slider_ball := osu.get_slider_ball_pos(
                hit_object,
                beatmap_time,
            )
            if has_slider_ball {
                slider_ball_pos := osu_to_view(slider_ball_osu_pos + stack_offset_vec)

                af.set_draw_params(color = {0, 1, 1, 0.5})
                af.draw_circle(af.im, slider_ball_pos, circle_radius * 1.25, 64)
            }

            // slider repeat arrows
            remaining_repeats := hit_object.slider_repeats - repeat
            draw_repeat_start, draw_repeat_end: bool
            switch {
            case remaining_repeats >= 2:
                draw_repeat_start, draw_repeat_end = true, true
            case remaining_repeats == 1:
                draw_repeat_end = hit_object.slider_repeats % 2 == 0
                draw_repeat_start = !draw_repeat_end
            }

            draw_slider_repeat_arrow :: proc(start, start_plus_dir: af.Vec2, circle_radius: f32) {
                thickness_percent :: 0.15
                arrow_wing_percent :: 0.3

                arrow_dir := linalg.normalize(start_plus_dir - start)
                arrow_angle := math.atan2(arrow_dir.y, arrow_dir.x)

                arrow_start := start - arrow_dir * circle_radius * 0.5
                arrow_end := start + arrow_dir * circle_radius * 0.5

                line_thickness := thickness_percent * circle_radius
                af.draw_line(af.im, arrow_start, arrow_end, line_thickness, .Circle)

                arrow_wing_size := arrow_wing_percent * circle_radius
                arrow_rwing_end :=
                    arrow_end + angle_vec(arrow_angle + math.PI * 0.75, arrow_wing_size)
                arrow_lwing_end :=
                    arrow_end + angle_vec(arrow_angle - math.PI * 0.75, arrow_wing_size)

                af.draw_line(af.im, arrow_end, arrow_rwing_end, line_thickness, .Circle)
                af.draw_line(af.im, arrow_end, arrow_lwing_end, line_thickness, .Circle)
            }

            af.set_draw_params(color = {1, 1, 1, opacity})
            if draw_repeat_start {
                draw_slider_repeat_arrow(
                    osu_to_view(slider_path_buffer[0]),
                    osu_to_view(slider_path_buffer[1]),
                    circle_radius,
                )
            }

            if draw_repeat_end {
                n := len(slider_path_buffer)
                draw_slider_repeat_arrow(
                    osu_to_view(slider_path_buffer[n - 1]),
                    osu_to_view(slider_path_buffer[n - 2]),
                    circle_radius,
                )
            }
        }
    }

    if hit_object.type == .Circle ||
       (hit_object.type == .Slider && beatmap_time < hit_object.start_time) {
        // draw circle or slider head

        opacity := start_opacity

        af.set_draw_params(color = af.Color{1, 1, 1, 1 * opacity}, texture = nil)
        af.draw_circle_outline(af.im, circle_pos, circle_radius - thickness, 64, thickness)

        af.set_draw_color(color = af.Color{0, 0, 0, 1 * opacity})
        af.draw_circle_outline(af.im, circle_pos, circle_radius, 64, 1)

        af.set_draw_color(color = af.Color{0, 0, 0, 0.75 * opacity})
        af.draw_circle(af.im, circle_pos, circle_radius - thickness, 64)

        nc_number_text_size := circle_radius
        af.set_draw_color(color = {1, 1, 1, opacity})
        res := af.draw_font_text_pivoted(
            af.im,
            source_code_pro_regular,
            fmt.tprintf("%d", hit_object.combo_number),
            nc_number_text_size,
            circle_pos,
            {0.5, 0.5},
        )


        if preempt_start < beatmap_time && beatmap_time < hit_object.start_time {
            approach_circle_thickness :: 8

            approach_circle_radius_max := circle_radius * 3
            ac_start := preempt_start
            ac_end := hit_object.start_time
            approach_circle_radius := math.lerp(
                approach_circle_radius_max,
                circle_radius,
                f32(inv_lerp(ac_start, ac_end, beatmap_time)),
            )

            af.set_draw_params(color = {1, 1, 1, opacity})
            af.draw_circle_outline(
                af.im,
                circle_pos,
                approach_circle_radius,
                64,
                approach_circle_thickness,
            )
        }
    }
}

draw_hit_objects :: proc(beatmap: ^osu.Beatmap, first, last: int, preempt, fade_in: f64) {
    if len(beatmap.hit_objects) == 0 {
        af.draw_font_text_pivoted(
            af.im,
            source_code_pro_regular,
            "no hit objects",
            32,
            {af.vw() / 2, af.vh() / 2},
            {0.5, 0.5},
        )
        return
    }

    for i := last; i >= first; i -= 1 {
        opacity := osu.calculate_opacity(
            beatmap,
            beatmap.hit_objects[i].start_time,
            beatmap.hit_objects[i].end_time,
            beatmap_time,
            preempt,
            fade_in,
            fade_in,
        )

        // draw follow point
        if i < len(beatmap.hit_objects) - 1 && beatmap.hit_objects[i + 1].combo_number != 1 {
            opacity_next := osu.calculate_opacity(
                beatmap,
                beatmap.hit_objects[i + 1].start_time,
                beatmap.hit_objects[i + 1].end_time,
                beatmap_time,
                preempt,
                fade_in,
                fade_in,
            )

            min_opacity :: 0.3
            opacity_followpoint := max(
                0,
                min(min(opacity - min_opacity, opacity_next - min_opacity), min_opacity),
            )

            p0 := beatmap.hit_objects[i].end_position
            p1 := beatmap.hit_objects[i + 1].start_position
            p0p1_dir := linalg.normalize(p1 - p0)
            circle_radius_osu := osu.get_circle_radius(beatmap)
            p0 += (p0p1_dir * circle_radius_osu)
            p1 -= (p0p1_dir * circle_radius_osu)

            af.set_draw_params(color = {1, 1, 1, opacity_followpoint})
            af.draw_line(af.im, osu_to_view(p0), osu_to_view(p1), 1, .None)
        }

        draw_hit_object(beatmap, i, preempt, fade_in)
    }
}


view_beatmap :: proc(beatmap_folder: string, beatmap_filename: string) -> string {
    current_beatmap_folder = beatmap_folder
    current_beatmap_filename = beatmap_filename
    set_screen(.BeatmapView)
    return ""
}

beatmap_view_cleanup :: proc() {
    // clean up previous beatmap.
    if beatmap != nil {
        osu.free_beatmap(beatmap)
        beatmap = nil

        audio.free_music(music)
        music = nil
    }
}

reset_ai_replays :: proc() {
    for i in 0 ..< len(ais) {
        reset_ai_replay(&ais[i].replay_state)
    }
}

load_current_beatmap :: proc() {
    beatmap_time = 0
    wanted_music_time = 0

    reset_ai_replays()
    beatmap_view_cleanup()

    // load beatmap file
    beatmap_fullpath := filepath.join([]string{current_beatmap_folder, current_beatmap_filename})
    defer delete(beatmap_fullpath)
    beatmap = osu.new_osu_beatmap(beatmap_fullpath)
    if beatmap == nil {
        set_beatmap_view_error("Failed to load beatmap", {})
        return
    }

    // initialize the beatmap. 
    // TODO: may need to move this code to a better place if we ever want to add an editor, but that is unlikely at this stage
    for i in 0 ..< len(beatmap.hit_objects) {
        osu.recalculate_slider_path(beatmap, i, SLIDER_LOD)
        osu.recalculate_object_values(beatmap, i, SLIDER_LOD)
    }

    osu.recalculate_stack_counts(beatmap)

    // load and set the music
    music_fullpath := filepath.join([]string{current_beatmap_folder, beatmap.AudioFilename})
    music_fullpath_cstr := strings.clone_to_cstring(music_fullpath)
    delete(music_fullpath)
    defer delete(music_fullpath_cstr)

    err: audio.AudioError
    music, err = audio.new_music(music_fullpath_cstr)
    if err.ErrorMessage != "" {
        set_beatmap_view_error("Failed to open music", err)
        return
    }

    err = audio.set_music(music)
    if err.ErrorMessage != "" {
        set_beatmap_view_error("Failed to set the music", err)
        return
    }

    set_beatmap_view_error("", {})
    af.debug_log(
        "Loaded beatmap with %v hit objects and %v timing points",
        len(beatmap.hit_objects),
        len(beatmap.timing_points),
    )
}


draw_beatmap_view :: proc() {
    if af.key_just_pressed(.Escape) {
        beatmap_view_cleanup()

        set_screen(.BeatmapPickeView)
        return
    }

    if screens_moved {
        screens_moved = false

        load_current_beatmap()
    }

    process_input()


    playfield_padding :: 80
    layout_base := af.layout_rect
    layout_playfield := layout_base
    layout_playfield.width *= 0.7
    af.set_rect_size(
        &layout_playfield,
        layout_playfield.width - 2 * playfield_padding,
        layout_playfield.height - 2 * playfield_padding,
        0.5,
        0.5,
    )

    padding :: 20
    layout_ui := layout_base
    layout_ui.x0 += layout_playfield.width + layout_playfield.x0 + padding
    layout_ui.width -= layout_ui.x0

    beatmap_info: CurrentBeatmapInfo

    af.set_layout_rect(layout_playfield)
    draw_osu_beatmap(&beatmap_info)
    draw_ai_cursors(ais)

    af.set_layout_rect(layout_ui)
    draw_info_panel(beatmap_info, ais)

    process_input :: proc() {
        if adjust_value_with_mousewheel(
               "overshoot_amnt",
               &ais[0].replay_state.accel_params.overshoot_multuplier,
               .D,
               0.01,
           ) {
            return
        }

        if af.key_just_pressed(.R) {
            reset_ai_replays()
        }

        ai_hide_inputs := []bool {
            af.key_just_pressed(.Number1),
            af.key_just_pressed(.Number2),
            af.key_just_pressed(.Number3),
        }
        for i in 0 ..< len(ai_hide_inputs) {
            if ai_hide_inputs[i] {
                ais[i].is_hidden = !ais[i].is_hidden
            }
        }

        preempt := f64(osu.get_preempt(beatmap))

        // playback input
        scroll_speed: f64 = 0.25 * (preempt)
        if af.key_is_down(.Shift) {
            scroll_speed *= 20
        }
        if af.key_is_down(.Ctrl) {
            scroll_speed /= 5
        }
        if abs(af.mouse_wheel_notches) > 0.01 {
            wanted_music_time -= f64(af.mouse_wheel_notches) * scroll_speed
        }

        if af.key_just_pressed(.C) {
            draw_control_points = !draw_control_points
        }

        if af.key_just_pressed(.Space) {
            audio.set_playing(!audio.is_playing())

            if audio.is_playing() {
                wanted_music_time = beatmap_time
                audio.set_playback_seconds(wanted_music_time)
            }
        }

        if audio.is_playing() {
            t, res := audio.get_playback_seconds()
            beatmap_time = t
            wanted_music_time = t
            if res.ErrorMessage != "" {
                af.debug_warning("Error getting time - %v", res)
            }
        } else {
            beatmap_time = math.lerp(beatmap_time, wanted_music_time, 20 * f64(af.delta_time))
        }
    }

    CURSOR_ANALYSIS_DELTATIME :: 0.01
    CURSOR_ANALYSIS_AFTERIMAGES :: 1
    CurrentBeatmapInfo :: struct {
        first_visible, last_visible: int,
        t0, t1:                      f64,
    }


    draw_osu_beatmap :: proc(info: ^CurrentBeatmapInfo) {
        preempt := f64(osu.get_preempt(beatmap))

        // make our playfield 4:3, put it on the left
        layout_rect := af.layout_rect
        set_rect_aspect_ratio(&layout_rect, 4.0 / 3.0, 0.5, 0.5)
        af.set_layout_rect(layout_rect)

        af.set_draw_params(color = af.Color{1, 0, 0, 1}, texture = nil)
        af.draw_rect_outline(af.im, {0, 0, af.vw(), af.vh()}, 4)

        fade_in := f64(osu.get_fade_in(beatmap))
        fade_out := fade_in

        info.t0 = beatmap_time - fade_out
        info.t1 = beatmap_time + preempt

        beatmap_first_visible = osu.beatmap_get_first_visible(
            beatmap,
            info.t0,
            beatmap_first_visible,
        )
        info.first_visible = beatmap_first_visible
        info.last_visible = osu.beatmap_get_last_visible(beatmap, info.t1, beatmap_first_visible)

        draw_hit_objects(beatmap, beatmap_first_visible, info.last_visible, preempt, fade_in)
    }

    draw_ai_cursors :: proc(ais: []AIInfo) {
        circle_radius_osu := osu.get_circle_radius(beatmap)
        circle_radius := osu_to_view_dir({circle_radius_osu, 0}).x
        last_generated_slider := -1
        cursor_size := osu_to_view_dir({10, 0}).x

        for i in 0 ..< CURSOR_ANALYSIS_AFTERIMAGES {
            t := beatmap_time - f64(i) * CURSOR_ANALYSIS_DELTATIME
            afterimage_strength: f32 =
                f32(CURSOR_ANALYSIS_AFTERIMAGES - i) / f32(CURSOR_ANALYSIS_AFTERIMAGES)

            for i in 0 ..< len(ais) {
                recorded_input := get_ai_replay_cursor_pos(
                    &ais[i].replay_state,
                    beatmap,
                    t,
                    circle_radius_osu,
                    beatmap_first_visible,
                    ais[i].ai_fn,
                )
                pos := recorded_input.pos
                col := ais[i].color
                col.w = afterimage_strength
                af.set_draw_params(color = col)
                if !ais[i].is_hidden {
                    af.draw_circle(af.im, osu_to_view(pos), cursor_size, 64)
                }
            }
        }

        for ai in ais {
            if ai.is_hidden {
                continue
            }

            replay := ai.replay_state
            replay_hindsight :: 100

            ai_col := ai.color
            ai_col[3] = 0.5
            af.set_draw_color(ai_col)
            for i in max(
                0,
                replay.replay_seek_from - replay_hindsight,
            ) ..< replay.replay_seek_from {
                p0 := osu_to_view(replay.replay[i].pos)
                p1 := osu_to_view(replay.replay[i + 1].pos)

                thickness := linalg.length(p0 - p1) * 0.5
                if thickness < circle_radius {
                    af.draw_line(af.im, p0, p1, thickness, .None)
                }
            }
        }
    }

    draw_info_panel :: proc(state: CurrentBeatmapInfo, ais: []AIInfo) {
        text_size :: 32
        x, y, line_height: f32
        line_height = 32
        draw_text :: proc(text: string, x, y: f32) -> f32 {
            res := af.draw_font_text(
                af.im,
                source_code_pro_regular,
                text,
                text_size,
                {x, af.vh() - y - text_size},
            )

            padding :: 0
            return x + res.width + padding
        }


        af.set_draw_color(color = af.Color{1, 0, 0, 1})
        x = draw_text(fmt.tprintf("%v <- %v -> %v", state.t0, beatmap_time, state.t1), x, y)
        x = 0
        y += line_height
        x = draw_text(
            fmt.tprintf(
                " | objects %v to %v of %v",
                state.first_visible,
                state.last_visible,
                len(beatmap.hit_objects),
            ),
            x,
            y,
        )

        x = 0
        y += line_height
        for ai in ais {
            x, y = 0, y + line_height
            af.set_draw_color(ai.color)
            draw_text(fmt.tprintf("--- %v ---", ai.name), x, y)
            x, y = 0, y + line_height
            draw_text(fmt.tprintf("%v points", len(ai.replay_state.replay)), x, y)
            x, y = 0, y + line_height
        }
    }
}


set_rect_aspect_ratio :: proc(rect: ^af.Rect, aspect: f32, px, py: f32) {
    rect := rect
    rect_aspect := rect.width / rect.height
    if rect_aspect > aspect {
        af.set_rect_width(rect, rect.height * aspect, px)
    } else {
        af.set_rect_height(rect, rect.width * (1 / aspect), py)
    }
}
