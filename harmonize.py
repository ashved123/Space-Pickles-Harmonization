"""
MODIS / VIIRS active-fire harmonization pipeline (steps 1-6).

Usage:
    python harmonize.py <input_dir> <output_dir>

Inputs (FIRMS archive + NRT CSVs, one region):
    *fire_archive_M-C61_*.csv   MODIS Terra+Aqua, standard processing
    *fire_nrt_M-C61_*.csv       MODIS NRT
    *fire_archive_SV-C2_*.csv   VIIRS S-NPP, standard processing
    *fire_nrt_SV-C2_*.csv       VIIRS S-NPP NRT
    *fire_archive_J1V-C2_*.csv  VIIRS NOAA-20, standard processing
    *fire_nrt_J1V-C2_*.csv      VIIRS NOAA-20 NRT

Method
    1. Clean: keep vegetation fires (type 0), drop low confidence
       (MODIS < 30, VIIRS 'l'). NRT files have no 'type', so NRT points that
       fall in ~1 km cells flagged as static/offshore (type 2/3) in any archive
       are removed instead.
    2. Common grid: snap every detection to a 0.01 deg (~1 km) grid and count
       unique fire-occupied cells per day ("fire cell-days") per sensor. This
       removes most of the 375 m vs 1 km pixel-size difference.
    3. Aggregate monthly: cell-days and summed FRP per month (region total and
       per 0.25 deg cell).
    4. Fit on the archive overlap (Feb 2012 - Jul 2026):
       log(VIIRS S-NPP) = a + b * log(MODIS), separately for
       MODIS Terra+Aqua combined, Terra only (for the pre-Aqua period),
       and Aqua only (like-for-like afternoon diagnostic).
       Validated by training 2012-2019 and testing 2020-2026.
    5. Express everything in S-NPP-equivalent units.
    6. Splice: MODIS (converted) before Feb 2012, S-NPP from Feb 2012,
       NOAA-20 (scaled to S-NPP) once S-NPP ends; NRT months flagged preliminary.
"""
import glob
import json
import os
import sys

import numpy as np
import pandas as pd

GRID = 0.01      # ~1 km common grid for occupancy counting
MAPGRID = 0.25   # coarse grid for per-cell output
MODIS_MIN_CONF = 30
OVERLAP = ("2012-02", "2026-07")   # full months where MODIS & S-NPP archives overlap
TRAIN_END = "2019-12"


def find(d, pattern):
    hits = glob.glob(os.path.join(d, pattern))
    if len(hits) != 1:
        raise SystemExit(f"expected one file for {pattern}, found {hits}")
    return hits[0]


def load(path, sensor, kind):
    df = pd.read_csv(path)
    df["sensor"] = sensor
    df["kind"] = kind
    df["acq_date"] = pd.to_datetime(df["acq_date"])
    df["satellite"] = df["satellite"].replace({"Terra": "Terra", "Aqua": "Aqua", "SNPP": "SNPP", "N20": "N20"})
    df["instrument"] = "MODIS" if sensor == "MODIS" else "VIIRS"
    df["cx"] = np.floor(df["longitude"] / GRID).astype(int)
    df["cy"] = np.floor(df["latitude"] / GRID).astype(int)
    return df


def clean(df, static_cells):
    n0 = len(df)
    if df["sensor"].iat[0] == "MODIS":
        df = df[df["confidence"].astype(float) >= MODIS_MIN_CONF]
    else:
        df = df[df["confidence"].astype(str).str.lower().isin(["n", "h", "nominal", "high"])]
    if "type" in df.columns:
        df = df[df["type"] == 0]
    else:
        key = list(zip(df["cx"], df["cy"]))
        df = df[[k not in static_cells for k in key]]
    return df, n0, len(df)


def cell_days(df, by_sat=False):
    """Unique fire-occupied ~1 km cells per day (optionally per satellite)."""
    keys = ["acq_date", "cx", "cy"] + (["satellite"] if by_sat else [])
    u = df.drop_duplicates(keys)
    return u


def monthly(df, group_extra=()):
    m = df.assign(month=df["acq_date"].dt.to_period("M"))
    return m.groupby(["month", *group_extra])


