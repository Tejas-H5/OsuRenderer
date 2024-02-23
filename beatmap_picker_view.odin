package main

import "af"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

g_beatmap_folder_picker := FilePickerState {
    folders_only = true,
}
g_beatmap_file_picker := FilePickerState {
    files_only     = true,
    file_extension = "osu",
}
g_beatmap_picker_error: string = ""
g_beatmap_folder_chosen: bool
g_beatmap_picker_current_folder: string = ""

refresh_beatmap_picker :: proc() {
    if !refresh_files_list(&g_beatmap_folder_picker, OSU_DIR) {
        g_beatmap_picker_error = "Failed to check the osu directory"
    }
}

draw_beatmap_picker :: proc() {
    if g_app.screen_changed {
        g_app.screen_changed = false
        refresh_beatmap_picker()
    } else if af.key_is_down(.Ctrl) && af.key_just_pressed(.R) {
        refresh_beatmap_picker()
    }

    if g_beatmap_picker_error != "" {
        if af.key_just_pressed(.Escape) {
            set_screen(.Exit)
            return
        }

        af.set_draw_params(color = g_current_theme.Error)

        error_msg := fmt.tprintf("%v - currently checking \"%v\"", g_beatmap_picker_error, OSU_DIR)
        // TODO: better text rendering 
        y := af.vh() / 2
        for len(error_msg) > 0 {
            res := af.draw_font_text_pivoted(
                af.im,
                g_source_code_pro_regular,
                error_msg,
                24,
                {af.vw() / 2, y},
                {0.5, 0.5},
                max_width = af.vw() / 2,
            )

            error_msg = error_msg[res.str_pos:]
            y -= 24
        }
        return
    }

    if !g_beatmap_folder_chosen {
        if af.key_just_pressed(.Escape) {
            set_screen(.Exit)
            return
        }

        draw_file_picker(&g_beatmap_folder_picker)
        if af.key_just_pressed(.Enter) {
            folder, ok := get_file_picker_selection(&g_beatmap_folder_picker)
            if ok {
                if g_beatmap_picker_current_folder != "" {
                    delete(g_beatmap_picker_current_folder)
                }
                g_beatmap_picker_current_folder = filepath.join([]string{OSU_DIR, folder})
                if refresh_files_list(&g_beatmap_file_picker, g_beatmap_picker_current_folder) {
                    g_beatmap_folder_chosen = true
                } else {
                    af.debug_info(
                        "couldn't open folder with path %v :(",
                        g_beatmap_picker_current_folder,
                    )

                    // TODO: figure out how to allocate this memory
                    g_beatmap_picker_error =
                    "unable to open that folder in particular. see console for more info"
                }
            }
        }
    } else {
        if af.key_just_pressed(.Escape) {
            g_beatmap_folder_chosen = false
            return
        }

        draw_file_picker(&g_beatmap_file_picker)
        if af.key_just_pressed(.Enter) {
            file, ok := get_file_picker_selection(&g_beatmap_file_picker)
            if ok {
                view_beatmap(g_beatmap_picker_current_folder, file)
                return
            }
        }
    }
}
