package af// short for Application Framework

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import gl "vendor:OpenGL"
import "vendor:glfw"

Mat4 :: linalg.Matrix4f32
MAT4_IDENTITY :: linalg.MATRIX4F32_IDENTITY
QUAT_IDENTITY :: linalg.QUATERNIONF32_IDENTITY
DEG2RAD :: math.PI / 180
RAD2DEG :: 180 / math.PI

Color :: linalg.Vector4f32
Vec4 :: linalg.Vector4f32
Vec3 :: linalg.Vector3f32
Vec2 :: linalg.Vector2f32
Quat :: linalg.Quaternionf32

GL_MAJOR_VERSION :: 3
GL_MINOR_VERSION :: 3

KEYBOARD_CHARS :: "\t\b\n `1234567890-=qwertyuiop[]asdfghjkl;'\\zxcvbnm,./"

// Window state

window_title: string
@(private)
target_fps: f32
target_fps_update: f32
window: glfw.WindowHandle
last_frame_time: f64
last_frame_time_update: f64
delta_time: f32
delta_time_update: f32
layout_rect: Rect

window_rect: Rect // NOTE: x0, y0 are always zero. 
window_wants_render_context: bool
framebuffer_rect: Rect

// Render state

has_exit_signal: bool
render_proc: proc()

white_pixel_texture: ^Texture
im: ^MeshBuffer // use this mesh buffer to render things in an immediate mode style
internal_shader: ^Shader

transform, view, projection: Mat4
draw_color: Color

current_shader: ^Shader
current_framebuffer: ^Framebuffer
current_texture: ^Texture

// Input state

keyboard_state_prev := [KeyCode_Max]bool{}
keyboard_state_curr := [KeyCode_Max]bool{}

inputted_runes := [KeyCode_Max]rune{}
inputted_runes_count: int
is_any_down, was_any_down: bool

// unlike key_just_pressed, this also captures repeats
keys_just_pressed_or_repeated := [KeyCode_Max]KeyCode{}
keys_just_pressed_or_repeated_count: int
get_keys_just_pressed_or_repeated :: proc() -> []KeyCode {
	return keys_just_pressed_or_repeated[0:keys_just_pressed_or_repeated_count]
}

incoming_mouse_wheel_notches: f32 = 0
mouse_wheel_notches: f32 = 0
prev_mouse_button_states := [MBCode]bool{}
mouse_button_states := [MBCode]bool{}
mouse_was_any_down, mouse_any_down: bool

internal_prev_mouse_position: Vec2
internal_mouse_position: Vec2
mouse_delta: Vec2

stencil_mode: StencilMode

// these are mainly for diagnostics, and aren't intended for highly accurate reporting of the fps
fps_tracker_render: FpsTracker
fps_tracker_update: FpsTracker

FpsTracker :: struct {
	last_fps, timer: f64,
	frames:          int,
}

// returns true when it ticks an interval
track_fps :: proc(state: ^FpsTracker, interval: f64, delta_time: f32) -> bool {
	state.frames += 1

	if state.timer >= interval {
		state.last_fps = f64(state.frames) / state.timer
		state.timer = 0
		state.frames = 0
		return true
	}

	state.timer += f64(delta_time)

	return false
}

// (\w+) (\*?)([\w_]+)

get_time :: proc() -> f64 {
	return glfw.GetTime()
}

set_time :: proc(t: f64) {
	glfw.SetTime(t)
}

// Short for layout_rect.width
vw :: proc() -> f32 {
	return layout_rect.width
}

// Short for layout_rect.height
vh :: proc() -> f32 {
	return layout_rect.height
}

new_frame :: proc() -> bool {

	return true
}

update_sleep_nano: i64
new_update_frame :: proc() -> bool {
	update_sleep_nano = sleep_for_fps(
		target_fps_update,
		&delta_time_update,
		&last_frame_time_update,
	)

	track_fps(&fps_tracker_update, 1, delta_time_update)

	internal_update_key_inputs_before_poll()
	glfw.PollEvents()
	internal_update_mouse_input()
	internal_update_key_input()

	if window_should_close() {
		has_exit_signal = true
		return false
	}

	// w, h := glfw.GetWindowSize(window)
	// window_rect.width = f32(w)
	// window_rect.height = f32(h)

	free_all(context.temp_allocator)

	return true
}


// returns how many nanoseconds we slept for
sleep_for_fps :: proc(target_fps: f32, delta_time: ^f32, last_frame_time: ^f64) -> i64 {
	last_frame_end := last_frame_time^

	t := get_time()
	delta_time^ = f32(t - last_frame_end)
	last_frame_time^ = t

	if (target_fps > 0.001) {
		// This is a power saving mechanism that will sleep the thread if we
		// have the time available to do so. It should reduce the overall CPU consumption.
		// TODO: extract to a seprate function like sleep_for_hz

		frame_duration := 1.0 / f64(target_fps)
		time_to_next_frame := frame_duration - f64(delta_time^)
		if (time_to_next_frame > 0) {
			nanoseconds_to_next_frame := i64(time_to_next_frame * 1_000_000_000)
			time.accurate_sleep(time.Duration(nanoseconds_to_next_frame))

			// extend the delta time as needed, since we just slept a bunch
			t := get_time()
			delta_time^ = f32(t - last_frame_end)
			last_frame_time^ = t

			return nanoseconds_to_next_frame
		}
	}

	return 0
}

