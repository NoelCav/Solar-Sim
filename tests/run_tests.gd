extends SceneTree
## Headless test runner. Runs every `test_*` method in every tests/test_*.gd file.
##   godot --headless --path . -s res://tests/run_tests.gd
## A test fails on a failed check or on any script error raised while it runs.
## Exits with code 1 if any test fails.

const TEST_DIR := "res://tests"


class ErrorCounter extends Logger:
	var errors: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_SCRIPT or error_type == ERROR_TYPE_ERROR:
			errors.append("%s (%s:%d in %s)" % [rationale if rationale != "" else code, file, line, function])


func _initialize() -> void:
	var counter := ErrorCounter.new()
	OS.add_logger(counter)
	var passed := 0
	var failed: PackedStringArray = []
	for file in DirAccess.get_files_at(TEST_DIR):
		if not (file.begins_with("test_") and file.ends_with(".gd")):
			continue
		var script: GDScript = load(TEST_DIR.path_join(file))
		for method in script.get_script_method_list():
			var name: String = method["name"]
			if not name.begins_with("test_"):
				continue
			counter.errors.clear()
			var suite: TestSuite = script.new()
			suite.call(name)
			var problems := suite.failures.duplicate()
			for e in counter.errors:
				problems.append("error: " + e)
			var label := "%s::%s" % [file.get_basename(), name]
			if problems.is_empty():
				passed += 1
				print("  PASS  ", label)
			else:
				failed.append(label)
				print("  FAIL  ", label)
				for f in problems:
					print("        ", f)
	OS.remove_logger(counter)
	print("\n%d passed, %d failed" % [passed, failed.size()])
	quit(1 if failed.size() > 0 else 0)
