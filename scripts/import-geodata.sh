#!/usr/bin/env bash
# import-geodata.sh — Download and import geodata into PostGIS
#
# All downloads are automated from public open-data sources (no auth required):
#   - CORINE Land Cover 2018: EEA ArcGIS WCS
#   - Soil classification: ISRIC SoilGrids (WRB) via GDAL /vsicurl/
#   - Copernicus DEM GLO-25: AWS Open Data S3
#
# Prerequisites:
#   - gdal-bin (gdalwarp, gdal_translate, gdaldem, gdal_merge.py)
#   - postgis (raster2pgsql)
#   - PostgreSQL client (psql)
#   - PostGIS + postgis_raster extensions enabled in target DB
#
# Usage:
#   make geodata-import          # loads .env via Makefile
#   bash scripts/import-geodata.sh   # or run directly (sources .env itself)

set -euo pipefail

# Load .env safely (line-by-line to handle values with spaces, e.g. PEM keys)
if [ -f .env ]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in \#*|'') continue ;; esac
        export "$line"
    done < .env
fi

DB_URL="${DATABASE_URL:-postgres://funghimap:funghimap_dev@localhost:5432/funghimap_dev}"
DATA_DIR="data/geodata"
# Italy bounding box
BBOX_MIN_LON=6.5
BBOX_MIN_LAT=36.5
BBOX_MAX_LON=18.5
BBOX_MAX_LAT=47.5

echo "=== Funghi Map — GeoData Import ==="
echo ""

mkdir -p "$DATA_DIR"

# ─── Helpers ──────────────────────────────────────────────────────────

fail() { echo "  ✗ $1"; exit 1; }

check_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found. Install with: $2"
}

check_cmd gdalwarp "brew install gdal"
check_cmd gdal_translate "brew install gdal"
check_cmd gdaldem "brew install gdal"
check_cmd raster2pgsql "brew install postgis"
check_cmd psql "brew install libpq"
check_cmd curl "brew install curl"

# ─── 1. CORINE Land Cover (CLC 2018) ────────────────────────────────

CORINE_RAW="$DATA_DIR/corine_italy.tif"
CORINE_4326="$DATA_DIR/corine_italy_4326.tif"

if [ ! -f "$CORINE_RAW" ]; then
    echo "▶ Downloading CORINE Land Cover (CLC 2018)..."

    # Strategy: EEA ArcGIS WCS — public, no auth required.
    # Returns raw CLC classification values (UINT8, codes like 311, 312, 313).
    # We request ~500m effective resolution (2400x2200 px for Italy bbox) which
    # matches the pipeline grid spacing and stays within ArcGIS WCS size limits.
    WCS_BASE="https://image.discomap.eea.europa.eu/arcgis/services/Corine/CLC2018_WM/MapServer/WCSServer"

    # Try known coverage identifiers (varies by ArcGIS config)
    CORINE_OK=0
    for COV_NAME in "1" "CLC2018_WM" "CLC2018" "0"; do
        echo "  Trying WCS coverage=$COV_NAME ..."

        cat > "${DATA_DIR}/_corine_wcs.xml" <<XMLEOF
<WCS_GDAL>
  <ServiceURL>${WCS_BASE}</ServiceURL>
  <CoverageName>${COV_NAME}</CoverageName>
  <Version>1.1.1</Version>
  <Timeout>300</Timeout>
