package main

import "af"
import "audio"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "osu"


g_source_code_pro_regular: ^af.DrawableFont

App :: struct {
    curent_fps_count, fps: int,
    time:                  f32,
    screen:                AppScreen,
    screen_changed:        bool,
}
g_app := App {
    screen = .BeatmapPickeView,
}

AppScreen :: enum {
    BeatmapPickeView,
    BeatmapView,
    Exit,
}

set_screen :: proc(screen: AppScreen) {
    g_app.screen = screen
    g_app.screen_changed = true
}

count_and_draw_fps :: proc() {
    g_app.time += af.delta_time
    g_app.curent_fps_count += 1
    if g_app.time > 1 {
        g_app.fps = g_app.curent_fps_count
        g_app.curent_fps_count = 0
        g_app.time = 0
    }

    af.set_draw_params(color = g_current_theme.Foreground)
    af.draw_font_text_pivoted(
        af.im,
        g_source_code_pro_regular,
        fmt.tprintf("fps: %v", g_app.fps),
        16,
        {af.vw() - 8, 8},
        {1, 0},
    )
}


init :: proc() {
    audio.initialize()

    af.initialize(800, 600)

    af.set_window_title("Osu Renderer!")
    af.maximize_window()
    af.show_window()

    g_source_code_pro_regular = af.new_font("./res/SourceCodePro-Regular.ttf", 64)

    // initialize the beatmap 
    g_beatmap_view.slider_framebuffer_texture = af.new_texture_from_size(1, 1)
    g_beatmap_view.slider_framebuffer = af.new_framebuffer(
        g_beatmap_view.slider_framebuffer_texture,
    )
}


cleanup :: proc() {
    // uninit main program
    defer audio.un_initialize()
    defer af.un_initialize()
    defer af.free_font(g_source_code_pro_regular)

    // uninit beatmap view
    defer af.free_texture(g_beatmap_view.slider_framebuffer_texture)
    defer af.free_framebuffer(g_beatmap_view.slider_framebuffer)
    defer beatmap_view_cleanup()
}


render :: proc() -> bool {
    af.clear_screen(g_current_theme.Background)

    base_layout := af.layout_rect

    current_screen := g_app.screen
    switch current_screen {
    case .BeatmapPickeView:
        draw_beatmap_picker()
    case .BeatmapView:
        draw_beatmap_view()
    case .Exit:
    // should be unreachable, as we should have exited at the 
    // end of the frame where we moved to .Exit
    }

    af.set_layout_rect(base_layout)
    count_and_draw_fps()
    if g_app.screen == .Exit {
        return false
    }

    return true
}


PointSimulation :: struct {
    graph_points_1:     [dynamic]af.Vec2,
    pos, vel, accel:    af.Vec2,
    targets:            [dynamic]af.Vec2,
    color:              af.Color,
    total_time_taken:   f32,
    current_time_taken: f32,
    accel_params:       AccelParams,
}


g_motion_integration_test: struct {
    point_simulations:   []PointSimulation,
    sec_between_targets: f32,
    // p_t: f32
    first:               bool,
} = {
    first               = true,
    sec_between_targets = 0.1,
    point_simulations   = []PointSimulation {
        {
            color = af.Color{1, 0, 0, 1},
            accel_params = {
                use_dynamic_axis = false,
                overshoot_multuplier = 1,
                delta_accel_factor = 1,
                max_accel = 99999999,
                use_flow_aim = false,
            },
        }, 
        {
            color = af.Color{0, 1, 0, 1},
            accel_params = {
                use_alternate_accelerator = true,
                use_dynamic_axis = false,
                overshoot_multuplier = 1,
                delta_accel_factor = 1,
                max_accel = 99999999,
                use_flow_aim = false,
            },
        },
    },
}


