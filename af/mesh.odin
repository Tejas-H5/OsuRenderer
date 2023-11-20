package af

import "core:c"
import "core:math/linalg"
import gl "vendor:OpenGL"

vertices_uploaded: uint = 0
indices_uploaded: uint = 0

reset_mesh_stats :: proc() {
	vertices_uploaded = 0
	indices_uploaded = 0
}

Vertex :: struct {
	position: linalg.Vector3f32,
	uv:       linalg.Vector2f32,
}

Mesh :: struct {
	vbo, ebo, vao:                   c.uint,
	vertices:                        []Vertex,
	indices:                         []c.uint,
	vertices_length, indices_length: c.uint,
}

new_mesh :: proc(vertices_length, indices_length: c.uint) -> ^Mesh {
	mesh := Mesh {
		vertices        = make([]Vertex, vertices_length),
		vertices_length = vertices_length,
		indices         = make([]c.uint, indices_length),
		indices_length  = indices_length,
	}

	return new_clone(mesh)
}

upload_mesh :: proc(mesh: ^Mesh, is_dynamic: bool) {
	if (mesh.vao != 0) {
		reupload_mesh(mesh, mesh.vertices_length, mesh.indices_length)
		return
	}

	buffer_usage: u32 = is_dynamic ? gl.DYNAMIC_DRAW : gl.STATIC_DRAW

	gl.GenVertexArrays(1, &mesh.vao)
	gl.BindVertexArray(mesh.vao)

	gl.GenBuffers(1, &mesh.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, mesh.vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		int(mesh.vertices_length * size_of(Vertex)),
		raw_data(mesh.vertices),
		buffer_usage,
	)
	vertices_uploaded += uint(mesh.vertices_length)

	gl.GenBuffers(1, &mesh.ebo)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, mesh.ebo)
	gl.BufferData(
		gl.ELEMENT_ARRAY_BUFFER,
		int(mesh.indices_length * size_of(c.uint)),
		raw_data(mesh.indices),
		buffer_usage,
	)
	indices_uploaded += uint(mesh.indices_length)

	current_offset := 0

	// enable attribute 'position'
	gl.VertexAttribPointer(
		0,
		3,
		gl.FLOAT,
		false,
		size_of(Vertex),
		transmute(uintptr)current_offset,
	)
	gl.EnableVertexAttribArray(0)
	current_offset += size_of(f32) * 3

	// enable attribute 'uv'
	gl.VertexAttribPointer(
		1,
		2,
		gl.FLOAT,
		false,
		size_of(Vertex),
		transmute(uintptr)current_offset,
	)
	gl.EnableVertexAttribArray(1)
	// current_offset += size_of(f32) * 3;

	// unbind this thing so that future GL calls won't act on this by accident
	gl.BindVertexArray(0)
}

reupload_mesh :: proc(mesh: ^Mesh, vertices_length, indices_length: c.uint) {
	gl.BindVertexArray(mesh.vao)

	assert(mesh.vertices_length >= vertices_length)
	assert(mesh.indices_length >= indices_length)

	gl.BindBuffer(gl.ARRAY_BUFFER, mesh.vbo)
	gl.BufferSubData(
		gl.ARRAY_BUFFER,
		0,
		int(vertices_length * size_of(Vertex)),
		raw_data(mesh.vertices),
	)
	vertices_uploaded += uint(vertices_length)

	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, mesh.ebo)
	gl.BufferSubData(
		gl.ELEMENT_ARRAY_BUFFER,
		0,
		int(indices_length * size_of(c.uint)),
		raw_data(mesh.indices),
	)
	indices_uploaded += uint(indices_length)

	gl.BindVertexArray(0)
}

draw_mesh :: proc(mesh: ^Mesh, indices_length: c.uint) {
	gl.BindVertexArray(mesh.vao)
	gl.DrawElements(gl.TRIANGLES, c.int(indices_length), gl.UNSIGNED_INT, nil)
}

free_mesh :: proc(mesh: ^Mesh) {
	gl.BindVertexArray(0)
	gl.DeleteBuffers(1, &mesh.vbo)
	gl.DeleteBuffers(1, &mesh.ebo)
	gl.DeleteVertexArrays(1, &mesh.vao)

	delete(mesh.vertices)
	delete(mesh.indices)
	free(mesh)
}
