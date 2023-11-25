package osu

import "../af"
import "core:fmt"
import "core:io"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strconv"
import "core:strings"

compare_at :: proc(main, s: string, pos: int) -> bool {
    if pos + len(s) > len(main) {
        return false
    }

    for i := 0; i < len(s); i += 1 {
        if main[pos + i] != s[i] {
            return false
        }
    }

    return true
}

next_index_of :: proc(main: string, s: string, pos: int, if_not_found := -1) -> int {
    for i := pos; i < len(main); i += 1 {
        if compare_at(main, s, i) {
            return i
        }
    }

    return if_not_found
}

next_index_of_proc :: proc(
    main: string,
    fn: proc(_: rune) -> bool,
    val: bool,
    pos: int,
    if_not_found := -1,
) -> int {
    rest := main[pos:]
    pos := pos
    for codepoint, size in rest {
        if fn(codepoint) == val {
            return pos
        }

        pos += size
    }

    return if_not_found
}

parse_key_value_pair :: proc(line: string) -> (string, string, bool) {
    split_point := strings.index(line, ":")
    if split_point == -1 {
        return "", "", false
    }

    key := strings.trim_space(line[:split_point])
    value := strings.trim_space(line[split_point + 1:])
    return key, value, true
}

parse_lines_iterator :: proc(text: string, pos: ^int) -> (string, bool) {
    start := pos^
    if start < 0 || start >= len(text) {
        return "", false
    }

    if text[start] == '\n' {
        start += 1
    }
    start = next_index_of_proc(text, strings.is_space, false, start, if_not_found = len(text))
    end_of_line := next_index_of(text, "\n", start, if_not_found = len(text))

    if strings.trim_space(text[start:end_of_line]) == "" {
        return "", false
    }

    pos^ = end_of_line
    return text[start:end_of_line], true
}


Beatmap :: struct {
    text:              string,

    // metadata
    AudioFilename:     string,
    AudioLeadIn:       int,
    TitleUnicode:      string,
    Version:           string, // the diff name
    ArtistUnicode:     string,
    Creator:           string,
    BeatmapID:         string,
    BGFilename:        string,
    StackLeniency:     f32,
    ApproachRate:      f32,
    CircleSize:        f32,
    OverallDifficulty: f32,
    SliderMultiplier:  f32,

    // not metadata
    timing_points:     []TimingPoint,
    combo_colors:      []ComboColor,
    hit_objects:       []HitObject, // https://osu.ppy.sh/wiki/en/Client/File_formats/osu_%28file_format%29#hit-objects
}

free_beatmap :: proc(beatmap: ^Beatmap) {
    delete(beatmap.timing_points)
    delete(beatmap.combo_colors)

    for i in 0 ..< len(beatmap.hit_objects) {
        free_hitobject(&beatmap.hit_objects[i])
    }
    delete(beatmap.hit_objects)
    delete(beatmap.text)
    beatmap.text = ""
}

free_hitobject :: proc(hitobject: ^HitObject) {
    delete(hitobject.slider_nodes)
}

TimingPoint :: struct {
    time:          f64,
    beat_length:   f64,
    bpm:           f64,
    sv:            f64,
    meter:         int,
    sample_set:    int,
    sample_index:  int,
    volume:        int,
    is_bpm_change: int,
    effects:       int,
}

ComboColor :: struct {
    r, g, b: f32,
}

HitObjectType :: enum {
    Circle,
    Slider,
    Spinner,
}

Vec2 :: linalg.Vector2f32

HitObject :: struct {
    type:               HitObjectType,
    is_new_combo:       bool,
    start_time:         f64,
    end_time:           f64, // spinner. NOTE: for sliders, this is inferred by it's slider_length and the current slider velocity
    start_position:     Vec2, // an osu! pixel is confined to a 512, 384 playfield - https://osu.ppy.sh/wiki/en/Client/Playfield
    hit_sound:          int,
    slider_nodes:       [dynamic]SliderNode,
    slider_repeats:     int,
    slider_length:      f32,
    slider_edge_sounds: string,
    slider_edge_sets:   string,
    hit_sample:         string,

    // these props need to be recalculated
    stack_count:        int,
    end_position:       Vec2,
    combo_number:       int,
}

