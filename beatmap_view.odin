package main

import "af"
import "audio"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "osu"


beatmap_time: f64 = 0
wanted_music_time: f64 = 0

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

set_beatmap_view_error :: proc(msg: string, audio_err: audio.AudioError) {
    beatmap_view_error = msg
    beatmap_view_error_audio = audio_err
}

/**

Main objectives:

- test my odin renderer, get better at programming, find edges of the Odin language
- more natural looking osu AI movement

TODO:

- General issues
    - [] song playback desyncs if I scroll far enough, not sure why :(


- Combo-colours
- Hit objects
    - [x] load them from the beatmap
    - [x] circles, slider heads
    - [x] slider bodies
    - [] object stacking
    - [] slider snaking animation
        - [x] code support
    - [] slider un-snaking animation, i.e receeding from the start towards the end, in earlier Lazer videos
        - [] code support
    - [x] spinners
    - [] approach circles
    - [] slider repeat arrows
    - [] followpoints
    - spinners
        - [x] outline
        - [] spin animation
    - [] combo numbers
    - combo colours
        - [] basic support
        - [] load them from the beatmap

- [] Background image
- Music
    - [x] basic support
    - [] load and use the beatmap music
- Hitsounds
    - [] basic support
    - [] load and use the beatmap hitsounds

- AI cursor
    - [] osu! auto mod movement
    - [] more natural looking osu AI movement
*/


draw_hit_object :: proc(beatmap: ^osu.Beatmap, index: int, preempt, fade_in: f64) {
    // TODO: move
    osu.calculate_object_end_time(beatmap, index)
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

    thickness :: 5
    circle_pos := osu_to_view(hit_object.position)
    circle_radius := osu_to_view({osu.get_circle_size(beatmap), 0}).x

    if hit_object.type == .Slider {
        // draw slider body

        draw_control_points :: false

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

        // The main slider body. 
        // TODO: get this fully working
        osu.generate_slider_path(
            hit_object.slider_nodes,
            &slider_path_buffer,
            &slider_path_buffer_temp,
            hit_object.slider_length,
            10,
        )

        if len(slider_path_buffer) > 0 {
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
            stroke_slider_path :: proc(thickness: f32) {
                for i in 1 ..< len(slider_path_buffer) {
                    p0 := osu_to_view(slider_path_buffer[i - 1])
                    p1 := osu_to_view(slider_path_buffer[i])
                    af.draw_line(af.im, p0, p1, thickness, .Circle)
                }
            }

            af.set_stencil_mode(.WriteOnes)
            af.clear_stencil()
            af.set_draw_color(color = af.Color{0, 0, 0, 0})
            stroke_slider_path((circle_radius - thickness) * 2)
            af.set_stencil_mode(.DrawOverZeroes)
            af.set_draw_color(color = af.Color{1, 1, 1, 1})
            stroke_slider_path(circle_radius * 2)
            af.set_stencil_mode(.Off)

            af.set_framebuffer(nil)
            af.set_layout_rect(af.window_rect, false)
            af.set_draw_params(color = {1, 1, 1, opacity}, texture = slider_framebuffer_texture)
            af.draw_rect(af.im, af.window_rect)
            af.set_layout_rect(original_layout_rect, false)
        }
    }

    if hit_object.type == .Circle || hit_object.type == .Slider {
        // draw circle or slider head on top of the bezier curve
        af.set_draw_params(color = af.Color{1, 1, 1, 1 * opacity}, texture = nil)
        af.draw_circle_outline(af.im, circle_pos, circle_radius - thickness, 64, thickness)

        af.set_draw_color(color = af.Color{1, 1, 1, 0.3 * opacity})
        af.draw_circle(af.im, circle_pos, circle_radius - thickness, 64)

        if beatmap_time < hit_object.time && beatmap_time + fade_in > hit_object.time {
            // draw the approach circle

        }
    }


    if hit_object.type == .Slider {
        // slider ball
        pos, ok := osu.get_slider_ball_pos(slider_path_buffer, hit_object, beatmap_time)
        if ok {
            pos := osu_to_view(pos)

            af.set_draw_params(color = {0, 1, 1, 0.5})
            af.draw_circle(af.im, pos, circle_radius * 1.25, 64)
        }
    }
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
    }

    if af.key_just_pressed(.Space) {
        if audio.is_playing() {
            audio.set_playback_seconds(wanted_music_time)
        }

        audio.set_playing(!audio.is_playing())
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

    iterator_start := osu.BeatmapIterator {
        beatmap = beatmap,
        t0      = t0,
        t1      = t1,
    }

    iterator := iterator_start
    for hit_object_index in osu.beatmap_iterator(&iterator) {
        draw_hit_object(beatmap, hit_object_index, preempt, fade_in)
    }

    af.set_draw_color(color = af.Color{1, 0, 0, 1})
    af.draw_font_text(
        af.im,
        source_code_pro_regular,
        fmt.tprintf("t=%v to %v", t0, t1),
        32,
        {0, af.vh() - 32},
    )
}


view_beatmap :: proc(beatmap_folder: string, beatmap_filename: string) -> string {
    current_beatmap_folder = beatmap_folder
    current_beatmap_filename = beatmap_filename
    set_screen(.BeatmapView)
    return ""
}

load_current_beatmap :: proc() {
    beatmap_time = 0
    wanted_music_time = 0

    // clean up previous beatmap.
    if beatmap != nil {
        osu.free_osu_beatmap(beatmap)
        beatmap = nil

        audio.free_music(music)
        music = nil
    }

    // initialize this beatmap.

    beatmap_fullpath := filepath.join([]string{current_beatmap_folder, current_beatmap_filename})
    defer delete(beatmap_fullpath)
    beatmap = osu.new_osu_beatmap(beatmap_fullpath)
    if beatmap == nil {
        set_beatmap_view_error("Failed to load beatmap", {})
        return
    }

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
        set_screen(.BeatmapPickeView)
        return
    }

    if screens_moved {
        screens_moved = false

        load_current_beatmap()
    }

    draw_osu_beatmap(beatmap)
}
