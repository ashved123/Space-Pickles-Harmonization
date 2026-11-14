# Sources

Every external resource we use: data, papers, libraries, tools, assets.
Space Apps requires this. Add an entry **when you start using something**, not at the end.

Status tags: **used** = already relied on · **planned** = in the design, not pulled yet.
All DOIs below were checked to resolve on 2026-11-14.

## Challenge
- NASA Space Apps Challenge 2026, "Harmonization of MODIS and VIIRS Hot Spots".
  https://www.spaceappschallenge.org/2026/challenges/modis-and-viirs-hot-spots/ (**used**)
  - TODO: copy the challenge's own Resources list here once someone reads the page in a browser.

## Active-fire data (hotspots)
- NASA FIRMS (Fire Information for Resource Management System), LANCE / ESDIS.
  Archive Download tool: https://firms.modaps.eosdis.nasa.gov/download/ (**used**: California inputs for `pipeline/harmonize.py`)
  Area API: https://firms.modaps.eosdis.nasa.gov/api/area/ · yearly country CSVs: https://firms.modaps.eosdis.nasa.gov/country/ (**planned**)
  We acknowledge the use of data and imagery from NASA's Fire Information for Resource Management System (FIRMS),
  part of NASA's Earth Science Data and Information System (ESDIS).
- MODIS Collection 6.1 active fire, standard (MCD14ML): https://doi.org/10.5067/FIRMS/MODIS/MCD14ML (**used**)
- MODIS Collection 6.1 active fire, NRT (MCD14DL): https://doi.org/10.5067/FIRMS/MODIS/MCD14DL.NRT.0061 (**used**)
- VIIRS 375 m active fire, Suomi NPP (VNP14IMG v2): https://doi.org/10.5067/VIIRS/VNP14IMG.002 (**used**)
  NRT: https://doi.org/10.5067/FIRMS/VIIRS/VNP14IMGT_NRT.002 (**used**)
- VIIRS 375 m active fire, NOAA-20 (VJ114IMG v2): https://doi.org/10.5067/VIIRS/VJ114IMG.002 (**used**)
  NRT: https://doi.org/10.5067/FIRMS/VIIRS/VJ114IMGT_NRT.002 (**used**)
- VIIRS 375 m active fire, NOAA-21 (VJ214IMG v2): https://doi.org/10.5067/VIIRS/VJ214IMG.002 (**planned**)
  NRT: https://doi.org/10.5067/VIIRS/VJ214IMG_NRT.002

## Sim inputs
- LANDFIRE FBFM40 (40 Scott & Burgan fire behavior fuel models), USGS / USFS. https://landfire.gov/ (**planned**)
  - TODO: record the exact LANDFIRE version used (must predate the fire, e.g. pre-Nov 2018 for Camp Fire).
- Copernicus DEM GLO-30, ESA. https://doi.org/10.5270/ESA-c5d3d65 (**planned**)
  "Produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved."
- USGS 3D Elevation Program (3DEP), alternative DEM. https://www.usgs.gov/3d-elevation-program (**planned**)
- MODIS MOD13Q1 v6.1 vegetation indices (NDVI), 16-day 250 m. Didan, K. (2021). NASA LP DAAC. https://doi.org/10.5067/MODIS/MOD13Q1.061 (**planned**)
- Open-Meteo Historical Weather API. Zippenfenig, P. (2023). Open-Meteo.com Weather API [Computer software]. Zenodo. https://doi.org/10.5281/zenodo.7970649 · data CC BY 4.0, https://open-meteo.com/en/license (**planned**)
- ERA5 reanalysis (behind Open-Meteo archive). Hersbach, H. et al. (2020). The ERA5 global reanalysis. *Q. J. R. Meteorol. Soc.* 146, 1999–2049. https://doi.org/10.1002/qj.3803 · dataset: https://doi.org/10.24381/cds.adbb2d47 (**planned**)
- NASA Worldview Snapshots (background imagery), NASA ESDIS / GIBS. https://wvs.earthdata.nasa.gov/ (**planned**)

