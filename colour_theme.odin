package main

import "af"

ColorTheme :: struct {
    Foreground:   af.Color,
    Background:   af.Color,
    SliderPath:   af.Color,
    ReverseArrow: af.Color,
    SliderHead:   af.Color,
    Error:        af.Color,
}

DARK_THEME :: ColorTheme {
    Foreground = af.Color{1, 1, 1, 1},
    Background = af.Color{0, 0, 0, 1},
    SliderPath = af.Color{0.1, 0.1, 0.1, 1},
    ReverseArrow = af.Color{1, 1, 1, 1},
    SliderHead = af.Color{0, 0, 0, 0.75},
    Error = af.Color{1, 0, 0, 1},
}

LIGHT_THEME :: ColorTheme {
    Foreground = af.Color{0, 0, 0, 1},
    Background = af.Color{1, 1, 1, 1},
    SliderPath = af.Color{0.1, 0.1, 0.1, 1},
    ReverseArrow = af.Color{1, 1, 1, 1},
    SliderHead = af.Color{1, 1, 1, 1},
    Error = af.Color{1, 0, 0, 1},
}

g_current_theme: ColorTheme = DARK_THEME

with_alpha :: proc(c: af.Color, a: f32) -> af.Color {
    c := c
    c.a *= a
    return c
}
