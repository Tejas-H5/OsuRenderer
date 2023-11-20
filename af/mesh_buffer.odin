package af

import "core:c"

MeshBuffer :: struct {
	mesh:                          ^Mesh,
	vertices_count, indices_count: c.uint,

	// TODO: currently just disables drawing when flushing, but eventually I want it to resize the backeng arrays like a list,
	// so that we can build meshes like how you would build a string
	is_builder:                    bool,
}

NLineStrip :: struct {
	v1, v2:             Vertex,
	v1_index, v2_index: c.uint,
	started:            bool,
	output:             ^MeshBuffer,
}

NGon :: struct {
	v1, v2:             Vertex,
	v1_index, v2_index: c.uint,
	count:              c.uint,
	output:             ^MeshBuffer,
}


new_mesh_buffer :: proc(vert_capacity, indices_capacity: c.uint) -> ^MeshBuffer {
	debug_log("making mesh")
	backing_mesh := new_mesh(vert_capacity, indices_capacity)
	debug_log("mesh made")
	upload_mesh(backing_mesh, true)
	debug_log("uploaded")

	buffer := new(MeshBuffer)
	buffer.mesh = backing_mesh

	return buffer
}

free_mesh_buffer :: proc(output: ^MeshBuffer) {
	free_mesh(output.mesh)

	free(output)
}

flush_mesh_buffer :: proc(output: ^MeshBuffer) {
	if output.vertices_count == 0 && output.indices_count == 0 {
		return
	}

	if !output.is_builder {
		reupload_mesh(output.mesh, output.vertices_count, output.indices_count)
		draw_mesh(output.mesh, output.indices_count)
	}

	output.vertices_count = 0
	output.indices_count = 0
}

add_vertex_mesh_buffer :: proc(output: ^MeshBuffer, vertex: Vertex) -> c.uint {
	count := output.vertices_count
	assert(count + 1 <= output.mesh.vertices_length)

	output.mesh.vertices[count] = vertex
	output.vertices_count += 1
	return count
}

add_mesh_buffer_triangle :: proc(output: ^MeshBuffer, v1, v2, v3: c.uint) {
	count := output.indices_count
	assert(count + 3 <= output.mesh.indices_length)

	output.mesh.indices[count + 0] = v1
	output.mesh.indices[count + 1] = v2
	output.mesh.indices[count + 2] = v3
	output.indices_count += 3
}

add_quad_mesh_buffer :: proc(output: ^MeshBuffer, v1, v2, v3, v4: c.uint) {
	add_mesh_buffer_triangle(output, v1, v2, v3)
	add_mesh_buffer_triangle(output, v3, v4, v1)
}

mesh_buffer_has_enough_space :: proc(
	output: ^MeshBuffer,
	incoming_verts, incoming_indices: c.uint,
) -> bool {
	return(
		(output.indices_count + incoming_indices < output.mesh.indices_length) &&
		(output.vertices_count + incoming_verts < output.mesh.vertices_length) \
	)
}

flush_mesh_buffer_if_not_enough_space :: proc(
	output: ^MeshBuffer,
	incoming_verts, incoming_indices: c.uint,
) -> bool {
	if (!mesh_buffer_has_enough_space(output, incoming_verts, incoming_indices)) {
		flush_mesh_buffer(output)
		return true
	}

	return false
}

begin_nline_strip :: proc(output: ^MeshBuffer) -> NLineStrip {
	state: NLineStrip
	state.started = false
	state.output = output
	return state
}

extend_nline_strip :: proc(line: ^NLineStrip, v1, v2: Vertex) {
	output: ^MeshBuffer = line.output
	if (!line.started) {
		flush_mesh_buffer_if_not_enough_space(output, 4, 6)

		line.v1 = v1
		line.v2 = v2
		line.v1_index = add_vertex_mesh_buffer(output, v1)
		line.v2_index = add_vertex_mesh_buffer(output, v2)
		line.started = true
		return
	}

	if (flush_mesh_buffer_if_not_enough_space(output, 2, 6)) {
		// v1 and v2 just got flushed, so we need to re-add them
		line.v1_index = add_vertex_mesh_buffer(output, line.v1)
		line.v2_index = add_vertex_mesh_buffer(output, line.v2)
	}

	next_last_1_index := add_vertex_mesh_buffer(output, v1)
	next_last_2_index := add_vertex_mesh_buffer(output, v2)

	add_mesh_buffer_triangle(output, line.v1_index, line.v2_index, next_last_2_index)
	add_mesh_buffer_triangle(output, next_last_2_index, next_last_1_index, line.v1_index)

	line.v1 = v1
	line.v2 = v2
	line.v1_index = next_last_1_index
	line.v2_index = next_last_2_index
}


begin_ngon :: proc(output: ^MeshBuffer) -> NGon {
	ngon: NGon
	ngon.count = 0
	ngon.output = output
	return ngon
}

extend_ngon :: proc(ngon: ^NGon, v: Vertex) {
	output: ^MeshBuffer = ngon.output

	// we need at least 2 vertices to start creating triangles with NGonContinue.
	if (ngon.count == 0) {
		flush_mesh_buffer_if_not_enough_space(output, 3, 3)

		ngon.v1_index = add_vertex_mesh_buffer(output, v)
		ngon.v1 = v
		ngon.count += 1
		return
	}

	if (ngon.count == 1) {
		flush_mesh_buffer_if_not_enough_space(output, 2, 3)

		ngon.v2_index = add_vertex_mesh_buffer(output, v)
		ngon.v2 = v
		ngon.count += 1
		return
	}

	if (flush_mesh_buffer_if_not_enough_space(output, 1, 3)) {
		// v1 and v2 just got flushed, so we need to re-add them
		ngon.v1_index = add_vertex_mesh_buffer(output, ngon.v1)
		ngon.v2_index = add_vertex_mesh_buffer(output, ngon.v2)
	}

	v3 := add_vertex_mesh_buffer(output, v)
	add_mesh_buffer_triangle(output, ngon.v1_index, ngon.v2_index, v3)

	ngon.v2_index = v3
	ngon.v2 = v
	ngon.count += 1
}
