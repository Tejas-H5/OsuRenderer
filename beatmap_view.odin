package main

import "af"
import "audio"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "osu"


beatmap_time: f64 = 0
wanted_music_time: f64 = 0

beatmap_first_visible: int

slider_path_buffer := [dynamic]af.Vec2{}
slider_path_buffer_temp := [dynamic]af.Vec2{}

slider_framebuffer: ^af.Framebuffer
slider_framebuffer_texture: ^af.Texture

music: ^audio.Music
beatmap: ^osu.Beatmap

current_beatmap_folder: string
current_beatmap_filename: string
beatmap_view_error: string
beatmap_view_error_audio: audio.AudioError

seek_debounce_timer: f32 = 0
seek_debounce_timer_amount :: 1
draw_control_points := false

set_beatmap_view_error :: proc(msg: string, audio_err: audio.AudioError) {
    beatmap_view_error = msg
    beatmap_view_error_audio = audio_err
}


SLIDER_LOD :: 10

draw_hit_object :: proc(beatmap: ^osu.Beatmap, index: int, preempt, fade_in: f64) {
    // TODO: move
    hit_object := beatmap.hit_objects[index]
    original_layout_rect := af.layout_rect

    opacity := osu.calculate_opacity(hit_object, beatmap, beatmap_time, fade_in, fade_in)

    af.set_draw_params()

    if hit_object.type == .Spinner {
        // TODO: draw fan

        spinner_radius := min(af.vw(), af.vh()) / 2 - 20

        af.set_draw_color({1, 1, 1, 1})
        af.draw_circle_outline(af.im, {af.vw() / 2, af.vh() / 2}, spinner_radius, 64, 20)
        return
    }


    osu_to_view :: proc(pos: af.Vec2) -> af.Vec2 {
        x := pos.x
        y := pos.y
        return {af.vw() * f32(x) / 512, af.vh() * (1 - f32(y) / 384)}
    }

    osu_to_view_dir :: proc(dir: af.Vec2) -> af.Vec2 {
        return osu_to_view(dir) - osu_to_view({0, 0})
    }


    circle_radius_osu := osu.get_circle_radius(beatmap)
    circle_radius := osu_to_view_dir({circle_radius_osu, 0}).x
    thickness: f32 = circle_radius / 10

    // stack_offset_amount is the stack offset from https://gist.github.com/peppy/1167470
    // NOTE(peppy): ymmv
    stack_offset_osu := (circle_radius_osu / 10) * af.Vec2{1, 1}
    circle_pos := osu_to_view(osu.get_hit_object_stacked_position(hit_object, circle_radius_osu))

    if hit_object.type == .Slider {
        // draw slider body

        if draw_control_points {
            // control points. TODO: remove or something
            for i in 1 ..< len(hit_object.slider_nodes) {
                node0 := hit_object.slider_nodes[i - 1]
                node1 := hit_object.slider_nodes[i]
                pos0 := osu_to_view(node0.pos)
                pos1 := osu_to_view(node1.pos)


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
            snake_duration :: 0.2
            t: f32 =
                1 -
                math.min(
                    1,
                    math.max(0, -f32(beatmap_time - hit_object.start_time) / snake_duration),
                )
            slider_end_length = t * hit_object.slider_length
        }

        // The main slider body. 
        // TODO: get this fully working
        osu.generate_slider_path(
            hit_object.slider_nodes,
            &slider_path_buffer,
            &slider_path_buffer_temp,
            slider_end_length,
            SLIDER_LOD,
        )

        if len(slider_path_buffer) >= 2 {
            // draw slider end
            slider_end_pos := slider_path_buffer[len(slider_path_buffer) - 1]
            af.set_draw_params(color = af.Color{1, 1, 1, 1 * opacity}, texture = nil)
            af.draw_circle_outline(af.im, circle_pos, circle_radius - thickness, 64, thickness)

            // draw the slider body to a framebuffer, then blit that framebuffer to the screen with an opacity
            af.resize_framebuffer(
                slider_framebuffer,
                int(af.window_rect.width),
                int(af.window_rect.height),
            )
            af.set_framebuffer(slider_framebuffer)
            af.clear_screen({0, 0, 0, 0})
            stroke_slider_path :: proc(thickness: f32, slider_end_length: f32) {
                iter: osu.SliderPathIterator
                for p0, p1 in osu.slider_path_iterator(
                    &iter,
                    slider_path_buffer,
                    0,
                    slider_end_length,
                ) {
                    p0 := osu_to_view(p0)
                    p1 := osu_to_view(p1)
                    af.draw_line(af.im, p0, p1, thickness, .Circle)
                }
            }

            af.set_stencil_mode(.WriteOnes)
            af.clear_stencil()
            af.set_draw_color(color = af.Color{0, 0, 0, 0})
            stroke_slider_path((circle_radius - thickness) * 2, slider_end_length)
            af.set_stencil_mode(.DrawOverZeroes)
            af.set_draw_color(color = af.Color{1, 1, 1, 1})
            stroke_slider_path(circle_radius * 2, slider_end_length)
            af.set_stencil_mode(.Off)

            af.set_framebuffer(nil)
            af.set_layout_rect(af.window_rect, false)
            af.set_draw_params(color = {1, 1, 1, opacity}, texture = slider_framebuffer_texture)
            af.draw_rect(af.im, af.window_rect)
            af.set_layout_rect(original_layout_rect, false)
            // slider ball
            slider_ball_osu_pos, repeat, has_slider_ball := osu.get_slider_ball_pos(
                slider_path_buffer,
                hit_object,
                beatmap_time,
            )
            if has_slider_ball {
                slider_ball_pos := osu_to_view(slider_ball_osu_pos)

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
                angle_vec :: proc(angle, size: f32) -> af.Vec2 {
                    return size * af.Vec2{math.cos(angle), math.sin(angle)}
                }

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

    if hit_object.type == .Circle || hit_object.type == .Slider {
        // draw circle or slider head on top of the bezier curve
        af.set_draw_params(color = af.Color{1, 1, 1, 1 * opacity}, texture = nil)
        af.draw_circle_outline(af.im, circle_pos, circle_radius - thickness, 64, thickness)

        af.set_draw_color(color = af.Color{0, 0, 0, 1 * opacity})
        af.draw_circle_outline(af.im, circle_pos, circle_radius, 64, 1)

        af.set_draw_color(color = af.Color{0, 1, 1, 0.5 * opacity})
        af.draw_circle(af.im, circle_pos, circle_radius - thickness, 64)

        nc_number_text_size := circle_radius
        af.set_draw_color(color = {1, 1, 1, opacity})
        af.draw_font_text_pivoted(
            af.im,
            source_code_pro_regular,
            fmt.tprintf("%d", hit_object.combo_number),
            nc_number_text_size,
            circle_pos - {0, nc_number_text_size / 2},
            -0.5,
        )

        if beatmap_time < hit_object.start_time && beatmap_time + preempt > hit_object.start_time {
            approach_circle_thickness :: 5

            approach_circle_radius_max := circle_radius * 4
            approach_circle_radius := math.lerp(
                circle_radius,
                approach_circle_radius_max,
                f32((hit_object.start_time - beatmap_time) / preempt),
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

    // if hit_object.type == .Slider {
    // text := fmt.tprintf("cost: %v", len(slider_path_buffer))
    // af.set_draw_color({0, 1, 0, 1})
    // af.draw_font_text(af.im, source_code_pro_regular, text, 32, circle_pos)
    // }
}

draw_osu_beatmap :: proc(beatmap: ^osu.Beatmap) {
    preempt := f64(osu.get_preempt(beatmap))
    fade_in := f64(osu.get_fade_in(beatmap))

    // playback input
    scroll_speed: f64 = 0.25 * (preempt)
    if af.key_is_down(.Shift) {
        scroll_speed *= 10
    }
    if abs(af.mouse_wheel_notches) > 0.01 {
        wanted_music_time -= f64(af.mouse_wheel_notches) * scroll_speed
        seek_debounce_timer = seek_debounce_timer_amount
    }

    if af.key_just_pressed(.C) {
        draw_control_points = !draw_control_points
    }

    if af.key_just_pressed(.Space) {
        audio.set_playing(!audio.is_playing())

        if audio.is_playing() {
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

        if seek_debounce_timer > 0 {
            seek_debounce_timer -= af.delta_time
        } else {
            audio.set_playback_seconds(wanted_music_time)
        }
    }

    // make our playfield 4:3
    rect := af.layout_rect
    aspect := af.layout_rect.width / af.layout_rect.height
    if aspect > 4 / 3 {
        af.set_rect_width(&rect, rect.height * 4 / 3, 0.5)
    } else {
        af.set_rect_height(&rect, rect.width * 3 / 4, 0.5)
    }
    af.set_layout_rect(rect)

    // ---- draw the objects

    af.set_draw_params(color = af.Color{1, 0, 0, 1}, texture = nil)
    af.draw_rect_outline(af.im, {0, 0, af.vw(), af.vh()}, 4)

    t0 := beatmap_time - preempt
    t1 := beatmap_time + fade_in

    beatmap_first_visible = osu.beatmap_get_first_visible(beatmap, t0, beatmap_first_visible)
    beatmap_last_visible := osu.beatmap_get_last_visible(beatmap, t1, beatmap_first_visible)
    for i := beatmap_last_visible; i >= beatmap_first_visible; i -= 1 {
        draw_hit_object(beatmap, i, preempt, fade_in)
    }

    af.set_draw_color(color = af.Color{1, 0, 0, 1})

    draw_debug_text :: proc(text: string, x: f32) -> f32 {
        res := af.draw_font_text(af.im, source_code_pro_regular, text, 32, {x, af.vh() - 32})

        padding :: 0
        return x + res.width + padding
    }

    x := draw_debug_text(fmt.tprintf("%v <- %v -> %v", t0, beatmap_time, t1), 0)
    x = draw_debug_text(
        fmt.tprintf(
            " | objects %v to %v of %v",
            beatmap_first_visible,
            beatmap_last_visible,
            len(beatmap.hit_objects),
        ),
        x,
    )
    if seek_debounce_timer > 0 {
        x = draw_debug_text(fmt.tprintf(" | %vs till reseek", seek_debounce_timer), x)
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

load_current_beatmap :: proc() {
    beatmap_time = 0
    wanted_music_time = 0

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
        osu.recalculate_object_values(
            beatmap,
            i,
            &slider_path_buffer,
            &slider_path_buffer_temp,
            SLIDER_LOD,
        )
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

    draw_osu_beatmap(beatmap)
}
