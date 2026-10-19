class_name TestSuite
extends RefCounted
## Minimal assertion base for headless tests (see run_tests.gd).

var failures: PackedStringArray = []


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func check_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [message, expected, actual])


func check_near(actual: float, expected: float, tolerance: float, message: String = "") -> void:
	if absf(actual - expected) > tolerance:
		failures.append("%s: expected %s ± %s, got %s" % [message, expected, tolerance, actual])


## Shared fixture: the real material set.
func load_materials() -> MaterialDB:
	var db := MaterialDB.new()
	var err := db.load_dir()
	check(err == "", "materials load: " + err)
	return db
