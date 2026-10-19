extends TestSuite


func test_all_materials_load_with_air_at_zero() -> void:
	var db := load_materials()
	check_eq(db.get_def(MaterialDB.AIR_ID).key, &"air", "id 0")
	check(db.placeable().size() >= 17, "expected the starter set")


func test_lookup_tables_match_defs() -> void:
	var db := load_materials()
	var copper := db.get_by_key(&"copper")
	check_near(db.conductivity[copper.id], 400.0, 0.01, "copper k")
	check_eq(db.is_solid[db.id_of(&"water")], 0, "water is not solid")
	check_eq(db.is_solid[db.id_of(&"sand")], 1, "powder counts as solid")


func test_crown_glass_index_is_realistic() -> void:
	# BK7 crown glass: n ≈ 1.517 at the sodium D line (589 nm).
	var glass := load_materials().get_by_key(&"crown_glass")
	check_near(glass.refractive_index(0.589), 1.517, 0.003, "n_D")
	check(glass.refractive_index(0.46) > glass.refractive_index(0.68), "blue bends more than red")


func test_duplicate_ids_are_rejected() -> void:
	var a := MaterialDef.new()
	a.key = &"air"
	a.id = 0
	var b := MaterialDef.new()
	b.key = &"other"
	b.id = 0
	var db := MaterialDB.new()
	check(db.register_all([a, b]).contains("Duplicate material id"), "duplicate id error")


func test_unknown_references_are_rejected() -> void:
	var a := MaterialDef.new()
	a.key = &"air"
	a.id = 0
	a.burns_to = &"nope"
	var db := MaterialDB.new()
	check(db.register_all([a]).contains("unknown material"), "bad reference error")
