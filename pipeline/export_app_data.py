"""Pack pipeline outputs into compact JSON for the Godot app.

Usage:
    python pipeline/export_app_data.py data app/datasets

Godot can only load files inside the project (app/), so this copies what the UI needs out of
data/. data/ stays the source of truth; don't edit app/datasets/ by hand, re-run this instead.

Writes:
    calendar.json  months, per-month source/labels, 0.25 deg cells, sparse cell-month values
    fires.json     fire events (observed detections grouped by find_fires.py)
    outlook.json   risk outlook per cell (copied, cells matched to calendar.json order)
"""
import json
import os
import sys

import pandas as pd

# Which months are observed on the reference scale and which are converted to it.
KIND = {
    "VIIRS S-NPP": "observed",
    "MODIS Terra+Aqua (converted)": "harmonized",
    "MODIS Terra (converted)": "harmonized",
    "VIIRS NOAA-20 (scaled to S-NPP)": "harmonized",
}


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
    fires = [{"id": r.event_id, "start": r.start, "end": r.end, "peak": r.peak_day,
              "km2": r.footprint_km2, "det": int(r.detections), "lat": r.lat, "lon": r.lon,
              "bbox": [r.min_lat, r.min_lon, r.max_lat, r.max_lon]} for r in ev.itertuples()]
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
        print(f"{name}: {os.path.getsize(os.path.join(out_dir, name)) // 1024} KB")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
