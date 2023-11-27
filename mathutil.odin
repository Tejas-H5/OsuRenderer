package main

import "af"
import "core:math"
import "core:math/linalg"

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

move_towards :: proc {
    move_towards_f32,
}

move_towards_f32 :: proc(a, b, amount: f32) -> f32 {
    a := a
    if a < b {
        return min(a - amount, b)
    }

    return max(a + amount, b)
}

// a trapezium curve. 0->1 from t0 to t0+fade_in, and 1->0 from t1-fade_out->t1
fade_in_fade_out_curve :: proc(t0, t1, t: f64, fade_in, fade_out: f64) -> f64 {
    if t < t0 || t > t1 {
        return 0
    }

    if t < t0 + fade_in {
        return inv_lerp(t0, t0 + fade_in, t)
    }

    if t > t1 - fade_out {
        return 1 - inv_lerp(t1 - fade_out, t1, t)
    }

    return 1
}

angle_between :: proc(a, b, c: af.Vec2) -> f32 {
    v1 := a - b
    v2 := c - b

    angle_1 := math.atan2(v1.y, v1.x)
    angle_2 := math.atan2(v2.y, v2.x)

    res1 := angle_1 - angle_2
    if abs(res1) <= math.PI {
        return res1
    }

    if res1 < 0 {
        res1 += math.TAU
        return res1
    }

    res1 -= math.TAU
    return res1
}

// solves for x when ax^2 + bx + c = 0. 
quadratic_equation :: proc(a, b, c: f32) -> (f32, f32) {
    sqrt_part := math.sqrt(b * b - 4 * a * c)

    return (-b + sqrt_part) / (2 * a), (-b - sqrt_part) / (2 * a)
}
