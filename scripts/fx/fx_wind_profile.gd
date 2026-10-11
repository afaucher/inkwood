extends RefCounted

# THE WIND BY HEIGHT, as the smoke needs it (decision wind-with-height, 2026-10-11: "The wind should pick up as the smoke rises"). A Wind
# (scripts/sim/wind.gd) gives the air's velocity near the ground, at(game_s); its height_factor(height_m) multiplies that by 1.0 at 10 m, about
# 1.6 at 100 m, about 2 at 300 m, flat above about 500 m. A puff that rises through the air drifts by the wind at its CURRENT height, so its
# horizontal position is the integral of the factor over its climb:
#
#   drift(age) = at(birth) x D(age),   D(age) = integral of height_factor(h(tau)) d tau, tau from 0 to age,   h(tau) = the puff's height then
#
# This file tabulates the factor (every STEP_M up to TOP_M, from the wind's own height_factor) and its running integral over height, so a puff
# of any height and constant rise gets D in a few lookups: D = (F(h0 + rise x age) - F(h0)) / rise, F the integral of the factor over height,
# and f(h0) x age for a puff that does not rise (a plane's trail at its altitude). A rise that slows (the fire's) is integrated over time into a
# table by the caller (drift_table). A wind with no height_factor is the same wind at every height: the factor is 1 and D is the age, so
# a Wind without the method, or no wind at all, drifts exactly as before.
#
#   var prof := FxWindProfile.from_wind(wind)       # null: the flat profile
#   prof.factor(height_m), prof.cum(height_m), prof.integral(h0, rise_mps, age)

const STEP_M := 5.0
const TOP_M := 600.0
const N := 121    # TOP_M / STEP_M + 1

var flat := true
var _f := PackedFloat64Array()   # the factor at h = i x STEP_M
var _cum := PackedFloat64Array() # the integral of the factor over height from 0 to i x STEP_M (trapezoids)

static func from_wind(w: Object) -> RefCounted:
	var p: RefCounted = load("res://scripts/fx/fx_wind_profile.gd").new()
	p.build(w)
	return p

func build(w: Object) -> void:
	_f = PackedFloat64Array()
	_cum = PackedFloat64Array()
	_f.resize(N)
	_cum.resize(N)
	flat = true
	var has := w != null and w.has_method("height_factor")
	for i in N:
		var f := 1.0
		if has:
			f = float(w.call("height_factor", float(i) * STEP_M))
			if absf(f - 1.0) > 1e-9:
				flat = false
		_f[i] = f
	_cum[0] = 0.0
	for i in range(1, N):
		_cum[i] = _cum[i - 1] + 0.5 * (_f[i - 1] + _f[i]) * STEP_M

# The wind's factor at a height above the ground (m); clamped to the table.
func factor(h: float) -> float:
	var x := clampf(h, 0.0, TOP_M) / STEP_M
	var i := mini(int(x), N - 2)
	return lerpf(_f[i], _f[i + 1], x - float(i))

# The integral of the factor over height from 0 to h (m x factor); above the table the last factor goes on.
func cum(h: float) -> float:
	if h >= TOP_M:
		return _cum[N - 1] + _f[N - 1] * (h - TOP_M)
	var hh := maxf(h, 0.0)
	var x := hh / STEP_M
	var i := mini(int(x), N - 2)
	var fr := x - float(i)
	# trapezoid inside the cell: the factor rises linearly across it
	var f0: float = _f[i]
	var f1: float = _f[i + 1]
	var d := fr * STEP_M
	return _cum[i] + f0 * d + 0.5 * (f1 - f0) * d * fr

# D(age) for a puff at height h0 (m above the ground) rising at a constant rise_mps: the seconds-of-wind it has drifted by (the age, in a wind that
# does not change with height).
func integral(h0: float, rise_mps: float, age: float) -> float:
	if flat:
		return age
	if absf(rise_mps) < 1e-6:
		return factor(h0) * age
	return (cum(h0 + rise_mps * age) - cum(h0)) / rise_mps

# D at every `step` seconds of age for a puff born at h0 whose rise starts at rise_mps and slows with the time constant tau_s: h(tau) = h0 +
# rise_mps x tau_s x (1 - e^(-tau / tau_s)) (tau_s <= 0: a constant rise). Index i is the age i x step; `n` entries.
func drift_table(h0: float, rise_mps: float, tau_s: float, step: float, n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	out[0] = 0.0
	var prev_f := factor(h0)
	for i in range(1, n):
		var a := float(i) * step
		var h := h0 + (rise_mps * a if tau_s <= 0.0 else rise_mps * tau_s * (1.0 - exp(-a / tau_s)))
		var f := factor(h)
		out[i] = out[i - 1] + 0.5 * (prev_f + f) * step
		prev_f = f
	return out

# The height (m above the ground) a fire puff of age `a` has reached: the same profile as drift_table's.
static func height_at(h0: float, rise_mps: float, tau_s: float, a: float) -> float:
	return h0 + (rise_mps * a if tau_s <= 0.0 else rise_mps * tau_s * (1.0 - exp(-a / tau_s)))
