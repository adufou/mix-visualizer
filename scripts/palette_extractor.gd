class_name PaletteExtractor
extends RefCounted
## Dominant-color extraction: k-means clustering in CIE Lab space (so
## "distance between colors" matches human perception, unlike RGB), then a
## greedy farthest-point walk picks 3 clusters that are maximally spread out
## in that space instead of just the 3 biggest — which is what keeps a
## palette from image with e.g. mostly green foliage from being 3 near-
## identical greens.

const MAX_DIM := 300
const SAMPLE_CAP := 8000     # cap on pixels fed to k-means, for speed
const K_CANDIDATES := 12
const MIN_FRACTION := 0.005  # drop clusters smaller than this share of pixels
const KMEANS_MAX_ITER := 15
const KMEANS_SEED := 42

const D65 := Vector3(0.95047, 1.0, 1.08883)
const RGB_TO_XYZ_M := Basis(
	Vector3(0.4124564, 0.2126729, 0.0193339),
	Vector3(0.3575761, 0.7151522, 0.1191920),
	Vector3(0.1804375, 0.0721750, 0.9503041)
)
const XYZ_TO_RGB_M := Basis(
	Vector3(3.2404542, -0.9692660, 0.0556434),
	Vector3(-1.5371385, 1.8760108, -0.2040259),
	Vector3(-0.4985314, 0.0415560, 1.0572252)
)


static func _srgb_to_linear(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


static func _linear_to_srgb(c: float) -> float:
	c = clamp(c, 0.0, 1.0)
	return c * 12.92 if c <= 0.0031308 else 1.055 * pow(c, 1.0 / 2.4) - 0.055


static func _lab_f(t: float) -> float:
	const DELTA := 6.0 / 29.0
	return pow(t, 1.0 / 3.0) if t > DELTA * DELTA * DELTA else t / (3.0 * DELTA * DELTA) + 4.0 / 29.0


static func _lab_finv(t: float) -> float:
	const DELTA := 6.0 / 29.0
	return t * t * t if t > DELTA else 3.0 * DELTA * DELTA * (t - 4.0 / 29.0)


static func _rgb_to_lab(color: Color) -> Vector3:
	var linear := Vector3(_srgb_to_linear(color.r), _srgb_to_linear(color.g), _srgb_to_linear(color.b))
	var xyz: Vector3 = RGB_TO_XYZ_M * linear
	var fx := _lab_f(xyz.x / D65.x)
	var fy := _lab_f(xyz.y / D65.y)
	var fz := _lab_f(xyz.z / D65.z)
	return Vector3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))


static func _lab_to_rgb(lab: Vector3) -> Color:
	var fy := (lab.x + 16.0) / 116.0
	var fx := fy + lab.y / 500.0
	var fz := fy - lab.z / 200.0
	var xyz := Vector3(D65.x * _lab_finv(fx), D65.y * _lab_finv(fy), D65.z * _lab_finv(fz))
	var linear: Vector3 = XYZ_TO_RGB_M * xyz
	return Color(_linear_to_srgb(linear.x), _linear_to_srgb(linear.y), _linear_to_srgb(linear.z))


## Resizes to a thumbnail (keeping aspect) and converts every opaque pixel
## to Lab, then strides down to SAMPLE_CAP points so k-means cost stays
## bounded regardless of source image size.
static func _sample_pixels_lab(image: Image) -> Array:
	var img: Image = image.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w > MAX_DIM or h > MAX_DIM:
		var scale: float = float(MAX_DIM) / float(max(w, h))
		img.resize(max(1, int(w * scale)), max(1, int(h * scale)))
		w = img.get_width()
		h = img.get_height()

	var all_points: Array = []
	for y in h:
		for x in w:
			var c: Color = img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			all_points.append(_rgb_to_lab(c))

	if all_points.size() <= SAMPLE_CAP:
		return all_points
	var stride: int = int(ceil(float(all_points.size()) / float(SAMPLE_CAP)))
	var sampled: Array = []
	var i := 0
	while i < all_points.size():
		sampled.append(all_points[i])
		i += stride
	return sampled


static func _kmeans_pp_init(points: Array, k: int, rng: RandomNumberGenerator) -> Array:
	var centers: Array = [points[rng.randi_range(0, points.size() - 1)]]
	var dist_sq: Array = []
	dist_sq.resize(points.size())
	for i in points.size():
		dist_sq[i] = points[i].distance_squared_to(centers[0])

	while centers.size() < k:
		var total := 0.0
		for d in dist_sq:
			total += d
		var new_center: Vector3
		if total <= 0.0:
			new_center = points[rng.randi_range(0, points.size() - 1)]
		else:
			var r: float = rng.randf() * total
			var acc := 0.0
			var chosen_idx: int = points.size() - 1
			for i in points.size():
				acc += dist_sq[i]
				if acc >= r:
					chosen_idx = i
					break
			new_center = points[chosen_idx]
		centers.append(new_center)
		for i in points.size():
			var d: float = points[i].distance_squared_to(new_center)
			if d < dist_sq[i]:
				dist_sq[i] = d
	return centers