SliderNodeType :: enum {
    Bezier,
    PerfectCircle,

    // These break up bezier curves into multiple segments, completing the previous one and starting the next one.
    // The osu! editor represents these control points with red as red squares, hence the name
    RedNode,
}

SliderNode :: struct {
    pos:  Vec2,
    type: SliderNodeType,
}

parse_timing_point :: proc(str: string) -> TimingPoint {
    tp := TimingPoint{}
    str := str


    time_str, _ := strings.split_iterator(&str, ",")
    beat_length_str, _ := strings.split_iterator(&str, ",")
    meter_str, _ := strings.split_iterator(&str, ",")
    sample_set_str, _ := strings.split_iterator(&str, ",")
    sample_index_str, _ := strings.split_iterator(&str, ",")
    volume_str, _ := strings.split_iterator(&str, ",")
    is_bpm_change_str, _ := strings.split_iterator(&str, ",")
    effects_str, _ := strings.split_iterator(&str, ",")

    tp.time, _ = strconv.parse_f64(time_str)
    tp.time /= 1000
    tp.beat_length, _ = strconv.parse_f64(beat_length_str)
    tp.meter, _ = strconv.parse_int(meter_str)
    tp.sample_set, _ = strconv.parse_int(sample_set_str)
    tp.sample_index, _ = strconv.parse_int(sample_index_str)
    tp.volume, _ = strconv.parse_int(volume_str)
    tp.is_bpm_change, _ = strconv.parse_int(is_bpm_change_str)
    tp.effects, _ = strconv.parse_int(effects_str)

    if tp.is_bpm_change == 1 {
        tp.bpm = (60000 / tp.beat_length)
        tp.sv = 1.0
    } else {
        tp.bpm = -1
        tp.sv = -100.0 / tp.beat_length
    }

    return tp
}


BeatmapLoadError :: enum {
    None,
    FileLoadError,
}

