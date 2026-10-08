# Track system overhaul: plan

Goal: keep the predefined, configurable pieces, but (a) give the chain real control over
jumps, gaps and elevation, and (b) make the car stop clipping, flipping and slipping out on
sharp turns and landings. Long term the system must also support loops and wall-rides.

This plan follows the same pattern as the gearbox work: each milestone is small, tested in
`car_test` (plus the affected levels), and leaves the game playable.

## Decisions (2026-10-08)
- **Loops and wall-rides: yes, eventually.** Pieces and the car are designed for them from M2 on
  (no "world up" assumptions), and they get their own milestone (M9).
- **Barriers:** the visual look stays the same (1 m striped barrier). Collision is a taller
  invisible wall (about 2.5 m).
- **Jump speed:** measured from a test run (a speed probe on each jump), not typed in by hand.
  A manual override stays available.

---

## Where things stand (read from the code, 2026-10-08)

**Pieces** (`pieces/track_piece.gd`, `TrackPiece extends StaticBody3D`, `@tool`)
- Kinds: STRAIGHT, CURVE, RAMP, GAP. Everything is generated from Inspector properties.
- Centerline is sampled as points + directions. Directions are always horizontal, so a piece
  can only yaw and change height. No pitch at the ends, no banking.
- Exit transform: yaw (curves) or a height offset (ramps/gaps). The ramp uses smoothstep, so it
  always starts and ends flat.
- Mesh and collision come from the same quads. ONE `ConcavePolygonShape3D` per piece holds
  asphalt, paint strips, barrier tops and both barrier faces, with `backface_collision = true`.
- The road is a zero-thickness surface. Barriers are 1.0 m high with a collidable top and no end caps.

**Chain** (`pieces/track_chain.gd`)
- Lays children end to end in tree order: `t = t * piece.get_exit_transform()`.
- That's the only connection rule. There's no offset, no free placement, no branching, and no
  check that a gap lands anywhere sensible.
- GAP just moves the cursor by `length` and `rise`. Where the car actually lands is luck plus tuning.

**Car** (`car/raycast_car.gd`, `raycast_wheel.gd`, `raycast_car.tscn`)
- RigidBody3D, 1000 kg, `gravity_scale` 2, a single box collider (1.9 x 0.9 x 4) for the body,
  four single-ray wheels.
- Wheel rays have the default collision mask, so they hit anything, including barrier tops.
- The spring force clamps at full compression (`spring_length` 0). There's no bump stop, so a
  hard landing ends with the body box slamming into a paper-thin trimesh.
- No anti-roll bar. Physics runs at the default 60 Hz (0.75 m per tick at 45 m/s).
- Gravity comes from the engine (world down). Auto-right uses world up.

**Known issues already logged** (`docs/track_collision_notes.md`)
- Start line too close to the track start (worked around in level_3).
- level_3 TrackPiece11 has `rise` set on a STRAIGHT, so it's ignored.
- A big drop (GAP rise -17.5) pitches the car about 52 deg nose-down.
- Not tested yet: 45 deg and wide turns, the grip limit in long turns, barrier hits at speed.
- New in level_5: TrackPiece16/17 are CURVEs with `rise = -6`, which is also ignored.

## Likely causes of the flips and slip-outs

These are ranked by how likely they are to cause what you're seeing. Milestone 0 confirms them before anything is changed.

1. **Wheel rays hit barrier tops.** In a sharp turn the car rides along the barrier. If a
   ray lands on the 1 m barrier top strip, that wheel's spring compresses by about 1 m in one tick, and
   the spike throws that corner up, so the car rolls over. This is the most likely flip cause in turns.
2. **The body box catches the barrier.** The wall contact is above the center of mass (CoM y 0.3), so
   wall hits roll the car toward the inside. The barrier is only 1 m high and its top is collidable,
   so the box can climb it. Inside-of-turn barriers are convex polylines whose segment
   corners snag the box.
