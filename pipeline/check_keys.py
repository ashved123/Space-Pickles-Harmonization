"""Check that the API keys in .env are present and working.

Usage: python pipeline/check_keys.py
Never prints the keys themselves.
"""
from pathlib import Path

import requests

ENV_PATH = Path(__file__).resolve().parent.parent / ".env"


def load_env(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        values[name.strip()] = value.strip().strip('"').strip("'")
    return values


def check_firms(key):
    url = "https://firms.modaps.eosdis.nasa.gov/mapserver/mapkey_status/"
    r = requests.get(url, params={"MAP_KEY": key}, timeout=30)
    if r.ok and "invalid" not in r.text.lower():
        return True, r.text.strip()[:200]
    return False, r.text.strip()[:200]


def check_earthdata(token):
    # A CMR search with the token: a bad token gets 401.
    url = "https://cmr.earthdata.nasa.gov/search/collections.json"
    r = requests.get(
        url,
        params={"short_name": "MOD13Q1", "version": "061"},
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    return r.status_code == 200, f"HTTP {r.status_code}"


def check_opentopo(key):
    # Tiny GLO-30 request near Paradise, CA.
    url = "https://portal.opentopography.org/API/globaldem"
    params = {
        "demtype": "COP30", "south": 39.75, "north": 39.76,
        "west": -121.62, "east": -121.61, "outputFormat": "GTiff", "API_Key": key,
    }
    r = requests.get(url, params=params, timeout=60)
    return r.status_code == 200, f"HTTP {r.status_code}"


CHECKS = [
    ("FIRMS_MAP_KEY", True, check_firms),
    ("EARTHDATA_TOKEN", True, check_earthdata),
    ("OPENTOPO_API_KEY", False, check_opentopo),
]


def main():
    env = load_env(ENV_PATH)
    if not env:
        print(f"No .env found at {ENV_PATH}. Copy .env.example to .env and fill it in.")
    for name, required, check in CHECKS:
        value = env.get(name, "")
        if not value:
            print(f"[{'MISSING' if required else 'skip'}] {name}")
            continue
        try:
            ok, info = check(value)
        except requests.RequestException as e:
            ok, info = False, str(e)
        print(f"[{'ok' if ok else 'FAIL'}] {name}: {info}")


if __name__ == "__main__":
    main()
