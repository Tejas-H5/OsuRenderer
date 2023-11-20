package af

Rect :: struct {
	x0, y0, width, height: f32,
}

set_rect_size :: proc(rect: ^Rect, new_width, new_height, px, py: f32) {
	set_rect_width(rect, new_width, px)
	set_rect_height(rect, new_height, py)
}

set_rect_width :: proc(rect: ^Rect, new_width, pivot: f32) {
	delta := new_width - rect.width
	rect.x0 -= delta * pivot
	rect.width = new_width
}

set_rect_height :: proc(rect: ^Rect, new_height, pivot: f32) {
	delta := new_height - rect.height
	rect.y0 -= delta * pivot
	rect.height = new_height
}

rectify_rect :: proc(rect: ^Rect) {
	if rect.height < 0 {
		rect.y0 += rect.height
		rect.height = -rect.height
	}

	if rect.width < 0 {
		rect.x0 += rect.width
		rect.width = -rect.width
	}
}

intersect_rect :: proc(r1, r2: ^Rect) -> Rect {
	rix0 := max(r1.x0, r2.x0)
	rix1 := min(r1.x0 + r1.width, r2.x0 + r2.width)
	riwidth := rix1 - rix0

	riy0 := max(r1.y0, r2.y0)
	riy1 := min(r1.y0 + r1.width, r2.y0 + r2.width)
	riheight := riy1 - riy0

	return Rect{rix0, riy0, riwidth, riheight}
}

get_rect_center :: proc(r1: Rect) -> (f32, f32) {
	return r1.x0 + 0.5 * r1.width, r1.y0 + 0.5 * r1.height
}
