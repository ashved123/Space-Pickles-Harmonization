## Autoload: carries choices between the calendar and the sim screens.
extends Node

var selection := PackedInt32Array()  # selected calendar cells (empty = all California)
var selected_year := 0
var selected_month := 0
var sim_event := {}                  # fire event picked in the calendar, or empty
var sim_request := {}                # where and when to run the sim: {lat, lon, year, doy, side_m, label}
                                     # (see data/sim_region.gd); empty = use sim_event, or test terrain
var map_state := {}                 # map view, date and filters, restored when coming back
var return_scene := "res://ui/map_view.tscn"  # where Esc in the sim goes
