package osu

import "core:math"
import "core:math/linalg"

// assumes that slider_nodes were generated using slider_length, so it doesn't check that the slider_path is actually slider_length long
get_slider_ball_pos :: proc(
    slider_path: [dynamic]Vec2,
    slider: HitObject,
    current_time: f64,
) -> (
    Vec2,
    bool,
) {
    if slider.type != .Slider || math.abs(slider.end_time - slider.time) < 0.00001 {
        return {}, false
    }

    start_time := slider.time
    end_time := slider.end_time

    if current_time <= start_time {
        return {}, false
    }

    if current_time >= end_time {
        // TODO: decide if this is useful or not

        if slider.slider_repeats % 2 == 1 {
            return slider_path[len(slider_path) - 1], false
        }

        return slider_path[0], false
    }

    slider_time_no_repeat := (end_time - start_time) / f64(slider.slider_repeats)
    elapsed_time := current_time - start_time
    going_backwards := false
    for elapsed_time > slider_time_no_repeat {
        going_backwards = !going_backwards
        elapsed_time -= slider_time_no_repeat
    }

    t := f32(elapsed_time / slider_time_no_repeat)
    distance: f32
    if going_backwards {
        distance = (1 - t) * slider.slider_length
    } else {
        distance = t * slider.slider_length
    }

    current_length: f32 = 0
    for i in 1 ..< len(slider_path) {
        p0 := slider_path[i - 1]
        p1 := slider_path[i]

        segment_length := linalg.length(p1 - p0)

        if current_length + segment_length > distance {
            distance_remaining := distance - current_length
            p0p1_lerped := linalg.lerp(p0, p1, distance_remaining / segment_length)
            return p0p1_lerped, true
        }

        current_length += segment_length
    }

    // ideally the code never reaches here...

    return {}, false
}


// level_of_detail is a value in osu!pixels. smaller = more detail
generate_slider_path :: proc(
    slider_nodes: [dynamic]SliderNode,
    output: ^[dynamic]Vec2,
    temp_buffer: ^[dynamic]Vec2,
    slider_length: f32,
    level_of_detail: f32,
) {
    clear(output)
    // generate the basic shape of the slider.
    // right now, the output is actually the 'temp' buffer

    current_node := 0
    end_node := 0
    current_length: f32
    for end_node != len(slider_nodes) - 1 {
        end_node = find_next_red_node_or_end(slider_nodes, current_node + 1)

        clear(temp_buffer)

        if end_node - current_node == 1 {
            generate_line_curve(slider_nodes, current_node, end_node, temp_buffer)
        } else if end_node - current_node == 2 &&
           slider_nodes[current_node + 1].type == .PerfectCircle {
            // NOTE: to be more like osu!, it should really be len(slider_nodes) == 3, but I want to allow for multiple perfect circles
            generate_circle_curve(
                slider_nodes,
                current_node,
                current_node + 1,
                end_node,
                temp_buffer,
                level_of_detail,
            )
        } else {
            generate_bezier_curve(
                slider_nodes,
                current_node,
                end_node,
                temp_buffer,
                level_of_detail,
            )
        }

        if len(temp_buffer) > 0 {
            append(output, temp_buffer[0])

            reached_slider_length := false
            for i in 1 ..< len(temp_buffer) {
                p0 := temp_buffer[i - 1]
                p1 := temp_buffer[i]

                segment_length := linalg.length(p1 - p0)

                if current_length + segment_length < slider_length {
                    append(output, p1)
                } else {
                    distance_remaining := slider_length - current_length
                    p0p1_lerped := linalg.lerp(p0, p1, distance_remaining / segment_length)
                    append(output, p0p1_lerped)

                    reached_slider_length = true
                    break
                }

                current_length += segment_length
            }

            if reached_slider_length {
                break
            }
        }

        current_node = end_node
    }
}