// NOTE: read https://osu.ppy.sh/wiki/en/osu%21_File_Formats/Osu_%28file_format%29 to understand this code, I basically translated that verbatim
parse_section :: proc(text: string, pos: int, beatmap: ^Beatmap) -> (int, bool) {
    pos := pos
    pos = next_index_of(text, "[", pos)
    if pos == -1 {
        return pos, false
    }

    end := next_index_of(text, "]", pos + 1)
    if end == -1 {
        return pos, false
    }

    section_name := text[pos + 1:end]
    pos = next_index_of_proc(text, strings.is_space, false, end + 1, if_not_found = len(text))
    switch (section_name) {
    case "General":
        for line in parse_lines_iterator(text, &pos) {
            k, v, _ := parse_key_value_pair(line)
            switch k {
            case "AudioFilename":
                beatmap.AudioFilename = strings.trim(v, `"`)
            case "AudioLeadIn":
                beatmap.AudioLeadIn, _ = strconv.parse_int(v)
            case "StackLeniency":
                beatmap.StackLeniency, _ = strconv.parse_f32(v)
            }
        }
    case "Metadata":
        for line in parse_lines_iterator(text, &pos) {
            k, v, _ := parse_key_value_pair(line)
            switch k {
            case "TitleUnicode":
                beatmap.TitleUnicode = strings.trim(v, `"`)
            case "ArtistUnicode":
                beatmap.ArtistUnicode = strings.trim(v, `"`)
            case "Version":
                beatmap.Version = strings.trim(v, `"`)
            case "Creator":
                beatmap.Creator = strings.trim(v, `"`)
            case "BeatmapID":
                beatmap.BeatmapID = strings.trim(v, `"`)
            }
        }
    case "Difficulty":
        for line in parse_lines_iterator(text, &pos) {
            k, v, _ := parse_key_value_pair(line)
            switch k {
            case "ApproachRate":
                beatmap.ApproachRate, _ = strconv.parse_f32(v)
            case "CircleSize":
                beatmap.CircleSize, _ = strconv.parse_f32(v)
            case "OverallDifficulty":
                beatmap.OverallDifficulty, _ = strconv.parse_f32(v)
            case "SliderMultiplier":
                beatmap.SliderMultiplier, _ = strconv.parse_f32(v)
            }
        }
    case "Editor":
    //TODO: load editor settings if we ever want to fully implement the editor
    case "Events":
        for line in parse_lines_iterator(text, &pos) {
            line := line
            str, _ := strings.split_iterator(&line, ",")
            if str == "0" {
                _, _ = strings.split_iterator(&line, ",")
                fileName, _ := strings.split_iterator(&line, ",")
                beatmap.BGFilename = fileName
            }
        }
    case "TimingPoints":
        init_pos := pos
        line_count := 0
        for line in parse_lines_iterator(text, &pos) {
            line_count += 1
        }
        beatmap.timing_points = make([]TimingPoint, line_count)
        pos = init_pos

        for i in 0 ..< len(beatmap.timing_points) {
            line, _ := parse_lines_iterator(text, &pos)
            beatmap.timing_points[i] = parse_timing_point(line)
        }
    case "Colours":
        init_pos := pos
        line_count := 0
        for line in parse_lines_iterator(text, &pos) {
            line_count += 1
        }
        beatmap.combo_colors = make([]ComboColor, line_count)
        pos = init_pos

        for line_count in 0 ..< len(beatmap.combo_colors) {
            line, _ := parse_lines_iterator(text, &pos)
            k, v, _ := parse_key_value_pair(line)
            if !strings.has_prefix(k, "Combo") {
                continue
            }

            r_str, _ := strings.split_iterator(&v, ",")
            g_str, _ := strings.split_iterator(&v, ",")
            b_str, _ := strings.split_iterator(&v, ",")

            r, _ := strconv.parse_f32(r_str)
            g, _ := strconv.parse_f32(g_str)
            b, _ := strconv.parse_f32(b_str)

            beatmap.combo_colors[line_count] = ComboColor {
                r = r / 255,
                g = g / 255,
                b = b / 255,
            }
        }
    case "HitObjects":
        init_pos := pos
        line_count := 0
        for line in parse_lines_iterator(text, &pos) {
            line_count += 1
        }
        beatmap.hit_objects = make([]HitObject, line_count)
        pos = init_pos

        for i in 0 ..< len(beatmap.hit_objects) {
            line, _ := parse_lines_iterator(text, &pos)
            hit_object, ok := parse_hit_object(line)
            beatmap.hit_objects[i] = hit_object
            if !ok {
                af.debug_log("failed to parse hit object %v", i)
            }
        }
    case:
        af.debug_log("NOTE: unhandled section in osu beatmap '%s'", section_name)
    }

    pos = next_index_of(text, "[", pos, if_not_found = len(text))
    return pos, true
}

