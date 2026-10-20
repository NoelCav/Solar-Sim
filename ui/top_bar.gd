class_name TopBar
extends PanelContainer
## The strip along the top of the screen: the clock and sky on the left; pause, speed (− / +
## steps through Main.SPEEDS), time jumps and Set time; money, what the site is selling and
## the grid price on the right; then the view and wavelength, and the Site menu (the player's
## site or a test scenario). Actions go to Main.

## Clock jumps: [hours, label, tooltip]. They move the sun without simulating the time between.
const JUMPS := [[-1.0, "−1 h", "Back an hour (,)"], [0.5, "+30 m", "Forward half an hour"],
	[1.0, "+1 h", "Forward an hour (.)"], [6.0, "+6 h", "Forward six hours (Shift+.)"]]

var world: SimWorld
var runner: Main

var _power: PowerSystem
var _clock: Label
var _sky: Label
var _pause: Button
var _speed: Label
var _set_time: PopupPanel
var _hour: HSlider
var _hour_label: Label
var _money: Label
var _selling: Label
var _price: Label
var _views: Array[Button] = []
var _wave: OptionButton


func setup(p_world: SimWorld, p_runner: Main) -> void:
	world = p_world
	runner = p_runner
	_power = world.get_system(&"power")
	UiStyle.style_panel(self, 0, 8)
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	custom_minimum_size.y = UiStyle.TOP_BAR_H
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	add_child(row)
	var when := VBoxContainer.new()
	when.add_theme_constant_override(&"separation", 0)
	when.custom_minimum_size.x = 210
	row.add_child(when)
	_clock = UiStyle.label("", 15)
	when.add_child(_clock)
	_sky = UiStyle.small_label()
	when.add_child(_sky)
	row.add_child(_time_controls())
	row.add_child(UiStyle.spacer())
	var money := VBoxContainer.new()
	money.add_theme_constant_override(&"separation", 0)
	row.add_child(money)
	_money = UiStyle.label("", 17, UiStyle.ACCENT)
	_money.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	money.add_child(_money)
	_selling = UiStyle.small_label()
	_selling.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	money.add_child(_selling)
	_price = UiStyle.label("", 13, UiStyle.WARM)
	_price.custom_minimum_size.x = 170
	_price.tooltip_text = "What the grid pays for power now; it follows a duck curve: cheap at midday, " \
		+ "dear in the evening"
	_price.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_price)
	row.add_child(VSeparator.new())
	row.add_child(_view_controls())
	row.add_child(_site_menu())


func update() -> void:
	var tod := world.time_of_day() * 24.0
	_clock.text = "Day %d · %s" % [world.day_number() + 1, Readout.clock(tod)]
	var air := "air %.1f °C" % SimConst.k_to_c(world.ambient_k)
	if world.sun_is_up:
		_sky.text = "Sun %.0f° · %.0f W/m² · %s" % [rad_to_deg(world.sun_elevation), world.sun_dni, air]
	elif world.moon_is_up:
		_sky.text = "Moon %.0f° · %.0f%% lit · %s" % [rad_to_deg(world.moon_elevation),
			world.moon_illuminated * 100.0, air]
	else:
		_sky.text = "Night · moon set · %s" % air
	_pause.text = "Play" if runner.paused else "Pause"
	_speed.text = "%d×" % runner.speed
	_speed.modulate.a = 0.45 if runner.paused else 1.0
	_money.text = Readout.money(world.money)
	var selling := 0.0
	_power.sync(world)
	for n in _power.networks.count:
		selling += _power.output_w(world, n)
	_selling.text = "selling %s" % Readout.power(selling) if selling > 0.0 else "selling nothing"
	var now := Market.price_per_kwh(world)
	var soon := Market.price_at_hour(tod + 1.0)
	var trend := "rising" if soon > now * 1.05 else ("falling" if soon < now * 0.95 else "steady")
	_price.text = "%.1f ¢/kWh · %s" % [now * 100.0, trend]


## Highlights the current view and wavelength (after Main changed them).
func refresh_view() -> void:
	for v in _views.size():
		_views[v].set_pressed_no_signal(v == runner.view)
	_wave.select(runner.wavelength + 1)