render_context_mutex: sync.Mutex
lock_render_context :: proc() {
	sync.lock(&render_context_mutex)
	glfw.MakeContextCurrent(window)
}

unlock_render_context :: proc() {
	glfw.MakeContextCurrent(nil)
	sync.unlock(&render_context_mutex)
}

render_sleep_nano: i64

end_render_frame :: proc() {
	flush()
	glfw.SwapBuffers(window)
	unlock_render_context()

	render_sleep_nano = sleep_for_fps(target_fps, &delta_time, &last_frame_time)
	track_fps(&fps_tracker_render, 1, delta_time)
}

begin_render_frame :: proc() {
	lock_render_context()

	internal_set_framebuffer_directly(nil)
	set_stencil_mode(.Off)
	set_transform(linalg.MATRIX4F32_IDENTITY)
	internal_set_draw_texture_directly(nil)

	set_layout_rect(window_rect, false)
	gl.Viewport(0, 0, i32(window_rect.width), i32(window_rect.height))

	free_all(context.temp_allocator)
	reset_mesh_stats()


}


// Enables a lot of cool things, like much faster input polling (hopefully), and
// rendering while a user is resizing, but at a cost.
// Your render and update code must now be separate, and 
// you need to be careful that you don't accidentally call main-thread functions here.
// TODO: document what these are
//
// Also The window flickers when you resize, might be an epilepsy risk
// NOTE: render_thread_proc should just render a single frame and then return. it shouldn't start it's own render loop
start_render_thread :: proc(render_thread_proc: proc()) -> ^thread.Thread {
	// relinquish the context from the main thread
	render_proc = render_thread_proc
	glfw.MakeContextCurrent(nil)

	// aquire the context in this new thread, and then run the rendering function.
	render_proc_wrapper :: proc() {
		for !has_exit_signal {
			if window_wants_render_context && target_fps < 0.001 {
				// If this isn't present, the render thread will hog the render context,
				// causing a resize op to make the window freeze when the target_fps is basically 0.
				// This code will sleep the render thread so that the resize thread has a chance to aquire the
				// render context.
				time.sleep(time.Millisecond)
			}

			begin_render_frame()

			render_proc()

			end_render_frame()
		}
	}
	render_thread := thread.create_and_start(render_proc_wrapper)

	return render_thread
}

// sets has_exit_signal = true. really only useful if you're calling new_render_frame by itself
// in a render thread - this should make that thread end gracefully assuming other things aren't blocking it
stop_and_join_render_thread :: proc(render_thread: ^thread.Thread) {
	has_exit_signal = true
	thread.destroy(render_thread)
	glfw.MakeContextCurrent(window)
}


// Enables or disables VSync.
// This method only works when called on the render thread.
// NOTE: calling this with state=true will call set_target_render_fps(0)
set_vsync :: proc(state: bool) {
	if state {
		set_target_render_fps(0)
		glfw.SwapInterval(1)
	} else {
		glfw.SwapInterval(0)
	}
}

// Sets a target framerate for the render thread to run at.
// NOTE: If you want to just use the current monitor's fps, 
// it is better to call set_vsync(true) rather than this method.
// NOTE: Calling this method will call set_vsync(false)
set_target_render_fps :: proc(fps: f32) {
	set_vsync(false)

	target_fps = fps
}

set_target_update_fps :: proc(fps: f32) {
	target_fps_update = fps
}

window_should_close :: proc() -> bool {
	return glfw.WindowShouldClose(window) == true
}


internal_glfw_character_callback :: proc "c" (window: glfw.WindowHandle, r: rune) {
	if (inputted_runes_count >= len(inputted_runes)) {
		context = runtime.default_context()
		debug_log("WARNING - text buffer is full")
		return
	}

	inputted_runes[inputted_runes_count] = r
	inputted_runes_count += 1
}

internal_glfw_key_callback :: proc "c" (
	window: glfw.WindowHandle,
	key, scancode, action, mods: c.int,
) {
	if (action == glfw.RELEASE) {
		return
	}

	if (keys_just_pressed_or_repeated_count >= len(keys_just_pressed_or_repeated)) {
		context = runtime.default_context()
		debug_log("WARNING - key input buffer is full")
		return
	}

	keys_just_pressed_or_repeated[keys_just_pressed_or_repeated_count] = KeyCode(key)
	keys_just_pressed_or_repeated_count += 1
}

internal_glfw_framebuffer_size_callback :: proc "c" (
	window: glfw.WindowHandle,
	width, height: c.int,
) {
	context = runtime.default_context()

	window_rect.width = f32(width)
	window_rect.height = f32(height)

	internal_on_framebuffer_resize(width, height)

	if render_proc != nil {
		window_wants_render_context = true

		begin_render_frame()

		window_wants_render_context = false

		render_proc()

		end_render_frame()
	}
}

