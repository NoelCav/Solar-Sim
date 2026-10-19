extends SceneTree
## Headless test runner. Runs every `test_*` method in every tests/test_*.gd file.
##   godot --headless --path . -s res://tests/run_tests.gd
## Exits with code 1 if any test fails.

const TEST_DIR := "res://tests"


func _initialize() -> void:
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
			var suite: TestSuite = script.new()
			suite.call(name)
			var label := "%s::%s" % [file.get_basename(), name]
			if suite.failures.is_empty():
				passed += 1
				print("  PASS  ", label)
			else:
				failed.append(label)
				print("  FAIL  ", label)
				for f in suite.failures:
					print("        ", f)
	print("\n%d passed, %d failed" % [passed, failed.size()])
	quit(1 if failed.size() > 0 else 0)
