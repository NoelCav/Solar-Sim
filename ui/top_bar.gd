class_name TopBar
extends PanelContainer
## The strip along the top of the screen: the clock and sky on the left; pause, speed and
## time jumps; money, what the site is selling and the grid price on the right; then the
## view and wavelength. Actions go to Main.

const JUMPS := [[-6.0, "−6 h  (Shift+,)"], [-1.0, "−1 h  (,)"], [-0.5, "−30 min"], [0.5, "+30 min"],
	[1.0, "+1 h  (.)"], [6.0, "+6 h  (Shift+.)"]]

var world: SimWorld
var runner: Main

var _power: PowerSystem
var _clock: Label
var _sky: Label
var _pause: Button
var _speeds: Array[Button] = []
var _money: Label
var _selling: Label
var _price: Label
var _views: Array[Button] = []
var _wave: OptionButton


func setup(p_world: SimWorld, p_runner: Main) -> void:
	world = p_world
	runner = p_runner
	_power = world.get_system(&"power")
	add_theme_stylebox_override(&"panel", UiStyle.box(UiStyle.PANEL_BG, 0, 8, UiStyle.PANEL_EDGE))
	mouse_filter = Control.MOUSE_FILTER_STOP
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
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
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


func update() -> void:
	var tod := world.time_of_day() * 24.0
	_clock.text = "Day %d · %02d:%02d" % [world.day_number() + 1, int(tod), int(fmod(tod, 1.0) * 60.0)]
	var air := "air %.1f °C" % SimConst.k_to_c(world.ambient_k)
	if world.sun_is_up:
		_sky.text = "Sun %.0f° · %.0f W/m² · %s" % [rad_to_deg(world.sun_elevation), world.sun_dni, air]
	elif world.moon_is_up:
		_sky.text = "Moon %.0f° · %.0f%% lit · %s" % [rad_to_deg(world.moon_elevation),
			world.moon_illuminated * 100.0, air]
	else:
		_sky.text = "Night · moon set · %s" % air
	_pause.text = "Play" if runner.paused else "Pause"
	for k in _speeds.size():
		_speeds[k].set_pressed_no_signal(not runner.paused and Main.SPEEDS[k] == runner.speed)
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
	var group := ButtonGroup.new()
	for n in Main.SPEEDS:
		var b := UiStyle.toggle("%d×" % n, "Run at %d× speed (Tab cycles)" % n, runner.set_speed.bind(n), group)
		b.custom_minimum_size.x = 38
		row.add_child(b)
		_speeds.append(b)
	var jump := MenuButton.new()
	jump.text = "Jump time ▾"
	jump.flat = false
	jump.focus_mode = Control.FOCUS_NONE
	jump.tooltip_text = "Move the clock (and the sun) without simulating the time between"
	for k in JUMPS.size():
		jump.get_popup().add_item(JUMPS[k][1], k)
	jump.get_popup().id_pressed.connect(func(id: int) -> void: runner.skip_hours(JUMPS[id][0]))
	row.add_child(jump)
	return row


func _view_controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 4)
	var group := ButtonGroup.new()
	for v in ViewMode.COUNT:
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
