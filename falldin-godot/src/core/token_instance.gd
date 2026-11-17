## A token placed on a map: its own position, size and rotation, above every
## hex layer. Any number of them can share a hex.
class_name TokenInstance
extends RefCounted

var def_id: String = ""
var pos: Vector2 = Vector2.ZERO   ## anchor position in hex widths
var scale: float = 1.0
var rot: float = 0.0
var flip: bool = false


func duplicate_instance() -> TokenInstance:
	var t := TokenInstance.new()
	t.def_id = def_id
	t.pos = pos
	t.scale = scale
	t.rot = rot
	t.flip = flip
	return t


## Untransformed bounds in hex widths, used for picking and for export extents.
func bounds(def: TokenDef) -> Rect2:
	if def == null:
		return Rect2(pos, Vector2.ZERO)
	var s := def.size_hex * scale
	return Rect2(pos - Vector2(s.x * def.pivot.x, s.y * def.pivot.y), s)


func to_dict() -> Dictionary:
	var d := {"id": def_id, "x": snappedf(pos.x, 0.0001), "y": snappedf(pos.y, 0.0001)}
	if not is_equal_approx(scale, 1.0):
		d["s"] = snappedf(scale, 0.0001)
	if not is_zero_approx(rot):
		d["r"] = snappedf(rad_to_deg(rot), 0.01)
	if flip:
		d["f"] = true
	return d


static func from_dict(d: Dictionary) -> TokenInstance:
	var t := TokenInstance.new()
	t.def_id = str(d.get("id", ""))
	t.pos = Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	t.scale = float(d.get("s", 1.0))
	t.rot = deg_to_rad(float(d.get("r", 0.0)))
	t.flip = bool(d.get("f", false))
	return t
