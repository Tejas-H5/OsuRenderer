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


g_beatmap_view := struct {
    // ai cursors
    ais:                        []AIInfo,

    // beatmap 
    beatmap_time:               f64,
    wanted_music_time:          f64,
    beatmap_first_visible:      int,
    music:                      ^audio.Music,
    beatmap:                    ^osu.Beatmap,

    // slider drawing
    slider_framebuffer:         ^af.Framebuffer,
    slider_framebuffer_texture: ^af.Texture,
    draw_control_points:        bool,

    // the selected beatmap
    current_beatmap_folder:     string,
    current_beatmap_filename:   string,

    // error
    error:                      string,
    error_audio:                audio.AudioError,
} {
    ais = []AIInfo {
        {
            name = "Automod",
            ai_fn = cursor_motion_strategy_automod,
            replay_state = AIReplay{},
            color = {1, 0, 0, 1},
        },
        {
            name = "Accelerator",
            ai_fn = cursor_strategy_physical_accelerator,
            replay_state = AIReplay {
                accel_params = AccelParams {
                    lazy_factor_circle = 0.5,
                    lazy_factor_slider = 1,
                    max_accel_circle = 999999,
                    max_accel_slider = 50000,
                    axis_count = 6,
                    stop_distance = 3,
                    overshoot_multuplier = 1,
                    delta_accel_factor = 6,
                    use_dynamic_axis = false,
                    responsiveness = 0.0012,
                },
            },
            color = {0, 1, 1, 1},
        },
        {
            name = "Alternate accelerator",
            ai_fn = cursor_strategy_physical_accelerator,
            replay_state = AIReplay {
                accel_params = AccelParams {
                    use_alternate_accelerator = true,
                    lazy_factor_circle = 0.8,
                    lazy_factor_slider = 1,
                    max_accel_circle = 999999,
                    max_accel_slider = 50000,
                    axis_count = 6,
                    stop_distance = 3,
                    overshoot_multuplier = 1,
                    delta_accel_factor = 6,
                    use_dynamic_axis = false,
                    responsiveness = 0.0012,
                },
            },
            color = {0, 1, 0, 1},
        },
        {
            // NOTE: it doesn't quite work - we need to work on navigating a simpler path from 
            // the start to the end rather than actually traversing the slider.
            // It could just be lerping between the start -> end straight line vs the actual slider path
            name = "AA Slider noob",
            ai_fn = cursor_strategy_physical_accelerator,
            replay_state = AIReplay {
                accel_params = AccelParams {
                    use_alternate_accelerator = true,
                    lazy_factor_circle = 0.8,
                    lazy_factor_slider = 1,
                    max_accel_circle = 999999,
                    max_accel_slider = 20000,
                    axis_count = 6,
                    stop_distance = 3,
                    overshoot_multuplier = 1,
                    delta_accel_factor = 6,
                    use_dynamic_axis = false,
                    responsiveness = 0.0012,
                },
            },
            color = {0, 1, 0, 1},
        },
        //  {
        //     name = "Accelerator [experimental]",
        //     ai_fn = cursor_strategy_physical_accelerator,
        //     replay_state = AIReplay {
        //         accel_params = AccelParams {
        //             lazy_factor_circle = 0.5,
        //             lazy_factor_slider = 1,
        //             max_accel_circle = 999999,
        //             max_accel_slider = 30000,
        //             axis_count = 6,
        //             stop_distance = 3,
        //             overshoot_multuplier = 1,
        //             delta_accel_factor = 6,
        //             use_dynamic_axis = false,
        //             responsiveness = 0.0012,
        //             use_flow_aim = true,
        //         },
        //     },
        //     color = {0, 1, 0, 1},
        // },
    },
}


ObjectHitResult :: struct {
    // TODO: figure out how to handle slider-ends, repeats, spinners
    object:  int,
    time:    f64,
    delta:   f32,
    is_miss: bool,
}