3. **Landings bottom out.** With no bump stop, the suspension runs out and the body box hits a
   zero-thickness, two-sided trimesh at speed. Jolt can resolve that penetration in the wrong
   direction, so the car either pops, gets launched, or sinks through.
4. **Seams and ghost edges.** Each piece is its own StaticBody. Jolt's internal-edge smoothing
   only works inside one body, so the box sliding across a piece joint (and paint/asphalt
   triangle edges, which are also collidable) can hit edges that "shouldn't" be there.
5. **60 Hz is coarse for a raycast car at 45 m/s.** Ray sensing and force response lag on
   fast landings and crests.

---

## Design

### 1. Pieces become "frame" pieces
Every piece describes its centerline as a function:

    frame_at(d) -> Transform3D   # position + full basis (forward, up incl. pitch and bank)
    width_at(d) -> float
    get_path_length() -> float

One generic sweeper builds the road, paint and barriers from those frames for every kind,
so new kinds only implement `frame_at`. `get_exit_transform()` becomes `frame_at(length)`,
and `get_point_transform()` (used by checkpoints and start/finish) becomes `frame_at(d)`. Same API,
so RaceManager and the gates keep working.

Because the frame carries pitch and bank, a piece can now **end pitched or banked**, and the next
piece starts from that frame. This is what makes kickers, landings, slopes and banked
turns possible.

**Loop-ready rule:** frames are built by rotating the piece's own entry frame (pitch about its
right axis, bank about its forward axis, turn about its up axis), never from world angles or
world up. The sweeper only ever uses the frame's own axes. A loop is then just a piece that pitches
360 deg, and a wall-ride is a bank to 90 deg. No special cases, and no gimbal flips at
vertical.

### 2. Piece kinds (existing ones stay, same property names)
| Kind | What it does | New controls |
|---|---|---|
| STRAIGHT | as now | optional `end_pitch` (constant slope) |
| CURVE | as now | `curve_rise` (helix up/down), `bank_degrees` |
| RAMP | smooth height change, flat ends (as now) | none, kept for existing levels |
| SLOPE | pitch transition, e.g. flat to 15 deg up | `start_pitch`, `end_pitch`, length |
| BANK | bank transition, e.g. 0 to 20 deg | `start_bank`, `end_bank` |
| KICKER | launch ramp, ends pitched up (the lip) | `lip_angle`, length |
| LANDING | starts pitched down, eases to flat | `entry_pitch` (auto-set by a jump) |
| GAP / JUMP | no road; moves the cursor | see Jumps below |
| CONNECTOR (later) | curve that meets a target marker | `target: NodePath` |
| LOOP (M9) | full vertical loop with sideways offset so it exits beside its entry | `radius`, `side_shift` |
| WALL_RIDE (M9) | bank-up, ride on the wall, bank-down | `bank`, `side`, length |

Why a new `curve_rise` instead of honoring `rise` on curves: level_5 already has curves with
`rise = -6` set. Honoring it would silently change that level.

### 3. Collision separated from visuals, merged per chain
- Pieces keep generating **visual** meshes (asphalt, paint, striped 1 m barriers) exactly as now.
- The **TrackChain** builds collision after layout by sweeping the whole chain's centerline in
  one go:
  - `TrackRoad` (StaticBody3D, layer **road**): asphalt only, no paint. It gets a real
    thickness (top, sides, underside) and `backface_collision = false`.
  - `TrackWalls` (StaticBody3D, layer **wall**): smooth inner faces only, **invisible and
    about 2.5 m tall** (the visual stays 1 m). No top surface, end caps where a barrier stops.
    Low friction, no bounce.
- One body per chain means no piece-to-piece seams in collision at all. The road is a
  continuous sweep even across joints.
- GAP pieces simply contribute nothing, so a jump is a real hole with clean edges.
- Pieces can switch each wall off (`wall_left` / `wall_right`), which wall-rides and loops need.

### 4. Collision layers
| Layer | Used by |
|---|---|
| 1 terrain | Ground |
| 2 road | TrackRoad |
| 3 wall | TrackWalls |
| 4 car | Car body |
| 5 probe | Jump speed probes (Area3D) |