@(private)
internal_on_framebuffer_resize :: proc(width, height: c.int) {
	framebuffer_rect.width = f32(width)
	framebuffer_rect.height = f32(height)
}


internal_set_draw_texture_directly :: proc(texture: ^Texture) {
	texture := texture
	if (texture == nil) {
		texture = white_pixel_texture
	}

	internal_set_texture_unit(gl.TEXTURE0)
	internal_use_texture(texture)
	current_texture = texture
}

set_draw_texture :: proc(texture: ^Texture) {
	if (texture == current_texture) {
		return
	}

	flush()
	internal_set_draw_texture_directly(texture)
}

set_draw_color :: proc(color: Color) {
	flush()

	draw_color = color
	set_shader_vec4(current_shader.color_loc, draw_color)
}

set_draw_params :: proc(color: Color = Color{0, 0, 0, 0}, texture: ^Texture = nil) {
	set_draw_color(color)
	set_draw_texture(texture)
}

clear_screen :: proc(col: Color) {
	flush()

	gl.ClearColor(col.r, col.g, col.b, col.a)

	// the stencil buffer but must be cleared manually
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
}

flush :: proc() {
	flush_mesh_buffer(im)
}

set_layout_rect :: proc(rect: Rect, clip := false) {
	flush()

	layout_rect = rect

	if (clip) {
		gl.Scissor(
			c.int(layout_rect.x0),
			c.int(layout_rect.y0),
			c.int(layout_rect.width),
			c.int(layout_rect.height),
		)

		gl.Enable(gl.SCISSOR_TEST)
	} else {
		gl.Disable(gl.SCISSOR_TEST)
	}

	set_transform(MAT4_IDENTITY)
	set_camera_2D(0, 0, 1, 1)
}

set_window_title :: proc(title: string) {
	window_title = title
	title_cstr := strings.clone_to_cstring(title)
	glfw.SetWindowTitle(window, title_cstr)
	delete(title_cstr)
}

iconify_window :: proc() {
	glfw.IconifyWindow(window)
}
restore_window :: proc() {
	glfw.RestoreWindow(window)
}
maximize_window :: proc() {
	glfw.MaximizeWindow(window)
}
show_window :: proc() {
	glfw.ShowWindow(window)
}
hide_window :: proc() {
	glfw.HideWindow(window)
}
focus_window :: proc() {
	glfw.FocusWindow(window)
}

initialize :: proc(width: int, height: int) -> bool {
	debug_log("Initializing window ... ")
	{
		if (!bool(glfw.Init())) {
			debug_log("glfw failed to initialize")
			return false
		}

		glfw.WindowHint(glfw.VISIBLE, 0)

		window = glfw.CreateWindow(c.int(width), c.int(height), "", nil, nil)
		if (window == nil) {
			debug_log("glfw failed to create a window")
			glfw.Terminate()
			return false
		}

		/* Make the window's context current */
		glfw.MakeContextCurrent(window)

		glfw.SetScrollCallback(window, internal_glfw_scroll_callback)
		glfw.SetKeyCallback(window, internal_glfw_key_callback)
		glfw.SetCharCallback(window, internal_glfw_character_callback)
		glfw.SetFramebufferSizeCallback(window, internal_glfw_framebuffer_size_callback)

		debug_log("GLFW initialized\n")
	}

	initialize_gl()

	return true
}

initialize_gl :: proc() {

	debug_log("Initializing Rendering ... ")
	{
		gl.load_up_to(GL_MAJOR_VERSION, GL_MINOR_VERSION, glfw.gl_set_proc_address)

		im = new_mesh_buffer(2000, 6000)
		internal_shader = new_shader_default()
		set_shader(internal_shader)

		gl.Enable(gl.BLEND)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

		gl.Enable(gl.STENCIL_TEST)
		gl.StencilFunc(gl.EQUAL, 0, 0xFF)

		gl.Enable(gl.DEPTH_TEST)

		set_backface_culling(false)

		// init blank texture
		{
			img: Image
			img.width = 1
			img.height = 1
			img.num_channels = 4

			data := make([]byte, 4)
			defer delete(data)
			data[0] = 0xFF
			data[1] = 0xFF
			data[2] = 0xFF
			data[3] = 0xFF
			img.data = raw_data(data)

			config := DEFAULT_TEXTURE_CONFIG
			config.filtering = gl.NEAREST
			white_pixel_texture = new_texture_from_image(&img, config)
		}

		debug_log(
			"OpenGL initialized. OpenGL info: %s, Version: %s",
			gl.GetString(gl.VENDOR),
			gl.GetString(gl.VERSION),
		)
	}

	internal_initialize_text()

	clear_screen({0, 0, 0, 0})
}


un_initialize :: proc() {
	debug_log("UnInitializing...")

	// free rendering resources
	free_shader(internal_shader)
	free_mesh_buffer(im)
	free_texture(white_pixel_texture)

	internal_un_initialize_text()

	debug_log("Done")
}

