@tool
class_name TrackChain
extends Node3D
## Lays its TrackPiece children end to end, in tree order: each piece's entry
## is snapped to the previous piece's exit. To build a track, add pieces as
## children of this node one after another; reorder them in the Scene dock to
## change the layout. Editing a piece (length, angle, radius...) re-flows the
## rest of the track.
##
## Turn "Auto Layout" off if you'd rather position pieces by hand. The button
## below lays everything out once on demand either way.

@export var auto_layout := true:
	set(value):
		auto_layout = value
		_queue_layout()

@export_tool_button("Re-layout now") var relayout_button := layout

var _layout_queued := false


func _ready() -> void:
	child_entered_tree.connect(_on_child_entered)
	child_order_changed.connect(_queue_layout)
	for child in get_children():
		_on_child_entered(child)
	if auto_layout:
		layout()


## Snaps every TrackPiece child to the end of the one before it.
func layout() -> void:
	_layout_queued = false
	var t := Transform3D.IDENTITY
	for child in get_children():
		var piece := child as TrackPiece
		if piece == null:
			continue
		piece.transform = t
		t = t * piece.get_exit_transform()


func _on_child_entered(node: Node) -> void:
	var piece := node as TrackPiece
	if piece != null and not piece.shape_changed.is_connected(_queue_layout):
		piece.shape_changed.connect(_queue_layout)
	_queue_layout()


func _queue_layout() -> void:
	if not auto_layout or _layout_queued or not is_inside_tree():
		return
	_layout_queued = true
	layout.call_deferred()