Wheels get mask = terrain + road, so **wheels can never stand on a barrier**. The car body
mask is terrain + road + wall.

### 5. Chain control
Each piece gets a `connect` mode:
- **SNAP** (default, as now): entry = previous exit.
- **OFFSET**: entry = previous exit plus a small local offset (shift left/right/up, extra
  yaw). Good for lining things up without a custom piece.
- **FREE**: the piece keeps its hand-placed transform and the chain continues from *its*
  exit. Starts a new section mid-chain.

Chain-level additions:
- `start_from: NodePath` lets a chain start at another chain's piece exit (branches, shortcuts).
- The validator (button plus warnings in the Inspector) checks for:
  - position/pitch/bank/width mismatches between pieces
  - turns too tight for a design speed
  - crests sharp enough to unload the car at a design speed (v^2/R > g)
  - a jump arc that misses its landing
  - a start line with less than about 8 m of road behind it
  - for a loop chain, the gap between the last exit and the first entry

### 6. Jumps (speed measured from a test run)
The GAP kind gets a `mode`:
- **MANUAL** (as now, plus `side_offset` and `yaw`): you place the far side.
- **BALLISTIC**: the jump reads the launch frame (the previous piece's exit, e.g. a KICKER's
  lip) and simulates the arc with the car's real gravity (`gravity_scale` 2) and aero drag.
  Then it:
  - places the next piece where the arc comes back down to the target height
    (`land_height`, relative or absolute)
  - sets the following LANDING piece's `entry_pitch` to the arc's descent angle, so the
    car lands parallel to the road, not nose-first into it

**Where the speed comes from:**
- Every BALLISTIC gap puts an invisible **speed probe** (Area3D, layer probe) on the
  launch lip. During a test run it records the car's speed and launch velocity (direction
  included) each time the car passes.
- A test run can be:
  - the M0 autopilot at full throttle (repeatable), or
  - you driving normally with "record jump speeds" switched on.
- Results go to a small per-level data file (`res://levels/<level>_jumps.tres`): min, median and
  max per jump.
- The jump uses the **median** for placement and the min/max for its safe-band preview. A
  `speed_override` (km/h) is there for when you want it.
- **Order matters:** a jump's approach speed depends on everything before it, including earlier
  landings. The tool therefore applies results in chain order and re-runs until nothing moves
  more than 0.5 m (usually one or two runs). It never changes geometry on its own: you press
  **"Apply measured speeds"** on the chain.
- **Editor preview:** arcs for the median plus the measured min/max band, so you can see the window
  where the jump works. Before any run exists, it shows a rough estimate from the car's top
  speed, marked "unmeasured".

### 7. Car-side contact fixes
- **Bump stop:** a strong progressive force over the last 15-20% of travel, so a landing is
  absorbed by the suspension instead of the body.
- **Anti-roll bar:** moves load from the outside to the inside wheel, which cuts roll and the
  lift-and-flip in sharp turns. Tunable, and added to the CarTuning presets.
- **Wheel sensing:** swap the single ray for a sphere `ShapeCast3D` (wheel radius). It rolls over
  lips and gap edges instead of dropping into them, and gives a sensible normal on
  edges. The ray stays available as a fallback flag.
- **Body collider:** replace the box with a rounded/chamfered convex hull, so it slides along
  walls instead of catching on them.
- **Physics at 120 ticks/s** (`physics/common/physics_ticks_per_second`). Forces are already
  delta-based, so tuning shouldn't change, but re-check the presets.
- **Car-owned gravity (loop prep):** the car sets `gravity_scale = 0` and applies its own
  gravity along a `gravity_dir` vector. That is world down by default, so nothing feels
  different yet. Auto-right, downforce, air control and "tipped" checks all use `gravity_dir`
  instead of world up. M9 then only has to change how `gravity_dir` is chosen.

---

## Milestones

