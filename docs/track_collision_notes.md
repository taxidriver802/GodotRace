# Track collision notes (raycast car)

## 2026-10-08: TrackMilestone M0 + M1

### Test harness (M0)

`res://tests/track_drive_test.tscn` drives the car by itself along a level's TrackChain
and logs what goes wrong. Pick the level and driving style in `res://tests/tdt_config.json`,
then run the scene (F6 on it, or Run Specific Scene). It prints a `[TDT]` summary to the
Output panel, saves the full report to `user://track_drive_report.json`, and quits.

Config keys:
- `level`: the scene to load.
- `speed_mode`: `limit` (as fast as corners allow) or `fixed` (with `target_kmh`).
- `corner_g`: corner speed budget. 1.0-1.6 is a clean line; 4.0 overcooks every turn into
  the outside wall.
- `line`: `center`, `outside`, `inside`, or a fixed `line_offset`.
- `laps`, `max_time`, `label`, and `recover` (reset the car after a flip or fall).

Test tracks:
- `res://tests/turn_test.tscn`: long straights into tight, medium and hairpin turns.
- `res://tests/stress_track.tscn`: turns, a ramp, a flat 16 m gap (too long to clear without
  a kicker; it's there to test falling in) and an 8 m drop.

What it logs:
- `seam`: the suspension's per-tick movement jumps by more than 12 mm.
- `wheel_off`: a wheel standing on something that isn't road (barrier top, ground beside the track).
- `body_floor` / `body_wall`: the body touching the road or a wall.
- `landing`: pitch and roll vs. the road, impact speed, and whether it bottomed out.
- `flip`, `fell_off`, `stuck`.

The autopilot always uses the automatic gearbox, whatever the saved setting is.

### Baseline (before M1, 60 Hz)

| Run | Result |
|---|---|
| turn_test, clean line 1.6g | Clean. Max roll 3.8 deg. |
| turn_test, overcooked 4g | Car slides into the outside barrier at 117-130 km/h and **climbs it**: wheel rays land on the barrier top (0.4-0.9 m up, at the road edge), suspension jolts up to 9.6 m/s, roll 17.8 deg, 126 seam events. That's cause #1 (wheels on barrier tops) and #2 (body climbs the barrier). |
| stress_track, 8 m drop at 87-99 km/h | Lands nose-first (-25 deg), suspension bottoms out (0.5 m), the body hits the road, and the **rear sinks through it**: wheel rays then hit the ground under the road. That's cause #3. |
| level_5, 1.4g | Max roll 24.8 deg. Landing after the crest at TrackPiece15: roll 23.7 deg, bottomed. Bottoming at the ramp-to-ramp valleys (TrackPiece7, 14). 36 seam events. |

### M1 changes

- `physics_layers.gd` (PhysicsLayers):
  - Named layers: 1 terrain, 2 road, 3 wall, 4 car, 5 probe.
  - The car body is on terrain + car, so gates still detect it. It hits terrain, road and walls.
  - **Wheels only see terrain + road.**
- `track_piece.gd`: collision is now separate from the visuals.
  - Road: solid 1 m slabs (one ConvexPolygonShape3D per segment) on layer road. They extend
    under the barriers.
  - Walls: an internal `WallCollider` StaticBody3D on layer wall. Inner face only, 2.5 m
    tall, no top, friction 0, bounce 0.
  - The visual barriers and paint are unchanged and have no collision.
- `raycast_wheel.gd`: `compression` is no longer capped at full travel, so the bump stop
  can see how far past it the tire went.
- `raycast_car.gd`:
  - Bump stop over the last `bump_zone` (0.12 m) of travel: a progressive spring
    (`bump_stiffness`), plus soaking up a share of the closing speed (`bump_absorb`).
  - Sets its own layers/masks and the wheel masks.
- Physics at **120 ticks/s**.

### After M1 (120 Hz)

| Run | Before | After |
|---|---|---|
| turn_test overcooked 4g | wheel_off 6, roll 17.8 deg, seams 126, body_floor 1 | wheel_off **0**, roll **4.5 deg**, seams 16 (only the wall-impact instants), body_floor **0**. The car now slides along the wall. |
| level_5 1.4g | roll 24.8 deg, crest landing roll 23.7 deg, seams 36 | roll **3.7 deg**, landing roll **3.3 deg** (impact 5.1 vs 8.7 m/s), seams **4** |
| stress 8 m drop | rear sank through the road | No sinking. Still a hard nose-first landing (-21 deg, 16 m/s impact) with the body touching. That's what LANDING pieces (M6) are for. |
| level_3 17.5 m drop at 178 km/h | - | Lands at a 24.5 m/s impact with a body touch, no flip, then drives on. |

Still open (handled by later milestones):
- Two RAMP pieces in a row make a valley where the car scrapes at 110+ km/h (level_5
  TrackPiece7, 14). The smoothstep ramps flatten at both ends. Fix: SLOPE pieces (M4) and the
  validator's crest/valley check (M5).
- Flat gaps need speed or a kicker. The far side's road slab now has a solid 1 m front face,
  so falling short means hitting a cliff, not slipping under a zero-thickness edge.

---

## Earlier notes

Logged while testing the new raycast car (`res://car/raycast_car.tscn`), for the
later track-collision cleanup pass. Track pieces (`res://pieces/*`) were NOT
changed in this pass.

### Method

- "Seam event" = any wheel's suspension compression changing by more than
  1-1.2 cm in a single physics tick, or a wheel losing contact, while driving.
- Straights: `level_3`, full throttle (~42-45 m/s) across the 11 straight-to-
  straight joins on the opening run.
- Turns: `track_demo`, a center-line-following autopilot at 22-25 m/s, two
  passes covering all 4 straights, all 4 `track_turn_90_left` pieces and all 8
  joins.
- Ramps / gaps: test pieces built at runtime in `car_test` (straight 120 ->
  ramp +4 m over 30 -> gap 12 -> straight 40 -> gap -5 m over 6 -> straight).

### Findings

| Piece / place | Location | Symptom | Suspected cause | Status |
|---|---|---|---|---|
| `level_3` StartLine on first `TrackPiece` | 4 m into the first piece (the start of the whole track) | After GO the car tipped backward off the start of the track and fell (~18 m drop). | Car spawns `start_offset` (3 m) behind the gate, so its rear wheels (1.3 m behind center) sat ~0.3 m past the back edge of the first piece. The old box-collider car rested on its body; the raycast car only stands where its rays hit road. | Worked around: StartLine `distance` set to 8 m in `level_3`. General fix to consider: a start piece with run-off behind the line, or RaceManager checking there is road under all four wheels. |
| `level_3` TrackPiece11 | 400-440 m along the track | No symptom. `rise = 4.0` is set but the piece is a STRAIGHT, so the rise is ignored. | Possibly meant to be a RAMP. | Not changed (level design question). |
| `level_3` TrackPiece12 (GAP, rise -17.5) | 440-480 m | Clears the gap and lands fine at ~150 km/h, but pitches ~52 deg nose-down in the air. | Front wheels leave the edge before the rears, so the rear suspension tips the nose down. Physically correct; steep on a big drop. | Not a collision bug. Options: a short down-ramp before big drops, or more air pitch control. |
| Straight -> straight joins (`track_piece.tscn`) | `level_3`, 11 joins | None at ~45 m/s. | - | OK |
| Straight <-> `track_turn_90_left` joins | `track_demo`, 8 joins | None at 22-25 m/s. | - | OK |
| RAMP (+4 m / 30 m) -> GAP -> straight | runtime test in `car_test` | None. Launches at the crest, lands on all four, settles in ~0.2 s. | - | OK |
| GAP (-5 m drop) | runtime test in `car_test` | None. Nose dips ~20 deg, lands front-first, settles. | - | OK |

### Not yet covered

- `track_turn_45_*` and `track_turn_90_wide_*` pieces.
- Turns at the grip limit for long stretches, or with the handbrake.
- RAMP down pieces (negative rise) at full speed in a real level.
- Full laps of `level_1` and `level_2` (only the start gate and checkpoints in
  `level_1` were tested).
- Barrier hits: the car body slides on walls (body friction 0.05), but
  glancing hits at speed haven't been checked at every piece type.
