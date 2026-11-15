"""Pack pipeline outputs into compact JSON for the Godot app.

Usage:
    python pipeline/export_app_data.py data app/datasets

Godot can only load files inside the project (app/), so this copies what the UI needs out of
data/. data/ stays the source of truth; don't edit app/datasets/ by hand, re-run this instead.

Writes:
    calendar.json  months, per-month source/labels, 0.25 deg cells, sparse cell-month values
    fires.json     fire events (observed detections grouped by find_fires.py)
    outlook.json   risk outlook per cell (copied, cells matched to calendar.json order)
    hotspots/<year>.bin   clean hotspots for the map (with --hotspots <raw firms dir>), see HOTSPOT_FORMAT
"""
import json
import os
import sys

import numpy as np
import pandas as pd

# Hotspot files: "HSP1", uint32 count, then per detection (little-endian, 10 bytes):
#   uint16 lat_q, uint16 lon_q, uint16 day_of_year (1-366), uint16 frp_mw (clamped),
#   uint8 sensor (0 MODIS, 1 VIIRS S-NPP, 2 VIIRS NOAA-20), uint8 hour_utc
# lat = LAT0 + lat_q * LAT_SPAN / 65535, lon = LON0 + lon_q * LON_SPAN / 65535 (~20 m steps)
HOTSPOT_FORMAT = {"lat0": 32.0, "lat_span": 10.5, "lon0": -125.0, "lon_span": 11.5}
SENSOR_CODE = {"MODIS": 0, "SNPP": 1, "N20": 2}

# Which months are observed on the reference scale and which are converted to it.
KIND = {
    "VIIRS S-NPP": "observed",
    "MODIS Terra+Aqua (converted)": "harmonized",
    "MODIS Terra (converted)": "harmonized",
    "VIIRS NOAA-20 (scaled to S-NPP)": "harmonized",
}


def export_hotspots(raw_dir, out_dir):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from find_fires import load_points  # same cleaning as the calendar and fire events
    pts = load_points(raw_dir)
    f = HOTSPOT_FORMAT
    hs_dir = os.path.join(out_dir, "hotspots")
    os.makedirs(hs_dir, exist_ok=True)
    rec = np.dtype([("lat", "<u2"), ("lon", "<u2"), ("doy", "<u2"), ("frp", "<u2"),
                    ("sensor", "u1"), ("hour", "u1")])
    years = {}
    for year, g in pts.groupby(pts["acq_date"].dt.year):
        g = g.sort_values(["acq_date", "acq_time"])
        a = np.zeros(len(g), dtype=rec)
        a["lat"] = np.clip(np.round((g["latitude"] - f["lat0"]) / f["lat_span"] * 65535), 0, 65535)
        a["lon"] = np.clip(np.round((g["longitude"] - f["lon0"]) / f["lon_span"] * 65535), 0, 65535)
        a["doy"] = g["acq_date"].dt.dayofyear
        a["frp"] = np.clip(np.round(g["frp"].fillna(0)), 0, 65535)
        a["sensor"] = g["sensor"].map(SENSOR_CODE)
        a["hour"] = g["acq_time"].astype(int) // 100
        with open(os.path.join(hs_dir, f"{year}.bin"), "wb") as fh:
            fh.write(b"HSP1")
            fh.write(np.uint32(len(a)).tobytes())
            fh.write(a.tobytes())
        years[int(year)] = len(a)
    with open(os.path.join(hs_dir, "index.json"), "w") as fh:
        json.dump({"format": f, "sensors": ["MODIS", "VIIRS S-NPP", "VIIRS NOAA-20"],
                   "label": "observed detections (cleaned like the calendar)", "years": years}, fh)
    print(f"hotspots: {sum(years.values()):,} in {len(years)} year files")


def main(data_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    cal = os.path.join(data_dir, "calendar")
    region = pd.read_csv(os.path.join(cal, "harmonized_monthly_region.csv"))
    grid = pd.read_csv(os.path.join(cal, "harmonized_monthly_grid_0p25deg.csv"))

    months = region["month"].tolist()
    m_index = {m: i for i, m in enumerate(months)}
    cells = grid[["lat_center", "lon_center"]].drop_duplicates().sort_values(
        ["lat_center", "lon_center"]).reset_index(drop=True)
    c_index = {(la, lo): i for i, (la, lo) in enumerate(zip(cells.lat_center, cells.lon_center))}

    values = []
    for la, lo, m, v in zip(grid.lat_center, grid.lon_center, grid.month, grid.harmonized_fire_celldays):
        values += [c_index[(la, lo)], m_index[m], round(float(v), 2)]

    calendar = {
        "unit": "fire cell-days (~1 km cells with fire, summed over the month), VIIRS S-NPP scale",
        "first_viirs_month": "2012-02",
        "snpp_end": "2026-11-02",
        "months": months,
        "source": region["source"].tolist(),
        "kind": [KIND[s] for s in region["source"]],
        "preliminary": region["preliminary_nrt"].astype(bool).tolist(),
        "partial": region["partial_month"].astype(bool).tolist(),
        "cells": [[float(la), float(lo)] for la, lo in zip(cells.lat_center, cells.lon_center)],
        "values": values,  # flat triples: cell index, month index, value
    }
    with open(os.path.join(out_dir, "calendar.json"), "w") as f:
        json.dump(calendar, f, separators=(",", ":"))

    ev = pd.read_csv(os.path.join(data_dir, "fires", "fire_events.csv"))
    hull_path = os.path.join(data_dir, "fires", "fire_hulls.json")
    hulls = json.load(open(hull_path)) if os.path.exists(hull_path) else {}
    fires = [{"id": r.event_id, "start": r.start, "end": r.end, "peak": r.peak_day,
              "km2": r.footprint_km2, "det": int(r.detections), "lat": r.lat, "lon": r.lon,
              "bbox": [r.min_lat, r.min_lon, r.max_lat, r.max_lon],
              "hull": hulls.get(r.event_id, [])} for r in ev.itertuples()]
    with open(os.path.join(out_dir, "fires.json"), "w") as f:
        json.dump({"label": "observed detections grouped into events", "events": fires}, f,
                  separators=(",", ":"))

    outlook_path = [p for p in os.listdir(cal) if p.startswith("risk_outlook_")]
    if outlook_path:
        with open(os.path.join(cal, sorted(outlook_path)[-1])) as f:
            o = json.load(f)
        by_cell = {(c["lat"], c["lon"]): c["p"] for c in o["cells"]}
        o["p"] = [by_cell.get((la, lo), [0.0] * 12) for la, lo in calendar["cells"]]
        del o["cells"]
        with open(os.path.join(out_dir, "outlook.json"), "w") as f:
            json.dump(o, f, separators=(",", ":"))

    for name in sorted(os.listdir(out_dir)):
        path = os.path.join(out_dir, name)
        if os.path.isfile(path):
            print(f"{name}: {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
    if "--hotspots" in sys.argv:
        export_hotspots(sys.argv[sys.argv.index("--hotspots") + 1], sys.argv[2])
