class_name PhysicsLayers
## Named 3D physics layers, as bit values for collision_layer / collision_mask.
## The names also show in Project Settings > Layer Names > 3D Physics.
##
##   1 terrain  ground, decor (trees) and the car itself (gates look for it here)
##   2 road     drivable track surface (TrackPiece)
##   3 wall     invisible track walls (TrackPiece's WallCollider)
##   4 car      the car body
##   5 probe    jump speed probes (later)
##
## Wheels only see terrain + road, so a wheel can never stand on a barrier.

const TERRAIN := 1
const ROAD := 2
const WALL := 4
const CAR := 8
const PROBE := 16

const WHEEL_MASK := TERRAIN | ROAD
const CAR_BODY_MASK := TERRAIN | ROAD | WALL
