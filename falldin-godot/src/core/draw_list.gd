## Turns a document into a flat, ordered list of "draw this here" commands.
##
## One painter, three consumers: the screen view, the image exporter and the
## headless renderer all walk the same list, so what you see is what you export.
## The old tools each had their own copy of the drawing loop, which is how a fix
## to the screen never reached the print render.
class_name DrawList
extends RefCounted

## A single textured quad in hex-width space.
class Cmd extends RefCounted:
	var tile: String = ""         ## asset name, empty for a baked token
	var token: TokenDef = null    ## set when this is a token's baked image
	var pos: Vector2 = Vector2.ZERO   ## centre
	var size: Vector2 = Vector2.ONE
	var rot: float = 0.0
	var flip: bool = false
	var hue: float = 0.0
	var sat: float = 1.0
	var alpha: float = 1.0

	func tinted() -> bool:
		return not is_zero_approx(hue) or not is_equal_approx(sat, 1.0)

	## Axis-aligned bounds, used for culling.
	func bounds() -> Rect2:
		var half := size * 0.5
		if not is_zero_approx(rot):
			var c := absf(cos(rot))
			var s := absf(sin(rot))
			half = Vector2(half.x * c + half.y * s, half.x * s + half.y * c)
		return Rect2(pos - half, half * 2.0)


## Build the ordered command list.
##
## [param region] culls to a rectangle in hex widths; an empty Rect2 keeps
## everything. [param recompose_tokens] rebuilds tokens from their parts, which
## is what an HD export wants; the screen uses the baked image because it is one
## texture instead of a dozen.
static func build(
	doc: MapDocument,
	lib: AssetLibrary,
	region: Rect2 = Rect2(),
	recompose_tokens: bool = false
) -> Array[Cmd]:
	var out: Array[Cmd] = []
	if doc == null:
		return out

	var ordered := _cells_in_paint_order(doc, region)

	# THREE FULL PASSES over the whole map, not one pass per cell.
	#
	# Tiles are drawn about twice as wide as their hex so the art bleeds over
	# the edges. Painting a hex complete — ground, river, town — before starting
	# the next one meant the next hex's ground landed on top of the previous
	# hex's town. Laying all the ground first, then all the water, then all the
	# buildings, is the fix, and it costs nothing.
	for at in ordered:
		var c: MapDocument.Cell = doc.cells[at]
		if c.terrain != null:
			_emit_piece(out, c.terrain, Hex.center_of(at), region)
	for at in ordered:
		var c: MapDocument.Cell = doc.cells[at]
		for p in c.lines:
			_emit_piece(out, p, Hex.center_of(at), region)
	for at in ordered:
		var c: MapDocument.Cell = doc.cells[at]
		for p in c.features:
			_emit_piece(out, p, Hex.center_of(at), region)

	_emit_tokens(out, doc, lib, region, recompose_tokens)
	return out


## Cells sorted so lower rows overlap the ones above, matching how the art is
## drawn to be seen from slightly above.
static func _cells_in_paint_order(doc: MapDocument, region: Rect2) -> Array:
	var keys: Array = []
	for at: Vector2i in doc.cells:
		if region.has_area():
			# A hex's art reaches well past the hex itself, so pad generously
			# rather than culling by the hex centre alone.
			var ctr := Hex.center_of(at)
			if not region.grow(2.5).has_point(ctr):
				continue
		keys.append(at)
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var ca := Hex.center_of(a)
		var cb := Hex.center_of(b)
		if not is_equal_approx(ca.y, cb.y):
			return ca.y < cb.y
		return ca.x < cb.x)
	return keys


static func _emit_piece(out: Array[Cmd], p: Piece, center: Vector2, region: Rect2) -> void:
	if p.tile.is_empty():
		return
	var cmd := Cmd.new()
	cmd.tile = p.tile
	cmd.pos = center + p.offset
	cmd.size = p.draw_size()
	cmd.rot = p.rot
	cmd.flip = p.flip
	cmd.hue = p.hue
	cmd.sat = p.sat
	cmd.alpha = p.alpha
	if region.has_area() and not region.intersects(cmd.bounds()):
		return
	out.append(cmd)


static func _emit_tokens(
	out: Array[Cmd], doc: MapDocument, lib: AssetLibrary,
	region: Rect2, recompose: bool
) -> void:
	if doc.tokens.is_empty():
		return
	var order: Array = []
	for i in doc.tokens.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var pa: Vector2 = doc.tokens[a].pos
		var pb: Vector2 = doc.tokens[b].pos
		if not is_equal_approx(pa.y, pb.y):
			return pa.y < pb.y
		return pa.x < pb.x)

	for i: int in order:
		var inst: TokenInstance = doc.tokens[i]
		var def := doc.token_def(inst.def_id)
		if def == null:
			continue
		if recompose and def.can_recompose(lib):
			for part in def.parts:
				var cmd := _token_part_cmd(inst, part)
				if region.has_area() and not region.intersects(cmd.bounds()):
					continue
				out.append(cmd)
		else:
			var cmd := _token_baked_cmd(inst, def)
			if region.has_area() and not region.intersects(cmd.bounds()):
				continue
			out.append(cmd)


## One part of a token, carried through the instance's own transform.
static func _token_part_cmd(inst: TokenInstance, part: TokenDef.Part) -> Cmd:
	var local := part.pos
	var prot := part.rot
	var pflip := part.flip
	if inst.flip:
		local.x = -local.x
		prot = -prot
		pflip = not pflip
	local = (local * inst.scale).rotated(inst.rot)
	var cmd := Cmd.new()
	cmd.tile = part.tile
	cmd.pos = inst.pos + local
	cmd.size = part.size * inst.scale
	cmd.rot = inst.rot + prot
	cmd.flip = pflip
	cmd.hue = part.hue
	cmd.sat = part.sat
	cmd.alpha = part.alpha
	return cmd


## The baked image, converted from anchor-and-pivot to the same centre-based
## form every other command uses, so renderers only ever handle one shape.
static func _token_baked_cmd(inst: TokenInstance, def: TokenDef) -> Cmd:
	var size := def.size_hex * inst.scale
	var offset := Vector2((0.5 - def.pivot.x) * size.x, (0.5 - def.pivot.y) * size.y)
	if inst.flip:
		offset.x = -offset.x
	var cmd := Cmd.new()
	cmd.token = def
	cmd.pos = inst.pos + offset.rotated(inst.rot)
	cmd.size = size
	cmd.rot = inst.rot
	cmd.flip = inst.flip
	return cmd


## Bounds of an already-built list, in hex widths.
static func bounds_of(cmds: Array[Cmd]) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in cmds:
		var b := c.bounds()
		lo = lo.min(b.position)
		hi = hi.max(b.end)
	if lo.x > hi.x:
		return Rect2()
	return Rect2(lo, hi - lo)
