package af

// Used for rendering most things.
new_shader_default :: proc() -> ^Shader {
	//odinfmt:disable
	vertex_source :=
		"#version 330\n" +
		"uniform mat4 model;" +
		"uniform mat4 projection;" +
		"uniform mat4 view;" +
		"layout(location=0) in vec3 position;" +
		"layout(location=1) in vec2 uv;" +
		"out vec2 uv0;" +
		"void main(){" +
		"   gl_Position = projection * view * model * vec4(position, 1);" +
		"   uv0 = uv;" +
		"}"
	
	
	fragment_source :=
		"#version 330\n" +
		"uniform vec4 color;" +
		"uniform sampler2D sampler;" +
		"in vec2 uv0;" +
		"layout(location = 0) out vec4 frag_color;" +
		"void main(){" +
		"   vec4 texColor = texture2D(sampler, uv0.xy);" +
		// "   frag_color = color * vec4(1, 0, 0, 1);" +
		"   frag_color = color * texColor;" +
		"}" 
	//odinfmt:enable

	shader := new_shader(vertex_source, fragment_source)
	return shader
}
