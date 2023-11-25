package main

import "af"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

FilePickerState :: struct {
    file_list:                [dynamic]string, // owns all the strings
    file_list_filtered:       [dynamic]int, // indices into file_list
    file_search_buffer:       [64]byte,
    file_search_buffer_count: int,
    current_file_selection:   int,

    // user-set
    files_only:               bool,
    file_extension:           string,
    folders_only:             bool,
}

get_file_viewer_search_query :: proc(file_picker: ^FilePickerState) -> string {
    return string(file_picker.file_search_buffer[0:file_picker.file_search_buffer_count])
}

get_file_picker_selection :: proc(file_picker: ^FilePickerState) -> (string, bool) {
    if file_picker.current_file_selection < 0 ||
       file_picker.current_file_selection >= len(file_picker.file_list_filtered) {
        return "", false
    }

    return file_picker.file_list[file_picker.file_list_filtered[file_picker.current_file_selection]],
        true
}

file_viewer_filter_files :: proc(file_picker: ^FilePickerState) {
    clear(&file_picker.file_list_filtered)

    current_search_query := get_file_viewer_search_query(file_picker)
    current_search_query_lower := strings.to_lower(current_search_query)
    defer delete(current_search_query_lower)

    for i in 0 ..< len(file_picker.file_list) {
        file_name := file_picker.file_list[i]

        check_match :: proc(str, query: string) -> bool {
            if len(query) == 0 {
                return true
            }

            query := query
            for word in strings.split_iterator(&query, " ") {
                if strings.contains(str, word) {
                    return true
                }
            }

            return false
        }

        file_name_lower := strings.to_lower(file_name)
        defer delete(file_name_lower)

        if check_match(file_name_lower, current_search_query_lower) {
            append(&file_picker.file_list_filtered, i)
        }
    }
}

// TODO: move to osu package if it ends up being any good
refresh_files_list :: proc(file_picker: ^FilePickerState, root_dir: string) -> bool {
    for i in 0 ..< len(file_picker.file_list) {
        delete(file_picker.file_list[i])
    }
    clear(&file_picker.file_list)

    fd, err := os.open(root_dir, os.O_RDONLY)
    if err != 0 {
        return false
    }
    defer os.close(fd)

    dirs: []os.File_Info
    dirs, err = os.read_dir(fd, -1)
    if err != 0 {
        return false
    }
    defer os.file_info_slice_delete(dirs)

    for dir in dirs {
        if file_picker.folders_only && !dir.is_dir {
            continue
        }

        if file_picker.files_only && dir.is_dir {
            continue
        }

        if file_picker.files_only && file_picker.file_extension != "" {
            dir_name_lower := strings.to_lower(dir.name)
            defer delete(dir_name_lower)
            if !strings.has_suffix(dir_name_lower, file_picker.file_extension) {
                continue
            }
        }

        folder_name := strings.clone(dir.name)
        append(&file_picker.file_list, folder_name)
    }

    file_picker.file_search_buffer_count = 0
    file_picker.current_file_selection = -1
    file_viewer_filter_files(file_picker)

    return true
}

// NOTE: this constantly allocates to the temp allocator, which will you should clear every frame
draw_file_picker :: proc(file_viewer: ^FilePickerState) {
    text_size :: 32
    padding :: 5

    // file search input
    {
        inputted_runes: [16]rune
        inputted_runes_count: int
        got_input := false
        for i in 0 ..< af.inputted_runes_count {
            r := af.inputted_runes[i]

            if r != ' ' && strings.is_space(r) {
                continue
            }

            if inputted_runes_count < len(inputted_runes) {
                inputted_runes[inputted_runes_count] = r
                inputted_runes_count += 1
            }
        }

        if file_viewer.file_search_buffer_count > 0 {
            for key in af.get_keys_just_pressed_or_repeated() {
                if key == .Backspace {
                    got_input = true
                    file_viewer.file_search_buffer_count -= 1
                }
            }
        }

        if inputted_runes_count > 0 {
            got_input = true
            // update search query 
            str := utf8.runes_to_string(inputted_runes[0:inputted_runes_count])
            defer delete(str)
            for i in 0 ..< len(str) {
                if file_viewer.file_search_buffer_count < len(file_viewer.file_search_buffer) {
                    file_viewer.file_search_buffer[file_viewer.file_search_buffer_count] = str[i]
                    file_viewer.file_search_buffer_count += 1
                }
            }
        }

        current_search_query := get_file_viewer_search_query(file_viewer)
        search_bar_str := fmt.tprintf("Search: %s", current_search_query)
        af.set_draw_params(color = {1, 1, 1, 1})
        af.draw_font_text_pivoted(
            af.im,
            source_code_pro_regular,
            search_bar_str,
            text_size,
            {af.vw() / 2, af.vh() - 32},
            {0.5, 0.5},
        )

        if got_input {
            file_viewer_filter_files(file_viewer)
        }
    }

    // beatmap selection input

    for key in af.get_keys_just_pressed_or_repeated() {
        if key == .Down {
            file_viewer.current_file_selection += 1
        }

        if key == .Up {
            file_viewer.current_file_selection -= 1
        }
    }

    if file_viewer.current_file_selection < -1 {
        file_viewer.current_file_selection = len(file_viewer.file_list_filtered) - 1
    } else if file_viewer.current_file_selection >= len(file_viewer.file_list_filtered) {
        file_viewer.current_file_selection = -1
    }


    // draw the UI

    y := af.vh() - text_size - padding - 64
    first_file_index := max(0, file_viewer.current_file_selection - 10)
    for i in first_file_index ..< len(file_viewer.file_list_filtered) {
        file_name := file_viewer.file_list[file_viewer.file_list_filtered[i]]

        text_pos := af.Vec2{10, y}
        af.set_draw_params(color = {1, 1, 1, 1})
        res := af.draw_font_text(af.im, source_code_pro_regular, file_name, text_size, text_pos)

        if i == file_viewer.current_file_selection {
            af.draw_rect_outline(
                af.im,
                 {
                    text_pos.x - padding,
                    text_pos.y - padding,
                    padding * 2 + res.width,
                    text_size + 2 * padding,
                },
                2,
            )
        }

        y -= text_size + padding
        if y < 0 {
            break
        }
    }
}
