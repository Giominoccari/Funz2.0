#!/usr/bin/env python3
"""Geodata import pipeline for Funghi Map.

Downloads geodata from WEkEO (HDA API) and ISRIC SoilGrids, reprojects
to EPSG:4326, clips to Italy bounding box, and imports into PostGIS.

Data sources (WEkEO HDA):
  - CORINE Land Cover 2018:     EO:EEA:DAT:CORINE
  - Tree Cover Density 2018:    EO:EEA:DAT:HRL:TCF
  - Dominant Leaf Type 2018:    EO:EEA:DAT:HRL:TCF
  - Copernicus DEM GLO-30:      EO:ESA:DAT:COP-DEM

Data sources (direct):
  - Soil classification:        ISRIC SoilGrids WRB (open, no auth)

Derived locally:
  - DEM Aspect:                 gdaldem aspect from Copernicus DEM

Prerequisites:
    pip install hda
    gdal-bin (gdalwarp, gdal_translate, gdaldem, gdal_merge.py)
    postgis  (raster2pgsql)
    psql     (PostgreSQL client)

WEkEO credentials:
    Set WEKEO_USERNAME and WEKEO_PASSWORD in .env or environment.
    Register free at https://www.wekeo.eu

Usage:
    python3 scripts/import-geodata.py                   # All datasets
    python3 scripts/import-geodata.py corine dem soil    # Specific ones
"""

import math
import os
import shutil
import subprocess
import sys
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
from pathlib import Path

# ─── Constants ────────────────────────────────────────────────────────

ITALY_BBOX = [6.5, 36.5, 18.5, 47.5]  # min_lon, min_lat, max_lon, max_lat
DATA_DIR = Path("data/geodata")

# WEkEO search timeout (seconds) — prevents infinite hangs
HDA_SEARCH_TIMEOUT = 120
HDA_DOWNLOAD_TIMEOUT = 1800  # 30 min per dataset

# ─── Helpers ──────────────────────────────────────────────────────────


def load_env():
    """Load .env file if present."""
    env_file = Path(".env")
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip())


def get_db_url():
    return os.environ.get(
        "DATABASE_URL",
        "postgres://funghimap:funghimap_dev@localhost:5432/funghimap_dev",
    )


def check_commands():
    """Verify required CLI tools are installed."""
    required = {
        "gdalwarp": "brew install gdal",
        "gdaldem": "brew install gdal",
        "raster2pgsql": "brew install postgis",
        "psql": "brew install libpq",
    }
    for cmd, hint in required.items():
        if shutil.which(cmd) is None:
            print(f"  ✗ Required command '{cmd}' not found. Install with: {hint}")
            sys.exit(1)