func _time_controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 4)
	_pause = UiStyle.button("Pause", "Pause or resume (Space)", runner.toggle_pause)
	_pause.custom_minimum_size.x = 64
	row.add_child(_pause)
	row.add_child(UiStyle.button("−", "Slower", _step_speed.bind(-1)))
	_speed = UiStyle.label("1×", 14, UiStyle.ACCENT)
	_speed.custom_minimum_size.x = 34
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed.tooltip_text = "Simulation speed (Tab cycles)"
	_speed.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_speed)
	row.add_child(UiStyle.button("+", "Faster", _step_speed.bind(1)))
	row.add_child(VSeparator.new())
	for j: Array in JUMPS:
		row.add_child(UiStyle.button(j[1], j[2] + ": moves the sun without simulating the time between",
			runner.skip_hours.bind(j[0])))
	var set_button := UiStyle.button("Set time…", "Jump to an hour of the day", _open_set_time)
	row.add_child(set_button)
	_set_time = _set_time_popup()
	add_child(_set_time)
	return row


## One step up or down Main.SPEEDS (and running again if paused).
func _step_speed(step: int) -> void:
	var k := clampi(Main.SPEEDS.find(runner.speed) + step, 0, Main.SPEEDS.size() - 1)
	runner.set_speed(Main.SPEEDS[k])


func _set_time_popup() -> PopupPanel:
	var popup := PopupPanel.new()
	popup.add_theme_stylebox_override(&"panel", UiStyle.box(UiStyle.PANEL_BG, 8, 12, UiStyle.PANEL_EDGE))
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 8)
	popup.add_child(col)
	var head := HBoxContainer.new()
	head.add_child(UiStyle.label("Set time", 14))
	head.add_child(UiStyle.spacer())
	_hour_label = UiStyle.label("", 16, UiStyle.ACCENT)
	head.add_child(_hour_label)
	col.add_child(head)
	_hour = HSlider.new()
	_hour.min_value = 0.0
	_hour.max_value = 23.75
	_hour.step = 0.25
	_hour.custom_minimum_size.x = 260
	_hour.focus_mode = Control.FOCUS_NONE
	_hour.value_changed.connect(func(h: float) -> void: _hour_label.text = Readout.clock(h))
	col.add_child(_hour)
	var ticks := HBoxContainer.new()
	for t: String in ["00:00", "06:00", "12:00", "18:00", "24:00"]:
		var l := UiStyle.small_label(t)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ticks.add_child(l)
	col.add_child(ticks)
	col.add_child(UiStyle.button("Set", "Move the clock to this hour of the day", func() -> void:
		runner.set_hour(_hour.value)
		_set_time.hide()))
	return popup


func _open_set_time() -> void:
	_hour.value = snappedf(world.time_of_day() * 24.0, 0.25)
	_hour_label.text = Readout.clock(_hour.value)
	var at := get_viewport().get_mouse_position()
	_set_time.popup(Rect2i(Vector2i(int(at.x) - 140, int(UiStyle.TOP_BAR_H) + 4), Vector2i.ZERO))


## The site shown: the player's own, or a test scenario (Scenarios; never saved).
func _site_menu() -> MenuButton:
	var menu := MenuButton.new()
	menu.flat = false
	menu.focus_mode = Control.FOCUS_NONE
	menu.text = "Site ▾" if Main.scenario == "" else "Test: %s ▾" % Main.scenario
	menu.tooltip_text = "Your site, or a test scenario (benchmarks and checks use the same ones; never saved)"
	var popup := menu.get_popup()
	popup.add_item("Your site", 0)
	popup.add_separator("Test scenarios")
	var names := Scenarios.names()
	for k in names.size():
		popup.add_item(names[k], k + 1)
		popup.set_item_tooltip(popup.get_item_index(k + 1), Scenarios.LIST[names[k]].about)
	popup.id_pressed.connect(func(id: int) -> void: runner.load_site("" if id == 0 else names[id - 1]))
	return menu


func _view_controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 4)
	var group := ButtonGroup.new()
	for v in ViewMode.NAMES.size():
		var b := UiStyle.toggle(ViewMode.NAMES[v], ViewMode.HINTS[v] + "  (H cycles)", runner.set_view.bind(v), group)
		b.custom_minimum_size.x = 64
		row.add_child(b)
		_views.append(b)
	_wave = OptionButton.new()
	_wave.focus_mode = Control.FOCUS_NONE
	_wave.tooltip_text = "Show one band of the spectrum (G / J)"
	_wave.add_item(ViewMode.wavelength_name(-1), 0)
	for b in Spectrum.BIN_COUNT:
		_wave.add_item(ViewMode.wavelength_name(b), b + 1)
	_wave.item_selected.connect(func(index: int) -> void: runner.set_wavelength(index - 1))
	row.add_child(_wave)
	return row