def fit_loglog(x, y):
    lx, ly = np.log(x), np.log(y)
    b, a = np.polyfit(lx, ly, 1)
    resid = ly - (a + b * lx)
    return {"a": float(a), "b": float(b), "sigma": float(resid.std(ddof=2)),
            "r2": float(1 - resid.var() / ly.var()), "n": int(len(x))}


def predict(fit, x):
    x = np.asarray(x, dtype=float)
    out = np.exp(fit["a"] + fit["b"] * np.log(np.where(x > 0, x, np.nan)))
    out = np.where(x > 0, out, 0.0)
    # smearing correction for log-retransformation bias
    return out * np.exp(fit["sigma"] ** 2 / 2)


def metrics(obs, pred):
    obs, pred = np.asarray(obs, float), np.asarray(pred, float)
    mape = np.median(np.abs(pred - obs) / obs) * 100
    lr = np.log(pred / obs)
    return {"median_abs_pct_error": round(float(mape), 1),
            "log_rmse": round(float(np.sqrt(np.mean(lr ** 2))), 3),
            "corr_log": round(float(np.corrcoef(np.log(obs), np.log(pred))[0, 1]), 3),
            "total_bias_pct": round(float((pred.sum() / obs.sum() - 1) * 100), 1)}


# ---------------------------------------------------------------------------
# Conversion model: log-link count regression with a fire-season term.
#   E[VIIRS] = exp(b0 + b1*log(MODIS) + b2*S + b3*S*log(MODIS)),  S = 1 in fire season
# Fitted by iteratively reweighted least squares (quasi-Poisson), which fits the
# counts on their original scale, so big months are not under-predicted the way a
# log-log least-squares fit is.
# ---------------------------------------------------------------------------
def fire_season_months(snpp_monthly):
    """Data-driven fire season: calendar months whose median activity exceeds the median month."""
    med = snpp_monthly.groupby(snpp_monthly.index.month).median()
    return set(int(m) for m in med[med > med.median()].index)


class SeasonGLM:
    def __init__(self, season):
        self.season = season
        self.band = None

    def _X(self, idx, x):
        lx = np.log(np.asarray(x, float))
        s = np.array([p.month in self.season for p in idx], float)
        return np.column_stack([np.ones(len(lx)), lx, s, s * lx])

    def fit(self, idx, x, y, iters=100):
        X, y = self._X(idx, x), np.asarray(y, float)
        beta = np.linalg.lstsq(X, np.log(y), rcond=None)[0]
        for _ in range(iters):
            mu = np.exp(X @ beta)
            z = X @ beta + (y - mu) / mu
            new = np.linalg.solve(X.T @ (X * mu[:, None]), X.T @ (mu * z))
            if np.max(np.abs(new - beta)) < 1e-10:
                beta = new
                break
            beta = new
        self.beta = beta
        mu = np.exp(X @ beta)
        self.r2_log = float(1 - np.var(np.log(y / mu)) / np.var(np.log(y)))
        self.n = int(len(y))
        return self

    def predict(self, idx, x):
        x = np.asarray(x, float)
        out = np.zeros(len(x))
        pos = x > 0
        if pos.any():
            out[pos] = np.exp(self._X(np.asarray(idx)[pos], x[pos]) @ self.beta)
        return out

    def interval(self, idx):
        s = np.array([p.month in self.season for p in idx])
        lo = np.where(s, self.band["season"][0], self.band["off_season"][0])
        hi = np.where(s, self.band["season"][1], self.band["off_season"][1])
        return lo, hi

    def describe(self):
        b = self.beta
        return {"formula": "VIIRS = exp(b0 + b1*ln(MODIS) + b2*S + b3*S*ln(MODIS)), S=1 in fire season",
                "b0": float(b[0]), "b1": float(b[1]), "b2": float(b[2]), "b3": float(b[3]),
                "r2_log_scale": round(self.r2_log, 3), "n_months": self.n,
                "band_68_log_ratio": self.band and {k: [round(v[0], 3), round(v[1], 3)]
                                                    for k, v in self.band.items() if k != "cv_metrics"}}


