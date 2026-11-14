"""Diagnostic figures for the harmonization. Usage: python plots.py <output_dir>"""
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.colors import LinearSegmentedColormap, LogNorm

out = sys.argv[1]
d = pd.read_csv(os.path.join(out, "harmonized_monthly_region.csv"))
ov = pd.read_csv(os.path.join(out, "overlap_validation.csv"))
diag = json.load(open(os.path.join(out, "diagnostics.json")))

INK, INK2, GRID_C, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
BLUE, ORANGE, GRAY = "#2a78d6", "#eb6834", "#a3a29c"
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "axes.edgecolor": GRID_C,
                     "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
                     "axes.titlecolor": INK, "axes.titlesize": 11.5, "axes.titleweight": "bold",
                     "axes.titlelocation": "left", "figure.facecolor": SURF, "axes.facecolor": SURF,
                     "axes.spines.top": False, "axes.spines.right": False})
d["date"] = pd.to_datetime(d["month"])
ov["date"] = pd.to_datetime(ov["month"])
v = diag["validation"]["modis_celldays"]

fig, axes = plt.subplots(2, 3, figsize=(20, 11))

# (a) out-of-sample scatter, new vs old model
ax = axes[0, 0]
ax.scatter(ov.snpp_observed, ov.modis_converted_OLD_loglog, s=30, color=GRAY, edgecolor=SURF, lw=0.8,
           label="Old model (log-log, fitted on all years)")
ax.scatter(ov.snpp_observed, ov.modis_converted_LOYO, s=36, color=BLUE, edgecolor=SURF, lw=1,
           label="New model, held-out years")
lim = [ov[["snpp_observed", "modis_converted_LOYO"]].min().min() * 0.8, ov.snpp_observed.max() * 1.3]
ax.plot(lim, lim, color=INK, lw=1.5, ls="--", label="Perfect agreement")
ax.set(xscale="log", yscale="log", xlim=lim, ylim=lim, xlabel="VIIRS S-NPP observed (fire cell-days / month)",
       ylabel="MODIS converted to S-NPP scale")
ax.set_title(f"Converted MODIS vs real VIIRS\n(leave-one-year-out median error {v['leave_one_year_out']['median_abs_pct_error']}%)")
ax.grid(color=GRID_C, lw=0.8); ax.legend(frameon=False, loc="upper left")

# (b) big-month bias, old vs new
ax = axes[0, 1]
tests = [("forward_train2012_2019_test2020_2026", "Fit 2012–19,\ntest 2020–26"),
         ("backcast_train2019_2026_test2012_2018", "Fit 2019–26,\ntest 2012–18")]
xpos = np.arange(len(tests)); w = 0.36
old = [v[t + "_OLD_loglog"]["largest_10pct_months_bias_pct"] for t, _ in tests]
new = [v[t]["largest_10pct_months_bias_pct"] for t, _ in tests]
b1 = ax.bar(xpos - w / 2 - 0.01, old, w, color=GRAY, label="Old model")
b2 = ax.bar(xpos + w / 2 + 0.01, new, w, color=BLUE, label="New model")
for bars in (b1, b2):
    for r in bars:
        h = r.get_height()
        ax.text(r.get_x() + r.get_width() / 2, h + (-1.2 if h < 0 else 0.4), f"{h:+.1f}%",
                ha="center", va="top" if h < 0 else "bottom", fontsize=9, color=INK)
ax.axhline(0, color=INK2, lw=1)
ax.set_xticks(xpos); ax.set_xticklabels([l for _, l in tests])
ax.set_ylabel("Error in total, largest 10% of months")
ax.set_title("Big fire months are no longer underestimated")
ax.grid(color=GRID_C, lw=0.8, axis="y"); ax.legend(frameon=False, loc="lower right")
ax.set_ylim(min(old + new) - 5, 5)

