package main

import "af"
import "audio"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "osu"

source_code_pro_regular: ^af.DrawableFont
curent_fps_count := 0
fps := 0
time: f32 = 0
count_and_draw_fps :: proc() {
    time += af.delta_time
    curent_fps_count += 1
    if time > 1 {
        fps = curent_fps_count
        curent_fps_count = 0
        time = 0
    }

    af.set_draw_params(color = {1, 0, 0, 1})
    af.draw_font_text_pivoted(
        af.im,
        source_code_pro_regular,
        fmt.tprintf("fps: %v", fps),
        32,
        {af.vw() - 10, 0},
        {1, 0},
    )
}


Testcase :: struct {
    beatmap_path: string,
    music_path:   cstring,
}


testcase_lil_darkie := Testcase {
    beatmap_path = "./res/Beatmaps/TestBeatmap/LIL DARKIE - AMV (emilia) [NIHIL'S UNHINGED].osu",
    music_path   = "./res/Beatmaps/TestBeatmap/audio.mp3",
}

testcase_centipede := Testcase {
    beatmap_path = "./res/Beatmaps/Centipede/Knife Party - Centipede (Plumato444) [Enjoying long walk on the beach with Gumi.].osu",
    music_path   = "./res/Beatmaps/Centipede/02-knife_party-centipede.mp3",
}


init :: proc() {
    audio.initialize()

    af.initialize(800, 600)

    af.set_window_title("Osu Renderer!")
    af.maximize_window()
    af.show_window()

    source_code_pro_regular = af.new_font("./res/SourceCodePro-Regular.ttf", 64)

    // initialize the beatmap view
    slider_framebuffer_texture = af.new_texture_from_size(1, 1)
    slider_framebuffer = af.new_framebuffer(slider_framebuffer_texture)
}


cleanup :: proc() {
    // uninit main program
    defer audio.un_initialize()
    defer af.un_initialize()
    defer af.free_font(source_code_pro_regular)

    // uninit beatmap view
    defer af.free_texture(slider_framebuffer_texture)
    defer af.free_framebuffer(slider_framebuffer)
    defer beatmap_view_cleanup()
}


AppScreen :: enum {
    BeatmapPickeView,
    BeatmapView,
    Exit,
}

screens_moved := false
current_screen := AppScreen.BeatmapPickeView
set_screen :: proc(screen: AppScreen) {
    current_screen = screen
    screens_moved = true
}

render :: proc() -> bool {
    af.clear_screen({0, 0, 0, 0})

    base_layout := af.layout_rect

    current_screen_original := current_screen
    switch current_screen {
    case .BeatmapPickeView:
        draw_beatmap_picker()
    case .BeatmapView:
        draw_beatmap_view()
    case .Exit:
    // break (does nothing here cause its a switch lol)
    }

    af.set_layout_rect(base_layout)
    count_and_draw_fps()

    if current_screen == .Exit {
        return false
    }

    return true
}


p_pos: af.Vec2
p_vel, p_accel: af.Vec2
target: af.Vec2
max_accel: f32 = 100


// p_t: f32
motion_integration_test :: proc() -> bool {
    // some code to accelerate a point to another point as fast as possible.

    af.clear_screen({0, 0, 0, 0})
    if af.key_just_pressed(.Escape) {
        return false
    }

    if af.key_just_pressed(.R) {
        p_pos = {af.vw() / 2, af.vh() / 2}
        p_vel = {}
        p_accel = {}
    }

    af.set_draw_params(color = {1, 1, 1, 1})
    if af.mouse_any_down {
        target = af.get_mouse_pos()
        // p_t = 0.1
    }

    af.set_draw_color({1, 0, 0, 1})
    af.draw_circle(af.im, target, 50, 64)

    af.set_draw_color({1, 1, 1, 1})
    af.draw_circle(af.im, p_pos, 50, 64)

    get_remaining_time :: proc(s, v, s1: f32) -> f32 {
        dist := s1 - s
        accel_sign := math.sign(dist)
        accel := accel_sign * max_accel
        r1, r2 := quadratic_equation(0.5 * accel, v, -dist)

        return max(r1, r2)
    }


    distance_constant_accel :: proc(a, v0, t: f32) -> f32 {
        t := abs(t)
        return 0.5 * a * t * t + v0 * t
    }


    // TODO: right now our axes are the x and y global. But we could just as easily use a coordinate system that is aligned with 
    // pos->target, right?
    get_acceleration :: proc(pos, velocity, target: af.Vec2) -> af.Vec2 {
        get_acceleration_axis :: proc(s, v, s1: f32) -> f32 {
            dist := s1 - s
            accel_sign := math.sign(dist)
            accel := accel_sign * max_accel
            rt1, rt2 := quadratic_equation(0.5 * accel, v, -dist)
            remaining_time := max(rt1, rt2) // whichever is positive

            if (accel > 0 && dist > 0) || (accel < 0 && dist < 0) {
                decel := -accel
                braking_time := abs(v) / abs(decel)
                braking_distance := distance_constant_accel(decel, v, braking_time)

                if (dist < 0 && braking_distance < dist) || (dist > 0 && braking_distance > dist) {
                    return decel
                }

                return accel
            }

            return accel
        }

        ax := get_acceleration_axis(pos.x, velocity.x, target.x)
        ay := get_acceleration_axis(pos.y, velocity.y, target.y)
        return {ax, ay}
    }

    decel_dist: af.Vec2
    // p_accel = get_acceleration(p_pos, p_vel, target)
    PHYSICS_DT :: 0.02
    integrate_motion(&p_vel, &p_pos, p_accel, PHYSICS_DT)

    rt := get_remaining_time(p_pos.x, p_vel.x, target.x)
    af.draw_font_text(af.im, source_code_pro_regular, fmt.tprintf("remaining: %v", rt), 32, target)


    if p_accel.x > 0 {
        af.set_draw_color({0, 1, 0, 1})
    } else {
        af.set_draw_color({1, 0, 0, 1})

    }

    af.draw_font_text(
        af.im,
        source_code_pro_regular,
        fmt.tprintf("accel: %v", p_accel.x),
        32,
        p_pos + {10, 10},
    )


    // af.draw_line(af.im, p_pos + {decel_dist.x, 10}, p_pos + {decel_dist.x, -10}, 10, .None)
    return true
}

main :: proc() {
    init()
    defer cleanup()

    set_screen(.BeatmapPickeView)
    af.run_main_loop(render)
    // af.run_main_loop(test)
}
