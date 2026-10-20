class_name Market
extends RefCounted
## The grid market (design doc §10): the price paid for exported energy follows a duck curve
## over the day, cheap at midday when every roof makes solar power and dear in the evening
## peak. Energy is counted in real time: a game day (SimConst.DAY_LENGTH_S) stands for 24 h,
## so a watt for one game second earns what a watt earns in REAL_S_PER_GAME_S seconds.

const REAL_S_PER_GAME_S := 86400.0 / SimConst.DAY_LENGTH_S
const J_PER_KWH := 3.6e6
## Price per kWh through the day: [hour, $/kWh], linear between, wrapping at 24 h.
const DUCK_CURVE := [
	[0.0, 0.10], [5.0, 0.09], [7.0, 0.14], [9.0, 0.08], [12.0, 0.03], [15.0, 0.05],
	[17.0, 0.20], [19.0, 0.35], [21.0, 0.22], [24.0, 0.10],
]


## Price paid now for exported energy, $/kWh.
static func price_per_kwh(world: SimWorld) -> float:
	return price_at_hour(world.time_of_day() * 24.0)


## Price at an hour of the day (any real number of hours; wraps at 24), $/kWh.
static func price_at_hour(hours: float) -> float:
	var hour := fposmod(hours, 24.0)
	for k in range(1, DUCK_CURVE.size()):
		var b: Array = DUCK_CURVE[k]
		if hour <= b[0]:
			var a: Array = DUCK_CURVE[k - 1]
			return lerpf(a[1], b[1], (hour - a[0]) / (b[0] - a[0]))
	return DUCK_CURVE[0][1]


## Money earned by exporting `watts` for `dt` game seconds at the current price, $.
static func earnings(world: SimWorld, watts: float, dt: float) -> float:
	return watts * dt * REAL_S_PER_GAME_S / J_PER_KWH * price_per_kwh(world)