set_camera_2D :: proc(x, y, scale_x, scale_y: f32) {
	x := layout_rect.x0 + x
	y := layout_rect.y0 + y

	width := scale_x * framebuffer_rect.width
	height := scale_y * framebuffer_rect.height

	translation := Vec3{x - width / 2, y - height / 2, 0}
	view := linalg.matrix4_translate(translation)

	scale := Vec3{2 / width, 2 / height, 1}
	projection := linalg.matrix4_scale(scale)

	set_view(view)
	set_projection(projection)

	gl.DepthFunc(gl.LEQUAL)
}

set_camera_3D :: proc(eye, target, up: Vec3, projection: Mat4) {
	view := linalg.matrix4_look_at_f32(eye, target, up, flip_z_axis = false)
	set_view(view)
	set_projection(projection)

	gl.DepthFunc(gl.LESS)
}

get_look_at :: proc(position: Vec3, target: Vec3, up: Vec3) -> Mat4 {
	return linalg.matrix4_look_at_f32(position, target, up)
}

get_orientation :: proc(position: Vec3, rotation: Quat) -> Mat4 {
	view := linalg.mul(
		linalg.matrix4_from_quaternion(rotation),
		linalg.matrix4_translate(position),
	)
	return view
}

internal_get_layout_rect_center_offset :: proc() -> Mat4 {
	// A translation in clipspace from the center of the framebuffer to the center of the current layout rect
	center_x := (layout_rect.x0 + vw() * 0.5) - framebuffer_rect.width * 0.5
	center_y := (layout_rect.y0 + vh() * 0.5) - framebuffer_rect.height * 0.5
	center_x_clipspace := 2 * center_x / framebuffer_rect.width
	center_y_clipspace := 2 * center_y / framebuffer_rect.height
	screen_center := linalg.matrix4_translate(Vec3{center_x_clipspace, center_y_clipspace, 0})

	return screen_center
}

get_perspective :: proc(fovy, depth_near, depth_far: f32) -> Mat4 {
	projection := linalg.matrix4_perspective(fovy, vw() / vh(), depth_near, depth_far, false)
	center_offset := internal_get_layout_rect_center_offset()
	return linalg.mul(center_offset, projection)
}


get_orthographic :: proc(size, depth_near, depth_far: f32) -> Mat4 {
	ySize := size
	xSize := size * vw() / vh()

	projection := linalg.matrix_ortho3d_f32(
		-xSize,
		xSize,
		ySize,
		-ySize,
		depth_near,
		depth_far,
		false,
	)
	center_offset := internal_get_layout_rect_center_offset()
	return linalg.mul(center_offset, projection)
}


set_projection :: proc(mat: Mat4) {
	flush()

	projection = mat
	set_shader_mat4(current_shader.projection_loc, &projection)
}

set_transform :: proc(mat: Mat4) {
	flush()

	transform = mat
	set_shader_mat4(current_shader.transform_loc, &transform)
}

set_view :: proc(mat: Mat4) {
	flush()

	view = mat
	set_shader_mat4(current_shader.view_loc, &view)
}

set_backface_culling :: proc(state: bool) {
	flush()

	if (state) {
		gl.Enable(gl.CULL_FACE)
	} else {
		gl.Disable(gl.CULL_FACE)
	}
}

set_shader :: proc(shader: ^Shader) {
	flush()

	shader := shader
	if (shader == nil) {
		shader = internal_shader
	}

	current_shader = shader
	internal_shader_use(current_shader)
	set_shader_mat4(current_shader.transform_loc, &transform)
	set_shader_mat4(current_shader.view_loc, &view)
	set_shader_mat4(current_shader.projection_loc, &projection)
}

clear_stencil :: proc() {
	flush()

	gl.ClearStencil(0)
	gl.Clear(gl.STENCIL_BUFFER_BIT)
}

clear_depth_buffer :: proc() {
	flush()

	gl.Clear(gl.DEPTH_BUFFER_BIT)
}

StencilMode :: enum {
	WriteOnes, // writes 0xFF where fragments appear
	WriteZeroes, // writes 0 where fragments appear
	DrawOverOnes, // allows fragments only where the buffer is 0xFF
	DrawOverZeroes, // allows fragments only where the buffer is 0
	Off, // disables the stencil
}

set_stencil_mode :: proc(mode: StencilMode) {
	flush()

	// TODO: use stencil_mode
	stencil_mode = mode

	if mode == .Off {
		gl.Disable(gl.STENCIL_TEST)
		return
	}

	gl.Enable(gl.STENCIL_TEST)

	// sfail, zfail, zpass. TODO: I would like more control over this later
	gl.StencilOp(gl.KEEP, gl.KEEP, gl.REPLACE)

	switch mode {
	case .WriteOnes:
		gl.StencilMask(0xFF)
		gl.StencilFunc(gl.ALWAYS, 0xFF, 0xFF)
	case .WriteZeroes:
		gl.StencilMask(0xFF)
		gl.StencilFunc(gl.ALWAYS, 0, 0xFF)
	case .DrawOverOnes:
		gl.StencilMask(0)
		gl.StencilFunc(gl.EQUAL, 0xFF, 0xFF)
	case .DrawOverZeroes:
		gl.StencilMask(0)
		gl.StencilFunc(gl.EQUAL, 0, 0xFF)
	case .Off:
	// should already be handled
	}
}