</WCS_GDAL>
XMLEOF

        if gdal_translate -of GTiff \
            -projwin $BBOX_MIN_LON $BBOX_MAX_LAT $BBOX_MAX_LON $BBOX_MIN_LAT \
            -outsize 2400 2200 \
            "${DATA_DIR}/_corine_wcs.xml" \
            "$CORINE_RAW" 2>/dev/null; then
            # Verify it's not an empty/error file (should be > 100KB for Italy)
            FILE_SIZE=$(wc -c < "$CORINE_RAW" | tr -d ' ')
            if [ "$FILE_SIZE" -gt 100000 ]; then
                echo "  ✔ CORINE downloaded via EEA WCS (coverage=$COV_NAME, ${FILE_SIZE} bytes)"
                CORINE_OK=1
                break
            else
                echo "  ⚠ Coverage=$COV_NAME returned too-small file (${FILE_SIZE} bytes), trying next..."
                rm -f "$CORINE_RAW"
            fi
        else
            rm -f "$CORINE_RAW"
        fi
    done
    rm -f "${DATA_DIR}/_corine_wcs.xml"

    # Fallback: try direct WCS GetCoverage request via curl
    if [ "$CORINE_OK" -eq 0 ]; then
        echo "  GDAL WCS failed, trying direct WCS GetCoverage via curl..."
        WCS_GET_URL="${WCS_BASE}?SERVICE=WCS&VERSION=1.1.1&REQUEST=GetCoverage&IDENTIFIER=1&FORMAT=image/tiff&GridBaseCRS=EPSG:4326&BoundingBox=${BBOX_MIN_LON},${BBOX_MIN_LAT},${BBOX_MAX_LON},${BBOX_MAX_LAT},urn:ogc:def:crs:EPSG::4326"

        if curl -sS -f -o "$CORINE_RAW" "$WCS_GET_URL" 2>/dev/null; then
            FILE_SIZE=$(wc -c < "$CORINE_RAW" | tr -d ' ')
            if [ "$FILE_SIZE" -gt 100000 ]; then
                echo "  ✔ CORINE downloaded via direct WCS request (${FILE_SIZE} bytes)"
                CORINE_OK=1
            else
                rm -f "$CORINE_RAW"
            fi
        else
            rm -f "$CORINE_RAW"
        fi
    fi

    if [ "$CORINE_OK" -eq 0 ]; then
        echo ""
        echo "  ✗ Automated CORINE download failed."
        echo ""
        echo "  Please download manually:"
        echo "  1. Go to: https://land.copernicus.eu/en/products/corine-land-cover/clc2018"
        echo "  2. Download the 100m raster GeoTIFF for Europe"
        echo "  3. Clip to Italy bbox:"
        echo "     gdalwarp -te $BBOX_MIN_LON $BBOX_MIN_LAT $BBOX_MAX_LON $BBOX_MAX_LAT -t_srs EPSG:4326 <downloaded_file> $CORINE_RAW"
        echo ""
        exit 1
    fi
else
    echo "✔ CORINE file already present: $CORINE_RAW"
fi

# Reproject to EPSG:4326 if needed
if [ ! -f "$CORINE_4326" ]; then
    echo "▶ Reprojecting CORINE to EPSG:4326..."
    gdalwarp -t_srs EPSG:4326 -r near \
        -te $BBOX_MIN_LON $BBOX_MIN_LAT $BBOX_MAX_LON $BBOX_MAX_LAT \
        "$CORINE_RAW" "$CORINE_4326"
    echo "  ✔ Reprojected: $CORINE_4326"
fi

echo "▶ Importing CORINE into PostGIS..."
raster2pgsql -s 4326 -t 100x100 -I -C -M "$CORINE_4326" corine_landcover | psql "$DB_URL" -q
echo "✔ CORINE Land Cover imported."
echo ""

# ─── 2. Soil Data (ISRIC SoilGrids WRB) ─────────────────────────────
#
# ESDAC requires manual JRC registration — cannot be automated.
# We use ISRIC SoilGrids WRB (World Reference Base) classification instead:
# - 250m resolution, global coverage
# - Open access, no authentication required
# - Returns WRB reference group codes (integers)
#
# NOTE: The pipeline's mapSoilType() must handle WRB codes (see PostGISForestClient.swift)

SOIL_FILE="$DATA_DIR/esdac_soil_italy.tif"

