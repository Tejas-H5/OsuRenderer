package af

import "core:c"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

GlyphRasterResult :: struct {
    glyph_info: GlyphInfo,
    dimensions: Rect,
}

GlyphInfo :: struct {
    code_point:  rune,

    // https://freetype.sourceforge.net/freetype2/docs/tutorial/step2.html
    // calculate y0 with cursor.y + bearing.y - size.y
    size:        Vec2,
    offset:      Vec2,
    advance_x:   f32,
    glyph_index: c.int, // an index used by stbtt into the font file, probably

    // initialized by the thing that places the glyph into the OpenGL texture
    uv:          Rect,
    slot:        int,
}

internal_initialize_text :: proc() {
    // this used to initialize SDL2, but it doesn't anymore. 
    // as I may need it later, I have kept it in, as with internal_un_initialize_text
    debug_log("Text initialized [stb::ttf]")
}
internal_un_initialize_text :: proc() {}

TEXT_TEXTURE_CHANNELS :: 4


DrawableFont :: struct {
    filename:              string,
    size:                  int,
    vendor_font:           stbtt.fontinfo,
    vendor_font_file_data: []byte,
    texture:               ^Texture,
    glyph_slots:           []GlyphInfo,
    glyph_to_slot:         map[rune]int,
    free_slot:             int,
    slot_size:             int,
    texture_grid_size:     int, // the opengl font texture consists of several sub-regions arranged in agrid_square_size x grid_square_size grid on an OpenGL texture
}