AIInfo :: struct {
    ai_fn:        OsuAIMovementProc,
    replay_state: AIReplay,
    is_hidden:    bool,
    color:        af.Color,
    name:         string,
}


set_beatmap_view_error :: proc(msg: string, audio_err: audio.AudioError) {
    g_beatmap_view.error = msg
    g_beatmap_view.error_audio = audio_err
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
    theme := g_current_theme
    beatmap_time := g_beatmap_view.beatmap_time

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

        af.set_draw_color(with_alpha(theme.Foreground, opacity))
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

    stack_offset_osu := osu.get_hit_object_stack_offset(hit_object, circle_radius_osu)
    circle_pos := osu_to_view(hit_object.start_position_unstacked + stack_offset_osu)

    if hit_object.type == .Slider {
        // draw slider body

        if g_beatmap_view.draw_control_points {
            // control points. TODO: remove or something
            for i in 1 ..< len(hit_object.slider_nodes) {
                node0 := hit_object.slider_nodes[i - 1]
                node1 := hit_object.slider_nodes[i]
                pos0 := osu_to_view(node0.pos + stack_offset_osu)
                pos1 := osu_to_view(node1.pos + stack_offset_osu)

                af.set_draw_color(color = theme.Foreground)
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

            // init the framebuffer
            af.resize_framebuffer(
                g_beatmap_view.slider_framebuffer,
                int(af.window_rect.width),
                int(af.window_rect.height),
            )

            // draw slider inner path to the framebuffer, and draw it
            af.set_framebuffer(g_beatmap_view.slider_framebuffer)
            af.clear_screen({0, 0, 0, 0})
            af.set_draw_params(color = theme.SliderPath)
            stroke_slider_path(
                slider_path_buffer,
                circle_radius * 2,
                slider_end_length,
                stack_offset_osu,
            )
            af.set_framebuffer(nil)
            af.set_layout_rect(af.window_rect, false)
            af.set_draw_params(
                color = with_alpha(theme.Foreground, 0.7 * opacity),
                texture = g_beatmap_view.slider_framebuffer_texture,
            )
            af.draw_rect(af.im, af.window_rect)
            af.set_layout_rect(original_layout_rect, false)

            // draw slider outline to the framebuffer, and draw it
            af.set_framebuffer(g_beatmap_view.slider_framebuffer)
            af.clear_screen({0, 0, 0, 0})
            af.set_stencil_mode(.WriteOnes)
            af.clear_stencil()
            af.set_draw_params(color = af.Color{0, 0, 0, 0})
            stroke_slider_path(
                slider_path_buffer,
                (circle_radius - thickness) * 2,
                slider_end_length,
                stack_offset_osu,
            )
            af.set_stencil_mode(.DrawOverZeroes)
            af.set_draw_color(color = theme.Foreground)
            stroke_slider_path(
                slider_path_buffer,
                circle_radius * 2,
                slider_end_length,
                stack_offset_osu,
            )
            af.set_stencil_mode(.Off)

            af.set_framebuffer(nil)
            af.set_layout_rect(af.window_rect, false)
            af.set_draw_params(
                color = with_alpha(theme.Foreground, opacity),
                texture = g_beatmap_view.slider_framebuffer_texture,
            )
            af.draw_rect(af.im, af.window_rect)
            af.set_layout_rect(original_layout_rect, false)

            // slider ball
            slider_ball_osu_pos, repeat, has_slider_ball := osu.get_slider_ball_pos_unstacked(
                hit_object,
                beatmap_time,
            )
            if has_slider_ball {
                slider_ball_pos := osu_to_view(slider_ball_osu_pos + stack_offset_osu)

                af.set_draw_params(color = with_alpha(theme.Foreground, 0.5))
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

            // TODO: fix this opacity. right now, this arrow is visible before the slider
            // has even finished snaking to the end
            af.set_draw_params(color = with_alpha(theme.ReverseArrow, opacity))
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

        af.set_draw_params(color = with_alpha(theme.Foreground, opacity), texture = nil)
        af.draw_circle_outline(af.im, circle_pos, circle_radius - thickness, 64, thickness)

        // this is a 1px 'shadow' outline around the hitcircle that isn't bound by the current theme
        af.set_draw_color(color = af.Color{0, 0, 0, 1 * opacity})
        af.draw_circle_outline(af.im, circle_pos, circle_radius, 64, 1)

        af.set_draw_color(color = with_alpha(theme.Background, opacity))
        af.draw_circle(af.im, circle_pos, circle_radius - thickness, 64)

        nc_number_text_size := circle_radius
        af.set_draw_color(color = with_alpha(theme.Foreground, opacity))
        res := af.draw_font_text_pivoted(
            af.im,
            g_source_code_pro_regular,
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

            af.set_draw_params(color = with_alpha(theme.Foreground, opacity))
            af.draw_circle_outline(
                af.im,
                circle_pos,
                approach_circle_radius,
                64,
                approach_circle_thickness,
            )
        }


        draw_debug_info :: false

        if draw_debug_info && hit_object.type == .Slider {
            // slider debug info
            af.set_draw_params(color = theme.Foreground)
            af.draw_font_text(
                af.im,
                g_source_code_pro_regular,
                fmt.tprintf(
                    "%0.5v bpm, %0.5v sv, %0.5v sL, %0.5v sR",
                    hit_object.bpm,
                    hit_object.sv,
                    hit_object.slider_length,
                    hit_object.slider_repeats,
                ),
                50,
                circle_pos + {50, 50},
            )
            af.draw_font_text(
                af.im,
                g_source_code_pro_regular,
                fmt.tprintf(
                    "%0.5v start, %0.5v end, %0.5v dur, %0.5v svx",
                    hit_object.start_time,
                    hit_object.end_time,
                    hit_object.end_time - hit_object.start_time,
                    hit_object.sm,
                ),
                50,
                circle_pos + {50, -50},
            )
        }
    }
}

draw_hit_objects :: proc(beatmap: ^osu.Beatmap, first, last: int, preempt, fade_in: f64) {
    theme := g_current_theme
    if len(beatmap.hit_objects) == 0 {
        af.draw_font_text_pivoted(
            af.im,
            g_source_code_pro_regular,
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
            g_beatmap_view.beatmap_time,
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
                g_beatmap_view.beatmap_time,
                preempt,
                fade_in,
                fade_in,
            )

            min_opacity :: 0.3
            opacity_followpoint := max(
                0,
                min(min(opacity - min_opacity, opacity_next - min_opacity), min_opacity),
            )

            circle_radius_osu := osu.get_circle_radius(beatmap)
            stack_offset_0 := osu.get_hit_object_stack_offset(
                beatmap.hit_objects[i],
                circle_radius_osu,
            )
            stack_offset_1 := osu.get_hit_object_stack_offset(
                beatmap.hit_objects[i + 1],
                circle_radius_osu,
            )
            p0 := beatmap.hit_objects[i].end_position_unstacked + stack_offset_0
            p1 := beatmap.hit_objects[i + 1].start_position_unstacked + stack_offset_1
            p0p1_dir := linalg.normalize(p1 - p0)

            p0 += (p0p1_dir * circle_radius_osu)
            p1 -= (p0p1_dir * circle_radius_osu)

            followpoint_thickness :: 3
            af.set_draw_params(color = with_alpha(theme.Foreground, opacity_followpoint))
            af.draw_line(af.im, osu_to_view(p0), osu_to_view(p1), followpoint_thickness, .None)
        }

        draw_hit_object(beatmap, i, preempt, fade_in)
    }
}


view_beatmap :: proc(beatmap_folder: string, beatmap_filename: string) -> string {
    g_beatmap_view.current_beatmap_folder = beatmap_folder
    g_beatmap_view.current_beatmap_filename = beatmap_filename
    set_screen(.BeatmapView)
    return ""
}

beatmap_view_cleanup :: proc() {
    // clean up previous beatmap.
    if g_beatmap_view.beatmap != nil {
        osu.free_beatmap(g_beatmap_view.beatmap)
        g_beatmap_view.beatmap = nil

        audio.free_music(g_beatmap_view.music)
        g_beatmap_view.music = nil
    }
}

reset_ai_replays :: proc(beatmap: ^osu.Beatmap) {
    for i in 0 ..< len(g_beatmap_view.ais) {
        reset_ai_replay(&g_beatmap_view.ais[i].replay_state, beatmap)
    }
}

load_current_beatmap :: proc() {
    g_beatmap_view.beatmap_time = 0
    g_beatmap_view.wanted_music_time = 0

    beatmap_view_cleanup()

    // load beatmap file
    beatmap_fullpath := filepath.join(
        []string{g_beatmap_view.current_beatmap_folder, g_beatmap_view.current_beatmap_filename},
    )
    defer delete(beatmap_fullpath)
    g_beatmap_view.beatmap = osu.new_osu_beatmap(beatmap_fullpath)
    if g_beatmap_view.beatmap == nil {
        set_beatmap_view_error("Failed to load beatmap", {})
        return
    }

    reset_ai_replays(g_beatmap_view.beatmap)

    // initialize the beatmap. 
    // TODO: may need to move this code to a better place if we ever want to add an editor, but that is unlikely at this stage
    for i in 0 ..< len(g_beatmap_view.beatmap.hit_objects) {
        osu.recalculate_slider_path(g_beatmap_view.beatmap, i, SLIDER_LOD)
        osu.recalculate_object_values(g_beatmap_view.beatmap, i, SLIDER_LOD)
    }

    osu.recalculate_stack_counts(g_beatmap_view.beatmap)

    // load and set the music
    music_fullpath := filepath.join(
        []string{g_beatmap_view.current_beatmap_folder, g_beatmap_view.beatmap.AudioFilename},
    )
    music_fullpath_cstr := strings.clone_to_cstring(music_fullpath)
    delete(music_fullpath)
    defer delete(music_fullpath_cstr)

    err: audio.AudioError
    g_beatmap_view.music, err = audio.new_music(music_fullpath_cstr)
    if err.ErrorMessage != "" {
        set_beatmap_view_error("Failed to open music", err)
        return
    }

    err = audio.set_music(g_beatmap_view.music)
    if err.ErrorMessage != "" {
        set_beatmap_view_error("Failed to set the music", err)
        return
    }

    set_beatmap_view_error("", {})
    af.debug_log(
        "Loaded beatmap with %v hit objects and %v timing points",
        len(g_beatmap_view.beatmap.hit_objects),
        len(g_beatmap_view.beatmap.timing_points),
    )
}


draw_beatmap_view :: proc() {
    if af.key_just_pressed(.Escape) {
        beatmap_view_cleanup()
        set_screen(.BeatmapPickeView)
        return
    }

    if g_app.screen_changed {
        g_app.screen_changed = false
        load_current_beatmap()
    }

    process_input()

    playfield_rect := af.layout_rect
    playfield_padding :: 80
    af.set_rect_size(
        &playfield_rect,
        playfield_rect.width - 2 * playfield_padding,
        playfield_rect.height - 2 * playfield_padding,
        0.5,
        0.5,
    )

    padding :: 20
    info_rect := af.layout_rect

    beatmap_info: CurrentBeatmapInfo

    af.set_layout_rect(playfield_rect)
    draw_osu_beatmap(&beatmap_info)
    draw_ai_cursors(g_beatmap_view.ais)

    af.set_layout_rect(info_rect)
    draw_info_panel(beatmap_info, g_beatmap_view.ais)

    process_input :: proc() {
        if adjust_value_with_mousewheel(
            "responsiveness",
            &g_beatmap_view.ais[1].replay_state.accel_params.responsiveness,
            .D,
            0.0001,
        ) {
            return
        }

        if af.key_just_pressed(.R) {
            reset_ai_replays(g_beatmap_view.beatmap)
        }

        ai_hide_inputs := []bool {
            af.key_just_pressed(.Number1),
            af.key_just_pressed(.Number2),
            af.key_just_pressed(.Number3),
        }
        for i in 0 ..< len(ai_hide_inputs) {
            if ai_hide_inputs[i] {
                g_beatmap_view.ais[i].is_hidden = !g_beatmap_view.ais[i].is_hidden
            }
        }

        preempt := f64(osu.get_preempt(g_beatmap_view.beatmap))

        // playback input
        scroll_speed: f64 = 0.25 * (preempt)
        if af.key_is_down(.Shift) {
            scroll_speed *= 20
        }
        if af.key_is_down(.Ctrl) {
            scroll_speed /= 5
        }
        if abs(af.mouse_wheel_notches) > 0.01 {
            g_beatmap_view.wanted_music_time -= f64(af.mouse_wheel_notches) * scroll_speed
        }

        if af.key_just_pressed(.C) {
            g_beatmap_view.draw_control_points = !g_beatmap_view.draw_control_points
        }

        if af.key_just_pressed(.Space) {
            audio.set_playing(!audio.is_playing())

            if audio.is_playing() {
                g_beatmap_view.wanted_music_time = g_beatmap_view.beatmap_time
                audio.set_playback_seconds(g_beatmap_view.wanted_music_time)
            }
        }

        if audio.is_playing() {
            t, res := audio.get_playback_seconds()
            g_beatmap_view.beatmap_time = t
            g_beatmap_view.wanted_music_time = t
            if res.ErrorMessage != "" {
                af.debug_warning("Error getting time - %v", res)
            }
        } else {
            g_beatmap_view.beatmap_time = math.lerp(
                g_beatmap_view.beatmap_time,
                g_beatmap_view.wanted_music_time,
                20 * f64(af.delta_time),
            )
        }
    }

    CURSOR_ANALYSIS_DELTATIME :: 0.01
    CURSOR_ANALYSIS_AFTERIMAGES :: 1
    CurrentBeatmapInfo :: struct {
        first_visible, last_visible: int,
        t0, t1:                      f64,
    }


    draw_osu_beatmap :: proc(info: ^CurrentBeatmapInfo) {
        theme := g_current_theme

        preempt := f64(osu.get_preempt(g_beatmap_view.beatmap))

        // make our playfield 4:3, put it on the left
        layout_rect := af.layout_rect
        set_rect_aspect_ratio(&layout_rect, 4.0 / 3.0, 0.5, 0.5)
        af.set_layout_rect(layout_rect)

        af.set_draw_params(with_alpha(theme.Foreground, 1))
        af.draw_rect_outline(af.im, {0, 0, af.vw(), af.vh()}, 4)

        fade_in := f64(osu.get_fade_in(g_beatmap_view.beatmap))
        fade_out := fade_in

        info.t0 = g_beatmap_view.beatmap_time - fade_out
        info.t1 = g_beatmap_view.beatmap_time + preempt

        g_beatmap_view.beatmap_first_visible = osu.beatmap_get_first_visible(
            g_beatmap_view.beatmap,
            info.t0,
            g_beatmap_view.beatmap_first_visible,
        )
        info.first_visible = g_beatmap_view.beatmap_first_visible
        info.last_visible = osu.beatmap_get_last_visible(
            g_beatmap_view.beatmap,
            info.t1,
            g_beatmap_view.beatmap_first_visible,
        )

        draw_hit_objects(
            g_beatmap_view.beatmap,
            g_beatmap_view.beatmap_first_visible,
            info.last_visible,
            preempt,
            fade_in,
        )
    }

    draw_ai_cursors :: proc(ais: []AIInfo) {
        circle_radius_osu := osu.get_circle_radius(g_beatmap_view.beatmap)
        circle_radius := osu_to_view_dir({circle_radius_osu, 0}).x
        last_generated_slider := -1
        cursor_size := osu_to_view_dir({10, 0}).x

        for i in 0 ..< CURSOR_ANALYSIS_AFTERIMAGES {
            t := g_beatmap_view.beatmap_time - f64(i) * CURSOR_ANALYSIS_DELTATIME
            afterimage_strength: f32 =
                f32(CURSOR_ANALYSIS_AFTERIMAGES - i) / f32(CURSOR_ANALYSIS_AFTERIMAGES)

            for i in 0 ..< len(ais) {
                recorded_input := get_ai_replay_cursor_pos(
                    &ais[i].replay_state,
                    g_beatmap_view.beatmap,
                    t,
                    circle_radius_osu,
                    g_beatmap_view.beatmap_first_visible,
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
            lo := max(0, replay.replay_seek_from - replay_hindsight)
            hi := replay.replay_seek_from
            for i in lo ..< hi {
                af.set_draw_color(with_alpha(ai_col, inv_lerp(f32(lo), f32(hi), f32(i))))

                p0 := osu_to_view(replay.replay[i].pos)
                p1 := osu_to_view(replay.replay[i + 1].pos)

                thickness := linalg.length(p0 - p1) * 0.5
                af.draw_line(af.im, p0, p1, thickness, .None)
            }

            af.set_draw_color(ai_col)
        }
    }

    draw_info_panel :: proc(state: CurrentBeatmapInfo, ais: []AIInfo) {
        theme := g_current_theme
        text_size :: 32
        x, y, line_height: f32
        line_height = 32
        y = af.vh() - line_height
        draw_text :: proc(text: string, x, y: f32) -> f32 {
            res := af.draw_font_text(af.im, g_source_code_pro_regular, text, text_size, {x, y})

            padding :: 0
            return x + res.width + padding
        }


        af.set_draw_color(color = theme.Foreground)
        x = draw_text(
            fmt.tprintf(
                "%0.3v <- %0.3v -> %0.3f",
                state.t0,
                g_beatmap_view.beatmap_time,
                state.t1,
            ),
            x,
            y,
        )
        x = 0
        y -= line_height
        x = draw_text(
            fmt.tprintf(
                " | objects %v to %v of %v",
                state.first_visible,
                state.last_visible,
                len(g_beatmap_view.beatmap.hit_objects),
            ),
            x,
            y,
        )

        x = 0
        y -= line_height
        for ai in ais {
            x, y = 0, y - line_height
            af.set_draw_color(ai.color)
            draw_text(fmt.tprintf("--- %v ---", ai.name), x, y)
            x, y = 0, y - line_height

            draw_text(fmt.tprintf("%v datapoints", len(ai.replay_state.replay)), x, y)
            x, y = 0, y - line_height

            hits := ai.replay_state.hits
            misses := ai.replay_state.misses
            draw_text(fmt.tprintf("%v hits", hits), x, y)
            x, y = 0, y - line_height

            if misses > 0 {
                draw_text("misses:", x, y)
                x, y = 0, y - line_height
                for res in ai.replay_state.hit_results {
                    if res.is_miss {
                        x2 := draw_text(fmt.tprintf("t = %v", res.time), x, y)

                        box := af.Rect{x, y, x2 - x, line_height}
                        if af.mouse_is_over(box) {
                            af.draw_rect_outline(af.im, box, 2)
                            if af.mouse_button_is_down(.Left) {
                                g_beatmap_view.wanted_music_time = res.time
                            }
                        }

                        x, y = 0, y - line_height
                    }
                }
            }
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
