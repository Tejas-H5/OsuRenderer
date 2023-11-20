package af

import "core:c"
import "core:math"
import "core:math/rand"
import "vendor:sdl2"
import "vendor:sdl2/ttf"


GlyphRasterResult :: struct {
    surface:    ^sdl2.Surface,
    glyph_info: GlyphInfo,
    dimensions: Rect,
}

GlyphInfo :: struct {
    code_point: rune,

    // https://freetype.sourceforge.net/freetype2/docs/tutorial/step2.html
    // calculate y0 with cursor.y + bearing.y - size.y
    size:       Vec2,
    offset:     Vec2,
    advance_x:  f32,


    // initialized by the thing that places the glyph into the OpenGL texture
    uv:         Rect,
    slot:       int,
}

internal_initialize_text :: proc() {
    if ttf.Init() < 0 {
        debug_fatal_error("Couldn't initialize sdl/ttf")
    }
}

internal_un_initialize_text :: proc() {
    ttf.Quit()
}


DrawableFont :: struct {
    file:                       cstring,
    size:                       int,
    vendor_font:                ^ttf.Font,
    vendor_intermediate_bitmap: ^sdl2.Surface,
    texture:                    ^Texture,
    glyph_slots:                []GlyphInfo,
    glyph_to_slot:              map[rune]int,
    free_slot:                  int,
    slot_size:                  int,
    texture_grid_size:          int, // the opengl font texture consists of several sub-regions arranged in agrid_square_size x grid_square_size grid on an OpenGL texture
}

new_font :: proc(file: cstring, ptsize: int, texture_grid_size := 16) -> ^DrawableFont {
    size := ptsize
    font := DrawableFont {
        file              = file,
        size              = size,
        texture_grid_size = texture_grid_size,
        free_slot         = 0,
    }

    font.vendor_font = ttf.OpenFont(file, c.int(size))
    if font.vendor_font == nil {
        debug_log("Couldn't load font %s [%dpt] - %s", file, ptsize, ttf.GetError())
        return nil
    }

    padding :: 2

    // Idk how much larger than the font size this should be to actually fit all the glyphs, but it is what it is.
    // We need to know this here, because later on, we may start using fallback fonts that have different glyph sizes.
    // Need to make sure that the entire character can always be rendered in all the glyphs
    magic_font_size_multiplier_lmao :: 1.5
    font.slot_size =
        int(math.floor_f32(magic_font_size_multiplier_lmao * f32(ptsize))) + 2 * padding
    bitmap_size := font.slot_size * font.texture_grid_size
    font.texture = new_texture_from_size(bitmap_size, bitmap_size, DEFAULT_TEXTURE_CONFIG)
    font.vendor_intermediate_bitmap = sdl2.CreateRGBSurface(
        0,
        c.int(font.slot_size),
        c.int(font.slot_size),
        32,
        0xFF000000,
        0x00FF0000,
        0x0000FF00,
        0x000000FF,
    )

    num_slots := font.texture_grid_size * font.texture_grid_size
    font.glyph_slots = make([]GlyphInfo, num_slots)
    font.glyph_to_slot = make(map[rune]int, num_slots)

    return new_clone(font)
}


free_font :: proc(font: ^DrawableFont) {
    ttf.CloseFont(font.vendor_font)
    sdl2.FreeSurface(font.vendor_intermediate_bitmap)

    free_texture(font.texture)

    delete(font.glyph_slots)
    delete(font.glyph_to_slot)

    free(font)
}

font_get_slot_x_y :: proc(font: ^DrawableFont, slot: int) -> (int, int) {
    return slot % font.texture_grid_size, slot / font.texture_grid_size
}

internal_font_rune_is_loaded :: proc(font: ^DrawableFont, codepoint: rune) -> int {
    slot, has_rune := font.glyph_to_slot[codepoint]
    if has_rune {
        return slot
    }

    return -1
}