if [ ! -f "$SOIL_FILE" ]; then
    echo "▶ Downloading soil classification via ISRIC SoilGrids..."

    SOIL_OK=0

    # Strategy 1: GDAL /vsicurl/ reading remote VRT → only downloads needed COG tiles
    SOILGRIDS_VRT="/vsicurl/https://files.isric.org/soilgrids/latest/data/wrb/MostProbable.vrt"

    echo "  Trying SoilGrids VRT via GDAL /vsicurl/ ..."
    if gdal_translate -of GTiff \
        -projwin $BBOX_MIN_LON $BBOX_MAX_LAT $BBOX_MAX_LON $BBOX_MIN_LAT \
        "$SOILGRIDS_VRT" \
        "$SOIL_FILE" 2>/dev/null; then
        FILE_SIZE=$(wc -c < "$SOIL_FILE" | tr -d ' ')
        if [ "$FILE_SIZE" -gt 10000 ]; then
            echo "  ✔ Soil data downloaded via SoilGrids VRT (${FILE_SIZE} bytes)"
            SOIL_OK=1
        else
            rm -f "$SOIL_FILE"
        fi
    else
        rm -f "$SOIL_FILE"
    fi

    # Strategy 2: SoilGrids WCS 2.0.1
    if [ "$SOIL_OK" -eq 0 ]; then
        echo "  VRT failed, trying SoilGrids WCS..."
        WCS_SOIL_URL="https://maps.isric.org/mapserv?map=/map/wrb.map&SERVICE=WCS&VERSION=2.0.1&REQUEST=GetCoverage&COVERAGEID=MostProbable&FORMAT=image/tiff&SUBSET=long(${BBOX_MIN_LON},${BBOX_MAX_LON})&SUBSET=lat(${BBOX_MIN_LAT},${BBOX_MAX_LAT})&SUBSETTINGCRS=http://www.opengis.net/def/crs/EPSG/0/4326"

        if curl -sS -f -o "$SOIL_FILE" "$WCS_SOIL_URL" 2>/dev/null; then
            FILE_SIZE=$(wc -c < "$SOIL_FILE" | tr -d ' ')
            if [ "$FILE_SIZE" -gt 10000 ]; then
                echo "  ✔ Soil data downloaded via SoilGrids WCS (${FILE_SIZE} bytes)"
                SOIL_OK=1
            else
                rm -f "$SOIL_FILE"
            fi
        else
            rm -f "$SOIL_FILE"
        fi
    fi

    # Strategy 3: SoilGrids REST API (tile-based COG direct download)
    if [ "$SOIL_OK" -eq 0 ]; then
        echo "  WCS failed, trying SoilGrids COG direct access..."
        SOILGRIDS_COG="/vsicurl/https://files.isric.org/soilgrids/latest/data/wrb/MostProbable/tileSG-017-049.tif"

        # Try downloading a single COG tile covering central Italy as a test
        if gdal_translate -of GTiff \
            -projwin $BBOX_MIN_LON $BBOX_MAX_LAT $BBOX_MAX_LON $BBOX_MIN_LAT \
            "$SOILGRIDS_COG" \
            "$SOIL_FILE" 2>/dev/null; then
            FILE_SIZE=$(wc -c < "$SOIL_FILE" | tr -d ' ')
            if [ "$FILE_SIZE" -gt 10000 ]; then
                echo "  ✔ Soil data downloaded via SoilGrids COG (${FILE_SIZE} bytes)"
                SOIL_OK=1
            else
                rm -f "$SOIL_FILE"
            fi
        else
            rm -f "$SOIL_FILE"
        fi
    fi

    if [ "$SOIL_OK" -eq 0 ]; then
        echo ""
        echo "  ✗ Automated soil download failed."
        echo ""
        echo "  Please download manually from one of:"
        echo "  Option A — ISRIC SoilGrids (open, no registration):"
        echo "    https://soilgrids.org → download WRB classification for Italy"
        echo "  Option B — ESDAC (requires free JRC registration):"
        echo "    https://esdac.jrc.ec.europa.eu/content/european-soil-database-derived-data"
        echo "  Then place at: $SOIL_FILE"
        echo ""
        exit 1
    fi
else
    echo "✔ Soil file already present: $SOIL_FILE"
fi

echo "▶ Importing soil data into PostGIS..."
raster2pgsql -s 4326 -t 100x100 -I -C -M "$SOIL_FILE" esdac_soil | psql "$DB_URL" -q
echo "✔ Soil data imported."
echo ""

# ─── 3. Copernicus DEM (Altitude) ─────────────────────────────────────
# Source: AWS Open Data — s3://copernicus-dem-25m/ (public, no auth)

DEM_FILE="$DATA_DIR/copernicus_dem_italy.tif"

