## A token: free-form art built from any number of assets, saved as one .ftok.
##
## The file carries two halves of the same picture. [member parts] is the
## recipe — the map re-composites it from the 300 DPI assets for a print render.
## [member baked_png] is a finished image, so a token still draws on a machine
## that does not have the asset pack it was built from.
class_name TokenDef
extends RefCounted

const FORMAT := "falldin-token"

class Part extends RefCounted:
	var tile: String = ""
	var pos: Vector2 = Vector2.ZERO   ## centre, in hex widths from the token anchor
	var size: Vector2 = Vector2.ONE   ## width and height in hex widths
	var rot: float = 0.0              ## radians
	var flip: bool = false
	var hue: float = 0.0
	var sat: float = 1.0
	var alpha: float = 1.0

var id: String = ""
var name: String = ""
var kind: String = "other"
var snap_to_hex: bool = true
var created: String = ""
var size_hex: Vector2 = Vector2.ONE   ## footprint of the baked image, in hex widths
var pivot: Vector2 = Vector2(0.5, 0.5)  ## anchor position as a fraction of the baked image
var parts: Array[Part] = []
var baked_png: PackedByteArray = PackedByteArray()
var thumb_png: PackedByteArray = PackedByteArray()
var source_file: String = ""

var _baked_texture: Texture2D = null


static func new_id() -> String:
	return "tok_%s%s" % [
		String.num_int64(Time.get_unix_time_from_system() as int, 36),
		String.num_int64(randi() % 1679616, 36).pad_zeros(4),
	]


## Read the .ftok JSON the browser tools write.
static func from_dict(d: Dictionary) -> TokenDef:
	if str(d.get("format", "")) != FORMAT:
		return null
	var t := TokenDef.new()
	t.id = str(d.get("id", new_id()))
	t.name = str(d.get("name", "untitled"))
	t.kind = str(d.get("kind", "other"))
	t.snap_to_hex = bool(d.get("snap", true))
	t.created = str(d.get("created", ""))
	t.size_hex = Vector2(float(d.get("widthHex", 1.0)), float(d.get("heightHex", 1.0)))
	var pv: Dictionary = d.get("pivot", {})
	t.pivot = Vector2(float(pv.get("x", 0.5)), float(pv.get("y", 0.5)))
	for raw: Variant in d.get("parts", []):
		var pd: Dictionary = raw
		var p := Part.new()
		p.tile = str(pd.get("tile", ""))
		p.pos = Vector2(float(pd.get("x", 0.0)), float(pd.get("y", 0.0)))
		p.size = Vector2(float(pd.get("wHex", 1.0)), float(pd.get("hHex", 1.0)))
		p.rot = deg_to_rad(float(pd.get("rot", 0.0)))
		p.flip = bool(pd.get("flip", false))
		p.hue = float(pd.get("hue", 0.0))
		p.sat = float(pd.get("sat", 1.0))
		p.alpha = float(pd.get("alpha", 1.0))
		t.parts.append(p)
	t.baked_png = _decode_data_url(str((d.get("baked", {}) as Dictionary).get("png", "")))
	t.thumb_png = _decode_data_url(str(d.get("thumb", "")))
	return t


func to_dict() -> Dictionary:
	var out_parts: Array = []
	for p in parts:
		out_parts.append({
			"tile": p.tile,
			"x": snappedf(p.pos.x, 0.0001), "y": snappedf(p.pos.y, 0.0001),
			"wHex": snappedf(p.size.x, 0.0001), "hHex": snappedf(p.size.y, 0.0001),
			"rot": snappedf(rad_to_deg(p.rot), 0.01),
			"flip": p.flip, "hue": p.hue, "sat": p.sat, "alpha": p.alpha,
		})
	var baked := {}
	if not baked_png.is_empty():
		baked = {"png": _encode_data_url(baked_png)}
	return {
		"format": FORMAT, "version": 1,
		"id": id, "name": name, "kind": kind, "snap": snap_to_hex,
		"created": created if not created.is_empty() else Time.get_datetime_string_from_system(true),
		"widthHex": snappedf(size_hex.x, 0.0001),
		"heightHex": snappedf(size_hex.y, 0.0001),
		"pivot": {"x": snappedf(pivot.x, 0.00001), "y": snappedf(pivot.y, 0.00001)},
		"parts": out_parts,
		"baked": baked,
		"thumb": _encode_data_url(thumb_png),
	}


static func load_file(path: String) -> TokenDef:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return null
	var t := from_dict(parsed)
	if t != null:
		t.source_file = path
	return t


func save_file(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ERR_CANT_OPEN
	f.store_string(JSON.stringify(to_dict()))
	source_file = path
	return OK


## Texture of the baked image, decoded once.
func baked_texture() -> Texture2D:
	if _baked_texture != null:
		return _baked_texture
	if baked_png.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(baked_png) != OK:
		return null
	_baked_texture = ImageTexture.create_from_image(img)
	return _baked_texture


func baked_image() -> Image:
	if baked_png.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(baked_png) != OK:
		return null
	return img


## True when every asset this token is made of is loaded, so it can be rebuilt
## at full resolution instead of falling back to the baked image.
func can_recompose(lib: AssetLibrary) -> bool:
	if parts.is_empty() or lib == null:
		return false
	for p in parts:
		if not lib.has(p.tile):
			return false
	return true


static func _decode_data_url(s: String) -> PackedByteArray:
	if s.is_empty():
		return PackedByteArray()
	var comma := s.find(",")
	if comma < 0:
		return PackedByteArray()
	return Marshalls.base64_to_raw(s.substr(comma + 1))


static func _encode_data_url(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	return "data:image/png;base64," + Marshalls.raw_to_base64(bytes)