parse_hit_object :: proc(line: string) -> (HitObject, bool) {
    line := line
    obj: HitObject

    x_str, _ := strings.split_iterator(&line, ",")
    y_str, _ := strings.split_iterator(&line, ",")
    time_str, _ := strings.split_iterator(&line, ",")
    type_str, _ := strings.split_iterator(&line, ",")
    hitSound_str, _ := strings.split_iterator(&line, ",")

    object_params := line

    x, _ := strconv.parse_f32(x_str)
    y, _ := strconv.parse_f32(y_str)
    obj.start_position = Vec2{x, y}
    obj.end_position = obj.start_position
    obj.start_time, _ = strconv.parse_f64(time_str)
    obj.start_time /= 1000
    obj.end_time = obj.start_time
    type_bitfield_int, _ := strconv.parse_int(type_str)
    type_bitfield := u8(type_bitfield_int)
    obj.hit_sound, _ = strconv.parse_int(hitSound_str)

    // TODO: figure out wtf I meant when I wrote this comment in the C# codebase
    //Make data conform to the application
    //y = 384f-y;

    switch {
    case (type_bitfield & (1 << 0)) != 0:
        obj.type = .Circle
    case (type_bitfield & (1 << 1)) != 0:
        obj.type = .Slider
    case (type_bitfield & (1 << 3)) != 0:
        obj.type = .Spinner
    }

    cc_offset := 0
    if ((type_bitfield & (1 << 2)) != 0) {
        if ((type_bitfield & (1 << 4)) != 0) {
            cc_offset = cc_offset | (1 << 0)
        }

        if ((type_bitfield & (1 << 5)) != 0) {
            cc_offset = cc_offset | (1 << 1)
        }

        if ((type_bitfield & (1 << 6)) != 0) {
            cc_offset = cc_offset | (1 << 2)
        }

        cc_offset += 1
    }

    if cc_offset > 0 {
        obj.is_new_combo = true
    }

    switch obj.type {
    case .Circle:
    // circles only have a position, and time, which we've already parsed...
    case .Spinner:
        // spinners have a start, and an end time
        obj.end_time, _ = strconv.parse_f64(object_params)
        obj.end_time /= 1000
    case .Slider:
        // ladies and gentlemen - fasten your seatbelts...

        curve_data, _ := strings.split_iterator(&object_params, ",")
        slides_str, _ := strings.split_iterator(&object_params, ",")
        length_str, _ := strings.split_iterator(&object_params, ",")

        obj.slider_nodes = make([dynamic]SliderNode)
        obj.slider_repeats, _ = strconv.parse_int(slides_str)
        obj.slider_length, _ = strconv.parse_f32(length_str)
        if obj.slider_length < 0.001 {
            af.debug_warning("zero length slider!: %v in line %v", length_str, line)
        }

        // Used for hitsounding each slider repeat. These two may not always be present
        obj.slider_edge_sounds, _ = strings.split_iterator(&object_params, ",")
        obj.slider_edge_sets, _ = strings.split_iterator(&object_params, ",")

        curve_type, _ := strings.split_iterator(&curve_data, "|")

        // making the first node the same as the object's position simplifies the curve drawing code at the expense of 
        // adding a bit of duplicated info to be aware of
        append(&obj.slider_nodes, SliderNode{pos = obj.start_position, type = .Bezier})

        switch curve_type {
        case "P":
            for i in 0 ..< 2 {
                point_str, _ := strings.split_iterator(&curve_data, "|")
                x_str, _ := strings.split_iterator(&point_str, ":")
                y_str, _ := strings.split_iterator(&point_str, ":")

                x, _ := strconv.parse_f32(x_str)
                y, _ := strconv.parse_f32(y_str)

                append(&obj.slider_nodes, SliderNode{pos = Vec2{x, y}, type = .PerfectCircle})
            }
        case "L":
            for i in 0 ..< 1 {
                point_str, _ := strings.split_iterator(&curve_data, "|")
                x_str, _ := strings.split_iterator(&point_str, ":")
                y_str, _ := strings.split_iterator(&point_str, ":")

                x, _ := strconv.parse_f32(x_str)
                y, _ := strconv.parse_f32(y_str)

                append(&obj.slider_nodes, SliderNode{pos = Vec2{x, y}, type = .Bezier})
            }
        case "B":
            for point_str in strings.split_iterator(&curve_data, "|") {
                point_str := point_str

                x_str, _ := strings.split_iterator(&point_str, ":")
                y_str, _ := strings.split_iterator(&point_str, ":")

                x, _ := strconv.parse_f32(x_str)
                y, _ := strconv.parse_f32(y_str)
                pos := Vec2{x, y}

                if x < 1 && y < 1 {
                    af.debug_log("node %d was zero", len(obj.slider_nodes))
                }

                if len(obj.slider_nodes) > 1 {
                    prev_node := obj.slider_nodes[len(obj.slider_nodes) - 1]

                    dist_to_prev := linalg.length(prev_node.pos - pos)
                    should_merge_to_make_red_node := dist_to_prev < 0.01
                    if should_merge_to_make_red_node {
                        obj.slider_nodes[len(obj.slider_nodes) - 1].type = .RedNode
                        continue
                    }
                }

                append(&obj.slider_nodes, SliderNode{pos = pos, type = .Bezier})
            }
        case:
            af.debug_warning("unhandled bezier curve node type - '%s'", curve_type)
        }
    }

    // The final object param for a hit object is actually the hit samples. but it may not be present
    obj.hit_sample, _ = strings.split_iterator(&object_params, ",")

    return obj, true
}

