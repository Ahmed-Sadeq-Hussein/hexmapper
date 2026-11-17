## Index of the tile pack on disk.
##
## The browser tools had to pick one DPI up front and keep a second "HD slot"
## for print renders. Here every DPI of a tile is indexed under one name and the
## right one is chosen per draw, so editing stays light and an export pulls the
## largest art available without the user swapping folders.
class_name AssetLibrary
extends RefCounted

const EXTENSIONS := ["png", "webp", "jpg", "jpeg"]
const CACHE_PATH := "user://asset_sizes.json"

## One tile, in every resolution it ships at.
class Entry extends RefCounted:
	var base: String              ## file name without extension, the shared key
	var variants: Dictionary = {} ## dpi:int -> absolute path:String
	var category: String = "Other"
	var is_hex: bool = false      ## a full hex tile rather than an Extra
	var dir_suffix: String = ""   ## "N", "SE", ... for directional river/path art
	var prefix: String = ""       ## the name with the direction suffix removed
	var size_px: Vector2i = Vector2i.ZERO  ## pixel size of [member size_dpi]
	var size_dpi: int = 0

	## The lowest DPI on offer, used for thumbnails and measuring.
	func smallest_dpi() -> int:
		var best := 1 << 30
		for d: int in variants:
			best = mini(best, d)
		return 0 if best == 1 << 30 else best

	func largest_dpi() -> int:
		var best := -1
		for d: int in variants:
			best = maxi(best, d)
		return best

	## The path whose art is at least [param want_px] wide, else the biggest there is.
	func path_for(want_px: float) -> String:
		var dpis: Array = variants.keys()
		dpis.sort()
		var chosen: int = dpis[0]
		for d: int in dpis:
			chosen = d
			var scaled := float(size_px.x) * (float(d) / maxf(1.0, float(size_dpi)))
			if size_dpi > 0 and scaled >= want_px:
				break
		return variants[chosen]


var entries: Dictionary = {}        ## base:String -> Entry
var categories: Dictionary = {}     ## category:String -> Array[String] of bases
var roots: PackedStringArray = []   ## folders that have been scanned
## Pixel width of a plain hex tile at [member ref_dpi]; the yardstick every
## other asset is measured against.
var ref_px: float = 224.0
var ref_dpi: int = 0
var ref_locked: bool = false        ## true once the user has set it by hand
## Global multiplier applied to non-hex art, for packs whose Extras read large.
var extras_scale: float = 1.0

var _textures: Dictionary = {}      ## "base@dpi" -> Texture2D
var _size_cache: Dictionary = {}    ## absolute path -> [w, h]
var _cache_dirty: bool = false

const CATEGORY_ORDER := [
	"Towns", "Ruins", "Flora", "Relief", "Ways", "Markers", "Other extras",
	"Hex · Base", "Hex · Relief", "Hex · Forest", "Hex · Water", "Hex · Lines", "Hex · Other",
]

static var _re_dpi := RegEx.create_from_string(r"(\d{2,3})\s*DPI")
static var _re_hex := RegEx.create_from_string(r"^(?i)Hex\s*-")
static var _re_dir := RegEx.create_from_string(r"\s(N|NE|E|SE|S|SW|W|NW)$")
static var _re_extras_copy := RegEx.create_from_string(r"(?i)Extras\s*-\s*Copy")


func _init() -> void:
	_load_cache()


# ---------------------------------------------------------------- scanning ---

