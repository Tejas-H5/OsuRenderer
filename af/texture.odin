package af

import "core:c"
import "core:strings"
import gl "vendor:OpenGL"
import stbimage "vendor:stb/image"

Image :: struct {
    data:                        [^]byte,
    width, height, num_channels: int,
}

Texture :: struct {
    width, height:                             int,
    handle:                                    u32,
    filtering, clamping:                       int,
    gl_pixel_format, internal_gl_pixel_format: uint,
    num_channels:                              int, // this should be consistent with the pixel format. af doesnt attempt to validate this
}

TEXTURE_FILTERING_NEAREST :: gl.NEAREST
TEXTURE_FILTERING_LINEAR :: gl.LINEAR

DEFAULT_TEXTURE_CONFIG :: Texture {
    filtering                = gl.LINEAR,
    clamping                 = gl.CLAMP,

    // these should all be set together
    gl_pixel_format          = gl.RGBA,
    internal_gl_pixel_format = gl.RGBA,
    num_channels             = 4,
}

new_image :: proc(path: string) -> ^Image {
    image := new(Image)

    path_cstr := strings.clone_to_cstring(path)
    defer delete(path_cstr)

    width, height, num_channels: c.int
    stbimage.set_flip_vertically_on_load(1)
    image.data = stbimage.load(path_cstr, &width, &height, &num_channels, 4)

    image.width = int(width)
    image.height = int(height)
    image.num_channels = int(num_channels)

    return image
}

free_image :: proc(image: ^Image) {
    stbimage.image_free(image.data)
    free(image)
}

upload_texture_settings :: proc(texture: ^Texture) {
    internal_use_texture(texture)

    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, c.int(texture.filtering))
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, c.int(texture.filtering))

    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, c.int(texture.clamping))
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, c.int(texture.clamping))
}

upload_texture :: proc(texture: ^Texture, data: [^]byte) {
    internal_use_texture(texture)

    gl.TexImage2D(
        target = gl.TEXTURE_2D,
        level = 0,
        internalformat = c.int(texture.internal_gl_pixel_format),
        width = c.int(texture.width),
        height = c.int(texture.height),
        border = 0,
        format = u32(texture.gl_pixel_format),
        type = gl.UNSIGNED_BYTE,
        pixels = data,
    )

    err := gl.GetError()
    if (err != gl.NO_ERROR) {
        debug_fatal_error(
            "ERROR uploading texture - %d, %d, %d, %d - %d",
            texture.internal_gl_pixel_format,
            texture.width,
            texture.height,
            texture.gl_pixel_format,
            err,
        )
    }
}

new_texture_from_image :: proc(
    image: ^Image,
    config: Texture = DEFAULT_TEXTURE_CONFIG,
) -> ^Texture {
    texture := config
    texture.width = image.width
    texture.height = image.height
    texture.num_channels = image.num_channels

    gl.GenTextures(1, &texture.handle)

    upload_texture(&texture, image.data)
    upload_texture_settings(&texture)

    gl.BindTexture(gl.TEXTURE_2D, 0)
    return new_clone(texture)
}

new_texture_from_size :: proc(
    width, height: int,
    config: Texture = DEFAULT_TEXTURE_CONFIG,
) -> ^Texture {
    texture := config
    texture.width = width
    texture.height = height
    gl.GenTextures(1, &texture.handle)

    upload_texture(&texture, nil)
    upload_texture_settings(&texture)

    gl.BindTexture(gl.TEXTURE_2D, 0)
    return new_clone(texture)
}

internal_use_texture :: proc(texture: ^Texture) {
    gl.BindTexture(gl.TEXTURE_2D, texture.handle)
}

@(private)
internal_set_texture_unit :: proc(unit: int) {
    gl.ActiveTexture(u32(unit))
}

// NOTE: this will change the currently bound OpenGL texture
upload_texture_subregion :: proc(texture: ^Texture, xOffset, yOffset: int, sub_image: ^Image) {
    internal_use_texture(texture)

    gl.TexSubImage2D(
        gl.TEXTURE_2D,
        0,
        c.int(xOffset),
        c.int(yOffset),
        c.int(sub_image.width),
        c.int(sub_image.height),
        u32(texture.gl_pixel_format),
        gl.UNSIGNED_BYTE,
        sub_image.data,
    )
}

free_texture :: proc(texture: ^Texture) {
    gl.DeleteTextures(1, &texture.handle)
    free(texture)
}

resize_texture :: proc(texture: ^Texture, width, height: int) {
    if (texture.width == width && texture.height == height) {
        return
    }

    texture.width = width
    texture.height = height

    upload_texture(texture, nil)
}
