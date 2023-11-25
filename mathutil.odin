package main

import "af"
import "core:math"

clamp01 :: proc(f: f32) -> f32 {
    return max(0, min(1, f))
}

angle_vec :: proc(angle, size: f32) -> af.Vec2 {
    return size * af.Vec2{math.cos(angle), math.sin(angle)}
}

// lerp uses a, b, t to calculate val
// inv_lerp uses a, b, val to calculate t
inv_lerp :: proc {
    inv_lerp_f32,
    inv_lerp_f64,
}

inv_lerp_f32 :: proc(a, b, val: f32) -> f32 {
    return (val - a) / (b - a)
}


inv_lerp_f64 :: proc(a, b, val: f64) -> f64 {
    return (val - a) / (b - a)
}
