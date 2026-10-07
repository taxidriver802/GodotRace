# Track collision notes (raycast car)

Logged while testing the new raycast car (`res://car/raycast_car.tscn`), for the
later track-collision cleanup pass. Track pieces (`res://pieces/*`) were NOT
changed in this pass.

## Method

- "Seam event" = any wheel's suspension compression changing by more than
  1-1.2 cm in a single physics tick, or a wheel losing contact, while driving.
- Straights: `level_3`, full throttle (~42-45 m/s) across the 11 straight-to-
  straight joins on the opening run.
- Turns: `track_demo`, a center-line-following autopilot at 22-25 m/s, two
  passes covering all 4 straights, all 4 `track_turn_90_left` pieces and all 8
  joins.
- Ramps / gaps: test pieces built at runtime in `car_test` (straight 120 ->
  ramp +4 m over 30 -> gap 12 -> straight 40 -> gap -5 m over 6 -> straight).

## Findings

| Piece / place | Location | Symptom | Suspected cause | Status |
|---|---|---|---|---|
| `level_3` StartLine on first `TrackPiece` | 4 m into the first piece (the start of the whole track) | After GO the car tipped backward off the start of the track and fell (~18 m drop). | Car spawns `start_offset` (3 m) behind the gate, so its rear wheels (1.3 m behind center) sat ~0.3 m past the back edge of the first piece. The old box-collider car rested on its body; the raycast car only stands where its rays hit road. | Worked around: StartLine `distance` set to 8 m in `level_3`. General fix to consider: a start piece with run-off behind the line, or RaceManager checking there is road under all four wheels. |
| `level_3` TrackPiece11 | 400-440 m along the track | No symptom. `rise = 4.0` is set but the piece is a STRAIGHT, so the rise is ignored. | Possibly meant to be a RAMP. | Not changed (level design question). |
| `level_3` TrackPiece12 (GAP, rise -17.5) | 440-480 m | Clears the gap and lands fine at ~150 km/h, but pitches ~52 deg nose-down in the air. | Front wheels leave the edge before the rears, so the rear suspension tips the nose down. Physically correct; steep on a big drop. | Not a collision bug. Options: a short down-ramp before big drops, or more air pitch control. |
| Straight -> straight joins (`track_piece.tscn`) | `level_3`, 11 joins | None at ~45 m/s. | - | OK |
| Straight <-> `track_turn_90_left` joins | `track_demo`, 8 joins | None at 22-25 m/s. | - | OK |
| RAMP (+4 m / 30 m) -> GAP -> straight | runtime test in `car_test` | None. Launches at the crest, lands on all four, settles in ~0.2 s. | - | OK |
| GAP (-5 m drop) | runtime test in `car_test` | None. Nose dips ~20 deg, lands front-first, settles. | - | OK |

## Not yet covered

- `track_turn_45_*` and `track_turn_90_wide_*` pieces.
- Turns at the grip limit for long stretches, or with the handbrake.
- RAMP down pieces (negative rise) at full speed in a real level.
- Full laps of `level_1` and `level_2` (only the start gate and checkpoints in
  `level_1` were tested).
- Barrier hits: the car body slides on walls (body friction 0.05), but
  glancing hits at speed haven't been checked at every piece type.