new_font :: proc(filename: string, ptsize: int, texture_grid_size := 16) -> ^DrawableFont {
    size := ptsize
    success := false
    font := new_clone(
        DrawableFont {
            filename = filename,
            size = size,
            texture_grid_size = texture_grid_size,
            free_slot = 0,
        },
    )
    defer if !success {
        free(font)
    }

    ok: bool
    font.vendor_font_file_data, ok = os.read_entire_file_from_filename(filename)
    if !ok {
        debug_warning("Failed to load font with filename %s", filename)
        return nil
    }

    // font.vendor_font = ttf.OpenFont(filename, c.int(size))
    if !stbtt.InitFont(&font.vendor_font, raw_data(font.vendor_font_file_data), 0) {
        debug_warning("Failed to init font with filename %s ptsize=%s", filename, ptsize)
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
    config := DEFAULT_TEXTURE_CONFIG
    config.num_channels = TEXT_TEXTURE_CHANNELS
    config.gl_pixel_format = gl.RGBA
    config.internal_gl_pixel_format = gl.RGBA
    font.texture = new_texture_from_size(bitmap_size, bitmap_size, config)

    num_slots := font.texture_grid_size * font.texture_grid_size
    font.glyph_slots = make([]GlyphInfo, num_slots)
    font.glyph_to_slot = make(map[rune]int, num_slots)

    success = true
    return font
}


free_font :: proc(font: ^DrawableFont) {
    delete(font.vendor_font_file_data)
    delete(font.glyph_slots)
    delete(font.glyph_to_slot)

    free_texture(font.texture)

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

    //if ttf.GlyphIsProvided32(font.vendor_font, codepoint) == 0 {
    glyph_index := stbtt.FindGlyphIndex(&font.vendor_font, codepoint)
    if glyph_index == 0 {
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

    // TODO: signed distance fields
    height := stbtt.ScaleForPixelHeight(&font.vendor_font, f32(font.size))
    w, h, x0, y0: c.int
    bitmap := stbtt.GetGlyphBitmap(&font.vendor_font, 0, height, glyph_index, &w, &h, &x0, &y0)
    if bitmap == nil {
        debug_log("Warning: could not render rune: %v (glyph index %v)", codepoint, glyph_index)
        return -1
    }

    idx :: proc(x, y, chan: int, w, num_chan: int) -> int {
        w := int(w)
        return y * num_chan * w + (x * num_chan + chan)
    }

    // copy to a bigger image with padding and more channels
    padding :: 2
    buff_w := int(w) + 2 * padding
    buff_h := int(h) + 2 * padding
    pixels := make([]byte, buff_w * buff_h * TEXT_TEXTURE_CHANNELS)
    for x in 0 ..< w {
        x := int(x)
        for y in 0 ..< h {
            y := int(y)
            w := int(w)

            x_dst := x + padding
            y_dst := y + padding
            pixels[idx(x_dst, y_dst, 0, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(x_dst, y_dst, 1, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(x_dst, y_dst, 2, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(x_dst, y_dst, 3, buff_w, TEXT_TEXTURE_CHANNELS)] =
                bitmap[idx(x, y, 0, w, 1)]
        }
    }
    stbtt.FreeBitmap(bitmap, nil)
    defer delete(pixels)

    slot_x, slot_y := font_get_slot_x_y(font, slot_to_free)
    insert_y := slot_y * font.slot_size + font.slot_size / 2 - int(buff_h) / 2
    insert_x := slot_x * font.slot_size + font.slot_size / 2 - int(buff_w) / 2

    // to debug the texture being biltted
    debug_atlas :: false
    when debug_atlas {
        for i in 0 ..< int(buff_w) {
            pixels[idx(i, 0, 0, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(i, 0, 1, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(i, 0, 2, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(i, 0, 3, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF

            pixels[idx(i, int(buff_h - 1), 0, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(i, int(buff_h - 1), 1, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(i, int(buff_h - 1), 2, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(i, int(buff_h - 1), 3, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
        }
        for i in 0 ..< int(buff_h) {
            pixels[idx(0, i, 0, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(0, i, 1, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(0, i, 2, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(0, i, 3, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF

            pixels[idx(buff_w - 1, i, 0, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(buff_w - 1, i, 1, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(buff_w - 1, i, 2, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
            pixels[idx(buff_w - 1, i, 3, buff_w, TEXT_TEXTURE_CHANNELS)] = 0xFF
        }
    }
    subregion_image := Image {
        width        = int(buff_w),
        height       = int(buff_h),
        num_channels = TEXT_TEXTURE_CHANNELS,
        data         = raw_data(pixels),
    }
    upload_texture_subregion(font.texture, insert_x, insert_y, &subregion_image)

    glyph_metric_advance, glyph_metric_lsb: c.int
    stbtt.GetGlyphHMetrics(
        &font.vendor_font,
        glyph_index,
        &glyph_metric_advance,
        &glyph_metric_lsb,
    )

    ascent, descent, lg: c.int
    stbtt.GetFontVMetrics(&font.vendor_font, &ascent, &descent, &lg)
    base: f32 = f32(descent) * height
    real_font_size := f32(abs(ascent - descent)) * height

    glyph_info := GlyphInfo {
        code_point = codepoint,
        slot = slot_to_free,
        size = Vec2{f32(buff_w) / real_font_size, f32(buff_h) / real_font_size},
        offset = Vec2{f32(x0) / real_font_size, (f32(-y0 - h) - base) / real_font_size},
        glyph_index = glyph_index,
        advance_x = height * f32(glyph_metric_advance) / real_font_size,
        // NOTE: the y uv coordinates have been flipped on purpose
        uv = Rect {
            f32(insert_x + padding) / f32(font.texture.width),
            f32(insert_y + buff_h - padding) / f32(font.texture.height),
            f32(buff_w - padding) / f32(font.texture.width),
            f32(-(buff_h - padding)) / f32(font.texture.height),
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

glyph_info_get_kerning_advance :: proc(
    font: ^DrawableFont,
    glyph_index, next_glyph_index: c.int,
) -> f32 {
    glyph_metric_advance := stbtt.GetGlyphKernAdvance(
        &font.vendor_font,
        glyph_index,
        next_glyph_index,
    )

    return f32(glyph_metric_advance) / f32(font.size)
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