internal_set_framebuffer_directly :: proc(framebuffer: ^Framebuffer) {
	current_framebuffer = framebuffer

	internal_use_framebuffer(framebuffer)
	if (framebuffer == nil) {
		internal_on_framebuffer_resize(c.int(window_rect.width), c.int(window_rect.height))
	} else {
		internal_on_framebuffer_resize(
			c.int(framebuffer.texture.width),
			c.int(framebuffer.texture.height),
		)
	}
}


set_framebuffer :: proc(framebuffer: ^Framebuffer) {
	if (current_framebuffer == framebuffer) {
		return
	}

	flush()

	internal_set_framebuffer_directly(framebuffer)
}


vertex_2D :: proc(pos: Vec2) -> Vertex {
	return Vertex{position = {pos.x, pos.y, 0}, uv = {pos.x, pos.y}}
}

vertex_2D_uv :: proc(pos: Vec2, uv: Vec2) -> Vertex {
	return Vertex{position = {pos.x, pos.y, 0}, uv = uv}
}

draw_triangle :: proc(output: ^MeshBuffer, v1, v2, v3: Vertex) {
	flush_mesh_buffer_if_not_enough_space(output, 3, 3)

	v1_index := add_vertex_mesh_buffer(output, v1)
	v2_index := add_vertex_mesh_buffer(output, v2)
	v3_index := add_vertex_mesh_buffer(output, v3)

	add_mesh_buffer_triangle(output, v1_index, v2_index, v3_index)
}


draw_triangle_outline :: proc(output: ^MeshBuffer, v1, v2, v3: Vertex, thickness: f32) {
	mean := (v1.position + v2.position + v3.position) / 3.0

	v1_outer := v1
	v1_outer.position = v1.position + (linalg.vector_normalize(v1.position - mean) * thickness)


	v2_outer := v2
	v2_outer.position = v2.position + (linalg.vector_normalize(v2.position - mean) * thickness)

	v3_outer := v3
	v3_outer.position = v3.position + (linalg.vector_normalize(v3.position - mean) * thickness)

	nline := begin_nline_strip(output)
	extend_nline_strip(&nline, v1, v1_outer)
	extend_nline_strip(&nline, v2, v2_outer)
	extend_nline_strip(&nline, v3, v3_outer)
	extend_nline_strip(&nline, v1, v1_outer)
}


draw_quad :: proc(output: ^MeshBuffer, v1, v2, v3, v4: Vertex) {
	flush_mesh_buffer_if_not_enough_space(output, 4, 6)

	v1_index := add_vertex_mesh_buffer(output, v1)
	v2_index := add_vertex_mesh_buffer(output, v2)
	v3_index := add_vertex_mesh_buffer(output, v3)
	v4_index := add_vertex_mesh_buffer(output, v4)

	add_quad_mesh_buffer(output, v1_index, v2_index, v3_index, v4_index)
}

draw_quad_outline :: proc(output: ^MeshBuffer, v1, v2, v3, v4: Vertex, thickness: f32) {
	mean := (v1.position + v2.position + v3.position + v4.position) / 4.0

	v1_outer := v1
	v1_outer.position = v1.position + (linalg.vector_normalize(v1.position - mean) * thickness)


	v2_outer := v2
	v2_outer.position = v2.position + (linalg.vector_normalize(v2.position - mean) * thickness)

	v3_outer := v3
	v3_outer.position = v3.position + (linalg.vector_normalize(v3.position - mean) * thickness)

	v4_outer := v4
	v4_outer.position = v4.position + (linalg.vector_normalize(v4.position - mean) * thickness)

	line := begin_nline_strip(output)
	extend_nline_strip(&line, v1, v1_outer)
	extend_nline_strip(&line, v2, v2_outer)
	extend_nline_strip(&line, v3, v3_outer)
	extend_nline_strip(&line, v4, v4_outer)
	extend_nline_strip(&line, v1, v1_outer)
}

draw_rect :: proc(output: ^MeshBuffer, rect: Rect) {
	v1 := vertex_2D_uv({rect.x0, rect.y0}, {0, 0})
	v2 := vertex_2D_uv({rect.x0, rect.y0 + rect.height}, {0, 1})
	v3 := vertex_2D_uv({rect.x0 + rect.width, rect.y0 + rect.height}, {1, 1})
	v4 := vertex_2D_uv({rect.x0 + rect.width, rect.y0}, {1, 0})

	draw_quad(output, v1, v2, v3, v4)
}

draw_rect_uv :: proc(output: ^MeshBuffer, rect: Rect, uv: Rect) {
	v1 := vertex_2D_uv({rect.x0, rect.y0}, {uv.x0, uv.y0})
	v2 := vertex_2D_uv({rect.x0, rect.y0 + rect.height}, {uv.x0, uv.y0 + uv.height})
	v3 := vertex_2D_uv(
		{rect.x0 + rect.width, rect.y0 + rect.height},
		{uv.x0 + uv.width, uv.y0 + uv.height},
	)
	v4 := vertex_2D_uv({rect.x0 + rect.width, rect.y0}, {uv.x0 + uv.width, uv.y0})

	draw_quad(output, v1, v2, v3, v4)
}

