"""Fire-activity risk outlook per 25 km cell and month, from historical patterns.

Usage:
    .venv/bin/python pipeline/risk_model.py data/calendar

Reworks the first model.py (random forest on daily FRP for one Los Angeles cell):
- Uses the harmonized monthly 0.25 deg grid (in the repo), and fills cell-months with no
  detections as 0. Missing months (before Nov 2000, the unfinished current month) stay missing,
  never 0.
- Target: "notable burning" = at least NOTABLE harmonized fire cell-days in the cell that month.
  The model gives the probability of that.
- Features use only years BEFORE the target year (no 'year' feature, no peeking): how often the
  cell burned in that month in the past WINDOW years, the same for neighbouring months and
  neighbouring cells, last year's value, the cell's overall activity, plus lat, lon and month.
- Validated on held-out years against a plain climatology baseline (past frequency).
- Writes an outlook for OUTLOOK_YEAR for every cell. It is an outlook from past patterns,
  NOT a forecast of actual fires, and the UI must say so.

Outputs (in the output dir):
    risk_outlook_<year>.json   per cell: 12 monthly probabilities + level; region summary; metadata
    risk_validation.json       held-out scores vs the climatology baseline
"""
import json
import os
import sys

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import brier_score_loss, roc_auc_score

NOTABLE = 10.0          # harmonized fire cell-days in a 25 km cell-month
WINDOW = 10             # past years used for features
MIN_HISTORY = 5         # first target year needs this many past years
TRAIN_YEARS = range(2006, 2019)
TEST_YEARS = range(2019, 2026)
OUTLOOK_YEAR = 2027
LEVELS = [(0.25, "High"), (0.08, "Medium"), (0.0, "Low")]  # probability thresholds
FEATURES = ["freq", "freq_season", "freq_neighbours", "mean_log", "last_year", "cell_activity",
            "lat", "lon", "month_sin", "month_cos"]


def load_panel(path):
    """Cell x year x month array of harmonized fire cell-days; NaN where there is no data."""
    g = pd.read_csv(path)
    g["year"] = g["month"].str[:4].astype(int)
    g["mon"] = g["month"].str[5:7].astype(int)
    cells = g[["lat_center", "lon_center"]].drop_duplicates().sort_values(
        ["lat_center", "lon_center"]).reset_index(drop=True)
    cells["cell"] = np.arange(len(cells))
    g = g.merge(cells, on=["lat_center", "lon_center"])
    years = np.arange(g["year"].min(), OUTLOOK_YEAR + 1)
    a = np.zeros((len(cells), len(years), 12))
    a[g["cell"], g["year"] - years[0], g["mon"] - 1] = g["harmonized_fire_celldays"]
    # Months with no satellite record (or not finished yet) are missing, not zero.
    first = (g["year"].min(), g.loc[g["year"] == g["year"].min(), "mon"].min())
    last = g["month"].max()
    last = (int(last[:4]), int(last[5:7]))
    for yi, y in enumerate(years):
        for m in range(1, 13):
            if (y, m) < first or (y, m) >= last:  # the latest month is unfinished
                a[:, yi, m - 1] = np.nan
    return cells, years, a


def neighbour_index(cells):
    """For each cell, indices of cells within one 0.25 deg step (3x3 block, excluding itself)."""
    key = {(round(la, 3), round(lo, 3)): i for i, la, lo in
           zip(cells["cell"], cells["lat_center"], cells["lon_center"])}
    out = []
    for la, lo in zip(cells["lat_center"], cells["lon_center"]):
        out.append([key[k] for k in ((round(la + dy * 0.25, 3), round(lo + dx * 0.25, 3))
                                     for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx)
                    if k in key])
    return out


def features_for(year, cells, years, a, nbrs):
    """Feature table for every cell and month of `year`, from the WINDOW years before it."""
    yi = int(np.where(years == year)[0][0])
    past = a[:, max(0, yi - WINDOW):yi, :]                  # cell x pastyear x month
    hit = np.where(np.isnan(past), np.nan, (past >= NOTABLE).astype(float))
    with np.errstate(invalid="ignore"):
        freq = np.nanmean(hit, axis=1)                          # cell x month
        mean_log = np.nanmean(np.log1p(past), axis=1)
        season = (np.roll(hit, 1, axis=2) + hit + np.roll(hit, -1, axis=2)) / 3.0
        freq_season = np.nanmean(season, axis=1)
        cell_activity = np.nanmean(np.log1p(past), axis=(1, 2))
    freq_nb = np.array([np.nanmean(freq[nb], axis=0) if nb else np.full(12, np.nan) for nb in nbrs])
    last = np.log1p(a[:, yi - 1, :])
    rows = []
    for m in range(12):
        rows.append(pd.DataFrame({
            "cell": cells["cell"], "year": year, "month": m + 1,
            "freq": freq[:, m], "freq_season": freq_season[:, m], "freq_neighbours": freq_nb[:, m],
            "mean_log": mean_log[:, m], "last_year": last[:, m], "cell_activity": cell_activity,
            "lat": cells["lat_center"], "lon": cells["lon_center"],
            "month_sin": np.sin(2 * np.pi * (m + 1) / 12), "month_cos": np.cos(2 * np.pi * (m + 1) / 12),
            "target": a[:, yi, m] >= NOTABLE if year < OUTLOOK_YEAR else np.nan,
            "observed": a[:, yi, m],
        }))
    df = pd.concat(rows, ignore_index=True)
    df["last_year"] = df["last_year"].fillna(-1.0)  # last year's month not observed yet
    return df


