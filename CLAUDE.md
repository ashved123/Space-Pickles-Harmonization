# CLAUDE.md — FireSim (NASA Space Apps 2026)

## What this is
Entry for NASA Space Apps 2026, challenge **"Harmonization of MODIS and VIIRS Hot Spots"** (Nov 14–15, 2026).

Official objective: build a web app that harmonizes MODIS and VIIRS records into a **burning activity calendar** from active-fire hotspots, so emergency responders, scientists and land managers can examine historical fire patterns, unusual conditions and critical periods for a selected area of interest.

Our product, in priority order:
1. **Harmonized burning calendar** (required by the brief, must ship): MODIS (1 km, 2000–) and VIIRS (375 m, 2012–) hotspots on one consistent scale. Area picker, year × day heatmap, flags for anomalies and critical periods.
2. **Fire sim** (what sets us apart): pick a day and place in the calendar to launch a 2D cellular-automaton fire sim, seeded with that day's real hotspots and weather.
3. **Responder what-ifs**: let the fire play out, change the conditions (wind, moisture), or deploy firebreaks and retardant, then compare outcomes.

If time runs short, cut from the bottom. Never ship 2 or 3 without 1.

## Repo layout
```
app/                Godot 4.5+ project (GDScript only, exported to web)
  project.godot
  main.tscn / main.gd      prototype view + input
  sim/fire_sim.gd          fire engine (pure logic, no rendering)
  ui/                      calendar, map view, tool panel
  data/                    loaders for region + calendar files
pipeline/           Python, runs offline, writes static files
  build_region.py          raw data -> region folder for the sim
  harmonize.py             MODIS/VIIRS -> harmonized calendar series
  plots.py                 harmonization diagnostics figure
  check_keys.py            checks the API keys in .env
  raw/                     downloads, git-ignored (raw/firms/ = the 6 FIRMS CSVs)
data/               pipeline output, shipped with the web build
  regions/<id>/            sim inputs (see Data contract)
  calendar/                harmonized daily series
docs/               specs, pitch notes, SOURCES.md
```

## Stack and hard constraints
- **Godot 4.5+, GDScript only.** C# can't export to the web in Godot 4. Don't add C#.
- **Web export: Compatibility renderer, single-threaded (Threads off).** No compute shaders, no threads, no special server headers, so the build runs on GitHub Pages or itch.io.
- **No backend.** Everything heavy is precomputed in `pipeline/` and shipped as static files.
- Python pipeline: `rasterio`, `numpy`, `pyproj`, `geopandas`, `pandas`, `requests`, `pillow`, `matplotlib` (diagnostic plots only).

## Fire sim model (`app/sim/fire_sim.gd`)
- A 2D grid, about 200×200 cells at 150 m. The **sim stays 2D**; only the visuals may be 3D (heightmap terrain, voxel-style columns). Don't make the sim voxel-based.
- Cell states: `NO_FUEL 0`, `UNBURNT 1`, `BURNING 2`, `BURNT 3`.
- Spread rule from Alexandridis et al. (2008): `p_burn = p_h * (1 + p_veg) * (1 + p_den) * p_wind * p_slope * retardant`
  - `p_wind = exp(c1*V) * exp(V*c2*(cos θ - 1))`, θ = angle between the wind's blow-toward direction and the direction of spread
  - `p_slope = exp(a * slope_deg)`, positive when spreading uphill
  - Starting constants: `p_h 0.58, c1 0.045, c2 0.131, a 0.078`. These are tuning targets.
- Each step processes only the burning front (`burning` array). The renderer redraws only `changed` cells.
- **Interventions edit cell data. Don't add new physics for them:** a firebreak sets cells to `NO_FUEL`; retardant multiplies the burn probability in an area (~0.2).
- Wind convention: `wind_to_deg` is the compass direction the wind blows **toward** (0 = N, 90 = E). Weather data reports where wind comes *from*, so convert with `(from + 180) % 360`.
- Performance rules: use typed packed arrays (`PackedByteArray`, `PackedFloat32Array`). Draw the grid as one `Image` → `ImageTexture`. **Never one node per cell.**
- Benchmark: `godot --headless --path app -s bench.gd`. Desktop baseline (Godot 4.5.2, 200×200 test terrain, wind 45° @ 5 m/s, 2026-11-14): ~1.1 ms worst step, ~29 ms per full fire (~147 steps, ~26.6k cells burnt). Recheck in the web build after big engine changes.
- Tests: `godot --headless --path app -s test_fire_sim.gd` (no-fuel, firebreak, wind, slope, retardant, wind-from conversion, seeded repeatability).

## Data contract (pipeline → sim)
Full spec: the "Data → Sim Space Pipeline Spec" doc. Summary:
```
data/regions/<id>/
  meta.json         crs (UTM, e.g. EPSG:32610), origin_x/origin_y (top-left, metres),
                    cell_size_m, rows, cols, bbox_wgs84, layer scales, fuel_classes
  fuel.png          8-bit fuel class index 0–6
  elevation.bin     raw little-endian float32, metres
  slope.png         8-bit degrees
  ndvi.png          8-bit scaled
  background.jpg    NASA Worldview snapshot, reprojected onto the grid
  days/<YYYY-MM-DD>.json   hotspots {row, col, sensor, time_utc, frp, conf} + hourly weather
  validation/<fire>.png    perimeter mask
```
- Grid: row 0 = north edge, col 0 = west edge.
- Fuel classes (FBFM40 code range → index → p_veg): NB 91–99 → 0 → −1.0 · GR 101–109 → 1 → 0.3 · GS 121–124 → 2 → 0.35 · SH 141–149 → 3 → 0.4 · TU 161–165 → 4 → 0.2 · TL 181–189 → 5 → 0.0 · SB 201–204 → 6 → 0.4
- Fuel is categorical: resample with **mode/nearest, never averaging**.
- Seed the sim at each hotspot's **center cell**.

