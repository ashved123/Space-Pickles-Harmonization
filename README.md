# MODIS + VIIRS active-fire harmonization (California prototype)

Builds one consistent monthly record of burning activity from NASA FIRMS active-fire hotspots,
combining the long MODIS record (Terra + Aqua, Nov 2000 on) with VIIRS (S-NPP from Jan 2012,
NOAA-20 from Apr 2018). Everything is expressed in **VIIRS S-NPP-equivalent units**.

**Status: v2, California only, preliminary.** The method is validated on California; it has not
yet been tested in other regions. See "Known limitations".

## Quick start

```bash
pip install pandas numpy matplotlib
python pipeline/harmonize.py pipeline/raw/firms data/calendar
python pipeline/plots.py data/calendar     # optional diagnostics figure
```

The input folder (`pipeline/raw/firms/`, git-ignored) must contain these six FIRMS files directly, not in subfolders (default FIRMS names, any request-number suffix):

| File pattern | Content |
|---|---|
| `fire_archive_M-C61_*.csv`  | MODIS Terra + Aqua, standard processing |
| `fire_nrt_M-C61_*.csv`      | MODIS near-real-time |
| `fire_archive_SV-C2_*.csv`  | VIIRS S-NPP, standard processing |
| `fire_nrt_SV-C2_*.csv`      | VIIRS S-NPP near-real-time |
| `fire_archive_J1V-C2_*.csv` | VIIRS NOAA-20, standard processing |
| `fire_nrt_J1V-C2_*.csv`     | VIIRS NOAA-20 near-real-time |

## How to download the inputs

FIRMS Archive Download: https://firms.modaps.eosdis.nasa.gov/download/ (free Earthdata login).
Submit one request per sensor, because each satellite has its own valid date range:

| Request | Source | From | To |
|---|---|---|---|
| 1 | MODIS | 2000-11-01 | latest available |
| 2 | VIIRS S-NPP | 2012-01-20 | latest available (data ends 2026-11-02) |
| 3 | VIIRS NOAA-20 | 2018-04-01 | latest available |

Settings used: region = US States -> California, buffer = 0, format = CSV.
Each request returns an `archive` file and an `nrt` file. Keep the region and buffer identical
across all requests. Unzip all six CSVs straight into `pipeline/raw/firms/`.

## Method

1. **Clean.** Keep vegetation fires only (`type == 0`); drop MODIS confidence < 30 and VIIRS
   `l`. NRT files have no `type` column, so NRT detections in ~1 km cells that the archives flag as
   static, volcano or offshore are removed instead.
2. **Common unit: fire cell-days.** Detections are snapped to a 0.01 degree (~1 km) grid and each
   fire-occupied cell counts once per day. This removes most of the 375 m vs 1 km pixel-size
   difference. Summed fire radiative power (FRP) is carried alongside.
3. **Aggregate** by month, by latitude band, and by 0.25 degree cell.
4. **Fit on the overlap** (Feb 2012 - Jul 2026, archive data only). A log-link count model with a
   fire-season term converts MODIS to S-NPP, fitted separately per latitude band:
   `VIIRS = exp(b0 + b1*ln(MODIS) + b2*S + b3*S*ln(MODIS))`, `S = 1` in fire season.
   Fire season (Jun-Nov) is derived from the data.
5. **Splice.** Converted MODIS before Feb 2012; S-NPP from Feb 2012; NOAA-20 (scaled to S-NPP)
   once S-NPP ends. NRT months are flagged `preliminary_nrt`.
6. **Uncertainty** (`low_68`, `high_68`) comes from leave-one-year-out cross-validation.

## Outputs

Written to the output folder (`data/calendar/` in this repo).

| File | Use |
|---|---|
| `harmonized_monthly_region.csv` | Main table: one row per month for the whole region. Harmonized value, FRP, source, preliminary flag, 68% range, raw per-sensor values, anomaly vs 2001-2025 same-month median. |
| `harmonized_monthly_by_band.csv` | Same, per latitude band. Lets you reproduce any month by hand from the coefficients in `diagnostics.json`. |
| `harmonized_monthly_grid_0p25deg.csv` | Monthly values per ~25 km cell, for maps and user-selected areas. Cells sum to the region file. |
| `overlap_validation.csv` | Each overlap month: real VIIRS vs held-out converted MODIS. |
| `diagnostics.json` | Fit coefficients, held-out validation, per-band and small-area checks, NOAA-20 vs S-NPP agreement, seam check. |
| `harmonization_diagnostics.png` | Summary figure. |

Column meanings for `harmonized_monthly_region.csv`:

- `harmonized_fire_celldays`: fire-occupied ~1 km cells summed over the days of the month (S-NPP scale).
- `harmonized_frp_mw`: total fire radiative power in MW (S-NPP scale).
- `source`: sensor the value came from. "(converted)" = MODIS mapped to S-NPP scale.
- `preliminary_nrt`: month includes near-real-time data that may be revised.
- `partial_month`: month not finished; anomaly columns are empty.
- `low_68`, `high_68`: about 2-in-3 range from cross-validation (equals the value for observed VIIRS months).
- `raw_*`: unconverted per-sensor values; blank when the sensor was not operating.
- `baseline_median`, `anomaly_ratio`, `percentile_vs_baseline`: comparison with the same calendar
  month over 2001-2025 (ratio 1.0 = typical; percentile 50 = median).

## Validation summary (California)

Tested on years the model was not fitted on:

| Check | Result |
|---|---|
| Leave-one-year-out, typical monthly error | about 12% |
| Error on the largest 10% of months | about -2% |
| Backcast (fit 2019-26, predict 2012-18), total | within about 2% |
| NOAA-20 vs S-NPP, typical monthly difference | about 4% |
| Latitude-band total bias | -5% to +1% |
| 1-degree boxes, yearly totals / single months | about 21% / 29% typical error |

## Known limitations

- **California only.** The fit and the latitude bands are tuned to California. Other regions need
  their own calibration (and likely their own fire season).
- **Pre-2012 values cannot be checked against VIIRS directly**; the backcast test is a stand-in.
- **Small areas are noisy.** Treat areas much smaller than ~100 km as indicative only.
- **Recent months are provisional** (NRT) and may shift when standard processing replaces them.
- Terra and Aqua have drifted from their original overpass times; the overlap-period ratio looked
  stable, but this is an assumption for the early record.
- Memory: the script loads every CSV into memory. It is fine for a state or the contiguous US; a
  global run needs chunked/tiled processing.

## Data citation

Data: NASA FIRMS (https://earthdata.nasa.gov/firms), part of NASA LANCE. NASA asks that FIRMS
data be acknowledged and cited, and publishes suggested acknowledgment wording and product DOIs at
https://www.earthdata.nasa.gov/learn/find-data/near-real-time/citation. Add that wording and the
DOIs for the MODIS and VIIRS products you use before publishing. The full list we use is in
[`docs/SOURCES.md`](docs/SOURCES.md).
