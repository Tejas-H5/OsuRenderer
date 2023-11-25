package osu

import "core:math"
import "core:math/linalg"

SliderPathIterator :: struct {
    dist: f32,
    idx:  int,
}

// NOTE: doesn't take repeats into account. use get_slider_ball_pos for that
slider_path_iterator :: proc(
    iter: ^SliderPathIterator,
    slider_path: [dynamic]Vec2,
    start_length, end_length: f32,
) -> (
    Vec2,
    Vec2,
    bool,
) {
    if iter.idx <= 0 {
        iter.idx = 1
    }

    if iter.idx >= len(slider_path) || iter.dist >= end_length {
        return {}, {}, false
    }

    for iter.idx < len(slider_path) {
        p0, p1 := slider_path[iter.idx - 1], slider_path[iter.idx]
        segment_length := linalg.length(p0 - p1)

        if iter.dist < start_length && iter.dist + segment_length >= start_length {
            remaining_length := start_length - iter.dist
            t := remaining_length / segment_length

            iter.idx += 1
            iter.dist = start_length
            return linalg.lerp(p0, p1, t), p1, true
        }

        if iter.dist < start_length {
            // keep iterating till we reach the start length
            iter.idx += 1
            iter.dist += segment_length
            continue
        }

        if iter.dist + segment_length >= end_length {
            remaining_length := end_length - iter.dist
            t := remaining_length / segment_length

            iter.idx += 1
            iter.dist = end_length
            return p0, linalg.lerp(p0, p1, t), true
        }

        iter.idx += 1
        iter.dist += segment_length

        return p0, p1, true
    }


    return {}, {}, false
}

// assumes that slider_nodes were generated using slider_length, so it doesn't check that the slider_path is actually slider_length long
get_slider_ball_pos :: proc(
    slider_path: [dynamic]Vec2,
    slider: HitObject,
    current_time: f64,
) -> (
    slider_ball_pos: Vec2,
    current_repeat: int,
    has_slider_ball: bool,
) {
    if slider.type != .Slider || math.abs(slider.end_time - slider.start_time) < 0.00001 {
        return
    }

    start_time := slider.start_time
    end_time := slider.end_time

    if current_time < start_time {
        return slider.start_position, 1, false
    }

    if current_time >= end_time {
        // TODO: decide if this is useful or not
        current_repeat = slider.slider_repeats + 1

        if slider.slider_repeats % 2 == 1 {
            slider_ball_pos = slider_path[len(slider_path) - 1]
            return
        }

        slider_ball_pos = slider_path[0]
        return
    }

    slider_time_no_repeat := (end_time - start_time) / f64(slider.slider_repeats)
    elapsed_time := current_time - start_time
    going_backwards := false
    current_repeat = 1
    for elapsed_time > slider_time_no_repeat {
        going_backwards = !going_backwards
        elapsed_time -= slider_time_no_repeat
        current_repeat += 1
    }

    t := f32(elapsed_time / slider_time_no_repeat)
    distance: f32
    if going_backwards {
        distance = (1 - t) * slider.slider_length
    } else {
        distance = t * slider.slider_length
    }

    iter: SliderPathIterator
    found := false
    for p0, _ in slider_path_iterator(&iter, slider_path, distance, 100000000) {
        slider_ball_pos = p0
        found = true
        break
    }

    if !found {
        slider_ball_pos = slider.end_position
    }

    return slider_ball_pos, current_repeat, found
}


// level_of_detail is a value in osu!pixels. smaller = more detail
generate_slider_path :: proc(
    slider_nodes: [dynamic]SliderNode,
    output: ^[dynamic]Vec2,
    temp_buffer: ^[dynamic]Vec2,
    slider_len: f32,
    level_of_detail: f32,
) {
    clear(output)
    clear(temp_buffer)
    // generate the basic shape of the slider.
    // right now, the output is actually the 'temp' buffer

    current_node := 0
    end_node := 0
    current_length: f32
    remaining_distance := slider_len
    for end_node != len(slider_nodes) - 1 && remaining_distance > 0 {
        end_node = find_next_red_node_or_end(slider_nodes, current_node + 1)

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

        iter: SliderPathIterator
        if len(temp_buffer) > 0 {
            first := true
            remaining_distance_orig := remaining_distance
            for p0, p1 in slider_path_iterator(&iter, temp_buffer^, 0, remaining_distance_orig) {
                if first {
                    first = false
                    append(output, p0)
                }

                append(output, p1)
                remaining_distance -= linalg.length(p0 - p1)
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
    clear(temp_buffer)

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
    clear(temp_buffer)

    center, radius, start_angle, arc_angle, ok := get_3_point_arc(
        slider_nodes[start_node].pos,
        slider_nodes[middle_node].pos,
        slider_nodes[end_node].pos,
    )

    if !ok {
        generate_line_curve(slider_nodes, start_node, end_node, temp_buffer)
        return
    }

    // distance = angle * radius => angle = distance / radius
    delta_angle := (level_of_detail / radius)
    subdivisions := int(math.floor(abs(arc_angle) / delta_angle))
    for sd in 0 ..= subdivisions {
        subdiv := f32(sd)
        subdivisions := f32(subdivisions)

        point_angle := start_angle + arc_angle * (subdiv / subdivisions)
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
    radius, start_angle, arc_angle: f32,
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
    end_angle := math.atan2(centerp3_dir.y, centerp3_dir.x)

    end_angle -= start_angle
    mid_angle -= start_angle

    if start_angle < 0 {
        start_angle += math.TAU
    }
    if mid_angle < 0 {
        mid_angle += math.TAU
    }
    if end_angle < 0 {
        end_angle += math.TAU
    }

    if mid_angle > end_angle {
        arc_angle = end_angle - math.TAU
    } else {
        arc_angle = end_angle
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
    is_recursive_pass := false,
) {
    subdivisions: f32
    if !is_recursive_pass {
        // approximate the slider _segment_ length with a low subdivisions bezier curve, 
        // and use that with level_of_detail to calculate the subdivisions

        generate_bezier_curve(
            slider_nodes,
            start_node,
            end_node,
            temp_buffer,
            -1, // should be zunused when recursive pass
            is_recursive_pass = true,
        )

        low_detail_slider_length: f32
        for i in 1 ..< len(temp_buffer) {
            low_detail_slider_length += linalg.length(temp_buffer[i] - temp_buffer[i - 1])
        }

        subdivisions = math.ceil(low_detail_slider_length / level_of_detail)
    } else {
        subdivisions = 10
    }

    clear(temp_buffer)

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