def run(cmd, timeout=600):
    """Run a shell command. Returns (success, stdout, stderr)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return False, "", "Command timed out"
    except FileNotFoundError:
        return False, "", f"Command not found: {cmd[0]}"


def get_raster_tile_count(raster_file, tile_size=100):
    """Estimate number of tiles raster2pgsql will produce."""
    ok, out, _ = run(["gdalinfo", str(raster_file)], timeout=30)
    if not ok:
        return None
    for line in out.splitlines():
        if "Size is" in line:
            parts = line.split("Size is")[1].strip().split(",")
            if len(parts) == 2:
                w, h = int(parts[0].strip()), int(parts[1].strip())
                return math.ceil(w / tile_size) * math.ceil(h / tile_size)
    return None


def print_progress(current, total, start_time, prefix="  "):
    """Print a progress bar to stderr."""
    elapsed = time.time() - start_time
    pct = current / total if total else 0
    filled = int(30 * pct)
    bar = "█" * filled + "░" * (30 - filled)

    if current > 0 and elapsed > 2:
        eta_secs = (elapsed / current) * (total - current)
        if eta_secs >= 60:
            eta = f"{eta_secs / 60:.0f}m"
        else:
            eta = f"{eta_secs:.0f}s"
        eta_str = f" ETA {eta}"
    else:
        eta_str = ""

    print(f"\r{prefix}{bar} {pct:5.1%}  ({current}/{total} tiles){eta_str}   ",
          end="", flush=True)


def file_ok(path, min_bytes=100_000):
    return path.exists() and path.stat().st_size > min_bytes


def size_mb(path):
    return path.stat().st_size / (1024 * 1024)


def clip_to_italy(src, dst, resample="near"):
    """Reproject + clip a raster to Italy bbox in EPSG:4326."""
    ok, _, err = run([
        "gdalwarp", "-t_srs", "EPSG:4326", "-r", resample,
        "-te", str(ITALY_BBOX[0]), str(ITALY_BBOX[1]),
        str(ITALY_BBOX[2]), str(ITALY_BBOX[3]),
        "-overwrite", "-q",
        str(src), str(dst),
    ])
    return ok, err


def import_postgis(raster_file, table_name, db_url):
    """Import a raster into PostGIS via raster2pgsql | psql with progress."""
    total_tiles = get_raster_tile_count(raster_file, tile_size=100)
    if total_tiles:
        print(f"  ▶ Importing into PostGIS table '{table_name}' (~{total_tiles} tiles)...")
    else:
        print(f"  ▶ Importing into PostGIS table '{table_name}'...")

    try:
        # Create a raw pipe for psql stdin — avoids Python's BufferedWriter
        # which causes "flush of closed file" errors on cleanup
        psql_read_fd, psql_write_fd = os.pipe()

        r2p = subprocess.Popen(
            ["raster2pgsql", "-d", "-s", "4326", "-t", "100x100",
             "-I", "-C", "-M", str(raster_file), table_name],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        psql_proc = subprocess.Popen(
            ["psql", db_url, "-q"],
            stdin=psql_read_fd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        os.close(psql_read_fd)  # psql owns it now

        r2p_fd = r2p.stdout.fileno()

        insert_count = 0
        start_time = time.time()
        last_update = 0

        while True:
            chunk = os.read(r2p_fd, 65536)
            if not chunk:
                break
            try:
                os.write(psql_write_fd, chunk)
            except OSError:
                break
            insert_count += chunk.count(b"INSERT")
            now = time.time()
            if total_tiles and now - last_update >= 0.3:
                print_progress(insert_count, total_tiles, start_time)
                last_update = now

        r2p.stdout.close()
        os.close(psql_write_fd)  # signal EOF to psql

        _, psql_err = psql_proc.communicate(timeout=3600)
        r2p.wait()
        elapsed = time.time() - start_time

        if total_tiles and insert_count > 0:
            # Use actual count as total for the final bar (estimate can overcount
            # because raster2pgsql skips nodata/empty tiles)
            print_progress(insert_count, insert_count, start_time)
            print()

        if psql_proc.returncode != 0:
            err_msg = psql_err.decode().strip() if psql_err else ""
            r2p_err = r2p.stderr.read().decode().strip() if r2p.stderr else ""
            detail = err_msg or r2p_err or "unknown"
            print(f"  ✗ Import failed: {detail[:300]}")
            return False
    except Exception as e:
        print(f"\n  ✗ Import error: {e}")
        return False

    if elapsed >= 60:
        elapsed_str = f"{elapsed / 60:.1f}m"
    else:
        elapsed_str = f"{elapsed:.0f}s"
    print(f"  ✔ '{table_name}' imported ({insert_count} tiles in {elapsed_str})")
    return True


# ─── WEkEO HDA helpers ───────────────────────────────────────────────


def _get_hda_client():
    """Create and return an authenticated HDA client."""
    try:
        from hda import Client, Configuration
    except ImportError:
        print("  ✗ 'hda' package not installed. Run: pip install hda")
        sys.exit(1)

    username = os.environ.get("WEKEO_USERNAME", "")
    password = os.environ.get("WEKEO_PASSWORD", "")

    if not username or not password:
        print("  ✗ WEKEO_USERNAME and WEKEO_PASSWORD must be set in .env")
        print("    Register free at https://www.wekeo.eu")
        sys.exit(1)

    conf = Configuration(user=username, password=password)
    return Client(config=conf)


def _hda_search_with_timeout(client, query, timeout=HDA_SEARCH_TIMEOUT):
    """Run client.search() with a timeout to prevent infinite hangs."""
    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(client.search, query)
        try:
            return future.result(timeout=timeout)
        except FuturesTimeout:
            print(f"  ✗ WEkEO search timed out after {timeout}s")
            return None
        except Exception as e:
            print(f"  ✗ WEkEO search failed: {e}")
            return None


def _hda_download_with_timeout(match, download_dir, timeout=HDA_DOWNLOAD_TIMEOUT):
    """Run match.download() with a timeout."""
    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(match.download, download_dir=str(download_dir))
        try:
            future.result(timeout=timeout)
            return True
        except FuturesTimeout:
            print(f"  ✗ WEkEO download timed out after {timeout}s")
            return False
        except Exception as e:
            print(f"  ✗ WEkEO download failed: {e}")
            return False


def _find_tif_in_dir(directory):
    """Find the largest TIF file in a directory tree."""
    tifs = list(directory.rglob("*.tif")) + list(directory.rglob("*.TIF"))
    if not tifs:
        return None
    return max(tifs, key=lambda f: f.stat().st_size)


def _extract_zips_in_dir(directory):
    """Extract all ZIP files in a directory, return list of extracted TIFs."""
    tifs = []
    for zf_path in directory.rglob("*.zip"):
        try:
            with zipfile.ZipFile(zf_path, "r") as zf:
                tif_members = [m for m in zf.namelist() if m.lower().endswith(".tif")]
                for m in (tif_members or zf.namelist()):
                    zf.extract(m, directory)
            tifs.extend(directory.rglob("*.tif"))
        except Exception as e:
            print(f"    ⚠ Failed to extract {zf_path.name}: {e}")
    return tifs


# ─── CORINE Land Cover CLC 2018 ──────────────────────────────────────


def download_corine(client):
    """Download CORINE CLC 2018 from WEkEO."""
    output = DATA_DIR / "corine_italy.tif"
    if file_ok(output):
        print("  ✔ Raw file already present")
        return output

    print("  ▶ Searching CORINE on WEkEO (EO:EEA:DAT:CORINE)...")
    matches = _hda_search_with_timeout(client, {
        "dataset_id": "EO:EEA:DAT:CORINE",
        "productType": "Corine Land Cover 2018",
        "format": "GeoTiff100mt",
    })
    if matches is None:
        return None

    # Find CLC 2018 raster 100m
    target = None
    for r in matches.results:
        rid = r.get("id", "")
        if "clc2018" in rid.lower() and "raster100m" in rid.lower():
            target = r
            break
        if rid == "u2018_clc2018_v2020_20u1_raster100m":
            target = r
            break

    if not target:
        # Fall back to first result
        if matches.results:
            target = matches.results[0]
            print(f"    Using first result: {target.get('id', 'unknown')}")
        else:
            print("  ✗ No CORINE results found")
            return None

    tmp_dir = DATA_DIR / ".tmp_corine"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    rid = target.get("id", "unknown")
    print(f"  ▶ Downloading {rid}...")
    idx = matches.results.index(target)
    if not _hda_download_with_timeout(matches[idx], tmp_dir):
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return None

    # Extract ZIPs if needed
    _extract_zips_in_dir(tmp_dir)

    tif = _find_tif_in_dir(tmp_dir)
    if not tif:
        print("  ✗ No TIF found after download")
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return None

    shutil.move(str(tif), str(output))
    shutil.rmtree(tmp_dir, ignore_errors=True)
    print(f"  ✔ CORINE downloaded ({size_mb(output):.0f} MB)")
    return output


def handle_corine(client):
    """Download + reproject + clip CORINE to Italy."""
    final = DATA_DIR / "corine_italy_4326.tif"
    if file_ok(final):
        print("  ✔ Already processed")
        return final

    raw = download_corine(client)
    if not raw:
        return None

    print("  ▶ Clipping to Italy (EPSG:4326)...")
    ok, err = clip_to_italy(raw, final, resample="near")
    if not ok:
        print(f"  ✗ Clip failed: {err[:200]}")
        return None

    print(f"  ✔ CORINE ready ({size_mb(final):.0f} MB)")
    return final


# ─── Tree Cover Density / Dominant Leaf Type (HRL) ───────────────────


def download_hrl(client, product):
    """Download TCD or DLT from WEkEO HRL Tree Cover and Forests."""
    configs = {
        "tcd": {
            "label": "Tree Cover Density (HRL 2018)",
            "output": "tree_cover_density_italy.tif",
            "productType": "Tree Cover Density",
            "year": "2018",
            "resolution": "100m",
        },
        "dlt": {
            "label": "Dominant Leaf Type (HRL 2018)",
            "output": "dominant_leaf_type_italy.tif",
            "productType": "Dominant Leaf Type",
            "year": "2018",
            # DLT 2018 only available at 10m — no resolution filter
        },
    }
    cfg = configs[product]
    output = DATA_DIR / cfg["output"]

    if file_ok(output):
        print(f"  ✔ Raw file already present")
        return output

    query = {
        "dataset_id": "EO:EEA:DAT:HRL:TCF",
        "productType": cfg["productType"],
        "year": cfg["year"],
        "bbox": ITALY_BBOX,
    }
    if "resolution" in cfg:
        query["resolution"] = cfg["resolution"]

    print(f"  ▶ Searching {cfg['label']} on WEkEO (EO:EEA:DAT:HRL:TCF)...")
    matches = _hda_search_with_timeout(client, query)
    if matches is None:
        return None

    candidates = matches.results
    if not candidates:
        print(f"  ✗ No {cfg['label']} files found")
        return None

    print(f"  ▶ Downloading {len(candidates)} {cfg['label']} tiles...")
    tmp_dir = DATA_DIR / f".tmp_{product}"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    try:
        from hda.api import SearchResults
        filtered = SearchResults(
            client=client, results=candidates, dataset=matches.dataset
        )
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(
                filtered.download, download_dir=str(tmp_dir)
            )
            future.result(timeout=HDA_DOWNLOAD_TIMEOUT)
    except FuturesTimeout:
        print(f"  ✗ HRL download timed out after {HDA_DOWNLOAD_TIMEOUT}s")
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return None
    except Exception as e:
        print(f"  ✗ HRL download failed: {e}")
        # Continue if we got some tiles
        if not list(tmp_dir.rglob("*.tif")) and not list(tmp_dir.glob("*.zip")):
            shutil.rmtree(tmp_dir, ignore_errors=True)
            return None
        print("  ⚠ Partial download, trying to use available tiles...")

    _extract_zips_in_dir(tmp_dir)
    tifs = list(tmp_dir.rglob("*.tif")) + list(tmp_dir.rglob("*.TIF"))

    if not tifs:
        print("  ✗ No TIF found after download")
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return None

    if len(tifs) == 1:
        shutil.move(str(tifs[0]), str(output))
    else:
        print(f"  ▶ Merging {len(tifs)} tiles...")
        ok, _, err = run(
            ["gdal_merge.py", "-o", str(output), "-q"] + [str(t) for t in tifs],
            timeout=600,
        )
        if not ok:
            ok, _, err = run(
                ["python3", "-m", "osgeo_utils.gdal_merge",
                 "-o", str(output), "-q"] + [str(t) for t in tifs],
                timeout=600,
            )
        if not ok or not file_ok(output, min_bytes=1000):
            print(f"  ✗ Merge failed: {err[:200] if err else 'unknown'}")
            shutil.rmtree(tmp_dir, ignore_errors=True)
            return None

    shutil.rmtree(tmp_dir, ignore_errors=True)
    print(f"  ✔ {cfg['label']} downloaded ({size_mb(output):.0f} MB)")
    return output


def handle_tcd(client):
    """Download + clip Tree Cover Density to Italy."""
    final = DATA_DIR / "tree_cover_density_italy_4326.tif"
    if file_ok(final):
        print("  ✔ Already processed")
        return final

    raw = download_hrl(client, "tcd")
    if not raw:
        return None

    print("  ▶ Clipping to Italy (EPSG:4326)...")
    ok, err = clip_to_italy(raw, final, resample="bilinear")
    if not ok:
        print(f"  ✗ Clip failed: {err[:200]}")
        return None

    print(f"  ✔ TCD ready ({size_mb(final):.0f} MB)")
    return final


def handle_dlt(client):
    """Download + clip Dominant Leaf Type to Italy."""
    final = DATA_DIR / "dominant_leaf_type_italy_4326.tif"
    if file_ok(final):
        print("  ✔ Already processed")
        return final

    raw = download_hrl(client, "dlt")
    if not raw:
        return None

    print("  ▶ Clipping to Italy (EPSG:4326)...")
    ok, err = clip_to_italy(raw, final, resample="near")
    if not ok:
        print(f"  ✗ Clip failed: {err[:200]}")
        return None

    print(f"  ✔ DLT ready ({size_mb(final):.0f} MB)")
    return final


# ─── Copernicus DEM GLO-30 ───────────────────────────────────────────


def download_dem(client):
    """Download Copernicus DEM GLO-30 tiles for Italy from WEkEO."""
    raw = DATA_DIR / "copernicus_dem_italy_raw.tif"
    if file_ok(raw):
        print("  ✔ Raw DEM already present")
        return raw

    # Check for already-downloaded WEkEO ZIP tiles
    tiles_dir = DATA_DIR / "dem_tiles"
    if tiles_dir.exists() and list(tiles_dir.glob("*.zip")):
        print(f"  ✔ Found existing DEM tile ZIPs")
        return _merge_dem_tiles(tiles_dir, raw)

    print("  ▶ Searching DEM on WEkEO (EO:ESA:DAT:COP-DEM, Italy bbox)...")
    matches = _hda_search_with_timeout(client, {
        "dataset_id": "EO:ESA:DAT:COP-DEM",
        "bbox": ITALY_BBOX,
    })
    if matches is None:
        return None

    # Filter for GLO-30 GeoTIFF (DGE_30 prefix)
    dem_tiles = [
        r for r in matches.results
        if "DGE_30" in r.get("id", "")
    ]
    if not dem_tiles:
        print(f"  ✗ No GLO-30 GeoTIFF tiles found (total results: {len(matches.results)})")
        if matches.results:
            for r in matches.results[:5]:
                print(f"    Sample: {r.get('id', '')}")
        return None

    print(f"  ▶ Downloading {len(dem_tiles)} GLO-30 tiles...")
    tiles_dir.mkdir(parents=True, exist_ok=True)

    try:
        from hda.api import SearchResults
        filtered = SearchResults(
            client=client, results=dem_tiles, dataset=matches.dataset
        )
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(
                filtered.download, download_dir=str(tiles_dir)
            )
            future.result(timeout=HDA_DOWNLOAD_TIMEOUT)
    except FuturesTimeout:
        print(f"  ✗ DEM download timed out after {HDA_DOWNLOAD_TIMEOUT}s")
        return None
    except Exception as e:
        print(f"  ✗ DEM download failed: {e}")
        # Continue if we got some tiles
        if not list(tiles_dir.glob("*.zip")):
            return None
        print("  ⚠ Partial download, trying to use available tiles...")

    return _merge_dem_tiles(tiles_dir, raw)


def _merge_dem_tiles(tiles_dir, output):
    """Unzip, find TIFs, merge into a single raw DEM raster."""
    # Unzip all ZIPs
    for zf_path in sorted(tiles_dir.glob("*.zip")):
        try:
            with zipfile.ZipFile(zf_path, "r") as zf:
                zf.extractall(tiles_dir)
        except Exception as e:
            print(f"    ⚠ Failed to extract {zf_path.name}: {e}")

    # Find DEM TIFs
    tifs = list(tiles_dir.rglob("*.tif")) + list(tiles_dir.rglob("*.TIF"))
    dem_tifs = [t for t in tifs if "DEM" in t.name.upper()] or tifs

    if not dem_tifs:
        print("  ✗ No TIF files found in DEM tiles")
        return None

    print(f"  ▶ Merging {len(dem_tifs)} DEM tiles...")
    ok, _, err = run(
        ["gdal_merge.py", "-o", str(output), "-q"] + [str(t) for t in dem_tifs],
        timeout=600,
    )
    if not ok:
        # Fallback
        ok, _, err = run(
            ["python3", "-m", "osgeo_utils.gdal_merge",
             "-o", str(output), "-q"] + [str(t) for t in dem_tifs],
            timeout=600,
        )

    if not ok or not file_ok(output, min_bytes=1000):
        print(f"  ✗ Merge failed: {err[:200] if err else 'unknown'}")
        return None

    print(f"  ✔ DEM tiles merged ({size_mb(output):.0f} MB)")
    return output


def handle_dem(client):
    """Download + clip Copernicus DEM to Italy."""
    final = DATA_DIR / "copernicus_dem_italy.tif"
    if file_ok(final):
        print("  ✔ Already processed")
        return final

    raw = download_dem(client)
    if not raw:
        return None

    print("  ▶ Clipping to Italy (EPSG:4326)...")
    ok, err = clip_to_italy(raw, final, resample="bilinear")
    if not ok:
        print(f"  ✗ Clip failed: {err[:200]}")
        return None

    print(f"  ✔ DEM ready ({size_mb(final):.0f} MB)")
    return final


# ─── Soil Classification (ISRIC SoilGrids WRB) ──────────────────────


def handle_soil(_client):
    """Download soil classification from ISRIC SoilGrids (open, no auth).

    Not on WEkEO — downloaded directly via GDAL or curl.
    """
    final = DATA_DIR / "esdac_soil_italy.tif"

    if file_ok(final):
        print("  ✔ Already present")
        return final

    min_lon, min_lat, max_lon, max_lat = ITALY_BBOX
    strategies = [
        {
            "label": "SoilGrids VRT via GDAL /vsicurl/",
            "cmd": [
                "gdal_translate", "-of", "GTiff",
                "-projwin", str(min_lon), str(max_lat),
                str(max_lon), str(min_lat),
                "/vsicurl/https://files.isric.org/soilgrids/latest/data/wrb/MostProbable.vrt",
                str(final),
            ],
        },
        {
            "label": "SoilGrids WCS 2.0.1",
            "cmd": [
                "curl", "-sS", "-f", "-o", str(final),
                (
                    "https://maps.isric.org/mapserv?map=/map/wrb.map"
                    "&SERVICE=WCS&VERSION=2.0.1&REQUEST=GetCoverage"
                    "&COVERAGEID=MostProbable&FORMAT=image/tiff"
                    f"&SUBSET=long({min_lon},{max_lon})"
                    f"&SUBSET=lat({min_lat},{max_lat})"
                    "&SUBSETTINGCRS=http://www.opengis.net/def/crs/EPSG/0/4326"
                ),
            ],
        },
        {
            "label": "SoilGrids COG direct",
            "cmd": [
                "gdal_translate", "-of", "GTiff",
                "-projwin", str(min_lon), str(max_lat),
                str(max_lon), str(min_lat),
                "/vsicurl/https://files.isric.org/soilgrids/latest/data/wrb/MostProbable/tileSG-017-049.tif",
                str(final),
            ],
        },
    ]

    for strat in strategies:
        print(f"  ▶ Trying {strat['label']}...")
        ok, _, err = run(strat["cmd"], timeout=300)
        if ok and file_ok(final, min_bytes=10_000):
            print(f"  ✔ Soil data downloaded ({size_mb(final):.1f} MB)")
            return final
        final.unlink(missing_ok=True)
        print(f"    ⚠ Failed, trying next...")

    print("  ✗ All soil download strategies failed")
    print("  Download manually from: https://soilgrids.org")
    print(f"  Place GeoTIFF at: {final}")
    return None


# ─── DEM Aspect (derived) ────────────────────────────────────────────


def handle_aspect(_client):
    """Derive aspect raster from DEM using gdaldem."""
    dem = DATA_DIR / "copernicus_dem_italy.tif"
    final = DATA_DIR / "dem_aspect_italy.tif"

    if file_ok(final):
        print("  ✔ Already present")
        return final

    if not file_ok(dem):
        print("  ✗ Cannot derive aspect: DEM not available")
        return None

    print("  ▶ Computing aspect from DEM...")
    ok, _, err = run([
        "gdaldem", "aspect", str(dem), str(final),
        "-of", "GTiff", "-b", "1", "-zero_for_flat",
    ])
    if not ok:
        print(f"  ✗ gdaldem failed: {err[:200]}")
        return None

    print(f"  ✔ Aspect raster generated ({size_mb(final):.0f} MB)")
    return final


# ─── Dataset Registry ────────────────────────────────────────────────

DATASETS = {
    "corine": {
        "label": "CORINE Land Cover (CLC 2018)",
        "critical": True,
        "table": "corine_landcover",
        "handler": handle_corine,
    },
    "tcd": {
        "label": "Tree Cover Density (HRL 2018)",
        "critical": False,
        "table": "tree_cover_density",
        "handler": handle_tcd,
    },
    "dlt": {
        "label": "Dominant Leaf Type (HRL 2018)",
        "critical": False,
        "table": "dominant_leaf_type",
        "handler": handle_dlt,
    },
    "dem": {
        "label": "Copernicus DEM GLO-30",
        "critical": True,
        "table": "copernicus_dem",
        "handler": handle_dem,
    },
    "soil": {
        "label": "Soil Classification (ISRIC SoilGrids WRB)",
        "critical": True,
        "table": "esdac_soil",
        "handler": handle_soil,
    },
    "aspect": {
        "label": "DEM Aspect (derived)",
        "critical": True,
        "table": "dem_aspect",
        "handler": handle_aspect,
        "depends": "dem",
    },
}

DATASET_ORDER = ["corine", "tcd", "dlt", "dem", "soil", "aspect"]


# ─── Main ─────────────────────────────────────────────────────────────


def verify_tables(db_url, tables):
    """Verify raster tables exist in PostGIS."""
    print("▶ Verifying raster tables...")
    for table in tables:
        ok, out, _ = run([
            "psql", db_url, "-t", "-A",
            "-c", f"SELECT count(*) FROM {table};",
        ])
        if ok:
            print(f"  ✔ {table}: {out.strip()} tiles")
        else:
            print(f"  ✗ {table}: not found or empty")


def main():
    load_env()
    check_commands()
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    db_url = get_db_url()

    print("=== Funghi Map — GeoData Import ===")
    print()

    # Determine targets
    targets = sys.argv[1:] if len(sys.argv) > 1 else list(DATASET_ORDER)
    invalid = [t for t in targets if t not in DATASETS]
    if invalid:
        print(f"Error: Unknown dataset(s): {', '.join(invalid)}")
        print(f"Available: {', '.join(DATASET_ORDER)}")
        sys.exit(1)

    # Ensure dependencies are included
    for t in list(targets):
        dep = DATASETS[t].get("depends")
        if dep and dep not in targets:
            targets.insert(targets.index(t), dep)

    # Preserve execution order
    targets = [d for d in DATASET_ORDER if d in targets]

    # Authenticate with WEkEO (only if needed)
    needs_wekeo = any(
        t in ("corine", "tcd", "dlt", "dem") for t in targets
    )
    client = None
    if needs_wekeo:
        print("▶ Authenticating with WEkEO...")
        try:
            client = _get_hda_client()
            print("  ✔ WEkEO authenticated")
        except Exception as e:
            print(f"  ✗ WEkEO authentication failed: {e}")
            # Check if any critical WEkEO datasets are targeted
            wekeo_critical = [
                t for t in targets
                if t in ("corine", "dem") and DATASETS[t]["critical"]
            ]
            if wekeo_critical:
                sys.exit(1)
            print("  ⚠ Continuing with non-WEkEO datasets only...")
    print()

    failed_critical = []
    failed_optional = []
    imported_tables = []

    for name in targets:
        ds = DATASETS[name]
        print(f"▶ {ds['label']}")

        # Skip WEkEO datasets if not authenticated
        if name in ("corine", "tcd", "dlt", "dem") and client is None:
            # Check if raw file already exists
            raw_files = {
                "corine": DATA_DIR / "corine_italy.tif",
                "dem": DATA_DIR / "copernicus_dem_italy_raw.tif",
                "tcd": DATA_DIR / "tree_cover_density_italy.tif",
                "dlt": DATA_DIR / "dominant_leaf_type_italy.tif",
            }
            raw = raw_files.get(name)
            if raw and file_ok(raw):
                print("  ⚠ No WEkEO auth, but raw file exists — processing...")
            else:
                print("  ✗ Skipped: WEkEO not authenticated")
                if ds["critical"]:
                    failed_critical.append(name)
                else:
                    failed_optional.append(name)
                print()
                continue

        try:
            result_file = ds["handler"](client)
        except Exception as e:
            print(f"  ✗ Unexpected error: {e}")
            result_file = None

        if result_file and file_ok(result_file, min_bytes=1000):
            if import_postgis(result_file, ds["table"], db_url):
                imported_tables.append(ds["table"])
            else:
                if ds["critical"]:
                    failed_critical.append(name)
                else:
                    failed_optional.append(name)
        else:
            if ds["critical"]:
                failed_critical.append(name)
            else:
                failed_optional.append(name)

        print()

    # Verify
    if imported_tables:
        verify_tables(db_url, imported_tables)
        print()

    # Summary
    if failed_optional:
        labels = [DATASETS[n]["label"] for n in failed_optional]
        print(f"⚠ Optional datasets skipped: {', '.join(labels)}")

    if failed_critical:
        labels = [DATASETS[n]["label"] for n in failed_critical]
        print(f"✗ Critical datasets failed: {', '.join(labels)}")
        sys.exit(1)

    print("✔ GeoData import complete.")


if __name__ == "__main__":
    main()