internal_font_load_rune :: proc(font: ^DrawableFont, codepoint: rune) -> int {
    // assumes that the rune is not already loaded. hence the internal_

    if ttf.GlyphIsProvided32(font.vendor_font, codepoint) == 0 {
        // this glyph isn't in the font!
        return -1
    }

    // find the next free slot to render the glyph into

    slot_to_free: int
    if font.free_slot < len(font.glyph_slots) {
        slot_to_free = font.free_slot
        font.free_slot += 1
    } else {
        // TODO: We need to evict the least recently used glyph.
        // But I don't want to write an LRU cache at the moment, so I am just going to evict a random glyph because I am lazy
        slot_to_free = rand.int_max(len(font.glyph_slots))
    }

    // rasterize the glyph

    sdl2_white := sdl2.Color {
        r = 0xFF,
        g = 0xFF,
        b = 0xFF,
        a = 0xFF,
    }
    glyph_metric_minx, glyph_metric_maxx, glyph_metric_miny, glyph_metric_maxy, glyph_metric_advance: c.int
    ttf.GlyphMetrics32(
        font.vendor_font,
        codepoint,
        &glyph_metric_minx,
        &glyph_metric_maxx,
        &glyph_metric_miny,
        &glyph_metric_maxy,
        &glyph_metric_advance,
    )

    surface := ttf.RenderGlyph32_Blended(font.vendor_font, codepoint, sdl2_white)
    if surface == nil {
        debug_log("Warning: could not render rune: %v - %s", codepoint, ttf.GetError())
        return -1
    }
    // TODO: check if this will be slow or not. I would have preferred to write into an existing surface instead of
    // allocate/deallocate every time.
    defer sdl2.FreeSurface(surface)

    // NOTE: SDL appears to allocate a buffer that is slightly wider than the surface's width, so we need
    // to move the actual images accross by that much to center the characters into the grid properly.
    surface_buffer_width := surface.pitch / 4
    surface_real_width := surface.w

    slot_x, slot_y := font_get_slot_x_y(font, slot_to_free)
    insert_y := slot_y * font.slot_size + font.slot_size / 2 - int(surface.h) / 2
    insert_x :=
        slot_x * font.slot_size +
        font.slot_size / 2 -
        int(surface_buffer_width) / 2 +
        int(surface_buffer_width - surface_real_width) / 2

    // to debug the texture being biltted
    pixels := cast([^]byte)surface.pixels
    debug_atlas :: false
    when debug_atlas {
        for i in 0 ..< int(surface_buffer_width) {
            pixels[i * 4] = 0xFF
            pixels[i * 4 + 1] = 0xFF
            pixels[i * 4 + 2] = 0xFF
            pixels[i * 4 + 3] = 0xFF

            pixels[int(surface.h - 1) * 4 * int(surface_buffer_width) + i * 4] = 0xFF
            pixels[int(surface.h - 1) * 4 * int(surface_buffer_width) + i * 4 + 1] = 0xFF
            pixels[int(surface.h - 1) * 4 * int(surface_buffer_width) + i * 4 + 2] = 0xFF
            pixels[int(surface.h - 1) * 4 * int(surface_buffer_width) + i * 4 + 3] = 0xFF
        }
        for i in 0 ..< int(surface.h) {
            pixels[i * int(surface_buffer_width) * 4] = 0xFF
            pixels[i * int(surface_buffer_width) * 4 + 1] = 0xFF
            pixels[i * int(surface_buffer_width) * 4 + 2] = 0xFF
            pixels[i * int(surface_buffer_width) * 4 + 3] = 0xFF

            pixels[int(surface_buffer_width - 1) * 4 + i * int(surface_buffer_width) * 4] = 0xFF
            pixels[int(surface_buffer_width - 1) * 4 + i * int(surface_buffer_width) * 4 + 1] =
            0xFF
            pixels[int(surface_buffer_width - 1) * 4 + i * int(surface_buffer_width) * 4 + 2] =
            0xFF
            pixels[int(surface_buffer_width - 1) * 4 + i * int(surface_buffer_width) * 4 + 3] =
            0xFF
        }
    }
    subregion_image := Image {
        width        = int(surface_buffer_width),
        height       = int(surface.h),
        num_channels = 4,
        data         = pixels,
    }
    // TODO: check if we need to clear the entire slot first. Something like:
    // // upload_texture_subregion(font.texture, x, y, Image{ width = font.slot_size, height=font.slot_size, num_channels = 4, data = nil})
    upload_texture_subregion(font.texture, insert_x, insert_y, &subregion_image)

    glyph_info := GlyphInfo {
        code_point = codepoint,
        slot = slot_to_free,
        size = Vec2{f32(surface_real_width) / f32(font.size), f32(surface.h) / f32(font.size)},
        offset = Vec2{f32(glyph_metric_minx) / f32(font.size), 0}, // -f32(glyph_metric_miny) / f32(font.size),
        advance_x = f32(glyph_metric_advance) / f32(font.size),
        // NOTE: the y uv coordinates have been flipped on purpose
        uv = Rect {
            f32(insert_x) / f32(font.texture.width),
            f32(insert_y + int(surface.h)) / f32(font.texture.height),
            f32(surface_real_width) / f32(font.texture.width),
            f32(-surface.h) / f32(font.texture.height),
        },
    }

    // free the slot after all the other stuff completes without errors
    existing_rune := font.glyph_slots[slot_to_free].code_point
    delete_key(&font.glyph_to_slot, existing_rune)
    font.glyph_slots[slot_to_free] = glyph_info
    font.glyph_to_slot[codepoint] = slot_to_free

    return slot_to_free
}