0. **Baseline and repro harness.**
   - Make `res://tests/track_drive_test.gd`, an autopilot that follows a chain's centerline at a
     set speed or at full throttle.
   - Log seam events (the same definition as in the collision notes), wheel ray hits on non-road
     surfaces, body contacts with walls, roll angle, and flips.
   - Run it on a turn-and-jump test chain plus levels 1-5.
   - Test: we can reproduce the flips on demand and know which cause above is responsible.
1. **Quick wins (no piece refactor yet).**
   - Put barrier collision on its own StaticBody child with layer **wall**, invisible and 2.5 m
     tall, with no top. Visual barriers are unchanged.
   - Drop paint from collision.
   - Set the layers and masks from section 4, and set the wheel ray mask.
   - Add the bump stop, and raise physics to 120 Hz.
   - Test: re-run M0. Turn flips from wheels on barriers are gone, and landings from the level_3
     drop no longer bottom out.
2. **Frame refactor.**
   - Add `frame_at` / `width_at`, and switch the sweeper to frames that follow the loop-ready rule.
     Old kinds are re-implemented on top.
   - Test: for every piece in all 7 level scenes, the exit transform before vs after differs by less
     than 1 mm, and the levels look identical.
   - Also: a hidden test piece that pitches 360 deg sweeps cleanly, with no twist at vertical.
3. **Merged chain collision.**
   - TrackChain builds TrackRoad (thick, one-sided) and TrackWalls (2.5 m invisible, smooth, end
     caps, per-side on/off) after each layout. Pieces stop owning collision.
   - Test: no seam events across 100+ joints at full speed, and wall slides at 45 deg and 90 deg
     without the car climbing the wall.
4. **New kinds: SLOPE, BANK, curve rise/bank, KICKER, LANDING.**
   - Gallery scene updated with each one.
   - Test: drive each at speed, with no seam events at pitched or banked joints.
5. **Chain control.**
   - Connect modes SNAP/OFFSET/FREE, `start_from` branches, and the validator with Inspector warnings.
   - Test: a branch rejoins the main chain cleanly, and the validator flags the known level
     problems listed above.
6. **Jumps with measured speed.**
   - GAP MANUAL/BALLISTIC, LANDING auto-pitch, speed probes, the per-level jump data file,
     "Apply measured speeds" (chain order, repeat until it settles), and the editor arc preview
     with the measured band.
   - Test: in car_test, build kicker-gap-landing, run the autopilot, apply, and run again. The car
     lands on all four wheels with less than 10 deg pitch at the median speed and still lands at
     the min/max. Two jumps in a row settle within two runs.
7. **Car contact pass 2 (plus gravity prep).**
   - Sphere-cast wheels, the anti-roll bar, the rounded body collider, and car-owned gravity
     (world down by default). Retune the arcade and sim presets.
   - Test: M0 harness clean on all levels, the 0-100 and top speed numbers about the same as in
     GearMilestone, and jumps land the same as before the gravity change.
   - (If M1 already fixes most of the flips, this can move later. If not, it moves up to right after M1.)
8. **Level migration and cleanup.**
   - Run the validator on levels 1-5, track_demo and car_test, and fix what it finds (start run-off,
     level_3 piece 11, level_5 curves 16/17).
   - Record jump speeds for every level, re-shoot the thumbnails, and update the collision notes.
   - Test: full laps of every level with the harness.
9. **Loops and wall-rides.**
   - LOOP and WALL_RIDE kinds.
   - Car: `gravity_dir` follows the road (the average contact normal) while enough wheels are
     grounded and speed is above a threshold, and blends back to world down when it drops or the car
     leaves the road. Trackmania-style.
   - Chase camera rolls with the car on loops. Auto-right is disabled while on a loop or wall.
   - Test: a loop and a wall-ride at the measured speed, with no drop-offs. Below the minimum speed
     the car falls off cleanly rather than glitching.
10. **Later / ideas.**
    - CONNECTOR pieces (auto-fit curve to a target, e.g. closing loops).
    - Width taper, a road surface type (grip multiplier) per piece.
    - Pipes/half-pipes on top of the same frame system.