## Data sources
- Keys live in `.env` (template: `.env.example`, git-ignored). Check them with `python pipeline/check_keys.py`. Needed: `FIRMS_MAP_KEY`, `EARTHDATA_TOKEN`; optional: `OPENTOPO_API_KEY`. Everything else is keyless.
- Hotspots (sim day files): NASA FIRMS area API (needs a free MAP_KEY; **never commit the key**, use `.env`).
  - URL: `/api/area/csv/<MAP_KEY>/<SOURCE>/<west,south,east,north>/<1-5 days>/<YYYY-MM-DD>`. Max 5 days per call, 5,000 calls per 10 min.
  - Sources: `MODIS_SP`, `VIIRS_SNPP_SP`, `VIIRS_NOAA20_SP`, `VIIRS_NOAA21_SP` (plus `_NRT` variants for recent days).
- Hotspots (calendar bulk): FIRMS yearly country CSVs, no MAP_KEY needed. Use these for `harmonize.py` instead of thousands of API calls.
  - `https://firms.modaps.eosdis.nasa.gov/data/country/<sensor>/<year>/<sensor>_<year>_<Country>.csv`, or `.../data/country/zips/<sensor>_<year>_all_countries.zip`
  - `<sensor>`: `modis` (2000–), `viirs-snpp` (2012–), `viirs-jpss1` = NOAA-20 (2018–)
- **Sensor timeline (as of 2026-11-14):**
  - Suomi NPP stopped delivering new data on **2026-11-02 15:40 UTC**. The archive stays available, so SNPP is still the 2012–Oct 2026 calibration record. After that, VIIRS comes from NOAA-21 (primary) / NOAA-20 (secondary). Mark the SNPP end on the calendar.
  - MODIS is still running. NASA plans to end science collection on Terra in Feb 2027 and Aqua in Sept 2027. Terra MODIS was in standby 2026-03-26 to 03-27: expect gaps, show them as missing data, not zero fire.
- Fuel: LANDFIRE FBFM40 (US only). Use the version from before the fire.
- Elevation: Copernicus GLO-30 / USGS 3DEP
- NDVI: MODIS MOD13Q1
- Weather: Open-Meteo archive (ERA5), one wind value per hour for the whole region
- Background: NASA Worldview Snapshots
- Validation: CAL FIRE FRAP / NIFC perimeters

## Harmonization (calendar)
- Calibrate on the 2012–present overlap: bin both sensors to the same cells/days and compute a MODIS↔VIIRS conversion factor per area/month. Start simple (a ratio), get fancier only if time allows.
- Validate on held-out years. The key chart: raw counts (with the jump at 2012) vs harmonized (smooth).
- Always label data as **observed**, **harmonized** or **simulated**. Missing data is not zero fire.

## Rules (Space Apps + honesty)
- **Cite every external resource** (data, libraries, assets, papers) in `docs/SOURCES.md`, even free or open-source ones. Teams that don't cite can lose awards.
  - Already used, must go in SOURCES.md: FIRMS (API + country CSVs), NOAA Suomi NPP cessation notice, NASA Suomi NPP transition page, LAADS MODIS→VIIRS transition page, Vadrevu & Lasko 2018 (MODIS vs VIIRS fire counts, PMC6108185).
- The official challenge page (spaceappschallenge.org/2026/challenges/modis-and-viirs-hot-spots/) doesn't pass the TLS check from our dev machines, so read it in a browser. Don't bypass the certificate check.
- **Never copy code from other teams' repos.** Borrow ideas or methods, cite the papers.
- Asset packs: free/CC0 only (Kenney, Quaternius), cited. No custom 3D modelling.
- Don't call sim output a "prediction." It's a **planning/training what-if tool**, validated against past fires where we can.
- Commit history stays honest. Don't backdate or squash to hide when work happened.

## Current status
- [x] Fire engine prototype + top-down view (fake terrain), benchmarked on desktop
- [ ] Web export benchmark in a browser (target < 30 ms/step)
- [ ] Pipeline: first region (Camp Fire, Butte County CA, 2018-11-08)
- [ ] Load real region files in place of `make_test_terrain()`
- [ ] Harmonization + calendar UI
- [ ] Calendar → sim handoff (click a day/place → seeded sim)
- [ ] "Play out" vs actual next-day hotspots / perimeter
- [ ] Monte Carlo risk map (precomputed offline if too slow in the browser)
- [ ] 3D heightmap view (stretch goal)

## Working conventions for Claude
- Keep code simple and direct. Small functions, no clever abstractions.
- `fire_sim.gd` stays free of rendering and node code, so it can be tested headless.
- After engine changes, run `bench.gd` and report step times.
- Ask before adding dependencies or changing the data contract (it's shared with the pipeline owner).
