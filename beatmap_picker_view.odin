package main

import "af"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

beatmap_folder_picker := FilePickerState {
    folders_only = true,
}
beatmap_file_picker := FilePickerState {
    files_only     = true,
    file_extension = "osu",
}
beatmap_picker_error: string = ""
beatmap_folder_chosen: bool
beatmap_picker_current_folder: string = ""

refresh_beatmap_picker :: proc() {
    if !refresh_files_list(&beatmap_folder_picker, OSU_DIR) {
        beatmap_picker_error = "Failed to check the osu directory"
    }
}

draw_beatmap_picker :: proc() {
    if screens_moved {
        screens_moved = false
        refresh_beatmap_picker()
    } else if af.key_is_down(.Ctrl) && af.key_just_pressed(.R) {
        refresh_beatmap_picker()
    }

    if beatmap_picker_error != "" {
        if af.key_just_pressed(.Escape) {
            set_screen(.Exit)
            return
        }

        af.set_draw_params(color = {1, 0, 0, 1})

        error_msg := fmt.tprintf("%v - currently checking \"%v\"", beatmap_picker_error, OSU_DIR)
        // TODO: better text rendering 
        y := af.vh() / 2
        for len(error_msg) > 0 {
            res := af.draw_font_text_pivoted(
                af.im,
                source_code_pro_regular,
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

    if !beatmap_folder_chosen {
        if af.key_just_pressed(.Escape) {
            set_screen(.Exit)
            return
        }

        draw_file_picker(&beatmap_folder_picker)
        if af.key_just_pressed(.Enter) {
            folder, ok := get_file_picker_selection(&beatmap_folder_picker)
            if ok {
                if beatmap_picker_current_folder != "" {
                    delete(beatmap_picker_current_folder)
                }
                beatmap_picker_current_folder = filepath.join([]string{OSU_DIR, folder})
                if refresh_files_list(&beatmap_file_picker, beatmap_picker_current_folder) {
                    beatmap_folder_chosen = true
                } else {
                    af.debug_info(
                        "couldn't open folder with path %v :(",
                        beatmap_picker_current_folder,
                    )

                    // TODO: figure out how to allocate this memory
                    beatmap_picker_error =
                    "unable to open that folder in particular. see console for more info"
                }
            }
        }
    } else {
        if af.key_just_pressed(.Escape) {
            beatmap_folder_chosen = false
            return
        }

        draw_file_picker(&beatmap_file_picker)
        if af.key_just_pressed(.Enter) {
            file, ok := get_file_picker_selection(&beatmap_file_picker)
            if ok {
                view_beatmap(beatmap_picker_current_folder, file)
                return
            }
        }
    }
}
