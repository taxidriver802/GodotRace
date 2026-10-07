Milestones

Each step is small and tested in car_test before moving on, the same way as today.

1. Telemetry first. Add RPM, gear, drive force and drag to the debug view (key 2). Nothing about how the car drives changes yet.
2. Aero drag. Add a drag force on the body (0.5 × ρ × Cd × A × v²) and tune it so top speed stays about the same as now. Test: same top speed, and coasting from speed feels heavier.
3. Engine with one fixed gear. Replace engine_accel and accel_curve with the torque curve plus idle/clutch, using a single ratio. Test: it launches, pulls, and tops out at redline.
4. Gearbox, automatic only.
	* Add the ratios and the upshift/downshift points with the gap and cooldown.
	* When pressing brake at a standstill, select reverse, so reverse works the same as now.
	* Test: gears climb cleanly with no back-and-forth, and top speed is now set by drag in top gear.
5. Shift feel. Add the torque cut during the shift time, and engine braking when you lift off the throttle. Test: the nose pitches on shifts and the car slows more in low gears.
6. Manual mode and the toggle. Add the shift_up/shift_down/toggle_transmission actions and the settings autoload. Test: you can switch modes mid-drive, a bad downshift is blocked, and the rev limiter hits if you hold a gear.
7. HUD and audio. Add a tachometer and gear readout to the speedometer, then engine sound with its pitch following RPM.
8. Tuning pass. Save presets for arcade and sim. I'd do this when the HUD exists, so you can see what you're tuning.

---

## Status (all 8 done, tested in car_test and level_1)

Results with the default (arcade) setup: 0-100 km/h 2.73 s, shifts at 78 / 104 / 131 km/h,
top speed ~183 km/h in 5th, set by drag (drive force = drag at ~6,760 rpm, under redline).

1. Telemetry: debug line 2 shows gear, rpm, drive N, drag N.
2. Drag: `drag_coefficient` / `frontal_area` / `air_density` on the Car (Aero group). Also
   found and removed Godot's hidden default linear damping (it was acting as invisible drag).
3. Engine: `car/car_engine.gd` (CarEngine, node "Engine"): torque curve, idle, launch clutch
   slip, rev limiter.
4. Gearbox: `car/gearbox.gd` (Gearbox, node "Gearbox"): 5 ratios, final drive, auto up/down
   points with gap + cooldown. Reverse = brake at a standstill (both modes); W returns to 1st.
5. Shift feel: `shift_time` (0.2 s) clutch-out with rev matching; nose dips ~0.6° on shifts.
   Engine braking (`engine_braking`, 110 N·m): ~10 km/h/s lost in 2nd vs ~7 in 5th at 80.
6. Manual: E up, Q down, G toggles. Setting lives in the GameSettings autoload
   (`game_settings.gd`), saved to user://settings.cfg. Downshifts that would over-rev are
   refused (gear box flashes red). Respawns/resets put the car back in 1st at idle.
7. HUD: rev ring (orange near the shift point, red at it), gear box, AUTO/MANUAL label.
   Engine sound: `car/engine_sound.gd`, generated in code (no audio file), pitch follows rpm,
   pauses with the game.
8. Presets: `car/car_tuning.gd` (CarTuning) + `car/presets/arcade.tres` and `sim.tres`.
   Drop one into the Car's `tuning` slot; empty = use the node values.
   Sim: 6 gears, 0.35 s shifts, less grip, more engine braking, 0-100 ~3.0 s.

### Not done yet / ideas
- The main menu Settings button is still a placeholder; GameSettings is ready for a
  Transmission toggle there (and key remapping later).
- Engine sound is a synth placeholder; swap in a recorded loop + pitch_scale later.
- No wheelspin rpm flare (wheels have no spin state of their own), no stalling.