@(private)
find_next_red_node_or_end :: proc(slider_nodes: [dynamic]SliderNode, start: int) -> int {
    last_node_index := len(slider_nodes) - 1
    for pos := start; pos < last_node_index; pos += 1 {
        if slider_nodes[pos].type == .RedNode {
            return pos
        }
    }

    return last_node_index
}

@(private)
generate_line_curve :: proc(
    slider_nodes: [dynamic]SliderNode,
    start_node, end_node: int,
    temp_buffer: ^[dynamic]Vec2,
) {
    pos_start := slider_nodes[start_node].pos
    pos_end := slider_nodes[end_node].pos
    append(temp_buffer, pos_start)
    append(temp_buffer, pos_end)
}

@(private)
generate_circle_curve :: proc(
    slider_nodes: [dynamic]SliderNode,
    start_node, middle_node, end_node: int,
    temp_buffer: ^[dynamic]Vec2,
    level_of_detail: f32,
) {
    center, radius, start_angle, end_angle, ok := get_3_point_arc(
        slider_nodes[start_node].pos,
        slider_nodes[middle_node].pos,
        slider_nodes[end_node].pos,
    )

    if !ok {
        generate_line_curve(slider_nodes, start_node, end_node, temp_buffer)
        return
    }

    // distance = angle * radius => angle = distance / radius
    angle := end_angle - start_angle
    delta_angle := (level_of_detail / radius)
    subdivisions := abs(int(math.floor(angle / delta_angle)))
    for sd in 0 ..= subdivisions {
        subdiv := f32(sd)
        subdivisions := f32(subdivisions)

        point_angle := start_angle + angle * (subdiv / subdivisions)
        x := math.cos(point_angle) * radius
        y := math.sin(point_angle) * radius

        point_on_circle := Vec2{x, y} + center
        append(temp_buffer, point_on_circle)
    }
}

@(private) // get_3_point_arc ensures that start_angle can be stepped towards end_angle without worrying about the 359->1 deg angle seam
get_3_point_arc :: proc(
    p1, p2, p3: Vec2,
) -> (
    center: Vec2,
    radius, start_angle, end_angle: f32,
    ok: bool,
) {
    p1p2_dir := p2 - p1
    p2p3_dir := p3 - p2

    p1p2_midpoint := p1 + 0.5 * (p1p2_dir)
    p2p3_midpoint := p2 + 0.5 * (p2p3_dir)

    p1p2_dir_perp := Vec2{-p1p2_dir.y, p1p2_dir.x}
    p2p3_dir_perp := Vec2{-p2p3_dir.y, p2p3_dir.x}

    center, ok = get_intersection(p1p2_midpoint, p1p2_dir_perp, p2p3_midpoint, p2p3_dir_perp)
    if !ok {
        return
    }

    radius = linalg.length(center - p1)

    centerp1_dir := p1 - center
    start_angle = math.atan2(centerp1_dir.y, centerp1_dir.x)

    centerp2_dir := p2 - center
    mid_angle := math.atan2(centerp2_dir.y, centerp2_dir.x)

    centerp3_dir := p3 - center
    end_angle = math.atan2(centerp3_dir.y, centerp3_dir.x)

    // ---- make sure we can move start_angle towards end_angle without worrying about the 359->1 deg angle seam angle seam

    start_from_end := false
    if mid_angle < start_angle || mid_angle > end_angle {
        end_angle, start_angle = start_angle, end_angle
        start_from_end = true
    }

    if end_angle < start_angle {
        end_angle += 2 * math.PI
    }

    if start_from_end {
        end_angle, start_angle = start_angle, end_angle
    }

    return
}

@(private) // converts a 2D line defined as point + direction*(xVector) to ax + by = c
get_line :: proc(pos, dir: Vec2) -> (a, b, c: f32) {
    a = -dir.y
    b = dir.x
    c = -dir.y * pos.x + dir.x * pos.y
    return
}

