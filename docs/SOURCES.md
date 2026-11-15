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
- Open-Meteo Historical Weather API. Zippenfenig, P. (2023). Open-Meteo.com Weather API [Computer software]. Zenodo. https://doi.org/10.5281/zenodo.7970649 · data CC BY 4.0, https://open-meteo.com/en/license (**used**: map wind layer, fetched live with `models=era5`; **planned** for sim day files)
- ERA5 reanalysis (behind Open-Meteo archive). Hersbach, H. et al. (2020). The ERA5 global reanalysis. *Q. J. R. Meteorol. Soc.* 146, 1999–2049. https://doi.org/10.1002/qj.3803 · dataset: https://doi.org/10.24381/cds.adbb2d47 (**used**: map wind layer)
- NASA Global Imagery Browse Services (GIBS), NASA ESDIS. Map tiles streamed by the app: MODIS Terra Corrected Reflectance (True Color), daily. https://www.earthdata.nasa.gov/engage/open-data-services-software/earthdata-developer-portal/gibs-api (**used**: "satellite view that day" layer)
  We acknowledge the use of imagery provided by services from NASA's Global Imagery Browse Services (GIBS), part of NASA's Earth Science Data and Information System (ESDIS).
- USGS The National Map base maps (USGSImageryOnly, USGSImageryTopo, USGSTopo tile services), U.S. Geological Survey, public domain. https://basemap.nationalmap.gov/arcgis/rest/services (**used**: map base layers)
  Map services and data available from U.S. Geological Survey, National Geospatial Program.
- US Census Bureau cartographic boundary file `cb_2018_us_state_5m` (public domain). https://www.census.gov/geographies/mapping-files/time-series/geo/carto-boundary-file.html (**used**: California outline, `pipeline/build_boundary.py`)
- NASA Worldview Snapshots (background imagery), NASA ESDIS / GIBS. https://wvs.earthdata.nasa.gov/ (**planned**)

## Validation
- CAL FIRE FRAP fire perimeters. https://www.fire.ca.gov/what-we-do/fire-resource-assessment-program (**planned**)
- NIFC Open Data, historic/interagency fire perimeters. https://data-nifc.opendata.arcgis.com/ (**planned**)

## Papers
- Alexandridis, A., Vakalis, D., Siettos, C. I., & Bafas, G. V. (2008). A cellular automata model for forest fire spread prediction: The case of the wildfire that swept through Spetses Island in 1990. *Applied Mathematics and Computation*, 204(1), 191–201. https://doi.org/10.1016/j.amc.2008.06.046 (**used**: base of the fire spread rule; our changes are in docs/fire_sim_calibration.md)
- Andrews, P. L. (2018). *The Rothermel surface fire spread model and associated developments: A comprehensive explanation*. Gen. Tech. Rep. RMRS-GTR-371. USDA Forest Service, Rocky Mountain Research Station. https://doi.org/10.2737/RMRS-GTR-371 (**used**: fire ellipse length-to-width `1 + 0.25·U` and spread-by-direction equations, sim wind term; moisture damping ηM and heat of preignition 250 + 1116·M, sim moisture term)
- Andrews, P. L. (2012). *Modeling wind adjustment factor and midflame wind speed for Rothermel's surface fire spread model*. Gen. Tech. Rep. RMRS-GTR-266. USDA Forest Service, Rocky Mountain Research Station. https://doi.org/10.2737/RMRS-GTR-266 (**used**: 10 m → 20 ft wind ÷1.15, unsheltered WAF 0.4)
- Cruz, M. G., & Alexander, M. E. (2019). The 10% wind speed rule of thumb for estimating a wildfire's forward rate of spread in forests and shrublands. *Annals of Forest Science*, 76, 44. https://doi.org/10.1007/s13595-019-0829-8 (**used**: sim time scale, head spread ≈ 10% of 10 m wind)
- Scott, J. H., & Burgan, R. E. (2005). *Standard fire behavior fuel models: a comprehensive set for use with Rothermel's surface fire spread model*. Gen. Tech. Rep. RMRS-GTR-153. USDA Forest Service, Rocky Mountain Research Station. https://doi.org/10.2737/RMRS-GTR-153 (**used**: dead fuel moisture of extinction per fuel group, arid-climate models)
- Ottmar, R. D., & Sandberg, D. V. (1985). *Calculating moisture content for 1000-hour timelag fuels in western Washington and western Oregon*. Res. Pap. PNW-336. USDA Forest Service, Pacific Northwest Forest and Range Experiment Station. https://doi.org/10.2737/PNW-RP-336 (**used**: source we read for the Simard (1968) equilibrium moisture content equations 4a–4c)
- Simard, A. J. (1968). *The moisture content of forest fuels – I: A review of the basic concepts*. Inf. Rep. FF-X-14. Forest Fire Research Institute, Ottawa. (**used** via Ottmar & Sandberg 1985; original not consulted)
- Bradshaw, L. S., Deeming, J. E., Burgan, R. E., & Cohen, J. D. (1984). *The 1978 National Fire-Danger Rating System: technical documentation*. Gen. Tech. Rep. INT-169. USDA Forest Service, Intermountain Forest and Range Experiment Station. https://doi.org/10.2737/INT-GTR-169 (**used**: 1-hour fuel moisture ≈ 1.03 × EMC, eq. 26)
- Balch, J. K., St. Denis, L. A., Mahood, A. L., et al. (2020). FIRED (Fire Events Delineation): An open, flexible algorithm and database of US fire events derived from the MODIS burned area product (2001–2019). *Remote Sensing*, 12(21), 3498. https://doi.org/10.3390/rs12213498 (**used**: idea of linking detections in space and time into fire events, `pipeline/find_fires.py`; our thresholds differ)
- Breiman, L. (2001). Random Forests. *Machine Learning*, 45, 5–32. https://doi.org/10.1023/A:1010933404324 (**used**: risk outlook model)
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
  - scikit-learn (BSD-3), **used** by `pipeline/risk_model.py`: https://scikit-learn.org/ · Pedregosa, F., et al. (2011). Scikit-learn: Machine Learning in Python. *Journal of Machine Learning Research*, 12, 2825–2830.

## Assets
- None yet. Only free/CC0 packs (e.g. Kenney, Quaternius), listed here with pack name, URL and license.

## AI assistance
- Claude Code (Anthropic) was used as a coding and research assistant. https://claude.com/claude-code
