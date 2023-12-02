package main

import "af"
import "audio"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
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


PointSimulation :: struct {
    pos, vel, accel:    af.Vec2,
    targets:            [dynamic]af.Vec2,
    color:              af.Color,
    total_time_taken:   f32,
    current_time_taken: f32,
    accel_params:       AccelParams,
}


target_radius: f32 = 100
radius_thinggy: f32 = 10
point_simulations: [2]PointSimulation

sec_between_targets: f32 = 0.0

// p_t: f32
first := true
motion_integration_test :: proc() -> bool {
    af.clear_screen({})

    if af.key_just_pressed(.N) {
        for i in 0 ..< 10 {
            p := af.Vec2{rand.float32() * af.vw(), rand.float32() * af.vh()}
            for i in 0 ..< len(point_simulations) {
                append(&point_simulations[i].targets, p)
            }
        }
    }

    adjust_value_with_mousewheel("sec_between_targets", &sec_between_targets, .S, 0.05)
    adjust_value_with_mousewheel(
        "accel_limit",
        &point_simulations[1].accel_params.max_accel,
        .D,
        0.05 * point_simulations[1].accel_params.max_accel,
    )
    adjust_value_with_mousewheel(
        "sim[1].overshoot_param",
        &point_simulations[1].accel_params.overshoot_multuplier,
        .F,
        0.1,
    )

    if af.key_just_pressed(.Escape) {
        return false
    }

    PHYSICS_DT :: AI_REPLAY_DT / 32

    for i in 0 ..< len(point_simulations) {
        targets := &point_simulations[i].targets
        sim_col := point_simulations[i].color

        freeze_time := af.key_is_down(.Shift)
        if freeze_time &&
           (af.mouse_button_just_pressed(.Left) ||
                   af.key_just_pressed(.Z) ||
                   af.key_just_pressed(.X)) {
            target := af.get_mouse_pos()
            if len(targets) == 0 {
                point_simulations[i].total_time_taken = 0
                point_simulations[i].current_time_taken = 0
            }
            append(targets, target)
        }

        if af.key_just_pressed(.R) {
            point_simulations[i].pos = {af.vw() / 2, af.vh() / 2}
            point_simulations[i].vel = {}
            point_simulations[i].accel = {}
            clear(targets)
        }


        for i in 0 ..< len(targets) {
            target := targets[i]
            col: af.Color = sim_col
            col[3] = f32(len(targets) - i) / f32(len(targets))

            af.set_draw_color(col)
            af.draw_circle_outline(af.im, target, target_radius, 64, 1)
            af.draw_line(af.im, target + {0, target_radius}, target - {0, target_radius}, 1, .None)
            af.draw_line(af.im, target + {target_radius, 0}, target - {target_radius, 0}, 1, .None)
        }


        target := af.Vec2{af.vw() / 2, af.vh() / 2}
        if len(targets) > 0 {
            target = targets[0]
        }
        next_target := af.Vec2{af.vw() / 2, af.vh() / 2}
        if len(targets) > 1 {
            next_target = targets[1]
        }

        af.set_draw_color(sim_col)
        af.draw_circle(af.im, point_simulations[i].pos, radius_thinggy, 64)

        if !freeze_time {
            time_taken := point_simulations[i].current_time_taken
            remaining_time := sec_between_targets - time_taken
            accel := get_cursor_acceleration(
                point_simulations[i].pos,
                point_simulations[i].vel,
                target,
                next_target,
                remaining_time,
                sec_between_targets,
                point_simulations[i].accel_params,
            )
            integrate_motion(
                &point_simulations[i].vel,
                &point_simulations[i].pos,
                accel,
                PHYSICS_DT,
            )

            if len(targets) > 0 {
                point_simulations[i].total_time_taken += PHYSICS_DT
                point_simulations[i].current_time_taken += PHYSICS_DT
            }
        }

        if len(targets) > 0 {
            target = targets[0]

            HIT_WINDOW :: 0.005

            TOLERANCE :: 10
            if linalg.length(target - point_simulations[i].pos) < TOLERANCE &&
               point_simulations[i].current_time_taken >= sec_between_targets - HIT_WINDOW {
                ordered_remove(targets, 0)
                point_simulations[i].current_time_taken = 0
            }
        }
    }

    y: f32 = 0
    s: f32 = 32
    for i in 0 ..< len(point_simulations) {
        af.set_draw_color(point_simulations[i].color)
        af.draw_font_text(
            af.im,
            source_code_pro_regular,
            fmt.tprintf("point %v - %v", i, point_simulations[i].total_time_taken),
            s,
            {0, y},
        )
        y += s + 2
    }

    return true
}


main :: proc() {
    init()
    defer cleanup()

    set_screen(.BeatmapPickeView)
    af.run_main_loop(render)

    // point_simulations[0].color = af.Color{0, 0, 1, 1}
    // point_simulations[0].overshoot_multuplier = 1.2
    // point_simulations[1].color = af.Color{1, 0, 0, 1}
    // point_simulations[1].overshoot_multuplier = 1.2
    // af.run_main_loop(motion_integration_test)
}


adjust_value_with_mousewheel :: proc(
    name: string,
    val: ^f32,
    key_code: af.KeyCode,
    increment: f32,
) -> bool {
    if af.key_is_down(key_code) {
        af.set_draw_color({1, 0, 0, 1})
        af.draw_font_text_pivoted(
            af.im,
            source_code_pro_regular,
            fmt.tprintf("adjusting %v... %v", name, val^),
            32,
            {af.vw() / 2, af.vh() / 2},
            {0.5, 0.5},
        )


        if abs(af.mouse_wheel_notches) > 0.0001 {
            val^ += af.mouse_wheel_notches * increment
            return true
        }
    }

    return false
}