// The lines are defined with a point, and a direction vector.
// returns intersection, true 
@(private)
get_intersection :: proc(p1, dir1, p2, dir2: Vec2) -> (Vec2, bool) {
    a1, b1, c1 := get_line(p1, dir1)
    a2, b2, c2 := get_line(p2, dir2)

    det := a1 * b2 - a2 * b1
    if math.abs(det) < 0.0000001 {
        // lines are parallel
        return Vec2{}, false
    }

    intersection := Vec2{(b2 * c1 - b1 * c2) / det, (a1 * c2 - a2 * c1) / det}
    return intersection, true
}

@(private)
generate_bezier_curve :: proc(
    slider_nodes: [dynamic]SliderNode,
    start_node, end_node: int,
    temp_buffer: ^[dynamic]Vec2,
    level_of_detail: f32,
) {
    // TODO: use level_of_detail somehow
    subdivisions: f32 = 8 * f32(end_node - start_node + 1)

    for f in 0 ..= subdivisions {
        point := get_point_on_bezier_curve(slider_nodes, start_node, end_node, f / subdivisions)
        append(temp_buffer, point)
    }

}

@(private)
get_point_on_bezier_curve :: proc(
    slider_nodes: [dynamic]SliderNode,
    start_node, end_node: int,
    t: f32,
) -> Vec2 {
    bezier_points := make([]Vec2, end_node - start_node + 1)
    for i in start_node ..= end_node {
        bezier_points[i - start_node] = slider_nodes[i].pos
    }

    bezier_points_count := len(bezier_points)

    for bezier_points_count > 1 {
        for i in 0 ..< bezier_points_count - 1 {
            bezier_points[i] = linalg.lerp(bezier_points[i], bezier_points[i + 1], t)
        }

        bezier_points_count -= 1
    }

    point := bezier_points[0]
    delete(bezier_points)
    return point
}


calculate_object_end_time :: proc(beatmap: ^Beatmap, hit_object_index: int) {
    hit_object := beatmap.hit_objects[hit_object_index]

    if hit_object.type == .Slider {
        // get the most recent sv. TODO: optimize
        sv: f64 = 1
        last_sv_index := -1
        for i in 0 ..< len(beatmap.timing_points) - 1 {
            tp := beatmap.timing_points[i]
            if tp.bpm > 0 {
                continue
            }

            if tp.time > hit_object.time {
                break
            }

            last_sv_index = i
        }
        if last_sv_index != -1 {
            sv = beatmap.timing_points[last_sv_index].sv
        }

        // get the most recent bpm. TODO: optimize
        bpm: f64 = 1
        last_bpm_index := -1
        for i in 0 ..< len(beatmap.timing_points) - 1 {
            tp := beatmap.timing_points[i]
            if tp.bpm < 0 {
                continue
            }

            if tp.time > hit_object.time {
                break
            }

            last_bpm_index = i
        }
        if last_bpm_index != -1 {
            bpm = beatmap.timing_points[last_bpm_index].bpm
        }

        sv_real := sv * 100 * f64(beatmap.SliderMultiplier)
        beat_length_real := 60 / bpm
        duration := (f64(hit_object.slider_length) / sv_real) * beat_length_real
        repeats := hit_object.slider_repeats

        beatmap.hit_objects[hit_object_index].end_time = hit_object.time + duration * f64(repeats)
    }
}

// call calculate_object_end_time on the object at least once beforehand
calculate_opacity :: proc(
    hit_object: HitObject,
    beatmap: ^Beatmap,
    current_time, fade_in, fade_out: f64,
) -> f32 {
    zero: f64 = 0
    one: f64 = 1

    if current_time <= hit_object.time {
        t := min(1, max(0, (hit_object.time - current_time) / fade_in))
        return f32(math.lerp(one, zero, t))
    }

    end_time := hit_object.end_time
    if current_time <= end_time {
        return 1
    }

    t := min(1, max(0, (current_time - end_time) / fade_out))
    return f32(math.lerp(one, zero, t))
}