draw_rect_outline :: proc(output: ^MeshBuffer, rect: Rect, thickness: f32) {
	using rect
	x1 := x0 + width
	y1 := y0 + height


	// the outline is broken into 4 smaller rects like this:
	// 322222222
	// 3       4
	// 3       4
	// 111111114

	draw_rect(output, {x0 - thickness, y0 - thickness, width + thickness, thickness})
	draw_rect(output, {x0, y1, width + thickness, thickness})
	draw_rect(output, {x0 - thickness, y0, thickness, height + thickness})
	draw_rect(output, {x1, y0 - thickness, thickness, height + thickness})
}

arc_edge_count :: proc(
	radius: f32,
	angle: f32 = math.TAU,
	max_circle_edge_count: int = 64,
	points_per_pixel: f32 = 4,
) -> int {
	// Circumferance C = radius * angle.
	// If we want 1 point every x units of circumferance, then num_points = C / x. 
	// We would break the angle down into angle / (num_points) to get the delta_angle.
	// So, delta_angle = angle / (num_points) = angle / ((radius * angle) / x) = (angle * x) / (radius * angle) = x / radius
	delta_angle := abs(points_per_pixel / radius)
	edge_count := min(int(angle / delta_angle) + 1, max_circle_edge_count)


	return edge_count
}


draw_arc :: proc(
	output: ^MeshBuffer,
	center: Vec2,
	radius, start_angle, end_angle: f32,
	edge_count: int,
) {
	ngon := begin_ngon(output)
	center_vertex := vertex_2D(center)
	extend_ngon(&ngon, center_vertex)

	delta_angle := (end_angle - start_angle) / f32(edge_count)
	for angle := end_angle; angle > start_angle - delta_angle + 0.001; angle -= delta_angle {
		x := center.x + radius * math.cos(angle)
		y := center.y + radius * math.sin(angle)

		v := vertex_2D({x, y})
		extend_ngon(&ngon, v)
	}
}


draw_arc_outline :: proc(
	output: ^MeshBuffer,
	center: Vec2,
	radius, start_angle, end_angle: f32,
	edge_count: int,
	thickness: f32,
) {
	if (edge_count < 0) {
		return
	}

	delta_angle := (end_angle - start_angle) / f32(edge_count)

	nline := begin_nline_strip(output)
	for angle := end_angle; angle > start_angle - delta_angle + 0.001; angle -= delta_angle {
		sin_angle := math.sin(angle)
		cos_angle := math.cos(angle)

		p1 := Vec2{center.x + radius * cos_angle, center.y + radius * sin_angle}
		p2 := Vec2 {
			center.x + (radius + thickness) * cos_angle,
			center.y + (radius + thickness) * sin_angle,
		}

		v1 := vertex_2D(p1)
		v2 := vertex_2D(p2)
		extend_nline_strip(&nline, v1, v2)
	}
}

draw_circle :: proc(output: ^MeshBuffer, center: Vec2, r: f32, edges: int) {
	draw_arc(output, center, r, 0, math.TAU, edges)
}

draw_circle_outline :: proc(
	output: ^MeshBuffer,
	center: Vec2,
	r: f32,
	edges: int,
	thickness: f32,
) {
	draw_arc_outline(output, center, r, 0, math.TAU, edges, thickness)
}


CapType :: enum {
	None,
	Circle,
}

draw_line :: proc(output: ^MeshBuffer, p0, p1: Vec2, thickness: f32, cap_type: CapType) {
	draw_cap :: proc(output: ^MeshBuffer, pos: Vec2, angle, thickness: f32, cap_type: CapType) {
		switch cap_type {
		case .None:
		// do nothing
		case .Circle:
			edge_count := arc_edge_count(thickness, math.PI, 64)
			draw_arc(output, pos, thickness, angle - math.PI / 2, angle + math.PI / 2, edge_count)
		}
	}

	thickness := thickness
	thickness /= 2

	dir := p1 - p0
	mag := linalg.length(dir)

	perp := Vec2{-thickness * dir.y / mag, thickness * dir.x / mag}

	v1 := vertex_2D(p0 + perp)
	v2 := vertex_2D(p0 - perp)
	v3 := vertex_2D(p1 - perp)
	v4 := vertex_2D(p1 + perp)
	draw_quad(output, v1, v2, v3, v4)

	startAngle := math.atan2(dir.y, dir.x)
	draw_cap(output, p0, startAngle - math.PI, thickness, cap_type)
	draw_cap(output, p1, startAngle, thickness, cap_type)
}