# (c) per-band bias
ax = axes[0, 2]
sp = {k: x for k, x in diag["spatial_checks"].items() if k.startswith("band")}
names = [k.replace("band ", "") for k in sp]
sw = [x["statewide_model_applied"]["total_bias_pct"] for x in sp.values()]
bm = [x["band_model_LOYO"]["total_bias_pct"] for x in sp.values()]
yp = np.arange(len(names))
ax.barh(yp + 0.2, sw, 0.38, color=GRAY, label="One statewide model")
ax.barh(yp - 0.2, bm, 0.38, color=BLUE, label="Separate model per band")
for y_, a_, b_ in zip(yp, sw, bm):
    ax.text(a_ + (0.5 if a_ >= 0 else -0.5), y_ + 0.2, f"{a_:+.0f}%", va="center",
            ha="left" if a_ >= 0 else "right", fontsize=9, color=INK)
    ax.text(b_ + (0.5 if b_ >= 0 else -0.5), y_ - 0.2, f"{b_:+.0f}%", va="center",
            ha="left" if b_ >= 0 else "right", fontsize=9, color=INK)
ax.axvline(0, color=INK2, lw=1)
ax.set_yticks(yp); ax.set_yticklabels(names)
ax.set_xlabel("Total bias vs VIIRS, 2012–2026 (held-out)")
ax.set_title("Regional bias by latitude band")
ax.grid(color=GRID_C, lw=0.8, axis="x"); ax.legend(frameon=False, loc="lower right")
ax.set_xlim(min(bm + sw) - 6, max(bm + sw) + 8)

# (d) overlap time series
ax = axes[1, 0]
ax.plot(ov.date, ov.snpp_observed, color=BLUE, lw=2, label="VIIRS S-NPP (observed)")
ax.plot(ov.date, ov.modis_converted_LOYO, color=ORANGE, lw=2, label="MODIS converted (held-out years)")
ax.set_yscale("log"); ax.set_ylabel("Fire cell-days per month")
ax.set_title("Converted MODIS tracks VIIRS month by month")
ax.grid(color=GRID_C, lw=0.8, axis="y"); ax.legend(frameon=False, loc="upper left")

# (e) NOAA-20 vs S-NPP
ax = axes[1, 1]
o2 = d[(d.month >= "2018-04") & (d.month <= "2026-07")]
r = diag["noaa20_vs_snpp"]
ax.plot(o2.date, o2.raw_snpp_celldays, color=BLUE, lw=2, label="VIIRS S-NPP")
ax.plot(o2.date, o2.raw_n20_celldays, color=ORANGE, lw=2, label="VIIRS NOAA-20")
ax.set_yscale("log"); ax.set_ylabel("Fire cell-days per month")
ax.set_title(f"NOAA-20 vs S-NPP (median difference {r['median_abs_pct_error']}%)")
ax.grid(color=GRID_C, lw=0.8, axis="y"); ax.legend(frameon=False, loc="upper left")

# (f) burning calendar
ax = axes[1, 2]
cal = d.pivot(index="year", columns="month_num", values="harmonized_fire_celldays")
cmap = LinearSegmentedColormap.from_list("blue", ["#f0efec", "#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"])
im = ax.imshow(cal.values, aspect="auto", cmap=cmap, norm=LogNorm(vmin=max(cal.min().min(), 50), vmax=cal.max().max()))
ax.set_xticks(range(12)); ax.set_xticklabels(list("JFMAMJJASOND"))
ax.set_yticks(range(len(cal.index))); ax.set_yticklabels(cal.index, fontsize=8)
ax.axhline(cal.index.get_loc(2012) - 0.5, color=INK, lw=1.2, ls="--")
ax.text(11.6, cal.index.get_loc(2012) - 0.7, "VIIRS from Feb 2012 ↓", ha="right", va="bottom", fontsize=8, color=INK)
ax.set_title("Harmonized burning calendar, California")
for s in ax.spines.values():
    s.set_visible(False)
cb = fig.colorbar(im, ax=ax, fraction=0.045, pad=0.02)
cb.set_label("Fire cell-days (S-NPP scale)", color=INK2); cb.outline.set_visible(False)

fig.tight_layout(pad=2)
fig.savefig(os.path.join(out, "harmonization_diagnostics.png"), dpi=140)
print("saved")
