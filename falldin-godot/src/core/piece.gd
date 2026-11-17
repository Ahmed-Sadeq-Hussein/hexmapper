## One drawn asset sitting in a hex.
##
## Every transform lives on the piece, not on the hex. That is the difference
## between "shrink the town" and "shrink the town, the grass and the river with
## it", which is what a single per-cell transform forced you into.
class_name Piece
extends RefCounted

var tile: String = ""
## Width in hex widths. 1.0 spans exactly one hex. Absolute, not a multiplier,
## so a piece keeps its size when the asset pack or the zoom changes.
var size: float = 1.0
## Height divided by width, kept from the source art so nothing is squashed into
## a hex's proportions.
var aspect: float = Hex.ASPECT
## Nudge from the hex centre, in hex widths.
var offset: Vector2 = Vector2.ZERO
var rot: float = 0.0          ## radians
var flip: bool = false
var hue: float = 0.0          ## degrees
var sat: float = 1.0
var alpha: float = 1.0


static func make(tile_name: String, lib: AssetLibrary, rotation := 0.0) -> Piece:
	var p := Piece.new()
	p.tile = tile_name
	p.rot = rotation
	if lib != null and lib.has(tile_name):
		var n := lib.native_size(tile_name)
		p.size = n.x
		p.aspect = n.y / maxf(0.0001, n.x)
	return p


func duplicate_piece() -> Piece:
	var p := Piece.new()
	p.tile = tile
	p.size = size
	p.aspect = aspect
	p.offset = offset
	p.rot = rot
	p.flip = flip
	p.hue = hue
	p.sat = sat
	p.alpha = alpha
	return p


func draw_size() -> Vector2:
	return Vector2(size, size * aspect)


func is_plain() -> bool:
	return is_zero_approx(hue) and is_equal_approx(sat, 1.0) and is_equal_approx(alpha, 1.0)


func to_dict() -> Dictionary:
	var d := {"t": tile, "w": snappedf(size, 0.0001)}
	if not is_equal_approx(aspect, Hex.ASPECT):
		d["a"] = snappedf(aspect, 0.0001)
	if offset != Vector2.ZERO:
		d["o"] = [snappedf(offset.x, 0.0001), snappedf(offset.y, 0.0001)]
	if not is_zero_approx(rot):
		d["r"] = snappedf(rad_to_deg(rot), 0.01)
	if flip:
		d["f"] = true
	if not is_zero_approx(hue):
		d["h"] = snappedf(hue, 0.01)
	if not is_equal_approx(sat, 1.0):
		d["s"] = snappedf(sat, 0.001)
	if not is_equal_approx(alpha, 1.0):
		d["al"] = snappedf(alpha, 0.001)
	return d


static func from_dict(d: Dictionary) -> Piece:
	var p := Piece.new()
	p.tile = str(d.get("t", ""))
	p.size = float(d.get("w", 1.0))
	p.aspect = float(d.get("a", Hex.ASPECT))
	if d.has("o"):
		var o: Array = d["o"]
		p.offset = Vector2(float(o[0]), float(o[1]))
	p.rot = deg_to_rad(float(d.get("r", 0.0)))
	p.flip = bool(d.get("f", false))
	p.hue = float(d.get("h", 0.0))
	p.sat = float(d.get("s", 1.0))
	p.alpha = float(d.get("al", 1.0))
	return p
