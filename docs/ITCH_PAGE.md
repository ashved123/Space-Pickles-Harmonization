# Unisim on itch.io: page text and settings

Copy the text below into the itch.io project page. Images are in `build/itch/` (git-ignored; regenerate with
`app/screenshot.gd`, see CLAUDE.md). Upload `build/unisim-web.zip`.

## Page settings
- **Kind of project:** HTML. **Upload:** `unisim-web.zip`, tick "This file will be played in the browser".
- **Project URL:** `unisim`.
- **Embed options:** viewport 1280 x 800 (or bigger), fullscreen button on, mobile friendly off, SharedArrayBuffer off (the build is single-threaded). "Automatically start on page load" is optional.
- **Pricing:** no payments. **Release status:** Released (or In development).
- **Genre:** Simulation. **Tags:** wildfire, nasa, space-apps, satellite, data-visualization, simulation, godot, education.
- **Cover image:** `cover-630x500.png`. **Screenshots:** `screenshot-1-map.png` to `screenshot-4-satellite-colours.png`.
- **Visibility:** Draft first, test from the itch page (the map tiles, and opening the sim from a hotspot), then Public.

## Short description (under 100 characters)
California's fire history from two NASA satellites in one calendar, with a what-if fire sim.

## Description

**Unisim** puts two decades of satellite fire detections on one scale, then lets you play out a fire on the real
terrain.

Built for the NASA Space Apps Challenge 2026, "Harmonization of MODIS and VIIRS Hot Spots".

### What you can do
1. **Explore the map.** Pick a day and see every fire hotspot NASA's satellites detected in California, from
   2000 to now. Turn on "Satellite colours" to see which satellite saw each one, or the wind layer to see that day's
   wind as flowing lines.
2. **Read the burning calendar.** A year-by-month heatmap of burning activity for all of California or any area you
   select. MODIS (1 km pixels, 2000 on) and VIIRS (375 m, 2012 on) are put on one consistent scale, so the jump at
   2012 disappears. Unusual months and gaps in the record are flagged.
3. **Play out a fire.** Click a hotspot and open it in the fire sim. It builds the real area around it (fuel,
   terrain, that day's weather), starts the fire from the day's observed detections, and lets you change the wind and
   humidity, or drop firebreaks and retardant, and watch what changes.
4. **Ask about the season ahead.** Type a year, month or date and get the fire-season outlook for it.

### Please read: what the data is, and isn't
- Everything is labelled **observed**, **harmonized**, **simulated** or **outlook**. A missing month is shown as
  missing, never as zero fire.
- The sim is a **planning and training what-if tool, not a prediction**. Its spread engine is not yet calibrated
  against real fires: in our Camp Fire test it burns about three times the real area.
- The outlook is built from historical patterns for one year (2027), so every later date gets the same answer. It is
  not a forecast of actual fires and it can't foresee extreme years.
- The harmonization is validated on California only.

### Tips
- It needs an internet connection: the map tiles and the sim's fuel, terrain and weather are fetched live.
- The first load downloads about 58 MB. Click the map once to give it keyboard focus, and use the fullscreen button.
- Scroll to zoom, drag to pan. In the sim: scroll to zoom, middle-drag to pan, Space to play.

### Credits and data
- Active-fire data: NASA FIRMS (MODIS Collection 6.1, VIIRS 375 m from Suomi NPP and NOAA-20). We acknowledge the
  use of data and imagery from NASA's Fire Information for Resource Management System (FIRMS), part of NASA's Earth
  Science Data and Information System (ESDIS).
- Satellite imagery and land / water mask: NASA Global Imagery Browse Services (GIBS), part of ESDIS (MODIS Terra
  true colour; the OSM land/water map contains data from OpenStreetMap, © OpenStreetMap contributors, ODbL).
- Base maps: USGS The National Map (public domain). Fuel models: LANDFIRE FBFM40 (USGS / USFS).
- Terrain: Terrain Tiles on AWS (built from USGS 3DEP, SRTM and other open elevation data).
- Weather: Open-Meteo Historical Weather API (CC BY 4.0), ERA5 reanalysis (Hersbach et al. 2020, Copernicus Climate
  Change Service).
- Fire spread model after Alexandridis et al. (2008), with wind, moisture and time-scale changes described in the
  project notes (Andrews 2018, 2012; Cruz & Alexander 2019; Scott & Burgan 2005; Bradshaw et al. 1984).
- Made with the Godot Engine (MIT). Built with help from Claude Code (Anthropic).
- Full list with links and DOIs: `docs/SOURCES.md` in the project repository.
