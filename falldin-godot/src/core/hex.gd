## Flat-top hexagon grid maths, odd columns shifted down.
##
## Everything in Falldin is measured in HEX WIDTHS: one hex is 1.0 wide and
## [constant ASPECT] tall. Pixels only appear at the very end, when a view or an
## export multiplies by its own scale. That is what lets the same document draw
## at 64 px per hex on screen and 933 px per hex in a print render without a
## single number changing.
class_name Hex
extends RefCounted

## Height of a hex tile divided by its width, from the source art (194 / 224 px).
const ASPECT := 194.0 / 224.0
## Horizontal distance between neighbouring columns.
const COL_STEP := 0.75
## Vertical distance between neighbouring rows.
const ROW_STEP := ASPECT

enum Dir { N, NE, SE, S, SW, NW }

const DIR_NAMES := {
	Dir.N: "N", Dir.NE: "NE", Dir.SE: "SE",
	Dir.S: "S", Dir.SW: "SW", Dir.NW: "NW",
}
const OPPOSITE := {
	Dir.N: Dir.S, Dir.S: Dir.N,
	Dir.NE: Dir.SW, Dir.SW: Dir.NE,
	Dir.SE: Dir.NW, Dir.NW: Dir.SE,
}
## The pack also ships East/West pieces; they are points, not edges, so they
## have no opposite and never auto-connect.
const NAME_TO_DIR := {
	"N": Dir.N, "NE": Dir.NE, "SE": Dir.SE,
	"S": Dir.S, "SW": Dir.SW, "NW": Dir.NW,
}


## Centre of the hex at column [param c], row [param r], in hex widths.
static func center(c: int, r: int) -> Vector2:
	var y := r * ROW_STEP + ASPECT * 0.5
	if c & 1:
		y += ASPECT * 0.5
	return Vector2(c * COL_STEP + 0.5, y)


static func center_of(cell: Vector2i) -> Vector2:
	return center(cell.x, cell.y)


## The neighbouring cell in [param dir]. Odd columns sit half a row lower, so
## the diagonal steps differ between even and odd columns.
static func neighbor(c: int, r: int, dir: int) -> Vector2i:
	var even := (c & 1) == 0
	match dir:
		Dir.N: return Vector2i(c, r - 1)
		Dir.S: return Vector2i(c, r + 1)
		Dir.NE: return Vector2i(c + 1, r - 1) if even else Vector2i(c + 1, r)
		Dir.SE: return Vector2i(c + 1, r) if even else Vector2i(c + 1, r + 1)
		Dir.NW: return Vector2i(c - 1, r - 1) if even else Vector2i(c - 1, r)
		Dir.SW: return Vector2i(c - 1, r) if even else Vector2i(c - 1, r + 1)
	return Vector2i(c, r)


## The cell whose centre is nearest to [param p] (hex widths).
## Candidate columns/rows are derived from the bounding box, then the true
## nearest centre is picked — the cheap "divide and round" answer is wrong near
## the slanted edges of a hex.
static func from_point(p: Vector2, bounds := Vector2i.ZERO) -> Vector2i:
	var ac := int(floor(p.x / COL_STEP))
	var ar := int(floor(p.y / ROW_STEP))
	var best := Vector2i(ac, ar)
	var best_d := INF
	for c in range(ac - 1, ac + 2):
		for r in range(ar - 1, ar + 2):
			if bounds != Vector2i.ZERO and (c < 0 or r < 0 or c >= bounds.x or r >= bounds.y):
				continue
			var d := center(c, r).distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = Vector2i(c, r)
	return best


## Cube coordinates for [param cell].
##
## Offset coordinates are not translation-invariant: moving a shape one column
## across changes which of its cells sit half a row lower. Cube coordinates have
## no such seam, so a stamp converted through them lands as the same shape
## whether you drop it on an odd column or an even one.
static func to_cube(cell: Vector2i) -> Vector3i:
	var x := cell.x
	var z := cell.y - ((cell.x - (cell.x & 1)) / 2)
	return Vector3i(x, -x - z, z)


static func from_cube(c: Vector3i) -> Vector2i:
	return Vector2i(c.x, c.z + ((c.x - (c.x & 1)) / 2))


## Distance in hexes between two cells.
static func distance(a: Vector2i, b: Vector2i) -> int:
	var d := to_cube(a) - to_cube(b)
	return int((absi(d.x) + absi(d.y) + absi(d.z)) / 2)


## Outline of a hex centred on the origin, one hex wide. Multiply by a scale to
## draw it.
static func outline() -> PackedVector2Array:
	var w := 0.5
	var h := ASPECT * 0.5
	return PackedVector2Array([
		Vector2(w, 0.0), Vector2(w * 0.5, -h), Vector2(-w * 0.5, -h),
		Vector2(-w, 0.0), Vector2(-w * 0.5, h), Vector2(w * 0.5, h),
	])


## Bounding box, in hex widths, of a rectangular block of cells.
static func block_bounds(c0: int, r0: int, c1: int, r1: int) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in range(c0, c1 + 1):
		for r in range(r0, r1 + 1):
			var ctr := center(c, r)
			lo.x = minf(lo.x, ctr.x - 0.5)
			hi.x = maxf(hi.x, ctr.x + 0.5)
			lo.y = minf(lo.y, ctr.y - ASPECT * 0.5)
			hi.y = maxf(hi.y, ctr.y + ASPECT * 0.5)
	if lo.x > hi.x:
		return Rect2()
	return Rect2(lo, hi - lo)


## True when the point lies inside the hexagon centred at [param c] (hex widths).
static func contains_point(c: Vector2, p: Vector2) -> bool:
	var d := (p - c).abs()
	if d.x > 0.5 or d.y > ASPECT * 0.5:
		return false
	# The two slanted edges: x/0.5 + y/(ASPECT/2) <= 1.5 in the corner quadrant.
	return d.x / 0.5 + d.y / (ASPECT * 0.5) <= 1.5