def loyo_band(idx, x, y, season):
    """Leave-one-year-out cross-validation: predict each overlap year from a model fitted on
    all other years. The 16th/84th percentiles of log(observed/predicted) give an honest 68%
    band (separately for fire season / off season)."""
    years = np.array([p.year for p in idx])
    pred = np.zeros(len(y))
    for yr in np.unique(years):
        tr = years != yr
        pred[~tr] = SeasonGLM(season).fit(idx[tr], x[tr], y[tr]).predict(idx[~tr], x[~tr])
    lr = np.log(y / pred)
    s = np.array([p.month in season for p in idx])
    band = {"season": (float(np.quantile(lr[s], 0.16)), float(np.quantile(lr[s], 0.84))),
            "off_season": (float(np.quantile(lr[~s], 0.16)), float(np.quantile(lr[~s], 0.84)))}
    band["cv_metrics"] = metrics(y, pred)
    return band


# ---------------------------------------------------------------------------
# Spatially varying calibration: one SeasonGLM per latitude band.
# ---------------------------------------------------------------------------
BAND_DEG = 2.0              # starting band width (degrees latitude)
MIN_BAND_CELLDAYS = 5000    # merge bands with fewer S-NPP fire cell-days than this in the overlap


def band_edges(all_lat, snpp_overlap_lat):
    lo = np.floor(all_lat.min() / BAND_DEG) * BAND_DEG
    hi = np.ceil((all_lat.max() + 1e-9) / BAND_DEG) * BAND_DEG
    edges = list(np.arange(lo, hi + BAND_DEG / 2, BAND_DEG))
    def counts(e):
        return np.histogram(snpp_overlap_lat, bins=e)[0]
    while len(edges) > 2:
        c = counts(edges)
        i = int(np.argmin(c))
        if c[i] >= MIN_BAND_CELLDAYS:
            break
        # merge the smallest band with its smaller neighbour
        if i == 0:
            edges.pop(1)
        elif i == len(c) - 1:
            edges.pop(-2)
        else:
            edges.pop(i if c[i - 1] < c[i + 1] else i + 1)
    return np.array(edges)


def band_labels(edges):
    return [f"{a:g}-{b:g}N" for a, b in zip(edges[:-1], edges[1:])]


def band_of(lat, edges, labels):
    i = np.clip(np.searchsorted(edges, lat, side="right") - 1, 0, len(labels) - 1)
    return np.array(labels)[i]


def band_tables(df, edges, months):
    labels = band_labels(edges)
    u = cell_days(df).copy()
    u["month"] = u.acq_date.dt.to_period("M")
    u["band"] = band_of(u.latitude.values, edges, labels)
    cd = u.groupby(["month", "band"]).size().unstack().reindex(index=months, columns=labels).fillna(0)
    f = df.assign(month=df.acq_date.dt.to_period("M"), band=band_of(df.latitude.values, edges, labels))
    frp = f.groupby(["month", "band"]).frp.sum().unstack().reindex(index=months, columns=labels).fillna(0)
    return {"celldays": cd, "frp": frp}


def grid_counts(df):
    u = cell_days(df).copy()
    u["month"] = u.acq_date.dt.to_period("M")
    u["lon_center"] = np.floor(u.longitude / MAPGRID) * MAPGRID + MAPGRID / 2
    u["lat_center"] = np.floor(u.latitude / MAPGRID) * MAPGRID + MAPGRID / 2
    return u.groupby(["month", "lat_center", "lon_center"]).size().rename("raw_celldays").reset_index()


class BandModel:
    def __init__(self, season):
        self.season = season
        self.models = {}
        self.band = None

    def fit(self, X, Y, train_mask):
        for b in X.columns:
            ok = (train_mask & (X[b] > 0) & (Y[b] > 0)).values
            self.models[b] = SeasonGLM(self.season).fit(X.index[ok], X[b].values[ok], Y[b].values[ok])
        return self

    def predict(self, X):
        return pd.DataFrame({b: self.models[b].predict(X.index, X[b].values) for b in X.columns}, index=X.index)

    def interval(self, idx):
        s = np.array([p.month in self.season for p in idx])
        return (np.where(s, self.band["season"][0], self.band["off_season"][0]),
                np.where(s, self.band["season"][1], self.band["off_season"][1]))

    def describe(self):
        return {"bands": {b: {k: v for k, v in m.describe().items() if k != "band_68_log_ratio"}
                          for b, m in self.models.items()},
                "band_68_log_ratio_regional_total": {k: [round(v[0], 3), round(v[1], 3)]
                                                     for k, v in self.band.items()}}


