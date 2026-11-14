"""Group FIRMS hotspots into individual fire events.

Usage:
    python pipeline/find_fires.py pipeline/raw/firms data/fires

Hotspots from all sensors (MODIS, VIIRS S-NPP, VIIRS NOAA-20) are cleaned exactly like
harmonize.py, snapped to its ~1 km grid (0.01 deg) and reduced to fire cell-days. Two cell-days
belong to the same event if they are within LINK_CELLS grid cells of each other (~2 km) and
within LINK_DAYS days. This space-time flood fill follows the idea of FIRED (Balch et al. 2020),
which links MODIS burned-area pixels the same way; the thresholds here are our own choice for
active-fire points.

Outputs (data/fires/):
    fire_events.csv          one row per event with >= MIN_CELL_DAYS cell-days, largest first
    fire_event_days.csv      per event and day: detections, fire cells, FRP, sensors (for picking
                             sim days and seeding the sim)

All values are observed detections, not burned area. A big event can be several nearby fires
that touched in space and time.
"""
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harmonize import GRID, clean, find, load  # noqa: E402  same cleaning as the calendar

LINK_CELLS = 2      # neighbour radius in grid cells (~2 km)
LINK_DAYS = 3       # max gap in days (clouds, missed overpasses)
MIN_CELL_DAYS = 20  # drop tiny events (agricultural burns, single flares)
CELL_KM2 = 1.0      # 0.01 x 0.01 deg is ~1.1 x 0.9 km in California


def load_points(indir):
    files = {
        ("MODIS", "archive"): "*fire_archive_M-C61_*.csv",
        ("MODIS", "nrt"): "*fire_nrt_M-C61_*.csv",
        ("SNPP", "archive"): "*fire_archive_SV-C2_*.csv",
        ("SNPP", "nrt"): "*fire_nrt_SV-C2_*.csv",
        ("N20", "archive"): "*fire_archive_J1V-C2_*.csv",
        ("N20", "nrt"): "*fire_nrt_J1V-C2_*.csv",
    }
    raw = {k: load(find(indir, pat), *k) for k, pat in files.items()}
    static = set()
    for (_, kind), df in raw.items():
        if kind == "archive":
            st = df[df["type"].isin([1, 2, 3])]
            static.update(zip(st["cx"], st["cy"]))
    parts = []
    for s in ["MODIS", "SNPP", "N20"]:
        a = clean(raw[(s, "archive")], static)[0]
        n = clean(raw[(s, "nrt")], static)[0]
        n = n[n["acq_date"] > a["acq_date"].max()]  # archive wins where they overlap
        parts += [a, n]
    pts = pd.concat(parts, ignore_index=True)
    return pts[["latitude", "longitude", "acq_date", "acq_time", "sensor", "frp", "cx", "cy"]]


def link_cell_days(cd):
    """Union-find over cell-days, processed in date order. Returns an event label per row."""
    parent = np.arange(len(cd))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    last = {}  # (cx, cy) -> (day, node) most recent cell-day seen in that cell
    offsets = [(dx, dy) for dx in range(-LINK_CELLS, LINK_CELLS + 1)
               for dy in range(-LINK_CELLS, LINK_CELLS + 1)]
    for node, (cx, cy, day) in enumerate(zip(cd["cx"].to_numpy(), cd["cy"].to_numpy(), cd["day"].to_numpy())):
        for dx, dy in offsets:
            hit = last.get((cx + dx, cy + dy))
            if hit is not None and day - hit[0] <= LINK_DAYS:
                a, b = root(node), root(hit[1])
                if a != b:
                    parent[a] = b
        last[(cx, cy)] = (day, node)
    return np.array([root(i) for i in range(len(cd))])


def main(indir, outdir):
    os.makedirs(outdir, exist_ok=True)
    pts = load_points(indir)
    pts["day"] = (pts["acq_date"] - pd.Timestamp("2000-01-01")).dt.days

    cd = (pts.groupby(["cx", "cy", "day"])
             .agg(n=("frp", "size"), frp=("frp", "sum"),
                  lat=("latitude", "mean"), lon=("longitude", "mean"),
                  sensors=("sensor", lambda s: "+".join(sorted(set(s)))))
             .reset_index()
             .sort_values(["day", "cx", "cy"], kind="stable")
             .reset_index(drop=True))
    cd["label"] = link_cell_days(cd)

    size = cd.groupby("label").size()
    keep = size[size >= MIN_CELL_DAYS].index
    cd = cd[cd["label"].isin(keep)].copy()
    cd["date"] = pd.Timestamp("2000-01-01") + pd.to_timedelta(cd["day"], unit="D")

    ev = cd.groupby("label").agg(
        start=("date", "min"), end=("date", "max"),
        cell_days=("n", "size"), detections=("n", "sum"), total_frp_mw=("frp", "sum"),
        lat=("lat", "mean"), lon=("lon", "mean"),
        min_lat=("lat", "min"), max_lat=("lat", "max"),
        min_lon=("lon", "min"), max_lon=("lon", "max"))
    ev["footprint_km2"] = cd.drop_duplicates(["label", "cx", "cy"]).groupby("label").size() * CELL_KM2
    daily = cd.groupby(["label", "date"]).agg(
        detections=("n", "sum"), fire_cells=("n", "size"), frp_mw=("frp", "sum"),
        sensors=("sensors", lambda s: "+".join(sorted(set("+".join(s).split("+"))))))
    ev["peak_day"] = daily["fire_cells"].groupby(level=0).idxmax().map(lambda t: t[1])
    ev["duration_days"] = (ev["end"] - ev["start"]).dt.days + 1

    ev = ev.sort_values("footprint_km2", ascending=False)
    ev["event_id"] = [f"CA-{s:%Y%m%d}-{i:04d}" for i, s in enumerate(ev["start"], 1)]
    ids = ev["event_id"]
    daily = daily.reset_index()
    daily["event_id"] = daily["label"].map(ids)

    cols = ["event_id", "start", "end", "duration_days", "peak_day", "footprint_km2", "cell_days",
            "detections", "total_frp_mw", "lat", "lon", "min_lat", "max_lat", "min_lon", "max_lon"]
    out = ev[cols].copy()
    for c in ["start", "end", "peak_day"]:
        out[c] = out[c].dt.strftime("%Y-%m-%d")
    out = out.round({"lat": 4, "lon": 4, "min_lat": 4, "max_lat": 4, "min_lon": 4, "max_lon": 4,
                     "total_frp_mw": 1, "footprint_km2": 1})
    out.to_csv(os.path.join(outdir, "fire_events.csv"), index=False)

    daily["date"] = daily["date"].dt.strftime("%Y-%m-%d")
    daily = daily.round({"frp_mw": 1})
    daily[["event_id", "date", "detections", "fire_cells", "frp_mw", "sensors"]].sort_values(
        ["event_id", "date"]).to_csv(os.path.join(outdir, "fire_event_days.csv"), index=False)

    print(f"{len(pts):,} clean detections -> {len(size):,} raw clusters -> {len(out):,} events "
          f"(>= {MIN_CELL_DAYS} cell-days)")
    return out


if __name__ == "__main__":
    print(main(sys.argv[1], sys.argv[2]).head(15).to_string(index=False))