draw_line_outline :: proc(
	output: ^MeshBuffer,
	p0, p1: Vec2,
	thickness: f32,
	cap_type: CapType,
	outline_thickness: f32,
) {
	draw_cap_outline :: proc(
		output: ^MeshBuffer,
		center: Vec2,
		angle, thickness: f32,
		cap_type: CapType,
		outline_thickness: f32,
	) {
		switch (cap_type) {
		case .None:
			line_vec := Vec2{math.cos(angle), math.sin(angle)}
			line_vec_perp := Vec2{-line_vec.y, line_vec.x}

			p1_inner := center - line_vec_perp * (thickness + outline_thickness)
			p2_inner := center + line_vec_perp * (thickness + outline_thickness)

			p1_outer := p1_inner + line_vec * outline_thickness
			p2_outer := p2_inner + line_vec * outline_thickness

			draw_quad(
				output,
				vertex_2D(p1_inner),
				vertex_2D(p1_outer),
				vertex_2D(p2_outer),
				vertex_2D(p2_inner),
			)
		case .Circle:
			edge_count := arc_edge_count(thickness, math.PI, 64)
			draw_arc_outline(
				output,
				center,
				thickness,
				angle - math.PI / 2,
				angle + math.PI / 2,
				edge_count,
				outline_thickness,
			)
		}
	}

	thickness := thickness
	thickness /= 2

	dir := p1 - p0
	mag := linalg.length(dir)

	perp_inner := Vec2{-thickness * dir.y / mag, thickness * dir.x / mag}
	perp_outer := Vec2 {
		-(thickness + outline_thickness) * dir.y / mag,
		(thickness + outline_thickness) * dir.x / mag,
	}

	// draw quad on one side of the line
	vInner := vertex_2D_uv(p0 + perp_inner, perp_inner)
	vOuter := vertex_2D_uv(p0 + perp_outer, perp_outer)
	v1Inner := vertex_2D_uv(p1 + perp_inner, perp_inner)
	v1Outer := vertex_2D_uv(p1 + perp_outer, perp_outer)
	draw_quad(output, vInner, vOuter, v1Outer, v1Inner)

	// draw quad on other side of the line
	vInner = vertex_2D_uv(p0 - perp_inner, -perp_inner)
	vOuter = vertex_2D_uv(p0 - perp_outer, -perp_outer)
	v1Inner = vertex_2D_uv(p1 - perp_inner, -perp_inner)
	v1Outer = vertex_2D_uv(p1 - perp_outer, -perp_outer)
	draw_quad(output, vInner, vOuter, v1Outer, v1Inner)

	// Draw both caps
	startAngle := math.atan2(dir.y, dir.x)
	draw_cap_outline(output, p0, startAngle - math.PI, thickness, cap_type, outline_thickness)
	draw_cap_outline(output, p1, startAngle, thickness, cap_type, outline_thickness)
}


DrawFontTextMeasureResult :: struct {
	str_pos:        int, // how far into the text did we get to? (makes more sense if you set a max_width on the text)
	start_x, width: f32,
}

draw_font_text_pivoted :: proc(
	output: ^MeshBuffer,
	font: ^DrawableFont,
	text: string,
	size: f32,
	pos: Vec2,
	pivot: Vec2,
	max_width: f32 = math.INF_F32,
) -> DrawFontTextMeasureResult {
	res := draw_font_text(
		output,
		font,
		text,
		size,
		pos,
		is_measuring = true,
		max_width = max_width,
	)
	res = draw_font_text(
		output,
		font,
		text,
		size,
		{pos.x - pivot.x * res.width, pos.y - pivot.y * size},
		is_measuring = false,
		max_width = max_width,
	)

	return res
}

draw_font_text :: proc(
	output: ^MeshBuffer,
	font: ^DrawableFont,
	text: string,
	size: f32,
	pos: Vec2,
	is_measuring := false,
	max_width: f32 = math.INF_F32,
) -> DrawFontTextMeasureResult {
	prev_texture := current_texture
	if !is_measuring {
		set_draw_texture(font.texture)
	}

	res := DrawFontTextMeasureResult{}
	res.start_x = pos.x
	prev_glyph_index: c.int
	for res.str_pos < len(text) {
		codepoint, codepoint_size := utf8_next_rune(text, res.str_pos)
		is_space: bool
		glyph_info: GlyphInfo
		advance_x: f32

		if codepoint == ' ' {
			is_space = true
			advance_x = size * 0.5
		} else if codepoint == '\t' {
			// TODO: render tabs properly
			is_space = true
			advance_x = size * 2
		} else {
			glyph_info = font_rasterize_glyph(font, codepoint)
			// advance_x := glyph_info.advance_x
			advance_x = size * glyph_info.advance_x
			if prev_glyph_index != 0 {
				advance_x += glyph_info_get_kerning_advance(
					font,
					prev_glyph_index,
					glyph_info.glyph_index,
				)
			}
		}

		if res.width + advance_x > max_width {
			break
		}

		x := res.start_x + res.width
		if !is_measuring && !is_space {
			draw_font_glyph(output, font, glyph_info, size, {x, pos.y})
		}

		res.width += advance_x
		res.str_pos += codepoint_size
		prev_glyph_index = glyph_info.glyph_index
	}

	if !is_measuring {
		set_draw_texture(prev_texture)
	}

	return res
}