if [ ! -f "$DEM_FILE" ]; then
    echo "▶ Downloading Copernicus DEM GLO-25 tiles for Italy..."

    DEM_TILES_DIR="$DATA_DIR/dem_tiles"
    mkdir -p "$DEM_TILES_DIR"

    TILE_COUNT=0
    TILE_FAIL=0

    # Download 1-degree tiles covering Italy bbox (N36-N47, E006-E018)
    for lat in $(seq 36 47); do
        for lon in $(seq 6 18); do
            TILE_LAT=$(printf "N%02d" "$lat")
            TILE_LON=$(printf "E%03d" "$lon")
            TILE_NAME="Copernicus_DSM_COG_10_${TILE_LAT}_00_${TILE_LON}_00_DEM"
            TILE_URL="https://copernicus-dem-25m.s3.eu-central-1.amazonaws.com/${TILE_NAME}/${TILE_NAME}.tif"
            TILE_PATH="$DEM_TILES_DIR/${TILE_NAME}.tif"

            if [ ! -f "$TILE_PATH" ]; then
                if curl -sS -f -o "$TILE_PATH" "$TILE_URL" 2>/dev/null; then
                    TILE_COUNT=$((TILE_COUNT + 1))
                else
                    # Ocean tiles or tiles without data are expected to 404
                    rm -f "$TILE_PATH"
                    TILE_FAIL=$((TILE_FAIL + 1))
                fi
            else
                TILE_COUNT=$((TILE_COUNT + 1))
            fi
        done
    done
    echo "  Downloaded $TILE_COUNT tiles ($TILE_FAIL skipped — ocean/no data)"

    # Merge all tiles into a single GeoTIFF clipped to Italy bbox
    echo "▶ Merging DEM tiles and clipping to Italy bbox..."
    TILE_LIST=$(find "$DEM_TILES_DIR" -name "*.tif" -type f 2>/dev/null)
    if [ -z "$TILE_LIST" ]; then
        fail "No DEM tiles found. Check network connectivity."
    fi
    # shellcheck disable=SC2086
    gdal_merge.py -o "$DATA_DIR/dem_merged.tif" $TILE_LIST -q
    gdalwarp -t_srs EPSG:4326 \
        -te $BBOX_MIN_LON $BBOX_MIN_LAT $BBOX_MAX_LON $BBOX_MAX_LAT \
        -r bilinear \
        "$DATA_DIR/dem_merged.tif" "$DEM_FILE"
    rm -f "$DATA_DIR/dem_merged.tif"
    echo "  ✔ Copernicus DEM merged: $DEM_FILE"
else
    echo "✔ Copernicus DEM file already present: $DEM_FILE"
fi

# Generate aspect raster from DEM
DEM_ASPECT="$DATA_DIR/dem_aspect_italy.tif"
if [ ! -f "$DEM_ASPECT" ]; then
    echo "▶ Computing aspect raster from DEM..."
    gdaldem aspect "$DEM_FILE" "$DEM_ASPECT" -of GTiff -b 1 -zero_for_flat
    echo "  ✔ Aspect raster generated: $DEM_ASPECT"
else
    echo "✔ Aspect raster already present: $DEM_ASPECT"
fi

echo "▶ Importing Copernicus DEM into PostGIS..."
raster2pgsql -s 4326 -t 100x100 -I -C -M "$DEM_FILE" copernicus_dem | psql "$DB_URL" -q
echo "✔ Copernicus DEM imported."

echo "▶ Importing aspect raster into PostGIS..."
raster2pgsql -s 4326 -t 100x100 -I -C -M "$DEM_ASPECT" dem_aspect | psql "$DB_URL" -q
echo "✔ Aspect raster imported."
echo ""

# ─── 4. Verify ─────────────────────────────────────────────────────────

echo "▶ Verifying raster tables..."
psql "$DB_URL" -c "SELECT 'corine_landcover' AS table_name, count(*) AS tiles FROM corine_landcover;"
psql "$DB_URL" -c "SELECT 'esdac_soil' AS table_name, count(*) AS tiles FROM esdac_soil;"
psql "$DB_URL" -c "SELECT 'copernicus_dem' AS table_name, count(*) AS tiles FROM copernicus_dem;"
psql "$DB_URL" -c "SELECT 'dem_aspect' AS table_name, count(*) AS tiles FROM dem_aspect;"

echo ""
echo "=== GeoData import complete ==="