// returns the next rune, as well as it's size in bytes (so )
utf8_next_rune :: proc(str: string, pos: int) -> (rune, int) {
    Is10XXXXXX :: proc(b1: byte) -> bool {
        // (b1 & (00000011 << 6)) == 10000000
        return (b1 & (0x3 << 6)) == (0x1 << 7)
    }

    Get__XXXXXX :: proc(b1: byte) -> int {
        return int(b1 & 63)
    }

    b1 := uint(str[pos])

    // (b1 & 1xxxxxxx) == 0
    if ((b1 & (1 << 7)) == 0x0) {
        return rune(b1), 1
    }

    b2 := str[pos + 1]
    // 110xxxxx 10xxxxxx


    if ((b1 & (7 << 5)) == (3 << 6) && Is10XXXXXX(b2)) {     // ((b1 & (00000111) << 5 )) == (00000011 << 6)
        return rune(int((b1 & (31)) << 6) + Get__XXXXXX(b2)), 2
    }

    b3 := str[pos + 2]

    if ((b1 & (15 << 4)) == (7 << 5) && Is10XXXXXX(b2) && Is10XXXXXX(b3)) {     // 1110xxxx 10xxxxxx 10xxxxxx 
        return rune(int((b1 & (15)) << 12) + (Get__XXXXXX(b2) << 6) + (Get__XXXXXX(b3))), 3
    }

    b4 := str[pos + 3]

    if ((b1 & (31 << 3)) == (15 << 4) && Is10XXXXXX(b2) && Is10XXXXXX(b3) && Is10XXXXXX(b4)) {     // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        return rune(
                int((b1 & (15)) << 18) +
                (Get__XXXXXX(b2) << 12) +
                (Get__XXXXXX(b3) << 6) +
                (Get__XXXXXX(b4)),
            ),
            4
    }

    return '?', 1
}


utf8_test :: proc() {
    TestCase :: struct {
        str:                 string,
        expected_size:       int,
        expected_code_point: rune,
    }

    testcases := []TestCase {
        //new TestCase{ String="\u0024", ExpectedSize=1, ExpectedCodePoint=0x24},
        //new TestCase{ String="A", ExpectedSize=1, ExpectedCodePoint=65},
        //new TestCase{ String="\u00A3", ExpectedSize=2, ExpectedCodePoint=0xA3},
        {"\u0418", 2, 0x418},
        {"\u0939", 3, 0x939},
        {"\u20AC", 3, 0x20AC},
        {"\uD55C", 3, 0xD55C},
        {"\U0002825F", 4, 0x2825F},
    }

    for i in 0 ..< len(testcases) {
        tt := testcases[i]

        pos, size: int
        codepoint: rune
        codepoint, size = utf8_next_rune(tt.str, pos)

        if size != tt.expected_size {
            debug_log("size != expected for testcase %d", i)
        }
        if codepoint != tt.expected_code_point {
            debug_log(
                "codepoint %v != expected %v for testcase %d",
                codepoint,
                tt.expected_code_point,
                i,
            )
        }
    }
}


/**

x := 0
pos := 0
graphemeInfo : GraphemeInfo
for pos, graphemeInfo = af.next_grapheme(text, pos); pos < len(text) {    
    if x + graphemeInfo.width > boxWidth {
        y -= height
        x = 0
    }

    af.draw_grapheme(af.im, graphemeInfo, x, y)
    x += graphemeInfo.width
}

// or
af.draw_text(text, boxWidth)

*/
