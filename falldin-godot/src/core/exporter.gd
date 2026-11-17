## Renders a document to an image, on the CPU.
##
## The browser could not go past roughly 120 megapixels or 16 000 pixels a side,
## because those are canvas limits, so a whole-map print render always came out
## scaled down. Compositing into an [Image] has neither limit — the ceiling is
## how much memory you are willing to spend — and because it needs no graphics
## context it also runs headless, which is what makes batch rendering possible.
class_name ImageExporter
extends RefCounted

class Options extends RefCounted:
	## Area to render, in hex widths. Empty means "everything that is painted".
	var region: Rect2 = Rect2()
	## Output resolution. 0 asks for the asset pack's own resolution.
	var px_per_hex: float = 0.0
	var background: Color = Color(0, 0, 0, 0)
	## Rebuild tokens from their parts instead of using the baked image.
	var recompose_tokens: bool = true
	## Refuse to allocate more than this. 400 MP is about 1.6 GB of RGBA.
	var max_pixels: int = 400_000_000
	## Snap the frame to the hex grid rather than to the art's overhang, so the
	## result lines up with a VTT's grid.
	var align_to_grid: bool = false

class Result extends RefCounted:
	var image: Image = null
	var px_per_hex: float = 0.0
	var region: Rect2 = Rect2()
	var scaled_down: bool = false
	var missing: PackedStringArray = []
	var elapsed_ms: int = 0

	func size() -> Vector2i:
		return Vector2i(image.get_width(), image.get_height()) if image != null else Vector2i.ZERO


static func render(doc: MapDocument, lib: AssetLibrary, opts: Options = null) -> Result:
	var t0 := Time.get_ticks_msec()
	if opts == null:
		opts = Options.new()
	var res := Result.new()

	var region := opts.region
	if not region.has_area():
		region = doc.grid_bounds() if opts.align_to_grid else doc.content_bounds()
	if not region.has_area():
		res.image = Image.create(1, 1, false, Image.FORMAT_RGBA8)
		return res
	res.region = region

	# The pack's own resolution is the width of a hex tile in pixels, which is
	# exactly what "full resolution" means for this art.
	var ppx := opts.px_per_hex
	if ppx <= 0.0:
		ppx = _native_px_per_hex(doc, lib)
	var want := Vector2(region.size.x * ppx, region.size.y * ppx)
	var pixels := want.x * want.y
	if pixels > float(opts.max_pixels):
		var k := sqrt(float(opts.max_pixels) / pixels)
		ppx *= k
		res.scaled_down = true
	res.px_per_hex = ppx

	var w := maxi(1, int(ceil(region.size.x * ppx)))
	var h := maxi(1, int(ceil(region.size.y * ppx)))
	var canvas := Image.create(w, h, false, Image.FORMAT_RGBA8)
	canvas.fill(opts.background)

	var cmds := DrawList.build(doc, lib, region.grow(3.0), opts.recompose_tokens)
	var cache := {}
	var missing := {}
	for cmd in cmds:
		var src := _prepare(cmd, lib, ppx, cache, missing)
		if src == null:
			continue
		_blend(canvas, src, cmd, region, ppx)
	for name: String in missing:
		res.missing.append(name)

	res.image = canvas
	res.elapsed_ms = Time.get_ticks_msec() - t0
	return res


## A hex tile's own pixel width: the natural resolution of the pack.
static func _native_px_per_hex(doc: MapDocument, lib: AssetLibrary) -> float:
	if lib == null:
		return 224.0
	var best := 0.0
	for at: Vector2i in doc.cells:
		var c: MapDocument.Cell = doc.cells[at]
		if c.terrain == null:
			continue
		var entry: AssetLibrary.Entry = lib.entries.get(c.terrain.tile)
		if entry == null:
			continue
		var px := lib.size_of(c.terrain.tile)
		if px == Vector2i.ZERO:
			continue
		# Scale a tile's pixels up to its largest available DPI, and divide by
		# how many hexes wide that tile is drawn.
		var factor := 1.0
		if entry.size_dpi > 0 and entry.largest_dpi() > 0:
			factor = float(entry.largest_dpi()) / float(entry.size_dpi)
		best = maxf(best, float(px.x) * factor / maxf(0.01, c.terrain.size))
	return best if best > 0.0 else 224.0


## Fetch, scale, tint and rotate a command's art, once per distinct appearance.
static func _prepare(
	cmd: DrawList.Cmd, lib: AssetLibrary, ppx: float,
	cache: Dictionary, missing: Dictionary
) -> Image:
	var dest_w := maxi(1, int(round(cmd.size.x * ppx)))
	var dest_h := maxi(1, int(round(cmd.size.y * ppx)))
	var key := "%s|%d|%d|%d|%d|%.3f|%.3f|%.3f" % [
		cmd.token.id if cmd.token != null else cmd.tile,
		dest_w, dest_h, int(cmd.flip),
		int(round(rad_to_deg(cmd.rot) * 4.0)), cmd.hue, cmd.sat, cmd.alpha,
	]
	if cache.has(key):
		return cache[key]

	var src: Image = null
	if cmd.token != null:
		src = cmd.token.baked_image()
	else:
		if lib == null or not lib.has(cmd.tile):
			missing[cmd.tile] = true
			return null
		src = lib.image(cmd.tile, float(dest_w))
	if src == null:
		missing[cmd.tile if cmd.token == null else cmd.token.name] = true
		return null

	src = src.duplicate()
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	if src.get_width() != dest_w or src.get_height() != dest_h:
		var shrinking := dest_w < src.get_width()
		src.resize(dest_w, dest_h,
			Image.INTERPOLATE_LANCZOS if shrinking else Image.INTERPOLATE_CUBIC)
	if cmd.flip:
		src.flip_x()
	if cmd.tinted() or not is_equal_approx(cmd.alpha, 1.0):
		_tint(src, cmd.hue, cmd.sat, cmd.alpha)
	if not is_zero_approx(cmd.rot):
		src = _rotate(src, cmd.rot)

	cache[key] = src
	return src


