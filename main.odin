package main

import "af"
import "audio"
import "core:fmt"
import "core:math"
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
    af.draw_font_text(af.im, source_code_pro_regular, fmt.tprintf("fps: %v", fps), 32, {0, 0})
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

    source_code_pro_regular = af.new_font("./res/SourceCodePro-Regular.ttf", 32)

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

main :: proc() {
    init()
    defer cleanup()

    set_screen(.BeatmapPickeView)

    for !af.window_should_close() {
        af.begin_frame()
        af.clear_screen({0, 0, 0, 0})

        count_and_draw_fps()

        rect := af.layout_rect
        af.set_rect_size(&rect, rect.width, rect.height - 64, 0.5, 0.5)
        af.set_layout_rect(rect)

        current_screen_original := current_screen
        switch current_screen {
        case .BeatmapPickeView:
            draw_beatmap_picker()
        case .BeatmapView:
            draw_beatmap_view()
        case .Exit:
        // break (does nothing here cause its a switch lol)
        }

        free_all(context.temp_allocator)
        af.end_frame()

        if current_screen == .Exit {
            break
        }
    }
}
