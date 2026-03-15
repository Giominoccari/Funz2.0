#!/usr/bin/env bash
# import-geodata.sh — Download and import geodata into PostGIS
#
# Data sources:
#   - CORINE Land Cover 2018:       CLMS Download API (requires service key)
#   - Tree Cover Density 2018:      CLMS Download API
#   - Dominant Leaf Type 2018:       CLMS Download API
#   - Soil classification:          ISRIC SoilGrids (WRB) via GDAL /vsicurl/
#   - Copernicus DEM GLO-25:        AWS Open Data S3 (public, no auth)
#
# Prerequisites:
#   - gdal-bin (gdalwarp, gdal_translate, gdaldem, gdal_merge.py)
#   - postgis (raster2pgsql)
#   - PostgreSQL client (psql)
#   - PostGIS + postgis_raster extensions enabled in target DB
#   - openssl (for JWT signing — pre-installed on macOS)
#   - jq (for JSON parsing)
#
# CLMS authentication:
#   1. Create free EU Login at https://land.copernicus.eu
#   2. Profile → API Tokens → Create → download service key JSON
#   3. Set in .env: CLMS_SERVICE_KEY_FILE=path/to/your-service-key.json
#   Docs: https://eea.github.io/clms-api-docs/authentication.html
#
# Usage:
#   make geodata-import
#   bash scripts/import-geodata.sh

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
# Italy bounding box (EPSG:4326)
BBOX_MIN_LON=6.5
BBOX_MIN_LAT=36.5
BBOX_MAX_LON=18.5
BBOX_MAX_LAT=47.5

echo "=== Funghi Map — GeoData Import ==="
echo ""

mkdir -p "$DATA_DIR"
CLMS_TASKS_DIR="${DATA_DIR}/.clms_tasks"
mkdir -p "$CLMS_TASKS_DIR"

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
check_cmd openssl "brew install openssl"
check_cmd jq "brew install jq"

# ─── CLMS Authentication ─────────────────────────────────────────────
#
# Reads the service key JSON, signs a JWT with RS256, exchanges it for
# a bearer token valid ~1 hour.

CLMS_TOKEN=""

clms_authenticate() {
    local key_file="${CLMS_SERVICE_KEY_FILE:-}"
    if [ -z "$key_file" ] || [ ! -f "$key_file" ]; then
        echo "  ⚠ CLMS_SERVICE_KEY_FILE not set or file not found."
        echo "    Set CLMS_SERVICE_KEY_FILE in .env pointing to your service key JSON."
        echo "    Get one at: https://land.copernicus.eu → Profile → API Tokens → Create"
        return 1
    fi

    echo "  Authenticating with CLMS API..."

    # Extract fields from service key JSON
    local client_id user_id token_uri private_key
    client_id=$(jq -r '.client_id' "$key_file")
    user_id=$(jq -r '.user_id' "$key_file")
    token_uri=$(jq -r '.token_uri' "$key_file")
    private_key=$(jq -r '.private_key' "$key_file")

    if [ -z "$client_id" ] || [ "$client_id" = "null" ]; then
        echo "  ⚠ Invalid service key JSON: missing client_id"
        return 1
    fi

    # Write private key to temp file for openssl
    local pem_file
    pem_file=$(mktemp)
    echo "$private_key" > "$pem_file"

    # Build JWT (RS256)
    local now exp header payload sig jwt_token
    now=$(date +%s)
    exp=$((now + 3600))

    # Base64url encode helper (no padding, URL-safe)
    b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }

    header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | b64url)
    payload=$(echo -n "{\"iss\":\"${client_id}\",\"sub\":\"${user_id}\",\"aud\":\"${token_uri}\",\"iat\":${now},\"exp\":${exp}}" | b64url)
    sig=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign "$pem_file" | b64url)
    rm -f "$pem_file"

    jwt_token="${header}.${payload}.${sig}"

    # Exchange JWT for bearer token
    local response http_code body
    response=$(curl -sS -w "\n%{http_code}" \
        -X POST "$token_uri" \
        -H "Accept: application/json" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "assertion=${jwt_token}" 2>&1) || true

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        CLMS_TOKEN=$(echo "$body" | jq -r '.access_token')
        if [ -n "$CLMS_TOKEN" ] && [ "$CLMS_TOKEN" != "null" ]; then
            echo "  ✔ CLMS authenticated (token valid ~1h)"
            return 0
        fi
    fi

    echo "  ⚠ CLMS authentication failed (HTTP $http_code)"
    echo "  Response: $body"
    return 1
}

# ─── CLMS Dataset Info Discovery ─────────────────────────────────────
#
# Queries the CLMS API to discover the native format of a dataset and
# available projections, so we can use compatible values in download requests.

# Globals set by clms_discover_format:
CLMS_OUTPUT_FORMAT=""
CLMS_OUTPUT_GCS=""
CLMS_DISCOVERED_DOWNLOAD_ID=""