def table(years_range, cells, years, a, nbrs):
    df = pd.concat([features_for(y, cells, years, a, nbrs) for y in years_range], ignore_index=True)
    return df[~np.isnan(df["observed"])].fillna({"freq_neighbours": 0.0})


def make_model():
    return RandomForestClassifier(n_estimators=300, min_samples_leaf=25, max_features=0.5,
                                  random_state=42, n_jobs=-1)


def level(p):
    return next(name for cut, name in LEVELS if p >= cut)


def main(outdir):
    cells, years, a = load_panel(os.path.join(outdir, "harmonized_monthly_grid_0p25deg.csv"))
    nbrs = neighbour_index(cells)

    # ---- validation on held-out years ----
    train = table(TRAIN_YEARS, cells, years, a, nbrs)
    test = table(TEST_YEARS, cells, years, a, nbrs)
    model = make_model().fit(train[FEATURES], train["target"].astype(int))
    p_model = model.predict_proba(test[FEATURES])[:, 1]
    p_clim = test["freq"].to_numpy()
    y = test["target"].astype(int).to_numpy()
    base = float(y.mean())
    bs_model, bs_clim = brier_score_loss(y, p_model), brier_score_loss(y, p_clim)
    by_year = {}
    for yr in TEST_YEARS:
        k = (test["year"] == yr).to_numpy()
        by_year[str(yr)] = {"notable_cell_months": int(y[k].sum()),
                            "expected_by_model": round(float(p_model[k].sum()), 1),
                            "expected_by_climatology": round(float(p_clim[k].sum()), 1)}
    validation = {
        "train_years": f"{TRAIN_YEARS[0]}-{TRAIN_YEARS[-1]}", "test_years": f"{TEST_YEARS[0]}-{TEST_YEARS[-1]}",
        "rows_train": len(train), "rows_test": len(test), "base_rate_test": round(base, 4),
        "brier_model": round(bs_model, 5), "brier_climatology": round(bs_clim, 5),
        "brier_skill_vs_climatology": round(1 - bs_model / bs_clim, 3),
        "auc_model": round(roc_auc_score(y, p_model), 3), "auc_climatology": round(roc_auc_score(y, p_clim), 3),
        "by_year": by_year,
        "feature_importance": dict(sorted(((f, round(float(v), 3)) for f, v in
                                           zip(FEATURES, model.feature_importances_)), key=lambda kv: -kv[1])),
    }

    # ---- final model on all complete years, outlook for OUTLOOK_YEAR ----
    full = table(range(TRAIN_YEARS[0], OUTLOOK_YEAR), cells, years, a, nbrs)
    final = make_model().fit(full[FEATURES], full["target"].astype(int))
    out = features_for(OUTLOOK_YEAR, cells, years, a, nbrs).fillna({"freq_neighbours": 0.0})
    out["p"] = final.predict_proba(out[FEATURES])[:, 1]
    piv = out.pivot(index="cell", columns="month", values="p")
    region = [round(float(piv[m].sum()), 1) for m in range(1, 13)]

    outlook = {
        "label": "Outlook from historical patterns. Not a forecast of actual fires.",
        "year": OUTLOOK_YEAR,
        "definition": (f"Probability that a 0.25 deg cell (~25 km) has notable burning in that month: at least "
                       f"{NOTABLE:g} harmonized fire cell-days (S-NPP scale), based on the {WINDOW} years before "
                       f"{OUTLOOK_YEAR}. Missing months (no satellite record yet) count as missing, not zero."),
        "levels": {name: f"p >= {cut}" for cut, name in LEVELS},
        "model": "RandomForestClassifier (scikit-learn), features from past years only",
        "validation_summary": {k: validation[k] for k in
                               ["test_years", "brier_skill_vs_climatology", "auc_model", "auc_climatology"]},
        "region_expected_notable_cells_by_month": region,
        "cells": [{"lat": float(la), "lon": float(lo),
                   "p": [round(float(v), 3) for v in piv.loc[c]],
                   "level": [level(v) for v in piv.loc[c]]}
                  for c, la, lo in zip(cells["cell"], cells["lat_center"], cells["lon_center"])],
    }
    with open(os.path.join(outdir, f"risk_outlook_{OUTLOOK_YEAR}.json"), "w") as f:
        json.dump(outlook, f, separators=(",", ":"))
    with open(os.path.join(outdir, "risk_validation.json"), "w") as f:
        json.dump(validation, f, indent=1)
    return validation, outlook


if __name__ == "__main__":
    v, o = main(sys.argv[1])
    print(json.dumps({k: v[k] for k in v if k != "feature_importance"}, indent=1))
    print("feature importance:", v["feature_importance"])
    print("region expected notable cells by month:", o["region_expected_notable_cells_by_month"])
    lv = pd.Series([lvl for c in o["cells"] for lvl in c["level"]]).value_counts()
    print("levels over all cell-months:", lv.to_dict())
