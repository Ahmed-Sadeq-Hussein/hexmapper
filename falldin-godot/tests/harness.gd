## Minimal assertion harness. No dependencies, runs headless, exits non-zero on
## the first failing suite so CI and a terminal both notice.
class_name TestHarness
extends RefCounted

var passed := 0
var failed := 0
var _suite := ""
var _failures: Array[String] = []


func suite(name: String) -> void:
	_suite = name
	print("\n── %s" % name)


func ok(condition: bool, label: String) -> bool:
	if condition:
		passed += 1
		print("   PASS %s" % label)
	else:
		failed += 1
		_failures.append("%s › %s" % [_suite, label])
		print("   FAIL %s" % label)
	return condition


func eq(actual: Variant, expected: Variant, label: String) -> bool:
	if _same(actual, expected):
		passed += 1
		print("   PASS %s" % label)
		return true
	failed += 1
	_failures.append("%s › %s  (got %s, want %s)" % [_suite, label, actual, expected])
	print("   FAIL %s\n       got  %s\n       want %s" % [label, actual, expected])
	return false


func close(actual: float, expected: float, label: String, tol := 0.0005) -> bool:
	if absf(actual - expected) <= tol:
		passed += 1
		print("   PASS %s  (%.5f)" % [label, actual])
		return true
	failed += 1
	_failures.append("%s › %s  (got %.6f, want %.6f)" % [_suite, label, actual, expected])
	print("   FAIL %s\n       got  %.6f\n       want %.6f" % [label, actual, expected])
	return false


func close_vec(actual: Vector2, expected: Vector2, label: String, tol := 0.0005) -> bool:
	if actual.distance_to(expected) <= tol:
		passed += 1
		print("   PASS %s  (%.4f, %.4f)" % [label, actual.x, actual.y])
		return true
	failed += 1
	_failures.append("%s › %s  (got %s, want %s)" % [_suite, label, actual, expected])
	print("   FAIL %s\n       got  %s\n       want %s" % [label, actual, expected])
	return false


static func _same(a: Variant, b: Variant) -> bool:
	if a is float or b is float:
		return is_equal_approx(float(a), float(b))
	return a == b


func report() -> int:
	print("\n" + "".lpad(52, "─"))
	if failed == 0:
		print("  %d passed" % passed)
	else:
		print("  %d passed, %d FAILED" % [passed, failed])
		for f in _failures:
			print("    · %s" % f)
	print("".lpad(52, "─"))
	return failed
