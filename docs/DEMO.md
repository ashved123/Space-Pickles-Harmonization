# Presenting Unisim: demo mode

Unisim has a built-in guided demo that follows the team's 4-minute script: a caption bar that walks the
audience through the app, driving the real screens. Every number in the captions is read live from the data
(nothing is typed in), so it always matches what is on screen. The captions are short on-screen cues; the
speakers say the full lines from the script.

## Start it
- On the map, **type `demo`** (click the map first so it has keyboard focus; not while typing in the outlook
  box). **F9** and the **Demo** button under CA do the same. The code is `START_CODE` in `app/demo/demo.gd`.
- Next: **Right arrow** (Page Down and Enter also work, so a clicker's forward button does too).
- Back: **Left arrow** (also Page Up or Backspace).
- While the demo runs the arrow keys belong to it: in the sim they don't turn the wind (use the panel's buttons).
- **A** moves on by itself every 10 s (longer on the zoom, sim and firebreak steps); **A** again stops it.
- Leave: **Esc**. In a browser's fullscreen mode the first Esc leaves fullscreen; press it again to leave the demo.
- The bar shows only the title and caption: no step number, speaker name, buttons or key hints. Learn the
  keys above, and use the table below to know whose turn each step is.
- You can still use the app normally while the demo runs (pan, zoom, click).

## Before you present
1. **Run it once**, start to finish, on the machine and connection you will present on. This fills the
   browser's tile cache and shows right away if a source (NASA, USGS, LANDFIRE, Open-Meteo) is unreachable.
2. The demo needs internet. The sim step fetches the real fuel, terrain and weather live: about 1 s on a good
   connection, about 15 s on a slow one. Wait for the caption's number ("starts from the 1,078 detections").
3. Fullscreen, 16:9 or similar. The layout adapts to any window size.
4. Don't press Next while a step is loading; the press is ignored until it finishes.
5. Have a screen recording of a full run as a backup if the Wi-Fi dies.

## The steps (16, about 4 minutes)
| # | Script section | Screen | Caption cue |
|---|---|---|---|
| 1 | Hook · Speaker 1 | Map, all of 2020, hotspots only | Every red dot is a detection: 489,066 in 2020. You can't compare them. |
| 2 | The problem · Speaker 1 | 9 Sep 2020, satellite colours | MODIS (1 km): 2,649 detections that day. VIIRS (375 m): 30,986. |
| 3 | The problem · Speaker 1 | Slow zoom into the August Complex | Same fire, a handful of MODIS dots, dozens of VIIRS dots. The 2012 jump is the satellites. |
| 4 | Harmonization · Speaker 2 | Map, burning grid on | The fire cell-day; conversion fitted per latitude band, in and out of season. |
| 5 | Harmonization · Speaker 2 | Calendar, harmonized | 25 years on one scale. No jump at 2012. About 12% off in a typical month. Hatched = no record. |
| 6 | Layers · Speaker 3 | Hotspots only | FIRMS detections cleaned to vegetation fires. |
| 7 | Layers · Speaker 3 | Fire outlines only | Detections grouped into fire events. |
| 8 | Layers · Speaker 3 | Burning grid only | The harmonized data per 25 km cell. |
| 9 | Layers · Speaker 3 | Clouds + smoke only | NASA's image for that day (the smoke of 9 Sep 2020). Built in Godot. |
| 10 | Fire sim · Speaker 4 | 8 Nov 2018, slow zoom to Paradise | The Camp Fire. |
| 11 | Fire sim · Speaker 4 | Sim opens and plays | Real fuel, terrain and weather; starts from 1,078 detections. |
| 12 | Fire sim · Speaker 4 | Sim, wind turned 90° | Change the wind, and it runs a different way. |
| 13 | Fire sim · Speaker 4 | Sim, firebreak comparison | +8 h: 78,540 ha without, 59,314 ha with a 24 km firebreak (24% less). Not a prediction; overburns about 3x. |
| 14 | Risk model · Speaker 5 | Map, outlook layer | Random forest on our harmonized data, 707 cells, past years only. |
| 15 | Risk model · Speaker 5 | Outlook for Aug 2027 | 5 cells High, 67 Medium. 0.84 AUC against 0.73 on 2019-2025. Not a forecast. |
| 16 | Close · Speaker 6 | Opening view, wind on | One honest record. Thank you. |

## Where the captions differ from the written script, and why
The captions were checked against the code and data; these lines of the script should change to match:
- **Risk model.** The app's model (`pipeline/risk_model.py`) is a random forest on monthly cell data, using
  how often each cell (and its neighbours) had notable burning in the 10 years before. It does not use
  megawatts or "96,000 daily fire records": those describe the first `model.py`. It outputs a probability
  (High is 25% and up, Medium 8% and up).
- **"Amber is VIIRS"**: VIIRS has two colours, yellow (S-NPP) and aqua (NOAA-20).
- **"Grey means no record"**: no-record cells are dark with diagonal hatching.
- **"Live NASA imagery"**: it is NASA's image for the selected day; today's is not available yet.
- **"0.98 correlation"** is not in the repo's README; the captions quote only the 12% figure that is.
- The "big fire day" is 9 September 2020 (August Complex), which is also the smoke day used for step 9.

## Be upfront about
- The sim is **not calibrated** against real fires: the Camp Fire run burns roughly three times the real area.
  The firebreak step compares two runs of the same model, so the percentage is a relative effect only.
- The outlook exists for 2027 only; every later date gets the same answer.
- Harmonization is validated on California only.

## Changing the story
The steps are plain data at the top of `app/demo/demo.gd` (`STEPS`): a section label, a title, a caption with
`{placeholders}`, and `args` for that screen. Each screen documents its arguments in `demo_apply()`
(`ui/map_view.gd`, `ui/calendar_view.gd`, `main.gd`). To show another fire in the sim, change `CAMP_FIRE` and
the firebreak line `[[244, 16, 357, 129]]` (`[row0, col0, row1, col1]` on the 400 x 400 sim grid; row 0 =
north, col 0 = west). That line was chosen by testing placements in the path of the wind; for another fire,
find one the same way rather than guessing.