def loyo_bandmodel(X, Y, in_ov, season):
    """Leave-one-year-out CV of the band models: per-band errors and the error of the summed total."""
    months = X.index
    years = np.array([p.year for p in months])
    pred = pd.DataFrame(np.nan, index=months, columns=X.columns)
    for yr in np.unique(years[in_ov.values]):
        test = in_ov.values & (years == yr)
        m = BandModel(season).fit(X, Y, in_ov & (years != yr))
        pred.loc[test] = m.predict(X.loc[test]).values
    ovm = in_ov.values
    yt, pt = Y.sum(axis=1)[ovm], pred.sum(axis=1)[ovm]
    ok = (yt > 0) & (pt > 0)
    lr = np.log(yt[ok] / pt[ok])
    s = np.array([p.month in season for p in yt[ok].index])
    band = {"season": (float(np.quantile(lr[s], 0.16)), float(np.quantile(lr[s], 0.84))),
            "off_season": (float(np.quantile(lr[~s], 0.16)), float(np.quantile(lr[~s], 0.84)))}
    # per-band: band model vs a single statewide model applied to the band
    tot_ok = ovm & (X.sum(axis=1) > 0).values & (Y.sum(axis=1) > 0).values
    state = SeasonGLM(season).fit(months[tot_ok], X.sum(axis=1).values[tot_ok], Y.sum(axis=1).values[tot_ok])
    per_band = {}
    for b in X.columns:
        okb = ovm & (Y[b] > 0).values & (pred[b] > 0).values
        per_band[f"band {b}"] = {
            "band_model_LOYO": metrics(Y[b].values[okb], pred[b].values[okb]),
            "statewide_model_applied": metrics(Y[b].values[okb], state.predict(months[okb], X[b].values[okb])),
            "months": int(okb.sum())}
    return {"band": band, "metrics": metrics(yt[ok].values, pt[ok].values), "per_band": per_band,
            "pred_total": pred.sum(axis=1, min_count=1)}


def box_check(per_sensor, model, Xband, edges, labels, lo_p, hi_p):
    """1-degree boxes in the overlap: MODIS converted with its band's monthly factor vs S-NPP."""
    def boxes(df):
        u = cell_days(df).copy()
        u["month"] = u.acq_date.dt.to_period("M")
        u = u[(u.month >= lo_p) & (u.month <= hi_p)]
        # box = 1 deg lon x 1 deg lat; band from box latitude
        u["box"] = np.floor(u.latitude).astype(int).astype(str) + "_" + np.floor(u.longitude).astype(int).astype(str)
        u["band"] = band_of(u.latitude.values, edges, labels)
        return u.groupby(["box", "band", "month"]).size()
    j = pd.concat([boxes(per_sensor["MODIS"]).rename("modis"), boxes(per_sensor["SNPP"]).rename("snpp")], axis=1).fillna(0)
    Xo = Xband.loc[lo_p:hi_p]
    fac = (model.predict(Xo) / Xo.where(Xo > 0)).fillna(0).stack()
    fac.index.names = ["month", "band"]
    j = j.reset_index().join(fac.rename("f"), on=["month", "band"])
    j["pred"] = j.modis * j.f
    j["year"] = j.month.apply(lambda p: p.year)
    yearly = j.groupby(["box", "year"])[["snpp", "pred"]].sum()
    ya = yearly[(yearly.snpp >= 20) & (yearly.pred > 0)]
    ma = j[(j.snpp >= 20) & (j.pred > 0)]
    return {"yearly_totals": {**metrics(ya.snpp.values, ya.pred.values), "box_years": int(len(ya))},
            "monthly": {**metrics(ma.snpp.values, ma.pred.values), "box_months": int(len(ma))}}


