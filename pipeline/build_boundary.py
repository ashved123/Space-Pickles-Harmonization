"""California outline for the map, from the US Census cartographic boundary file (public domain).

Usage:
    python pipeline/build_boundary.py app/datasets

Downloads cb_2018_us_state_5m.zip (1:5,000,000) into pipeline/raw/boundary/ (git-ignored), reads the
shapefile directly (no extra libraries) and writes app/datasets/california.json:
    {"rings": [[[lat, lon], ...], ...], "bbox": [min_lat, min_lon, max_lat, max_lon]}
Rings are the mainland and islands, largest first.
"""
import io
import json
import os
import struct
import sys
import zipfile

import requests

URL = "https://www2.census.gov/geo/tiger/GENZ2018/shp/cb_2018_us_state_5m.zip"
RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw", "boundary")
STATE = "California"


def dbf_names(dbf):
    """Value of the NAME field for every record."""
    n_records, header_len, record_len = struct.unpack("<IHH", dbf[4:12])
    fields, pos, offset = [], 32, 1
    while dbf[pos] != 0x0D:
        name = dbf[pos:pos + 11].split(b"\x00")[0].decode()
        length = dbf[pos + 16]
        fields.append((name, offset, length))
        offset += length
        pos += 32
    _, off, length = next(f for f in fields if f[0] == "NAME")
    return [dbf[header_len + i * record_len + off:header_len + i * record_len + off + length]
            .decode("latin-1").strip() for i in range(n_records)]


def shp_polygons(shp):
    """List of records; each record is a list of rings [(lon, lat), ...]."""
    out, pos = [], 100
    while pos < len(shp):
        (length,) = struct.unpack(">I", shp[pos + 4:pos + 8])
        rec = shp[pos + 8:pos + 8 + length * 2]
        pos += 8 + length * 2
        (shape_type,) = struct.unpack("<I", rec[:4])
        if shape_type != 5:  # polygon
            out.append([])
            continue
        n_parts, n_points = struct.unpack("<II", rec[36:44])
        parts = list(struct.unpack(f"<{n_parts}I", rec[44:44 + 4 * n_parts])) + [n_points]
        pts = struct.unpack(f"<{2 * n_points}d", rec[44 + 4 * n_parts:44 + 4 * n_parts + 16 * n_points])
        out.append([[(pts[2 * i], pts[2 * i + 1]) for i in range(parts[p], parts[p + 1])]
                    for p in range(n_parts)])
    return out


def ring_area(ring):
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(ring, ring[1:]))) / 2


def main(out_dir):
    os.makedirs(RAW, exist_ok=True)
    zpath = os.path.join(RAW, os.path.basename(URL))
    if not os.path.exists(zpath):
        r = requests.get(URL, timeout=120)
        r.raise_for_status()
        with open(zpath, "wb") as f:
            f.write(r.content)
    z = zipfile.ZipFile(zpath)
    base = os.path.basename(URL)[:-4]
    names = dbf_names(z.read(base + ".dbf"))
    rings = shp_polygons(z.read(base + ".shp"))[names.index(STATE)]
    rings.sort(key=ring_area, reverse=True)
    lats = [p[1] for r in rings for p in r]
    lons = [p[0] for r in rings for p in r]
    out = {
        "source": "US Census Bureau, cartographic boundary file cb_2018_us_state_5m (public domain)",
        "bbox": [min(lats), min(lons), max(lats), max(lons)],
        "rings": [[[round(lat, 5), round(lon, 5)] for lon, lat in r[:-1]] for r in rings],  # drop closing point
    }
    path = os.path.join(out_dir, "california.json")
    with open(path, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"{len(rings)} rings, {[len(r) for r in out['rings']]} points, bbox {out['bbox']}, "
          f"{os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main(sys.argv[1])
