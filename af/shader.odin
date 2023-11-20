package af

import "core:c"
import "core:math/linalg"
import "core:strings"
import gl "vendor:OpenGL"

Shader :: struct {
    handle:         c.uint,
    transform_loc:  int,
    view_loc:       int,
    projection_loc: int,
    color_loc:      int,
}

new_shader :: proc(vertex_source, fragment_source: string) -> ^Shader {
    vertex_cstr := strings.clone_to_cstring(vertex_source)
    defer delete(vertex_cstr)
    vertex_handle := compile_shader(vertex_cstr, gl.VERTEX_SHADER)

    fragment_cstr := strings.clone_to_cstring(fragment_source)
    defer delete(fragment_cstr)
    fragment_handle := compile_shader(fragment_cstr, gl.FRAGMENT_SHADER)

    shader := new(Shader)
    shader.handle = link_program(vertex_handle, fragment_handle)
    shader.transform_loc = get_shader_uniform(shader, "model")
    shader.view_loc = get_shader_uniform(shader, "view")
    shader.projection_loc = get_shader_uniform(shader, "projection")
    shader.color_loc = get_shader_uniform(shader, "color")

    debug_log("%v", shader)

    return shader
}

// This will exit the program if we couldn't compile a shader
compile_shader :: proc(source: cstring, type: c.uint) -> c.uint {
    source := source
    source_length: c.int = c.int(len(source))
    shader_handle := gl.CreateShader(type)
    gl.ShaderSource(shader_handle, 1, &source, &source_length)
    gl.CompileShader(shader_handle)

    compile_status: c.int
    gl.GetShaderiv(shader_handle, gl.COMPILE_STATUS, &compile_status)
    if (compile_status != 1) {
        info_log: [1024]u8
        length: c.int
        gl.GetShaderInfoLog(shader_handle, 1024, &length, raw_data(&info_log))
        debug_fatal_error("ERROR when compiling shader:\n%s", info_log)
        return 0
    }

    return shader_handle
}


link_program :: proc(vertex_handle, fragment_handle: c.uint) -> c.uint {
    program := gl.CreateProgram()
    gl.AttachShader(program, vertex_handle)
    gl.AttachShader(program, fragment_handle)
    gl.LinkProgram(program)

    link_status: c.int
    gl.GetProgramiv(program, gl.LINK_STATUS, &link_status)
    if (link_status != 1) {
        info_log: [1024]u8
        length: c.int
        gl.GetProgramInfoLog(program, 1024, &length, raw_data(&info_log))
        debug_fatal_error("ERROR when linking shader:\n%s", info_log)
        return 0
    }

    gl.DetachShader(program, vertex_handle)
    gl.DeleteShader(vertex_handle)
    gl.DetachShader(program, fragment_handle)
    gl.DeleteShader(fragment_handle)
    return program
}

get_shader_uniform :: proc(shader: ^Shader, name: cstring) -> int {
    loc := gl.GetUniformLocation(c.uint(shader.handle), name)
    if (loc == -1) {
        debug_fatal_error("Warning: Could not find uniform %s", name)
    }

    return int(loc)
}

get_shader_uniform_count :: proc(shader: ^Shader) -> c.int {
    count := [1]c.int{}
    gl.GetProgramiv(c.uint(shader.handle), gl.ACTIVE_UNIFORMS, raw_data(&count))
    return count[0]
}

// TODO: figure out a good system for zero allocation text
// Shader_UniformName :: proc(shader: ^Shader, location: int, ) -> string {
//     buff := [256]u8{}
//     len: c.int
//     gl.GetActiveUniformName(shader.handle, c.uint(location), 256, &len, raw_data(&buff))

//     return 
// }

internal_shader_use :: proc(shader: ^Shader) {
    gl.UseProgram(shader.handle)
}

set_shader_int :: proc(loc: int, data: int) {
    gl.Uniform1i(c.int(loc), c.int(data))
}

set_shader_float :: proc(loc: int, data: f32) {
    gl.Uniform1f(c.int(loc), data)
}

set_shader_mat4 :: proc(loc: int, data: ^Mat4) {
    gl.UniformMatrix4fv(c.int(loc), 1, false, raw_data(data))
}

set_shader_vec2 :: proc(loc: int, data: Vec2) {
    gl.Uniform2f(c.int(loc), data[0], data[1])
}

set_shader_vec3 :: proc(loc: int, data: Vec3) {
    gl.Uniform3f(c.int(loc), data[0], data[1], data[2])
}

set_shader_vec4 :: proc(loc: int, data: Vec4) {
    gl.Uniform4f(c.int(loc), data[0], data[1], data[2], data[3])
}

free_shader :: proc(shader: ^Shader) {
    gl.DeleteProgram(shader.handle)

    free(shader)
}