def main(indir, outdir):
    os.makedirs(outdir, exist_ok=True)
    files = {
        ("MODIS", "archive"): find(indir, "*fire_archive_M-C61_*.csv"),
        ("MODIS", "nrt"): find(indir, "*fire_nrt_M-C61_*.csv"),
        ("SNPP", "archive"): find(indir, "*fire_archive_SV-C2_*.csv"),
        ("SNPP", "nrt"): find(indir, "*fire_nrt_SV-C2_*.csv"),
        ("N20", "archive"): find(indir, "*fire_archive_J1V-C2_*.csv"),
        ("N20", "nrt"): find(indir, "*fire_nrt_J1V-C2_*.csv"),
    }
    raw = {k: load(p, *k) for k, p in files.items()}

    # ---------- Step 1: clean ----------
    static = set()
    for (s, kind), df in raw.items():
        if kind == "archive":
            st = df[df["type"].isin([1, 2, 3])]
            static.update(zip(st["cx"], st["cy"]))
    cleaned, clean_log = {}, {}
    for k, df in raw.items():
        c, n0, n1 = clean(df, static)
        cleaned[k] = c
        clean_log[f"{k[0]}_{k[1]}"] = {"rows_in": n0, "rows_kept": n1,
                                       "first": str(df.acq_date.min().date()),
                                       "last": str(df.acq_date.max().date())}

    # archive wins over NRT if any dates overlap
    per_sensor = {}
    for s in ["MODIS", "SNPP", "N20"]:
        a, n = cleaned[(s, "archive")], cleaned[(s, "nrt")]
        n = n[n["acq_date"] > a["acq_date"].max()]
        per_sensor[s] = pd.concat([a, n], ignore_index=True)
    allpts = pd.concat(per_sensor.values(), ignore_index=True)

    # ---------- Steps 2-3: grid + monthly aggregation ----------
    def monthly_table(df, label):
        cd = cell_days(df)
        g = monthly(cd)
        t = pd.DataFrame({f"{label}_celldays": g.size(),
                          f"{label}_frp": monthly(df).frp.sum()})
        t[f"{label}_prelim"] = monthly(df)["kind"].agg(lambda k: (k == "nrt").any())
        return t

    m = per_sensor["MODIS"]
    tables = [
        monthly_table(m, "modis"),
        monthly_table(m[m.satellite == "Terra"], "terra"),
        monthly_table(m[m.satellite == "Aqua"], "aqua"),
        monthly_table(per_sensor["SNPP"], "snpp"),
        monthly_table(per_sensor["N20"], "n20"),
    ]
    mon = pd.concat(tables, axis=1)
    full_idx = pd.period_range(mon.index.min(), mon.index.max(), freq="M")
    mon = mon.reindex(full_idx)
    for c in mon.columns:
        if c.endswith("_prelim"):
            mon[c] = mon[c].astype("boolean").fillna(False).astype(bool)
    # zero-fill only inside each sensor's coverage window
    cover = {"modis": ("2000-11", None), "terra": ("2000-11", None), "aqua": ("2002-07", None),
             "snpp": ("2012-01", "2026-11"), "n20": ("2018-04", None)}
    for s, (start, end) in cover.items():
        inside = mon.index >= pd.Period(start, "M")
        if end:
            inside &= mon.index <= pd.Period(end, "M")
        for v in ("celldays", "frp"):
            col = f"{s}_{v}"
            mon.loc[inside, col] = mon.loc[inside, col].fillna(0)

    # ---------- Step 4: fit on overlap, separately for each latitude band ----------
    ov_lo, ov_hi = pd.Period(OVERLAP[0], "M"), pd.Period(OVERLAP[1], "M")
    ov_mask = (mon.index >= ov_lo) & (mon.index <= ov_hi)
    season = fire_season_months(mon.loc[ov_mask, "snpp_celldays"])
    snpp_ov = per_sensor["SNPP"][(per_sensor["SNPP"].acq_date.dt.to_period("M") >= ov_lo)
                                 & (per_sensor["SNPP"].acq_date.dt.to_period("M") <= ov_hi)]
    edges = band_edges(allpts.latitude, cell_days(snpp_ov).latitude)
    labels = band_labels(edges)
    msub = per_sensor["MODIS"]
    B = {  # band x month tables
        "modis": band_tables(msub, edges, mon.index),
        "terra": band_tables(msub[msub.satellite == "Terra"], edges, mon.index),
        "aqua": band_tables(msub[msub.satellite == "Aqua"], edges, mon.index),
        "snpp": band_tables(per_sensor["SNPP"], edges, mon.index),
        "n20": band_tables(per_sensor["N20"], edges, mon.index),
    }
    months = mon.index
    in_ov = pd.Series(ov_mask, index=months)
    fwd_tr = in_ov & (months <= pd.Period(TRAIN_END, "M")); fwd_te = in_ov & (months > pd.Period(TRAIN_END, "M"))
    bck_tr = in_ov & (months > pd.Period("2018-12", "M")); bck_te = in_ov & (months <= pd.Period("2018-12", "M"))

    models, valid, spatial = {}, {}, {}
    for src in ["modis", "terra", "aqua"]:
        for var in ["celldays", "frp"]:
            X, Y = B[src][var], B["snpp"][var]
            key = f"{src}_{var}"
            mdl = BandModel(season).fit(X, Y, in_ov)
            # leave-one-year-out predictions of the regional total -> honest 68% band
            cv_band = loyo_bandmodel(X, Y, in_ov, season)
            mdl.band = cv_band["band"]
            models[key] = mdl
            y_tot, x_tot = Y.sum(axis=1), X.sum(axis=1)
            big = x_tot >= x_tot[in_ov].quantile(0.9)
            res = {}
            for name, trm, tem in [("forward_train2012_2019_test2020_2026", fwd_tr, fwd_te),
                                   ("backcast_train2019_2026_test2012_2018", bck_tr, bck_te)]:
                p_band = BandModel(season).fit(X, Y, trm).predict(X).sum(axis=1)
                ok = tem & (y_tot > 0) & (x_tot > 0)
                tr_ok = trm & (y_tot > 0) & (x_tot > 0)
                p_state = SeasonGLM(season).fit(months[tr_ok], x_tot[tr_ok].values, y_tot[tr_ok].values) \
                    .predict(months[ok], x_tot[ok].values)
                p_old = predict(fit_loglog(x_tot[tr_ok].values, y_tot[tr_ok].values), x_tot[ok].values)
                bb = big[ok].values
                for tag, p in [("", p_band[ok].values), ("_statewide_single_model", p_state), ("_OLD_loglog", p_old)]:
                    res[name + tag] = {**metrics(y_tot[ok].values, p),
                                       "largest_10pct_months_bias_pct":
                                           round(float(p[bb].sum() / y_tot[ok].values[bb].sum() - 1) * 100, 1)}
            res["leave_one_year_out"] = cv_band["metrics"]
            valid[key] = res
            if key == "modis_celldays":
                spatial = cv_band["per_band"]
                ovv = pd.DataFrame({"month": months[ovm_ := in_ov.values].astype(str),
                                    "snpp_observed": Y.sum(axis=1).values[ovm_],
                                    "modis_raw": X.sum(axis=1).values[ovm_],
                                    "modis_converted_LOYO": cv_band["pred_total"].values[ovm_].round(1),
                                    "modis_converted_OLD_loglog": predict(fit_loglog(
                                        X.sum(axis=1)[ovm_].values, Y.sum(axis=1)[ovm_].values),
                                        X.sum(axis=1)[ovm_].values).round(1)})
                ovv.to_csv(os.path.join(outdir, "overlap_validation.csv"), index=False)

    # stability: early vs late halves of the overlap (orbit drift check)
    ov = mon.loc[ov_mask]
    stab = {}
    for src in ["terra", "aqua", "modis"]:
        x, y = ov[f"{src}_celldays"], ov["snpp_celldays"]
        early = ov.index <= pd.Period("2018-12", "M")
        stab[src] = {"ratio_snpp_per_modis_2012_2018": round(float(y[early].sum() / x[early].sum()), 3),
                     "ratio_snpp_per_modis_2019_2026": round(float(y[~early].sum() / x[~early].sum()), 3)}

    # NOAA-20 vs S-NPP agreement (2018-04 .. 2026-07)
    ov2 = mon.loc[pd.Period("2018-04", "M"):ov_hi]
    ok2 = (ov2.n20_celldays > 0) & (ov2.snpp_celldays > 0)
    n20_ratio = float(ov2.snpp_celldays[ok2].sum() / ov2.n20_celldays[ok2].sum())
    n20_frp_ratio = float(ov2.snpp_frp[ok2].sum() / ov2.n20_frp[ok2].sum())
    lr = np.log(ov2.snpp_celldays[ok2] / (ov2.n20_celldays[ok2] * n20_ratio))
    n20_band = (float(np.quantile(lr, 0.16)), float(np.quantile(lr, 0.84)))
    n20_check = {"snpp_per_n20_celldays": round(n20_ratio, 3),
                 "snpp_per_n20_frp": round(n20_frp_ratio, 3),
                 **metrics(ov2.snpp_celldays[ok2], ov2.n20_celldays[ok2] * n20_ratio)}

    # ---------- Steps 5-6: convert + splice ----------
    snpp_end = pd.Period("2026-10", "M")   # last full S-NPP month (S-NPP data stop 2026-11-02)
    aqua_start, viirs_start = pd.Period("2002-07", "M"), pd.Period("2012-02", "M")
    periods = [  # (mask, label, band-table key, conversion)
        (months < aqua_start, "MODIS Terra (converted)", "terra", "model"),
        ((months >= aqua_start) & (months < viirs_start), "MODIS Terra+Aqua (converted)", "modis", "model"),
        ((months >= viirs_start) & (months <= snpp_end), "VIIRS S-NPP", "snpp", 1.0),
        (months > snpp_end, "VIIRS NOAA-20 (scaled to S-NPP)", "n20", n20_ratio),
    ]
    harm_band = pd.DataFrame(0.0, index=months, columns=labels)   # harmonized cell-days per band
    raw_band = harm_band.copy()
    frp_tot = pd.Series(0.0, index=months)
    lo = pd.Series(np.nan, index=months); hi = lo.copy()
    src_col = pd.Series("", index=months, dtype=object); prelim = pd.Series(False, index=months)
    prelim_col = {"terra": "modis_prelim", "modis": "modis_prelim", "snpp": "snpp_prelim", "n20": "n20_prelim"}
    for sel, label, key, conv in periods:
        X = B[key]["celldays"].loc[sel]
        raw_band.loc[sel] = X.values
        if conv == "model":
            hb = models[f"{key}_celldays"].predict(X)
            harm_band.loc[sel] = hb.values
            frp_tot[sel] = models[f"{key}_frp"].predict(B[key]["frp"].loc[sel]).sum(axis=1).values
            l_, h_ = models[f"{key}_celldays"].interval(months[sel])
        else:
            harm_band.loc[sel] = X.values * conv
            frp_tot[sel] = mon.loc[sel, f"{key}_frp"].values * (n20_frp_ratio if key == "n20" else 1.0)
            l_ = h_ = np.zeros(sel.sum()) if key == "snpp" else None
            if key == "n20":
                l_, h_ = np.full(sel.sum(), n20_band[0]), np.full(sel.sum(), n20_band[1])
        tot = harm_band.loc[sel].sum(axis=1).values
        lo[sel], hi[sel] = tot * np.exp(l_), tot * np.exp(h_)
        src_col[sel] = label
        prelim[sel] = mon.loc[sel, prelim_col[key]].values

    out = pd.DataFrame(index=months)
    out.index.name = "month"
    out["harmonized_fire_celldays"] = harm_band.sum(axis=1).round(1)
    out["harmonized_frp_mw"] = frp_tot.round(1)
    out["source"] = src_col
    out["preliminary_nrt"] = prelim
    last_day = max(df["acq_date"].max() for df in per_sensor.values())
    out["partial_month"] = [(p == last_day.to_period("M")) and (last_day.day < p.days_in_month) for p in months]
    out["low_68"] = lo.round(1)
    out["high_68"] = hi.round(1)
    for c in ["modis_celldays", "terra_celldays", "aqua_celldays", "snpp_celldays", "n20_celldays",
              "modis_frp", "snpp_frp", "n20_frp"]:
        out[f"raw_{c}"] = mon[c].round(1)

    # anomaly vs same calendar month (complete years, 2001-2025 baseline)
    out["year"] = out.index.year
    out["month_num"] = out.index.month
    base = out[(out.year >= 2001) & (out.year <= 2025)]
    med = base.groupby("month_num").harmonized_fire_celldays.median()
    out["baseline_median"] = out.month_num.map(med).round(1)
    out["anomaly_ratio"] = (out.harmonized_fire_celldays / out.baseline_median).round(2)
    out["percentile_vs_baseline"] = [
        round(float((base[base.month_num == mm].harmonized_fire_celldays < vv).mean() * 100), 0)
        for mm, vv in zip(out.month_num, out.harmonized_fire_celldays)]
    out.loc[out.partial_month, ["anomaly_ratio", "percentile_vs_baseline"]] = np.nan
    out.reset_index().assign(month=lambda d: d.month.astype(str)).to_csv(
        os.path.join(outdir, "harmonized_monthly_region.csv"), index=False)

    # per-band table, so any month can be checked by hand against the band coefficients
    bl = pd.concat({"raw_celldays_of_source": raw_band.stack(), "harmonized_fire_celldays": harm_band.stack()}, axis=1)
    bl.index.names = ["month", "calibration_band"]
    bl = bl.reset_index()
    bl["source"] = bl.month.map(src_col)
    bl["month"] = bl.month.astype(str)
    bl.round(2).to_csv(os.path.join(outdir, "harmonized_monthly_by_band.csv"), index=False)

    # ---------- per 0.25 deg cell: same band models, so cells sum exactly to the region ----------
    # Every 0.25 deg cell sits inside one latitude band; it gets that band's conversion factor
    # for that month (harmonized band total / raw band total).
    factor = (harm_band / raw_band.where(raw_band > 0)).fillna(0.0)
    pieces = []
    for sel, label, key, _ in periods:
        df = per_sensor["MODIS"] if key in ("modis", "terra") else per_sensor[key.upper() if key == "snpp" else "N20"]
        if key == "terra":
            df = df[df.satellite == "Terra"]
        gc = grid_counts(df)
        gc = gc[gc.month.isin(months[sel])].copy()
        gc["calibration_band"] = band_of(gc.lat_center.values, edges, labels)
        f = factor.stack()
        f.index.names = ["month", "calibration_band"]
        gc = gc.join(f.rename("f"), on=["month", "calibration_band"])
        gc["harmonized_fire_celldays"] = (gc.raw_celldays * gc.f).round(3)
        gc["source"] = label
        pieces.append(gc.drop(columns="f"))
    grid = pd.concat(pieces)
    gsum = grid.groupby("month").harmonized_fire_celldays.sum().reindex(months).fillna(0)
    consistency = float(np.max(np.abs(gsum.values - harm_band.sum(axis=1).values)))
    grid["month"] = grid.month.astype(str)
    grid[["month", "lat_center", "lon_center", "harmonized_fire_celldays", "raw_celldays", "source", "calibration_band"]] \
        .sort_values(["month", "lat_center", "lon_center"]) \
        .to_csv(os.path.join(outdir, "harmonized_monthly_grid_0p25deg.csv"), index=False)

    # ---------- small-area check: 1-degree boxes, converted the way the grid file does it ----------
    spatial["one_degree_boxes"] = box_check(per_sensor, models["modis_celldays"], B["modis"]["celldays"],
                                            edges, labels, ov_lo, ov_hi)

    # ---------- seam check around the MODIS -> VIIRS switch ----------
    conv_all = models["modis_celldays"].predict(B["modis"]["celldays"]).sum(axis=1)
    seam = {int(y): {"raw_modis_celldays": int(mon.loc[months.year == y, "modis_celldays"].sum()),
                     "harmonized_celldays": round(float(out.loc[out.year == y, "harmonized_fire_celldays"].sum()), 0),
                     "modis_converted_all_year": round(float(conv_all[months.year == y].sum()), 0)}
            for y in range(2009, 2015)}

    diag = {"cleaning": clean_log, "static_cells_masked": len(static),
            "fire_season_months": sorted(season),
            "latitude_bands": {l: [float(a), float(b)] for l, a, b in zip(labels, edges[:-1], edges[1:])},
            "models": {k: m.describe() for k, m in models.items()},
            "validation": valid, "overlap_stability": stab, "noaa20_vs_snpp": n20_check,
            "spatial_checks": spatial, "seam_check_yearly": seam,
            "grid_vs_region_max_abs_difference": round(consistency, 4)}
    with open(os.path.join(outdir, "diagnostics.json"), "w") as fh:
        json.dump(diag, fh, indent=2)
    return mon, out, diag


if __name__ == "__main__":
    mon, out, diag = main(sys.argv[1], sys.argv[2])
    print(json.dumps({k: diag[k] for k in ["fire_season_months", "validation", "spatial_checks", "seam_check_yearly",
                                          "grid_vs_region_max_abs_difference"]}, indent=1))