clms_discover_format() {
    local dataset_id="$1"
    local download_info_id="$2"
    local label="$3"

    if [ -z "$CLMS_TOKEN" ]; then return 1; fi

    local api_base="https://land.copernicus.eu"

    # 1. Query dataset metadata to find native format
    echo "  Discovering native format for $label..."
    local ds_resp
    ds_resp=$(curl -sS \
        "${api_base}/api/@search?portal_type=DataSet&UID=${dataset_id}&metadata_fields=dataset_download_information" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true

    # Print all download info entries for debugging
    echo "  ── DEBUG: All download info entries:"
    echo "$ds_resp" | jq -r '.items[0]?.dataset_download_information.items[]? | "       [\(.["@id"])] name=\(.name) format=\(.full_format)"' 2>/dev/null || \
    echo "$ds_resp" | jq -r '.items[0]?.dataset_download_information[]? | "       [\(.["@id"])] name=\(.name) format=\(.full_format)"' 2>/dev/null || \
    echo "       (could not parse entries)"

    # Look for a RASTER entry — prefer raster over vector for GeoTIFF output
    local raster_id raster_format
    raster_id=$(echo "$ds_resp" | jq -r \
        '.items[0]?.dataset_download_information.items[]? | select(.name == "RASTER") | .["@id"]' 2>/dev/null | head -1)
    raster_format=$(echo "$ds_resp" | jq -r \
        '.items[0]?.dataset_download_information.items[]? | select(.name == "RASTER") | .full_format' 2>/dev/null | head -1)

    # Fallback: try without .items wrapper
    if [ -z "$raster_id" ] || [ "$raster_id" = "null" ]; then
        raster_id=$(echo "$ds_resp" | jq -r \
            '.items[0]?.dataset_download_information[]? | select(.name == "RASTER") | .["@id"]' 2>/dev/null | head -1)
        raster_format=$(echo "$ds_resp" | jq -r \
            '.items[0]?.dataset_download_information[]? | select(.name == "RASTER") | .full_format' 2>/dev/null | head -1)
    fi

    if [ -n "$raster_id" ] && [ "$raster_id" != "null" ]; then
        echo "  Found RASTER entry: id=${raster_id}, format=${raster_format}"
        # Override the download_info_id to use the raster version
        CLMS_DISCOVERED_DOWNLOAD_ID="$raster_id"
        native_format="$raster_format"
    else
        echo "  No RASTER entry found, using provided download info ID"
        CLMS_DISCOVERED_DOWNLOAD_ID=""
        # Extract format for the provided download_info_id
        local native_format
        native_format=$(echo "$ds_resp" | jq -r \
            ".items[0]?.dataset_download_information.items[]? | select(.\"@id\" == \"${download_info_id}\") | .full_format // empty" 2>/dev/null | head -1)
        if [ -z "$native_format" ] || [ "$native_format" = "null" ]; then
            native_format=$(echo "$ds_resp" | jq -r \
                ".items[0]?.dataset_download_information[]? | select(.\"@id\" == \"${download_info_id}\") | .full_format // empty" 2>/dev/null | head -1)
        fi
    fi

    local native_format="${native_format:-}"
    echo "  Native format: ${native_format:-unknown}"

    # 2. Query the format conversion table to find compatible output formats
    echo "  Querying format conversion table..."
    local conv_resp
    conv_resp=$(curl -sS \
        "${api_base}/api/@format_conversion_table" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true

    echo "  ── DEBUG: Conversion table response (first 500 chars):"
    echo "$conv_resp" | head -c 500 | sed 's/^/       /'
    echo ""

    # Find what output formats are compatible with the native format
    if [ -n "$native_format" ] && [ "$native_format" != "null" ]; then
        local compatible
        compatible=$(echo "$conv_resp" | jq -r \
            ".[\"${native_format}\"]? // {} | to_entries[] | select(.value == true) | .key" 2>/dev/null)
        echo "  Compatible output formats for '${native_format}': ${compatible:-none found}"

        # Prefer Geotiff, fall back to native format
        if echo "$compatible" | grep -q "Geotiff"; then
            CLMS_OUTPUT_FORMAT="Geotiff"
        elif [ -n "$compatible" ]; then
            CLMS_OUTPUT_FORMAT=$(echo "$compatible" | head -1)
        else
            CLMS_OUTPUT_FORMAT="$native_format"
        fi
    else
        CLMS_OUTPUT_FORMAT="Geotiff"
    fi

    # 3. Query available projections
    echo "  Querying available projections..."
    local proj_resp
    proj_resp=$(curl -sS \
        "${api_base}/api/@projections?uid=${dataset_id}" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true

    echo "  ── DEBUG: Projections response:"
    echo "$proj_resp" | sed 's/^/       /'

    # Prefer EPSG:4326, fall back to EPSG:3035
    if echo "$proj_resp" | jq -e '.. | select(. == "EPSG:4326")' >/dev/null 2>&1; then
        CLMS_OUTPUT_GCS="EPSG:4326"
    elif echo "$proj_resp" | jq -e '.. | select(. == "EPSG:3035")' >/dev/null 2>&1; then
        CLMS_OUTPUT_GCS="EPSG:3035"
    else
        # Use first available
        CLMS_OUTPUT_GCS=$(echo "$proj_resp" | jq -r '.. | strings | select(startswith("EPSG:"))' 2>/dev/null | head -1)
        if [ -z "$CLMS_OUTPUT_GCS" ]; then
            CLMS_OUTPUT_GCS="EPSG:4326"
        fi
    fi

    echo "  → Will use: OutputFormat=${CLMS_OUTPUT_FORMAT}, OutputGCS=${CLMS_OUTPUT_GCS}"
    echo ""
}

# ─── CLMS Download Helper ────────────────────────────────────────────
#
# Submits a download request, polls until ready, downloads the file.
# Args: dataset_id download_info_id output_file label [bbox_override]
# Requires: CLMS_OUTPUT_FORMAT and CLMS_OUTPUT_GCS to be set (via clms_discover_format)

# Submit a CLMS download request (or resume a saved task).
# Sets CLMS_SUBMITTED_TASK_ID and CLMS_SUBMITTED_TASK_FILE on success.
# Args: dataset_id download_info_id label bbox_value
clms_submit() {
    local dataset_id="$1"
    local download_info_id="$2"
    local label="$3"
    local bbox_value="$4"

    # Use discovered raster download ID if available (from clms_discover_format)
    if [ -n "${CLMS_DISCOVERED_DOWNLOAD_ID:-}" ]; then
        download_info_id="$CLMS_DISCOVERED_DOWNLOAD_ID"
    fi

    local api_base="https://land.copernicus.eu"
    local api_endpoint="${api_base}/api/@datarequest_post"
    local out_format="${CLMS_OUTPUT_FORMAT:-Geotiff}"
    local out_gcs="${CLMS_OUTPUT_GCS:-EPSG:4326}"

    # Task persistence: compute a key to save/resume task IDs across runs
    local task_key
    task_key=$(echo "${dataset_id}:${download_info_id}:${bbox_value}" | md5sum | cut -d' ' -f1)
    local task_file="${CLMS_TASKS_DIR}/${task_key}.taskid"

    local task_id=""

    # Check for a saved task from a previous run
    if [ -f "$task_file" ]; then
        task_id=$(cat "$task_file")
        if [ -n "$task_id" ]; then
            echo "  Resuming previous task $task_id for $label..."
            CLMS_SUBMITTED_TASK_ID="$task_id"
            CLMS_SUBMITTED_TASK_FILE="$task_file"
            return 0
        fi
    fi

    local request_body
    request_body=$(cat <<REQEOF
{
  "Datasets": [{
    "DatasetID": "${dataset_id}",
    "DatasetDownloadInformationID": "${download_info_id}",
    "BoundingBox": [${bbox_value}],
    "OutputFormat": "${out_format}",
    "OutputGCS": "${out_gcs}"
  }]
}
REQEOF
)

    echo "  Submitting download request for $label..."
    echo "  ── DEBUG: POST ${api_endpoint}"
    echo "  ── DEBUG: Headers:"
    echo "       Content-Type: application/json"
    echo "       Authorization: Bearer ${CLMS_TOKEN:0:20}...${CLMS_TOKEN: -10}"
    echo "  ── DEBUG: Request body:"
    echo "$request_body" | sed 's/^/       /'
    echo "  ──"

    local response http_code body
    response=$(curl -sS -w "\n%{http_code}" \
        -X POST "${api_endpoint}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${CLMS_TOKEN}" \
        --data "$request_body" 2>&1) || true

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    echo "  ── DEBUG: Response HTTP $http_code"
    echo "  ── DEBUG: Response body:"
    echo "$body" | sed 's/^/       /'
    echo "  ──"

    # Handle HTTP 400 "duplicate" — no saved task to resume
    if [ "$http_code" = "400" ] && echo "$body" | grep -qi "duplicate"; then
        echo "  ⚠ CLMS says duplicate request for $label"
        echo "  No saved task ID to resume — clear duplicates at https://land.copernicus.eu"
        echo "  Or delete ${CLMS_TASKS_DIR}/ and retry after tasks expire."
        return 1
    fi

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        echo "  ⚠ CLMS request failed for $label (HTTP $http_code)"
        return 1
    fi

    # Extract TaskID
    task_id=$(echo "$body" | jq -r '.TaskIds[0].TaskID // empty')
    if [ -z "$task_id" ]; then
        task_id=$(echo "$body" | jq -r '.TaskID // empty')
    fi

    if [ -z "$task_id" ]; then
        echo "  ⚠ No TaskID in response for $label"
        echo "  Response: $body"
        return 1
    fi

    # Persist task ID for resume on re-run
    echo "$task_id" > "$task_file"

    CLMS_SUBMITTED_TASK_ID="$task_id"
    CLMS_SUBMITTED_TASK_FILE="$task_file"
    echo "  Task submitted: $task_id"
    return 0
}

# Poll a CLMS task until ready, then download the file.
# Args: task_id task_file output_file label
clms_poll_and_download() {
    local task_id="$1"
    local task_file="$2"
    local output_file="$3"
    local label="$4"

    local api_base="https://land.copernicus.eu"

    echo "  Polling task $task_id for $label..."

    # Poll for completion (max ~180 minutes)
    local poll_max=1080
    local download_url=""
    for i in $(seq 1 $poll_max); do
        sleep 10
        local status_resp
        status_resp=$(curl -sS \
            "${api_base}/api/@datarequest_search?TaskID=${task_id}" \
            -H "Accept: application/json" \
            -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true

        # Check for download URL
        download_url=$(echo "$status_resp" | jq -r '
            .. | .DownloadURL? // empty | select(. != "" and . != "null")
        ' 2>/dev/null | head -1)

        if [ -n "$download_url" ]; then
            break
        fi

        # Check for failure
        local status
        status=$(echo "$status_resp" | jq -r '.. | .Status? // empty' 2>/dev/null | head -1)
        if [ "$status" = "Failed" ] || [ "$status" = "Rejected" ]; then
            echo ""
            echo "  ⚠ CLMS task failed for $label: $status_resp"
            rm -f "$task_file"
            return 1
        fi

        printf "  [%s] Poll %d/%d (status: %s)...\r" "$label" "$i" "$poll_max" "${status:-pending}"
    done
    echo "" # clear progress line

    if [ -z "$download_url" ]; then
        echo "  ⚠ Timed out waiting for $label download (task: $task_id)"
        echo "  Task saved — re-run to resume polling."
        return 1
    fi

    echo "  Downloading $label..."
    if curl -sS -f -L -o "$output_file" "$download_url" \
        -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1; then
        local file_size
        file_size=$(wc -c < "$output_file" | tr -d ' ')
        if [ "$file_size" -gt 100000 ]; then
            echo "  ✔ $label downloaded (${file_size} bytes)"
            rm -f "$task_file"
            return 0
        else
            echo "  ⚠ $label file too small (${file_size} bytes)"
            rm -f "$output_file"
            return 1
        fi
    else
        echo "  ⚠ Download failed for $label"
        rm -f "$output_file"
        return 1
    fi
}

# Legacy wrapper: submit + poll + download in one call (used for non-chunked downloads)
# Args: dataset_id download_info_id output_file label [bbox_override]
clms_download() {
    local dataset_id="$1"
    local download_info_id="$2"
    local output_file="$3"
    local label="$4"
    local bbox_override="${5:-}"

    if [ -z "$CLMS_TOKEN" ]; then
        echo "  ⚠ No CLMS token — skipping $label"
        return 1
    fi

    local bbox_value
    if [ -n "$bbox_override" ]; then
        bbox_value="$bbox_override"
    else
        bbox_value="${BBOX_MAX_LAT}, ${BBOX_MAX_LON}, ${BBOX_MIN_LAT}, ${BBOX_MIN_LON}"
    fi

    if ! clms_submit "$dataset_id" "$download_info_id" "$label" "$bbox_value"; then
        return 1
    fi

    clms_poll_and_download "$CLMS_SUBMITTED_TASK_ID" "$CLMS_SUBMITTED_TASK_FILE" "$output_file" "$label"
}

# ─── CLMS Chunked Download ───────────────────────────────────────────
#
# Splits Italy bbox into 4 quadrants to stay under the CLMS 1.6T limit,
# downloads each chunk, then merges with gdal_merge.py.
# Args: dataset_id download_info_id output_file label

clms_download_chunked() {
    local dataset_id="$1"
    local download_info_id="$2"
    local output_file="$3"
    local label="$4"

    if [ -z "$CLMS_TOKEN" ]; then
        echo "  ⚠ No CLMS token — skipping $label"
        return 1
    fi

    # Discover valid format and projection for this dataset
    clms_discover_format "$dataset_id" "$download_info_id" "$label"

    local mid_lon mid_lat
    mid_lon=$(echo "scale=1; ($BBOX_MIN_LON + $BBOX_MAX_LON) / 2" | bc)
    mid_lat=$(echo "scale=1; ($BBOX_MIN_LAT + $BBOX_MAX_LAT) / 2" | bc)

    echo "  Splitting bbox into 4 quadrants (mid: ${mid_lon}, ${mid_lat})..."
    echo "    Q1: SW [${BBOX_MIN_LAT}-${mid_lat}, ${BBOX_MIN_LON}-${mid_lon}]"
    echo "    Q2: SE [${BBOX_MIN_LAT}-${mid_lat}, ${mid_lon}-${BBOX_MAX_LON}]"
    echo "    Q3: NW [${mid_lat}-${BBOX_MAX_LAT}, ${BBOX_MIN_LON}-${mid_lon}]"
    echo "    Q4: NE [${mid_lat}-${BBOX_MAX_LAT}, ${mid_lon}-${BBOX_MAX_LON}]"

    local chunks_dir="${DATA_DIR}/clms_chunks_$$"
    mkdir -p "$chunks_dir"

    # bbox format: "north, east, south, west"
    local -a quadrants=(
        "${mid_lat}, ${mid_lon}, ${BBOX_MIN_LAT}, ${BBOX_MIN_LON}"   # SW
        "${mid_lat}, ${BBOX_MAX_LON}, ${BBOX_MIN_LAT}, ${mid_lon}"   # SE
        "${BBOX_MAX_LAT}, ${mid_lon}, ${mid_lat}, ${BBOX_MIN_LON}"   # NW
        "${BBOX_MAX_LAT}, ${BBOX_MAX_LON}, ${mid_lat}, ${mid_lon}"   # NE
    )
    local -a quad_names=("SW" "SE" "NW" "NE")

    # ── Phase 1: Submit all 4 chunks ──
    echo ""
    echo "  ── Phase 1: Submitting all 4 chunks ──"

    local -a task_ids=()
    local -a task_files=()
    local -a chunk_file_paths=()
    local submit_ok=0

    for qi in 0 1 2 3; do
        local qname="${quad_names[$qi]}"
        local chunk_file="${chunks_dir}/chunk_${qname}.tif"
        chunk_file_paths+=("$chunk_file")

        echo ""
        echo "  ── Submit ${qname} ($(( qi + 1 ))/4) ──"

        # Delay between requests to avoid HTTP 429 rate limiting
        if [ "$qi" -gt 0 ]; then
            echo "  (waiting 15s to avoid rate limiting...)"
            sleep 15
        fi

        if clms_submit "$dataset_id" "$download_info_id" "${label} (${qname})" "${quadrants[$qi]}"; then
            task_ids+=("$CLMS_SUBMITTED_TASK_ID")
            task_files+=("$CLMS_SUBMITTED_TASK_FILE")
            submit_ok=$((submit_ok + 1))
        else
            task_ids+=("")
            task_files+=("")
            echo "  ⚠ Submit failed for chunk ${qname}"
        fi
    done

    echo ""
    echo "  Submitted ${submit_ok}/4 chunks"

    if [ "$submit_ok" -eq 0 ]; then
        rm -rf "$chunks_dir"
        echo "  ✗ All submissions failed for $label"
        return 1
    fi

    # ── Phase 2: Poll all tasks in parallel, then download ──
    echo ""
    echo "  ── Phase 2: Polling all tasks in parallel (~180 min max) ──"

    local poll_max=1080   # 1080 × 10s = ~180 minutes
    local api_base="https://land.copernicus.eu"
    local -a download_urls=("" "" "" "")
    local -a chunk_status=("pending" "pending" "pending" "pending")
    local completed=0

    # Mark already-failed submissions as done
    for qi in 0 1 2 3; do
        if [ -z "${task_ids[$qi]}" ]; then
            chunk_status[$qi]="failed"
            completed=$((completed + 1))
        fi
    done

    for poll_i in $(seq 1 $poll_max); do
        if [ "$completed" -ge 4 ]; then
            break
        fi

        sleep 10

        for qi in 0 1 2 3; do
            # Skip already completed/failed chunks
            if [ "${chunk_status[$qi]}" != "pending" ]; then
                continue
            fi

            local tid="${task_ids[$qi]}"
            local status_resp
            status_resp=$(curl -sS \
                "${api_base}/api/@datarequest_search?TaskID=${tid}" \
                -H "Accept: application/json" \
                -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true

            # Check for download URL
            local dl_url
            dl_url=$(echo "$status_resp" | jq -r '
                .. | .DownloadURL? // empty | select(. != "" and . != "null")
            ' 2>/dev/null | head -1)

            if [ -n "$dl_url" ]; then
                download_urls[$qi]="$dl_url"
                chunk_status[$qi]="ready"
                completed=$((completed + 1))
                echo "  ✔ ${quad_names[$qi]} ready for download (poll $poll_i)"
                continue
            fi

            # Check for failure
            local status
            status=$(echo "$status_resp" | jq -r '.. | .Status? // empty' 2>/dev/null | head -1)
            if [ "$status" = "Failed" ] || [ "$status" = "Rejected" ]; then
                chunk_status[$qi]="failed"
                completed=$((completed + 1))
                rm -f "${task_files[$qi]}"
                echo "  ⚠ ${quad_names[$qi]} task failed ($status)"
                continue
            fi
        done

        # Show combined progress
        local progress=""
        for qi in 0 1 2 3; do
            progress+="${quad_names[$qi]}:${chunk_status[$qi]} "
        done
        printf "  Poll %d/%d [%s]\r" "$poll_i" "$poll_max" "$progress"
    done
    echo "" # clear progress line

    # ── Phase 3: Download ready chunks ──
    echo ""
    echo "  ── Phase 3: Downloading ready chunks ──"

    local chunk_files=()
    local chunk_ok=0

    for qi in 0 1 2 3; do
        local qname="${quad_names[$qi]}"
        local chunk_file="${chunk_file_paths[$qi]}"

        if [ "${chunk_status[$qi]}" = "ready" ]; then
            echo "  Downloading ${qname}..."
            if curl -sS -f -L -o "$chunk_file" "${download_urls[$qi]}" \
                -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1; then
                local file_size
                file_size=$(wc -c < "$chunk_file" | tr -d ' ')
                if [ "$file_size" -gt 100000 ]; then
                    echo "  ✔ ${qname} downloaded (${file_size} bytes)"
                    chunk_files+=("$chunk_file")
                    chunk_ok=$((chunk_ok + 1))
                    rm -f "${task_files[$qi]}"
                else
                    echo "  ⚠ ${qname} file too small (${file_size} bytes)"
                    rm -f "$chunk_file"
                fi
            else
                echo "  ⚠ ${qname} download failed"
                rm -f "$chunk_file"
            fi
        elif [ "${chunk_status[$qi]}" = "pending" ]; then
            echo "  ⚠ ${qname} timed out (task: ${task_ids[$qi]}) — saved for resume"
        else
            echo "  ⚠ ${qname} failed"
        fi
    done

    echo ""
    echo "  Downloaded ${chunk_ok}/4 chunks"

    if [ "$chunk_ok" -eq 0 ]; then
        rm -rf "$chunks_dir"
        echo "  ✗ All chunks failed for $label"
        return 1
    fi

    # Merge chunks
    echo "  Merging ${chunk_ok} chunks into ${output_file}..."
    gdal_merge.py -o "$output_file" "${chunk_files[@]}" -q
    rm -rf "$chunks_dir"

    local file_size
    file_size=$(wc -c < "$output_file" | tr -d ' ')
    if [ "$file_size" -gt 100000 ]; then
        echo "  ✔ $label merged (${file_size} bytes)"
        return 0
    else
        echo "  ⚠ Merged file too small (${file_size} bytes)"
        rm -f "$output_file"
        return 1
    fi
}

# ─── Authenticate with CLMS ──────────────────────────────────────────

echo "▶ CLMS Authentication"
if ! clms_authenticate; then
    echo ""
    echo "  CLMS datasets (CORINE, Tree Cover, Leaf Type) require authentication."
    echo "  Setup:"
    echo "    1. Create free EU Login at: https://land.copernicus.eu"
    echo "    2. Profile → API Tokens → Create → download the JSON key file"
    echo "    3. Add to .env: CLMS_SERVICE_KEY_FILE=path/to/key.json"
    echo ""
    echo "  Continuing with non-CLMS datasets (DEM, Soil)..."
fi
echo ""

# ─── 1. CORINE Land Cover (CLC 2018) ────────────────────────────────
# CLC classification codes (311=broadleaf, 312=coniferous, 313=mixed)
# Used by ScoringEngine via PostGISForestClient.mapCORINEToForestType()

CORINE_RAW="$DATA_DIR/corine_italy.tif"
CORINE_4326="$DATA_DIR/corine_italy_4326.tif"

# CLMS dataset identifiers (from API docs)
CLC_DATASET_ID="0407d497d3c44bcd93ce8fd5bf78596a"
CLC_DOWNLOAD_ID="1bda2fbd-3230-42ba-98cf-69c96ac063bc"

if [ ! -f "$CORINE_RAW" ]; then
    echo "▶ Downloading CORINE Land Cover (CLC 2018)..."

    if ! clms_download_chunked "$CLC_DATASET_ID" "$CLC_DOWNLOAD_ID" "$CORINE_RAW" "CORINE CLC 2018"; then
        echo ""
        echo "  ✗ CORINE download failed."
        echo ""
        echo "  Manual fallback:"
        echo "    1. Go to: https://land.copernicus.eu/en/products/corine-land-cover/clc2018"
        echo "    2. Download: u2018_clc2018_v2020_20u1_raster100m.zip (~1GB)"
        echo "    3. Extract and clip:"
        echo "       gdalwarp -te $BBOX_MIN_LON $BBOX_MIN_LAT $BBOX_MAX_LON $BBOX_MAX_LAT -t_srs EPSG:4326 U2018_CLC2018_V2020_20u1.tif $CORINE_RAW"
        echo "    4. Re-run: make geodata-import"
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

# ─── 2. Tree Cover Density (HRL 2018) ───────────────────────────────
# 10m resolution, values 0-100 (percentage tree cover)
# Useful for scoring: higher density = better mushroom habitat

TCD_FILE="$DATA_DIR/tree_cover_density_italy.tif"
TCD_4326="$DATA_DIR/tree_cover_density_italy_4326.tif"

# CLMS dataset identifiers for Tree Cover Density 2018
# These IDs are discovered via the CLMS @search API — update if needed
TCD_DATASET_ID="d50a2fe4-3de0-47b3-8474-3b218ab133e0"
TCD_DOWNLOAD_ID=""  # Will be discovered at runtime

if [ ! -f "$TCD_FILE" ]; then
    echo "▶ Downloading Tree Cover Density (HRL 2018)..."

    # If we don't have a hardcoded download ID, try to discover it
    if [ -z "$TCD_DOWNLOAD_ID" ] && [ -n "$CLMS_TOKEN" ]; then
        echo "  Discovering download info for Tree Cover Density..."
        local_resp=$(curl -sS \
            "https://land.copernicus.eu/api/@search?portal_type=DataSet&SearchableText=tree+cover+density+2018&metadata_fields=UID&metadata_fields=dataset_download_information&b_size=10" \
            -H "Accept: application/json" \
            -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true
        echo "  Catalog search response: $(echo "$local_resp" | head -c 500)"

        # Try to extract dataset UID and download info
        TCD_DATASET_ID_FOUND=$(echo "$local_resp" | jq -r '.items[]? | select(.title? | test("Tree Cover Density.*2018"; "i")) | .UID' 2>/dev/null | head -1)
        if [ -n "$TCD_DATASET_ID_FOUND" ] && [ "$TCD_DATASET_ID_FOUND" != "null" ]; then
            TCD_DATASET_ID="$TCD_DATASET_ID_FOUND"
            echo "  Found dataset UID: $TCD_DATASET_ID"

            # Get download information for this dataset
            ds_resp=$(curl -sS \
                "https://land.copernicus.eu/api/@search?portal_type=DataSet&UID=${TCD_DATASET_ID}&metadata_fields=dataset_download_information" \
                -H "Accept: application/json" \
                -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true

            TCD_DOWNLOAD_ID=$(echo "$ds_resp" | jq -r '.items[0]?.dataset_download_information[]? | select(.full_format? | test("raster|tif"; "i")) | .id' 2>/dev/null | head -1)
            if [ -n "$TCD_DOWNLOAD_ID" ] && [ "$TCD_DOWNLOAD_ID" != "null" ]; then
                echo "  Found download info ID: $TCD_DOWNLOAD_ID"
            fi
        fi
    fi

    if [ -n "$TCD_DOWNLOAD_ID" ] && [ -n "$TCD_DATASET_ID" ]; then
        if ! clms_download_chunked "$TCD_DATASET_ID" "$TCD_DOWNLOAD_ID" "$TCD_FILE" "Tree Cover Density 2018"; then
            echo "  ⚠ Tree Cover Density download failed — skipping (non-critical)"
        fi
    else
        echo "  ⚠ Could not discover Tree Cover Density dataset IDs — skipping"
        echo "  (This is non-critical; CLC forest data is sufficient for scoring)"
    fi
else
    echo "✔ Tree Cover Density file already present: $TCD_FILE"
fi

if [ -f "$TCD_FILE" ]; then
    if [ ! -f "$TCD_4326" ]; then
        echo "▶ Reprojecting Tree Cover Density to EPSG:4326..."
        gdalwarp -t_srs EPSG:4326 -r bilinear \
            -te $BBOX_MIN_LON $BBOX_MIN_LAT $BBOX_MAX_LON $BBOX_MAX_LAT \
            "$TCD_FILE" "$TCD_4326"
        echo "  ✔ Reprojected: $TCD_4326"
    fi

    echo "▶ Importing Tree Cover Density into PostGIS..."
    raster2pgsql -s 4326 -t 100x100 -I -C -M "$TCD_4326" tree_cover_density | psql "$DB_URL" -q
    echo "✔ Tree Cover Density imported."
fi
echo ""

# ─── 3. Dominant Leaf Type (HRL 2018) ────────────────────────────────
# Classification: 0=non-tree, 1=broadleaved, 2=coniferous
# Higher resolution complement to CLC 311/312/313

DLT_FILE="$DATA_DIR/dominant_leaf_type_italy.tif"
DLT_4326="$DATA_DIR/dominant_leaf_type_italy_4326.tif"

# CLMS dataset identifiers for Dominant Leaf Type 2018
DLT_DATASET_ID=""
DLT_DOWNLOAD_ID=""

if [ ! -f "$DLT_FILE" ]; then
    echo "▶ Downloading Dominant Leaf Type (HRL 2018)..."

    # Discover dataset IDs from CLMS catalog
    if [ -n "$CLMS_TOKEN" ]; then
        echo "  Discovering download info for Dominant Leaf Type..."
        local_resp=$(curl -sS \
            "https://land.copernicus.eu/api/@search?portal_type=DataSet&SearchableText=dominant+leaf+type+2018&metadata_fields=UID&metadata_fields=dataset_download_information&b_size=10" \
            -H "Accept: application/json" \
            -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true
        echo "  Catalog search response: $(echo "$local_resp" | head -c 500)"

        DLT_DATASET_ID=$(echo "$local_resp" | jq -r '.items[]? | select(.title? | test("Dominant Leaf Type.*2018"; "i")) | .UID' 2>/dev/null | head -1)
        if [ -n "$DLT_DATASET_ID" ] && [ "$DLT_DATASET_ID" != "null" ]; then
            echo "  Found dataset UID: $DLT_DATASET_ID"

            ds_resp=$(curl -sS \
                "https://land.copernicus.eu/api/@search?portal_type=DataSet&UID=${DLT_DATASET_ID}&metadata_fields=dataset_download_information" \
                -H "Accept: application/json" \
                -H "Authorization: Bearer ${CLMS_TOKEN}" 2>&1) || true

            DLT_DOWNLOAD_ID=$(echo "$ds_resp" | jq -r '.items[0]?.dataset_download_information[]? | select(.full_format? | test("raster|tif"; "i")) | .id' 2>/dev/null | head -1)
            if [ -n "$DLT_DOWNLOAD_ID" ] && [ "$DLT_DOWNLOAD_ID" != "null" ]; then
                echo "  Found download info ID: $DLT_DOWNLOAD_ID"
            fi
        fi
    fi

    if [ -n "$DLT_DOWNLOAD_ID" ] && [ -n "$DLT_DATASET_ID" ]; then
        if ! clms_download_chunked "$DLT_DATASET_ID" "$DLT_DOWNLOAD_ID" "$DLT_FILE" "Dominant Leaf Type 2018"; then
            echo "  ⚠ Dominant Leaf Type download failed — skipping (non-critical)"
        fi
    else
        echo "  ⚠ Could not discover Dominant Leaf Type dataset IDs — skipping"
        echo "  (This is non-critical; CLC forest data is sufficient for scoring)"
    fi
else
    echo "✔ Dominant Leaf Type file already present: $DLT_FILE"
fi

if [ -f "$DLT_FILE" ]; then
    if [ ! -f "$DLT_4326" ]; then
        echo "▶ Reprojecting Dominant Leaf Type to EPSG:4326..."
        gdalwarp -t_srs EPSG:4326 -r near \
            -te $BBOX_MIN_LON $BBOX_MIN_LAT $BBOX_MAX_LON $BBOX_MAX_LAT \
            "$DLT_FILE" "$DLT_4326"
        echo "  ✔ Reprojected: $DLT_4326"
    fi

    echo "▶ Importing Dominant Leaf Type into PostGIS..."
    raster2pgsql -s 4326 -t 100x100 -I -C -M "$DLT_4326" dominant_leaf_type | psql "$DB_URL" -q
    echo "✔ Dominant Leaf Type imported."
fi
echo ""

# ─── 4. Soil Data (ISRIC SoilGrids WRB) ─────────────────────────────
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
        "$SOIL_FILE" 2>&1; then
        FILE_SIZE=$(wc -c < "$SOIL_FILE" | tr -d ' ')
        if [ "$FILE_SIZE" -gt 10000 ]; then
            echo "  ✔ Soil data downloaded via SoilGrids VRT (${FILE_SIZE} bytes)"
            SOIL_OK=1
        else
            echo "  ⚠ VRT returned too-small file (${FILE_SIZE} bytes)"
            rm -f "$SOIL_FILE"
        fi
    else
        echo "  ⚠ gdal_translate failed for SoilGrids VRT"
        rm -f "$SOIL_FILE"
    fi

    # Strategy 2: SoilGrids WCS 2.0.1
    if [ "$SOIL_OK" -eq 0 ]; then
        echo "  VRT failed, trying SoilGrids WCS..."
        WCS_SOIL_URL="https://maps.isric.org/mapserv?map=/map/wrb.map&SERVICE=WCS&VERSION=2.0.1&REQUEST=GetCoverage&COVERAGEID=MostProbable&FORMAT=image/tiff&SUBSET=long(${BBOX_MIN_LON},${BBOX_MAX_LON})&SUBSET=lat(${BBOX_MIN_LAT},${BBOX_MAX_LAT})&SUBSETTINGCRS=http://www.opengis.net/def/crs/EPSG/0/4326"

        echo "  WCS URL: $WCS_SOIL_URL"
        if curl -sS -f -o "$SOIL_FILE" "$WCS_SOIL_URL" 2>&1; then
            FILE_SIZE=$(wc -c < "$SOIL_FILE" | tr -d ' ')
            if [ "$FILE_SIZE" -gt 10000 ]; then
                echo "  ✔ Soil data downloaded via SoilGrids WCS (${FILE_SIZE} bytes)"
                SOIL_OK=1
            else
                echo "  ⚠ WCS returned too-small file (${FILE_SIZE} bytes)"
                rm -f "$SOIL_FILE"
            fi
        else
            echo "  ⚠ curl failed for SoilGrids WCS"
            rm -f "$SOIL_FILE"
        fi
    fi

    # Strategy 3: SoilGrids REST API (tile-based COG direct download)
    if [ "$SOIL_OK" -eq 0 ]; then
        echo "  WCS failed, trying SoilGrids COG direct access..."
        SOILGRIDS_COG="/vsicurl/https://files.isric.org/soilgrids/latest/data/wrb/MostProbable/tileSG-017-049.tif"

        if gdal_translate -of GTiff \
            -projwin $BBOX_MIN_LON $BBOX_MAX_LAT $BBOX_MAX_LON $BBOX_MIN_LAT \
            "$SOILGRIDS_COG" \
            "$SOIL_FILE" 2>&1; then
            FILE_SIZE=$(wc -c < "$SOIL_FILE" | tr -d ' ')
            if [ "$FILE_SIZE" -gt 10000 ]; then
                echo "  ✔ Soil data downloaded via SoilGrids COG (${FILE_SIZE} bytes)"
                SOIL_OK=1
            else
                echo "  ⚠ COG returned too-small file (${FILE_SIZE} bytes)"
                rm -f "$SOIL_FILE"
            fi
        else
            echo "  ⚠ gdal_translate failed for SoilGrids COG"
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

# ─── 5. Copernicus DEM (Altitude) ─────────────────────────────────────
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
                if curl -sS -f -o "$TILE_PATH" "$TILE_URL" 2>&1; then
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

# ─── 6. Verify ─────────────────────────────────────────────────────────

echo "▶ Verifying raster tables..."
psql "$DB_URL" -c "SELECT 'corine_landcover' AS table_name, count(*) AS tiles FROM corine_landcover;"
psql "$DB_URL" -c "SELECT 'esdac_soil' AS table_name, count(*) AS tiles FROM esdac_soil;"
psql "$DB_URL" -c "SELECT 'copernicus_dem' AS table_name, count(*) AS tiles FROM copernicus_dem;"
psql "$DB_URL" -c "SELECT 'dem_aspect' AS table_name, count(*) AS tiles FROM dem_aspect;"

# Optional tables (may not exist if CLMS datasets were skipped)
psql "$DB_URL" -c "SELECT 'tree_cover_density' AS table_name, count(*) AS tiles FROM tree_cover_density;" 2>/dev/null || echo "  (tree_cover_density not imported)"
psql "$DB_URL" -c "SELECT 'dominant_leaf_type' AS table_name, count(*) AS tiles FROM dominant_leaf_type;" 2>/dev/null || echo "  (dominant_leaf_type not imported)"

echo ""
echo "=== GeoData import complete ==="
