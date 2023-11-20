package af

import "core:c"
import "core:strings"
import gl "vendor:OpenGL"

Framebuffer :: struct {
    framebuffer_handle:  c.uint,
    renderbuffer_handle: c.uint,
    texture:             ^Texture,
}


new_framebuffer :: proc(texture: ^Texture) -> ^Framebuffer {
    framebuffer := new(Framebuffer)

    framebuffer.texture = texture
    gl.GenFramebuffers(1, &framebuffer.framebuffer_handle)
    gl.GenRenderbuffers(1, &framebuffer.renderbuffer_handle)

    resize_framebuffer(framebuffer, texture.width, texture.height)
    return framebuffer
}

// NOTE: starts using the framebuffer texture internally
resize_framebuffer :: proc(fb: ^Framebuffer, width, height: int) {
    if fb.texture.width == width && fb.texture.height == height {
        return
    }

    previous_fb := current_framebuffer
    internal_use_framebuffer(fb)

    resize_texture(fb.texture, width, height)
    gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D,
        fb.texture.handle,
        0,
    )
    gl.BindRenderbuffer(gl.RENDERBUFFER, fb.renderbuffer_handle)
    gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, c.int(width), c.int(height))
    gl.FramebufferRenderbuffer(
        gl.FRAMEBUFFER,
        gl.DEPTH_STENCIL_ATTACHMENT,
        gl.RENDERBUFFER,
        fb.renderbuffer_handle,
    )

    fb_status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
    if (fb_status != gl.FRAMEBUFFER_COMPLETE) {
        // https://registry.khronos.org/OpenGL-Refpages/gl.4/html/gl.CheckFramebufferStatus.xhtml
        debug_log(
            "ERROR while resizing framebuffer - gl.CheckFramebufferStatus(gl.FRAMEBUFFER) = %d",
            fb_status,
        )
        panic("error")
    }

    internal_use_framebuffer(previous_fb)
}

internal_use_framebuffer :: proc(fb: ^Framebuffer) {
    flush()

    if (fb == nil) {
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
    } else {
        gl.BindFramebuffer(gl.FRAMEBUFFER, fb.framebuffer_handle)
    }
}

free_framebuffer :: proc(fb: ^Framebuffer) {
    gl.DeleteRenderbuffers(1, &fb.renderbuffer_handle)
    gl.DeleteFramebuffers(1, &fb.framebuffer_handle)

    free(fb)
}