// font_rasterize_glyph renders a new glyph to the atlas while evicting an old glyph if that glyph hasn't already been rendered.
@(private)
font_rasterize_glyph :: proc(font: ^DrawableFont, codepoint: rune) -> GlyphInfo {
	slot := internal_font_rune_is_loaded(font, codepoint)
	if slot == -1 {
		flush()
		slot = internal_font_load_rune(font, codepoint)
	}

	if slot == -1 {
		if codepoint == '?' {
			debug_fatal_error(
				"Font did not contain the '?' code point, which is requried when handling unknown code points",
			)
			return GlyphInfo{}
		}

		return font_rasterize_glyph(font, '?')
	}

	glyph_info := font.glyph_slots[slot]
	return glyph_info
}

// NOTE: this function does not start using the font's texture. You will need to do that manually
draw_font_glyph :: proc(
	output: ^MeshBuffer,
	font: ^DrawableFont,
	glyph_info: GlyphInfo,
	size: f32,
	pos: Vec2,
) {
	rect := Rect {
		pos.x + size * glyph_info.offset.x,
		pos.y + size * glyph_info.offset.y,
		glyph_info.size.x * size,
		glyph_info.size.y * size,
	}
	uv := glyph_info.uv
	draw_rect_uv(output, rect, uv)
}


// -------- Keyboard input --------


key_was_down :: proc(key: KeyCode) -> bool {
	if key == .Unknown {
		return false
	}

	return keyboard_state_prev[int(key)]
}

key_is_down :: proc(key: KeyCode) -> bool {
	if key == .Unknown {
		return false
	}

	return keyboard_state_curr[int(key)]
}

key_just_pressed :: proc(key: KeyCode) -> bool {
	return (!key_was_down(key)) && key_is_down(key)
}

key_just_released :: proc(key: KeyCode) -> bool {
	return key_was_down(key) && (!key_is_down(key))
}

@(private)
internal_update_key_inputs_before_poll :: proc() {
	inputted_runes_count = 0
	keys_just_pressed_or_repeated_count = 0
}

@(private)
internal_update_key_input :: proc() {
	was_any_down = is_any_down
	is_any_down = false

	check_key :: proc(key: KeyCode) -> bool {
		return glfw.GetKey(window, c.int(key)) == glfw.PRESS
	}

	for i in 0 ..< int(KeyCode_Max) {
		keyboard_state_prev[i] = keyboard_state_curr[i]

		key := KeyCode(i)
		is_down := false

		// TODO: report this bug in ols. I shouldn't need to put #partial here 
		// because of the case: at the end that should be handling everything
		#partial switch key {
		case .Ctrl:
			is_down = check_key(.LeftCtrl) || check_key(.RightCtrl)
		case .Shift:
			is_down = check_key(.LeftShift) || check_key(.RightShift)
		case .Alt:
			is_down = check_key(.LeftAlt) || check_key(.RightAlt)
		case:
			is_down = check_key(key)
		}

		keyboard_state_curr[key] = is_down
	}
}

// we are kinda just assuming these are 0, 1, 2
mouse_button_is_down :: proc(mb: MBCode) -> bool {
	return mouse_button_states[mb]
}

mouse_button_was_down :: proc(mb: MBCode) -> bool {
	return prev_mouse_button_states[mb]
}

mouse_button_just_pressed :: proc(b: MBCode) -> bool {
	return !mouse_button_was_down(b) && mouse_button_is_down(b)
}

mouse_button_just_released :: proc(b: MBCode) -> bool {
	return mouse_button_was_down(b) && !mouse_button_is_down(b)
}

get_mouse_pos :: proc() -> Vec2 {
	return {internal_mouse_position.x - layout_rect.x0, internal_mouse_position.y - layout_rect.y0}
}

set_mouse_position :: proc(pos: Vec2) {
	glfw.SetCursorPos(window, f64(pos.x), f64(pos.y))
}

internal_glfw_scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	incoming_mouse_wheel_notches += f32(yoffset)
}

mouse_is_over :: proc(rect: Rect) -> bool {
	pos := get_mouse_pos()
	x := pos[0]
	y := pos[1]

	left := rect.x0
	right := rect.x0 + rect.width
	top := rect.y0 + rect.height
	bottom := rect.y0

	return (x > left && x < right) && (y < top && y > bottom)
}

internal_update_mouse_input :: proc() {
	for i in MBCode {
		prev_mouse_button_states[i] = mouse_button_states[i]
	}

	mouse_wheel_notches = incoming_mouse_wheel_notches
	incoming_mouse_wheel_notches = 0

	mouse_was_any_down = mouse_any_down
	mouse_any_down = false
	for i in MBCode {
		state := glfw.GetMouseButton(window, c.int(i)) == glfw.PRESS
		mouse_button_states[i] = state
		mouse_any_down = mouse_any_down || state
	}

	internal_prev_mouse_position = internal_mouse_position
	x, y := glfw.GetCursorPos(window)
	internal_mouse_position.x = f32(x)
	internal_mouse_position.y = framebuffer_rect.height - f32(y)
	mouse_delta.x = internal_mouse_position.x - internal_prev_mouse_position.x
	mouse_delta.y = internal_mouse_position.y - internal_prev_mouse_position.y
}