static func _blend(canvas: Image, src: Image, cmd: DrawList.Cmd, region: Rect2, ppx: float) -> void:
	var centre := (cmd.pos - region.position) * ppx
	var top_left := Vector2i(
		int(round(centre.x - float(src.get_width()) * 0.5)),
		int(round(centre.y - float(src.get_height()) * 0.5)))
	var whole := Rect2i(Vector2i.ZERO, Vector2i(src.get_width(), src.get_height()))
	# Clip by hand: blend_rect happily writes nothing when the destination is
	# partly outside, which would silently drop every tile on the edges.
	var canvas_rect := Rect2i(Vector2i.ZERO, Vector2i(canvas.get_width(), canvas.get_height()))
	var placed := Rect2i(top_left, whole.size)
	var visible := placed.intersection(canvas_rect)
	if visible.size.x <= 0 or visible.size.y <= 0:
		return
	var src_rect := Rect2i(visible.position - top_left, visible.size)
	canvas.blend_rect(src, src_rect, visible.position)


## Hue rotation and saturation, matching the CSS filters the browser tools used
## so an imported map keeps the colours it was tinted with.
static func _tint(img: Image, hue_deg: float, sat: float, alpha: float) -> void:
	var m := _saturate_matrix(sat)
	if not is_zero_approx(hue_deg):
		m = _multiply(_hue_matrix(deg_to_rad(hue_deg)), m)
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			img.set_pixel(x, y, Color(
				clampf(m[0] * c.r + m[1] * c.g + m[2] * c.b, 0.0, 1.0),
				clampf(m[3] * c.r + m[4] * c.g + m[5] * c.b, 0.0, 1.0),
				clampf(m[6] * c.r + m[7] * c.g + m[8] * c.b, 0.0, 1.0),
				c.a * alpha))


static func _saturate_matrix(s: float) -> PackedFloat32Array:
	const LR := 0.213
	const LG := 0.715
	const LB := 0.072
	return PackedFloat32Array([
		LR + (1.0 - LR) * s, LG - LG * s, LB - LB * s,
		LR - LR * s, LG + (1.0 - LG) * s, LB - LB * s,
		LR - LR * s, LG - LG * s, LB + (1.0 - LB) * s,
	])


static func _hue_matrix(a: float) -> PackedFloat32Array:
	var c := cos(a)
	var s := sin(a)
	return PackedFloat32Array([
		0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
		0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
		0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
	])


static func _multiply(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(9)
	for row in 3:
		for col in 3:
			var sum := 0.0
			for k in 3:
				sum += a[row * 3 + k] * b[k * 3 + col]
			out[row * 3 + col] = sum
	return out


## Rotate an image about its centre, sampling backwards so no pixel is missed.
##
## Done at the destination size, and every distinct (art, size, angle) is cached
## by the caller, so the six orientations of a river cost six rotations for the
## whole map rather than one per hex.
static func _rotate(src: Image, angle: float) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var c := cos(angle)
	var s := sin(angle)
	var out_w := int(ceil(absf(w * c) + absf(h * s)))
	var out_h := int(ceil(absf(w * s) + absf(h * c)))
	out_w = maxi(1, out_w)
	out_h = maxi(1, out_h)

	var src_data := src.get_data()
	var out_data := PackedByteArray()
	out_data.resize(out_w * out_h * 4)

	var half_out := Vector2(float(out_w) * 0.5, float(out_h) * 0.5)
	var half_src := Vector2(float(w) * 0.5, float(h) * 0.5)
	for y in out_h:
		var dy := float(y) + 0.5 - half_out.y
		var row := y * out_w * 4
		for x in out_w:
			var dx := float(x) + 0.5 - half_out.x
			# Inverse rotation: where in the source does this output pixel come from?
			var sx := int(floor(dx * c + dy * s + half_src.x))
			var sy := int(floor(-dx * s + dy * c + half_src.y))
			if sx < 0 or sy < 0 or sx >= w or sy >= h:
				continue
			var si := (sy * w + sx) * 4
			var di := row + x * 4
			out_data[di] = src_data[si]
			out_data[di + 1] = src_data[si + 1]
			out_data[di + 2] = src_data[si + 2]
			out_data[di + 3] = src_data[si + 3]
	return Image.create_from_data(out_w, out_h, false, Image.FORMAT_RGBA8, out_data)