new_osu_beatmap :: proc(filepath: string) -> ^Beatmap {
    // load data from file
    data, ok := os.read_entire_file_from_filename(filepath)
    if !ok {
        af.debug_log("couldn't read the text from the filepath %s", filepath)
        return nil
    }

    // parse the file into objects
    beatmap: Beatmap
    beatmap.text = string(data)
    pos := 0
    for pos < len(beatmap.text) {
        pos, ok = parse_section(beatmap.text, pos, &beatmap)
        if !ok {
            af.debug_log("failed to parse a section")
            delete(data)
            return nil
        }
    }

    return new_clone(beatmap)
}

get_circle_radius :: proc(beatmap: ^Beatmap) -> f32 {
    /*
        Taken from https://osu.ppy.sh/wiki/cs/Beatmapping/Circle_size:

        In osu!, circle size changes the size of hit circles and sliders, with higher values creating smaller hit objects. Spinners are unaffected by circle size. Circle size is derived through the following formula:
        r = 54.4 - 4.48 * CS
    */

    // the 0.5 is because it was looking wrong, so I changed it. am still not sure why it wasn't the same size
    return 54.4 - 4.48 * (beatmap.CircleSize + 0.5)
}


get_preempt :: proc(beatmap: ^Beatmap) -> f32 {
    /* From https://osu.ppy.sh/wiki/en/Beatmap/Approach_rate:
        The hit object starts fading in at X - preempt with:

            AR < 5: preempt = 1200ms + 600ms * (5 - AR) / 5
            AR = 5: preempt = 1200ms
            AR > 5: preempt = 1200ms - 750ms * (AR - 5) / 5
    */

    if (beatmap.ApproachRate <= 5) {
        return 1.200 + 0.600 * (5 - beatmap.ApproachRate) / 5
    } else {
        return 1.200 - 0.750 * (beatmap.ApproachRate - 5) / 5
    }
}

get_fade_in :: proc(beatmap: ^Beatmap) -> f32 {
    /* From https://osu.ppy.sh/wiki/en/Beatmap/Approach_rate:

        The amount of time it takes for the hit object to completely fade in is also reliant on the approach rate:

        AR < 5: fade_in = 800ms + 400ms * (5 - AR) / 5
        AR = 5: fade_in = 800ms
        AR > 5: fade_in = 800ms - 500ms * (AR - 5) / 5
    */


    if (beatmap.ApproachRate <= 5) {
        return 0.800 + 0.400 * (5 - beatmap.ApproachRate) / 5
    } else {
        return 0.800 - 0.500 * (beatmap.ApproachRate - 5) / 5
    }
}


/*

o========o o o o o o   o=====o 
    |                    |
first_visible           last_visible
*/

beatmap_get_first_visible :: proc(beatmap: ^Beatmap, t: f64, seek_from: int) -> int {
    if len(beatmap.hit_objects) == 0 {
        return 0
    }

    i := seek_from
    if i > len(beatmap.hit_objects) {
        i = len(beatmap.hit_objects) - 1
    }

    for i > 0 && beatmap.hit_objects[i].end_time > t {
        i -= 1
    }

    for i < len(beatmap.hit_objects) - 1 && beatmap.hit_objects[i].end_time < t {
        i += 1
    }

    return i
}

beatmap_get_last_visible :: proc(beatmap: ^Beatmap, t: f64, seek_from: int) -> int {
    if len(beatmap.hit_objects) == 0 {
        return 0
    }

    i := seek_from
    if i > len(beatmap.hit_objects) {
        i = len(beatmap.hit_objects) - 1
    }

    for i < len(beatmap.hit_objects) - 1 && beatmap.hit_objects[i].start_time < t {
        i += 1
    }

    for i > 0 && beatmap.hit_objects[i].start_time > t {
        i -= 1
    }
    return i
}


hit_object_is_new_combo :: proc(hit_object: HitObject) -> bool {
    return hit_object.type == .Spinner || hit_object.is_new_combo
}

beatmap_get_new_combo_start :: proc(beatmap: ^Beatmap, hit_object_index: int) -> int {
    for i := hit_object_index; i > 0; i -= 1 {
        if hit_object_is_new_combo(beatmap.hit_objects[i]) {
            return i
        }
    }

    return 0
}