## Walk [param root] and index every image under it. Additive: scanning a second
## folder adds to the same library, which is how the pack's Extras get loaded
## separately from the hex set.
func scan(root: String) -> Dictionary:
	var stats := {"found": 0, "added": 0, "skipped": 0, "variants": 0}
	var files: PackedStringArray = []
	_walk(root, files)
	stats.found = files.size()
	for path in files:
		if _re_extras_copy.search(path) != null:
			stats.skipped += 1
			continue
		var file := path.get_file()
		var base := file.get_basename()
		var dpi := _dpi_of(path)
		var entry: Entry = entries.get(base)
		if entry == null:
			entry = Entry.new()
			entry.base = base
			entry.is_hex = _re_hex.search(base) != null and not path.containsn("extras")
			entry.category = _categorize(base, path)
			var m := _re_dir.search(base)
			if m != null:
				entry.dir_suffix = m.get_string(1)
				# Keep whatever separates the name from the direction — "Hex -
				# River 1 " + "S". Dropping the space here is what stopped the
				# browser tool from ever finding a river's opposite half.
				entry.prefix = base.substr(0, base.length() - entry.dir_suffix.length())
			else:
				entry.prefix = base
			entries[base] = entry
			if not categories.has(entry.category):
				categories[entry.category] = []
			categories[entry.category].append(base)
			stats.added += 1
		if entry.variants.has(dpi):
			stats.skipped += 1
			continue
		entry.variants[dpi] = path
		stats.variants += 1
	if not roots.has(root):
		roots.append(root)
	_refresh_reference()
	return stats


func _walk(dir_path: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			_walk(full, out)
		elif EXTENSIONS.has(name.get_extension().to_lower()):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()


func _dpi_of(path: String) -> int:
	var m := _re_dpi.search(path)
	return int(m.get_string(1)) if m != null else 0


func _categorize(base: String, path: String) -> String:
	if path.containsn("extras") or _re_hex.search(base) == null:
		if _matches(base, "Building|City|Town|Farm|Tower|Monastery|Wall|Castle|Keep|Village|Hamlet|House|Hut|Mill|Temple|Church"):
			return "Towns"
		if _matches(base, "Banner|Statue|Flag|Marker|Icon|Label|Compass|Skull|Arrow"):
			return "Markers"
		if _matches(base, "Tree|Forest|Wood|Bush|Pine"):
			return "Flora"
		if _matches(base, "Ruin|Rubble|Grave|Tomb|Cairn"):
			return "Ruins"
		if _matches(base, "Ship|Boat|Dock|Bridge|Road|Wagon"):
			return "Ways"
		if _matches(base, "Mount|Peak|Rock|Cliff|Volcano|Crag"):
			return "Relief"
		return "Other extras"
	var b := base.trim_prefix("Hex - ")
	if _matches(b, "^Base"): return "Hex · Base"
	if _matches(b, "River|Path|Road"): return "Hex · Lines"
	if _matches(b, "Mountain|Hill"): return "Hex · Relief"
	if _matches(b, "Forest|Tree"): return "Hex · Forest"
	if _matches(b, "Water|Ocean|Coast|Beach|Swamp|Wetland"): return "Hex · Water"
	return "Hex · Other"


static func _matches(s: String, pattern: String) -> bool:
	var re := RegEx.create_from_string("(?i)" + pattern)
	return re.search(s) != null


## Categories in display order, unknown ones last.
func sorted_categories() -> Array:
	var keys: Array = categories.keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		var ia := CATEGORY_ORDER.find(a)
		var ib := CATEGORY_ORDER.find(b)
		if ia < 0: ia = 99
		if ib < 0: ib = 99
		return ia < ib if ia != ib else a < b)
	return keys


# --------------------------------------------------------------- measuring ---

## Pixel size of a tile, loaded once and remembered on disk between runs.
func size_of(base: String) -> Vector2i:
	var entry: Entry = entries.get(base)
	if entry == null:
		return Vector2i.ZERO
	if entry.size_px != Vector2i.ZERO:
		return entry.size_px
	var dpi := entry.smallest_dpi()
	var path: String = entry.variants.get(dpi, "")
	if path.is_empty():
		return Vector2i.ZERO
	var cached: Variant = _size_cache.get(path)
	if cached is Array and (cached as Array).size() == 2:
		entry.size_px = Vector2i(int(cached[0]), int(cached[1]))
		entry.size_dpi = dpi
		return entry.size_px
	var img := Image.load_from_file(path)
	if img == null:
		return Vector2i.ZERO
	entry.size_px = Vector2i(img.get_width(), img.get_height())
	entry.size_dpi = dpi
	_size_cache[path] = [entry.size_px.x, entry.size_px.y]
	_cache_dirty = true
	return entry.size_px