## Validation
- CAL FIRE FRAP fire perimeters. https://www.fire.ca.gov/what-we-do/fire-resource-assessment-program (**planned**)
- NIFC Open Data, historic/interagency fire perimeters. https://data-nifc.opendata.arcgis.com/ (**planned**)

## Papers
- Alexandridis, A., Vakalis, D., Siettos, C. I., & Bafas, G. V. (2008). A cellular automata model for forest fire spread prediction: The case of the wildfire that swept through Spetses Island in 1990. *Applied Mathematics and Computation*, 204(1), 191–201. https://doi.org/10.1016/j.amc.2008.06.046 (**used**: fire spread rule and starting constants)
- Giglio, L., Schroeder, W., & Justice, C. O. (2016). The collection 6 MODIS active fire detection algorithm and fire products. *Remote Sensing of Environment*, 178, 31–41. https://doi.org/10.1016/j.rse.2016.02.054 (**planned**: MODIS product background)
- Schroeder, W., Oliva, P., Giglio, L., & Csiszar, I. A. (2014). The New VIIRS 375 m active fire detection data product: Algorithm description and initial assessment. *Remote Sensing of Environment*, 143, 85–96. https://doi.org/10.1016/j.rse.2013.12.008 (**planned**: VIIRS product background)
- Vadrevu, K., & Lasko, K. (2018). Intercomparison of MODIS AQUA and VIIRS I-Band Fires and Emissions in an Agricultural Landscape—Implications for Air Pollution Research. *Remote Sensing*, 10(7), 978. https://doi.org/10.3390/rs10070978 (**used**: MODIS/VIIRS count ratio, harmonization background)

## Sensor status notices
- NOAA NESDIS (2026-08-03). Cessation of Suomi NPP data to users on/after November 01, 2026. https://www.nesdis.noaa.gov/news/cessation-of-suomi-national-polar-orbiting-partnership-s-npp-data-users-onafter-november-01-2026 (**used**)
- NASA Earthdata, Suomi NPP transition resources. https://www.earthdata.nasa.gov/data/platforms/space-based-platforms/suomi-npp/transition-resources (**used**)
- NASA LAADS DAAC, MODIS to VIIRS transition. https://ladsweb.modaps.eosdis.nasa.gov/learn/modis-to-viirs-transition/ (**used**)
- NASA Earthdata, Transition from MODIS to VIIRS. https://www.earthdata.nasa.gov/data/alerts-outages/transition-from-modis-viirs (**used**)
- NASA Earthdata, Terra MODIS placed in standby mode (2026-03-26). https://www.earthdata.nasa.gov/data/alerts-outages/terra-modis-placed-standby-mode (**used**)

## Software and libraries
- Godot Engine 4.5+, MIT License. https://godotengine.org/ (**planned**)
- Python libraries, pipeline (**used** by `pipeline/harmonize.py` / `plots.py`: NumPy, pandas, Matplotlib; the rest **planned**):
  - Matplotlib (PSF-based Matplotlib License): https://matplotlib.org/
  - rasterio (BSD-3): https://rasterio.readthedocs.io/
  - NumPy (BSD-3): https://numpy.org/
  - pyproj (MIT): https://pyproj4.github.io/pyproj/
  - GeoPandas (BSD-3): https://geopandas.org/
  - pandas (BSD-3): https://pandas.pydata.org/
  - Requests (Apache-2.0): https://requests.readthedocs.io/
  - Pillow (MIT-CMU / HPND): https://python-pillow.org/

## Assets
- None yet. Only free/CC0 packs (e.g. Kenney, Quaternius), listed here with pack name, URL and license.

## AI assistance
- Claude Code (Anthropic) was used as a coding and research assistant. https://claude.com/claude-code