static func _nearest_center(point: Vector3, centers: Array) -> int:
	var best_c := 0
	var best_d := INF
	for c in centers.size():
		var d: float = point.distance_squared_to(centers[c])
		if d < best_d:
			best_d = d
			best_c = c
	return best_c


## Lloyd's algorithm seeded with k-means++, in Lab space. A fixed seed keeps
## results reproducible run to run for the same image.
static func _kmeans_lab(points: Array, k: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = KMEANS_SEED
	var centers: Array = _kmeans_pp_init(points, k, rng)
	var assignments: Array = []
	assignments.resize(points.size())
	for i in points.size():
		assignments[i] = -1

	for _iter in KMEANS_MAX_ITER:
		var changed := false
		for i in points.size():
			var best_c: int = _nearest_center(points[i], centers)
			if assignments[i] != best_c:
				changed = true
				assignments[i] = best_c
		if not changed:
			break
		var sums: Array = []
		var counts: Array = []
		for _c in k:
			sums.append(Vector3.ZERO)
			counts.append(0)
		for i in points.size():
			var a: int = assignments[i]
			sums[a] += points[i]
			counts[a] += 1
		for c in k:
			if counts[c] > 0:
				centers[c] = sums[c] / counts[c]

	var final_counts: Array = []
	for _c in k:
		final_counts.append(0)
	for a in assignments:
		final_counts[a] += 1
	return {"centers": centers, "counts": final_counts}


## Clusters the image's pixels in Lab space and returns the resulting
## clusters as {color, lab, frac} entries, sorted by descending frac, with
## noise clusters below MIN_FRACTION dropped.
static func generate(image: Image, k_candidates := K_CANDIDATES) -> Array:
	var points: Array = _sample_pixels_lab(image)
	if points.is_empty():
		return []
	var k: int = min(k_candidates, points.size())
	var result := _kmeans_lab(points, k)
	var centers: Array = result.centers
	var counts: Array = result.counts
	var total: int = points.size()

	var candidates: Array = []
	for c in k:
		var frac: float = float(counts[c]) / float(total)
		if frac < MIN_FRACTION:
			continue
		var lab: Vector3 = centers[c]
		candidates.append({"lab": lab, "color": _lab_to_rgb(lab), "frac": frac})
	candidates.sort_custom(func(a, b): return a.frac > b.frac)
	return candidates


## Greedy farthest-point selection in Lab space: seed with the most
## dominant cluster, then repeatedly add whichever remaining candidate is
## farthest from its closest already-chosen color. Produces a spread of
## genuinely distinct colors instead of the top-N by frequency.
static func pick_three(candidates: Array, n_final := 3) -> Array:
	if candidates.is_empty():
		return []
	if candidates.size() <= n_final:
		var out: Array = []
		for c in candidates:
			out.append(c.color)
		return out

	var chosen: Array = [0]
	while chosen.size() < n_final:
		var best_i := -1
		var best_min_dist := -1.0
		for i in candidates.size():
			if chosen.has(i):
				continue
			var min_dist := INF
			for j in chosen:
				var d: float = candidates[i].lab.distance_squared_to(candidates[j].lab)
				if d < min_dist:
					min_dist = d
			if min_dist > best_min_dist:
				best_min_dist = min_dist
				best_i = i
		chosen.append(best_i)

	var out: Array = []
	for i in chosen:
		out.append(candidates[i].color)
	return out


## Maps clusters onto 3 named bands (low/mid/high) for waveform-style
## visuals: each band picks whichever candidate's Lab lightness is closest
## to its target (26/50/74 on the 0-100 Lab L scale), exclusive of colors
## already claimed by another band. Falls back to gray only if `generate`
## found no clusters at all.
static func pick_bands(candidates: Array) -> Dictionary:
	if candidates.is_empty():
		return {"low": Color(0.2, 0.2, 0.2), "mid": Color(0.5, 0.5, 0.5), "high": Color(0.85, 0.85, 0.85)}
	var used := {}
	return {
		"low": _closest_lightness(candidates, 26.0, used),
		"mid": _closest_lightness(candidates, 50.0, used),
		"high": _closest_lightness(candidates, 74.0, used),
	}


static func _closest_lightness(pool: Array, target_l: float, used: Dictionary) -> Color:
	var best = null
	var best_dist := INF
	for exclusive in [true, false]:
		for c in pool:
			if exclusive and used.has(c.color):
				continue
			var dist: float = abs(c.lab.x - target_l)
			if dist < best_dist:
				best_dist = dist
				best = c
		if best != null:
			break
	used[best.color] = true
	return best.color