run_motion_integration_test :: proc() -> bool {
    af.clear_screen({})
    test := &g_motion_integration_test

    if af.key_just_pressed(.N) {
        for i in 0 ..< 10 {
            p := af.Vec2{rand.float32() * af.vw(), rand.float32() * af.vh()}
            for i in 0 ..< len(test.point_simulations) {
                append(&test.point_simulations[i].targets, p)
            }
        }
    }

    adjust_value_with_mousewheel("sec_between_targets", &test.sec_between_targets, .S, 0.01)
    adjust_value_with_mousewheel(
        "delta accel fac",
        &test.point_simulations[0].accel_params.delta_accel_factor,
        .D,
        0.05,
    )

    if af.key_just_pressed(.Escape) {
        return false
    }

    PHYSICS_DT :: AI_REPLAY_DT / 32

    draw_graph :: proc(graph: [dynamic]af.Vec2, ymul: f32 = 1) {
        if len(graph) <= 2 {
            return
        }

        corner_min, corner_max := graph[0], graph[0]
        for i in 1 ..< len(graph) {
            p := graph[i]
            corner_min.x = min(corner_min.x, p.x)
            corner_min.y = min(corner_min.y, p.y)
            corner_max.x = max(corner_max.x, p.x)
            corner_max.y = max(corner_max.y, p.y)
        }


        for i in 1 ..< len(graph) {
            p0 := graph[i - 1]
            p1 := graph[i]

            x0 := inv_lerp(corner_min.x, corner_max.x, p0.x) * af.vw()
            y0 := inv_lerp(corner_min.y, corner_max.y, p0.y * ymul) * af.vh()
            x1 := inv_lerp(corner_min.x, corner_max.x, p1.x) * af.vw()
            y1 := inv_lerp(corner_min.y, corner_max.y, p1.y * ymul) * af.vh()

            af.draw_line(af.im, {x0, y0}, {x1, y1}, 2, .None)
        }
    }

    point_simulations := test.point_simulations

    for &sim in point_simulations {
        freeze_time := af.key_is_down(.Shift)
        if freeze_time &&
           (af.mouse_button_just_pressed(.Left) ||
                   af.key_just_pressed(.Z) ||
                   af.key_just_pressed(.X)) {
            target := af.get_mouse_pos()
            if len(sim.targets) == 0 {
                sim.total_time_taken = 0
                sim.current_time_taken = 0
                clear(&sim.graph_points_1)
            }
            append(&sim.targets, target)
        }

        if af.key_just_pressed(.R) {
            sim.pos = {af.vw() / 2, af.vh() / 2}
            sim.vel = {}
            sim.accel = {}
            sim.current_time_taken = 0
            sim.total_time_taken = 0
            clear(&sim.targets)
        }

        target_radius: f32 : 100

        // draw some stuff
        {
            // targets
            {

                for i in 0 ..< len(sim.targets) {
                    target := sim.targets[i]
                    col: af.Color = sim.color
                    col[3] = f32(len(sim.targets) - i) / f32(len(sim.targets))


                    af.set_draw_color(col)
                    af.draw_circle_outline(af.im, target, target_radius, 64, 1)
                    af.draw_line(
                        af.im,
                        target + {0, target_radius},
                        target - {0, target_radius},
                        1,
                        .None,
                    )
                    af.draw_line(
                        af.im,
                        target + {target_radius, 0},
                        target - {target_radius, 0},
                        1,
                        .None,
                    )
                }
            }

            // the cursor
            radius_thinggy :: 50
            af.set_draw_color(sim.color)
            af.draw_circle(af.im, sim.pos, radius_thinggy, 64)

            // velocity debug info
            draw_graph(sim.graph_points_1)

            display_constant :: 0.001

            // acceleration debug info
            af.set_draw_color({1, 1, 1, 1})
            af.draw_line(af.im, sim.pos, sim.pos - display_constant * sim.accel, 10, .Circle)
            af.set_draw_color({ 0, 1, 0, 1})
            af.draw_line(af.im, sim.pos, sim.pos + sim.accel_params.predicted_distance, 10, .Circle)
            af.draw_font_text(
                af.im,
                g_source_code_pro_regular,
                fmt.tprintf("%0.4v", display_constant * sim.accel),
                50,
                sim.pos + {10, 10},
            )

            af.set_draw_color(sim.color)
        }

        // run the simulation
        if !freeze_time {
            time_taken := sim.current_time_taken
            remaining_time := test.sec_between_targets - time_taken

            target := af.Vec2{af.vw() / 2, af.vh() / 2}
            if len(sim.targets) > 0 {
                target = sim.targets[0]
            }
            next_target := af.Vec2{af.vw() / 2, af.vh() / 2}
            if len(sim.targets) > 1 {
                next_target = sim.targets[1]
            }

            sim.accel = get_cursor_acceleration(
                sim.pos,
                sim.vel,
                sim.accel,
                target,
                next_target,
                remaining_time,
                test.sec_between_targets,
                &sim.accel_params,
            )
            integrate_motion(&sim.vel, &sim.pos, sim.accel, PHYSICS_DT)

            // graph v
            append(&sim.graph_points_1, af.Vec2{sim.total_time_taken, sim.vel.x})

            if len(sim.targets) > 0 {
                sim.total_time_taken += PHYSICS_DT
                sim.current_time_taken += PHYSICS_DT
            }
        }

        if len(sim.targets) > 0 {
            target := sim.targets[0]

            HIT_WINDOW :: 0.005
            TOLERANCE :: target_radius

            if linalg.length(target - sim.pos) < TOLERANCE &&
               sim.current_time_taken >= test.sec_between_targets - HIT_WINDOW {
                ordered_remove(&sim.targets, 0)
                sim.current_time_taken = 0
            }
        }
    }

    y: f32 = 0
    s: f32 = 32
    for i in 0 ..< len(point_simulations) {
        af.set_draw_color(point_simulations[i].color)
        af.draw_font_text(
            af.im,
            g_source_code_pro_regular,
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

    testing :: true

    for af.new_update_frame() {
        af.begin_render_frame()

        res: bool
        when !testing {
            res = render()
        } else {
            res = run_motion_integration_test()
        }

        if !res {
            break
        }

        af.end_render_frame()
    }
}


adjust_value_with_mousewheel :: proc(
    name: string,
    val: ^f32,
    key_code: af.KeyCode,
    increment: f32,
) -> bool {
    if af.key_is_down(key_code) {
        af.set_draw_color(g_current_theme.Foreground)
        af.draw_font_text_pivoted(
            af.im,
            g_source_code_pro_regular,
            fmt.tprintf("adjusting %v... %0.6v", name, val^),
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