## How wide this asset wants to be, in hex widths, from its own pixels.
##
## This is the whole answer to "why do towns dwarf everything": a 96 px town
## beside a 224 px hex tile is 43 % of a hex, and drawing it any other size is a
## guess. Hex tiles come back at whatever their art says, so a mountain tile
## drawn 35 % oversized overhangs its hex exactly as the artist intended.
func native_width(base: String) -> float:
	var entry: Entry = entries.get(base)
	if entry == null:
		return 1.0
	var px := size_of(base)
	if px == Vector2i.ZERO or ref_px <= 0.0:
		return 1.0
	var ref := ref_px
	if entry.size_dpi > 0 and ref_dpi > 0:
		ref = ref_px * (float(entry.size_dpi) / float(ref_dpi))
	var w := float(px.x) / ref
	if not entry.is_hex:
		w *= extras_scale
	return clampf(w, 0.01, 8.0)


func native_size(base: String) -> Vector2:
	var px := size_of(base)
	var w := native_width(base)
	if px == Vector2i.ZERO or px.x == 0:
		return Vector2(w, w * Hex.ASPECT)
	return Vector2(w, w * (float(px.y) / float(px.x)))


func set_reference(px: float, dpi: int) -> void:
	ref_px = maxf(8.0, px)
	ref_dpi = dpi
	ref_locked = true


## Measure a plain, non-directional hex tile and use it as the yardstick.
func _refresh_reference() -> void:
	if ref_locked:
		return
	for cat in ["Hex · Base", "Hex · Water", "Hex · Other", "Hex · Forest"]:
		for base: String in categories.get(cat, []):
			var entry: Entry = entries[base]
			if not entry.dir_suffix.is_empty():
				continue
			var px := size_of(base)
			if px != Vector2i.ZERO:
				ref_px = float(px.x)
				ref_dpi = entry.size_dpi
				return


# --------------------------------------------------------------- textures ----

## A texture for [param base] at least [param want_px] wide. Cached per DPI, so
## a screen draw and a print render share nothing and neither pays for the other.
func texture(base: String, want_px: float = 0.0) -> Texture2D:
	var entry: Entry = entries.get(base)
	if entry == null:
		return null
	var path := entry.path_for(want_px)
	var key := path
	var cached: Variant = _textures.get(key)
	if cached != null:
		return cached
	var img := Image.load_from_file(path)
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	var tex := ImageTexture.create_from_image(img)
	_textures[key] = tex
	return tex


## The raw image, for CPU compositing during a headless export.
func image(base: String, want_px: float = 0.0) -> Image:
	var entry: Entry = entries.get(base)
	if entry == null:
		return null
	var img := Image.load_from_file(entry.path_for(want_px))
	if img != null and img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


func has(base: String) -> bool:
	return entries.has(base)


func count() -> int:
	return entries.size()


func extras_count() -> int:
	var n := 0
	for base: String in entries:
		if not (entries[base] as Entry).is_hex:
			n += 1
	return n


## Every base name in a category, sorted.
func in_category(cat: String) -> Array:
	var a: Array = (categories.get(cat, []) as Array).duplicate()
	a.sort()
	return a


## Names matching a search string, optionally restricted to Extras.
func search(query: String, extras_only: bool = false) -> Array:
	var q := query.strip_edges().to_lower()
	var out: Array = []
	for base: String in entries:
		var entry: Entry = entries[base]
		if extras_only and entry.is_hex:
			continue
		if q.is_empty() or base.to_lower().contains(q):
			out.append(base)
	out.sort()
	return out


## Directional sibling of a river/path piece, e.g. the S half that meets an N.
func opposite_piece(base: String) -> String:
	var entry: Entry = entries.get(base)
	if entry == null or entry.dir_suffix.is_empty():
		return ""
	if not Hex.NAME_TO_DIR.has(entry.dir_suffix):
		return ""
	var opp_dir: int = Hex.OPPOSITE[Hex.NAME_TO_DIR[entry.dir_suffix]]
	var candidate: String = entry.prefix + Hex.DIR_NAMES[opp_dir]
	return candidate if entries.has(candidate) else ""


# ------------------------------------------------------------- size cache ----

func _load_cache() -> void:
	if not FileAccess.file_exists(CACHE_PATH):
		return
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		_size_cache = parsed


func save_cache() -> void:
	if not _cache_dirty:
		return
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_size_cache))
	_cache_dirty = false
