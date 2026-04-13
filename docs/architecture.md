# Funz2.0 — Backend Architecture

## Table of Contents
1. [What this project is](#what-this-project-is)
2. [Tech stack](#tech-stack)
3. [System overview](#system-overview)
4. [Boot sequence](#boot-sequence)
5. [API modules](#api-modules)
6. [Subscription & entitlements](#subscription--entitlements)
7. [Map tiles](#map-tiles)
8. [Pipeline](#pipeline)
9. [Push notifications (APNs)](#push-notifications-apns)
10. [Database](#database)
11. [Configuration](#configuration)
12. [Logging](#logging)
13. [Infrastructure](#infrastructure)
14. [Development workflow](#development-workflow)
15. [What is not yet implemented](#what-is-not-yet-implemented)

---

## What this project is

Funz2.0 is the backend for the funzApp iOS app — a mushroom foraging probability map for Italy. It does two things:

1. **API server** — serves tile images, user data, weather, POIs, and handles auth. Built with Vapor 4.
2. **Pipeline** — a nightly computation job that generates probability maps as PNG tiles for all of Italy. Runs inside the same process on a `DailyScheduler`, or manually via CLI/admin API.

The iOS app embeds a `WKWebView` that loads `index.html` from this server. `index.html` renders a MapLibre map, fetches tile images from the server, and communicates back to native Swift via a JS bridge.

---

## Tech stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6 (strict concurrency) |
| HTTP framework | Vapor 4 |
| Database | PostgreSQL 16 + PostGIS (via Fluent ORM + SQLKit raw) |
| Cache | Redis (Upstash free tier) |
| Tile storage | Local filesystem (`Storage/tiles/`) — S3 fallback if AWS credentials present |
| Weather data | Open-Meteo API (free, no key) — cached in PostgreSQL |
| Push notifications | Apple APNs HTTP/2 (custom implementation, no third-party SDK) |
| Map rendering | MapLibre GL JS 4.7.1 (in-browser, served from `Public/index.html`) |
| Satellite imagery | ESRI World Imagery (fetched directly by the browser via `https://`) |
| Deployment | Docker Compose (local/beta) — AWS ECS Fargate (prod) |

---

## System overview

```
iOS app (WKWebView)
    │
    │  HTTPS (funz1.duckdns.org or prod domain)
    ▼
Vapor API server (Funz2.0)
    ├── Serves index.html (the map UI)
    ├── Serves tile PNGs from Storage/tiles/
    ├── Auth, User, POI, Weather, Subscription, Admin modules
    └── DailyScheduler (nightly pipeline at 02:45 Europe/Rome)
         ├── Step 1: Historical map for today
         ├── Step 2: Forecast maps (next 5 days)
         └── Step 3: Score POIs → send APNs push notifications
    │
    ├── PostgreSQL + PostGIS
    │       Users, tokens, subscriptions, weather observations, Italy boundary raster
    └── Redis
            Weather fetch cache (avoids re-querying Open-Meteo for same location+date)
```

The pipeline writes tiles to `Storage/tiles/{date}/{z}/{x}/{y}.png` (historical) and `Storage/tiles/forecast/{date}/{z}/{x}/{y}.png` (forecast). There is no S3 in active use — tiles live on disk. The S3 code path exists but only activates if `AWS_ACCESS_KEY_ID` is in the environment.

---

## Boot sequence

`configure.swift` runs at startup in this order:

1. Validate required env vars (`DATABASE_URL`, `REDIS_URL`, `JWT_PRIVATE_KEY_FILE`) — fatal crash if missing
2. Connect to PostgreSQL and Redis
3. Load RS256 JWT private key from the `.pem` file at `JWT_PRIVATE_KEY_FILE`
4. Register modules: `UserModule` → `AuthModule` → `SubscriptionModule` → `MapModule` → `AdminModule` → `WeatherModule` → `POIModule` (order matters: `CreateUser` migration must run before `CreateRefreshToken`)
5. Run Fluent auto-migrations
6. Validate PostGIS raster data (`copernicus_dem` table) — warns if missing, does not crash
7. Register CLI commands: `worker`, `bench-geo`, `evaluate`
8. Start `DailyScheduler`
9. Pre-warm `RasterCache` for the latest available tile date (avoids cold-start latency on the first dynamic tile request)

---

## API modules

All modules are registered in `configure.swift` and expose their routes via `RouteCollection`.

### AuthModule — `/auth/*`

Email + password authentication. JWT RS256 access tokens (15 min) + opaque refresh tokens (30 days, rotated on every use, SHA-256 hashed in DB).

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/auth/register` | No | Create account, returns token pair |
| POST | `/auth/login` | No | Email + password login, returns token pair |
| POST | `/auth/refresh` | No | Rotate refresh token, returns new pair |
| POST | `/auth/apple` | No | **Not implemented** — returns 501 |

Token response shape:
```json
{ "accessToken": "eyJ...", "refreshToken": "base64url...", "expiresIn": 900 }
```

All authenticated endpoints use `JWTAuthMiddleware` which validates the Bearer token and populates `req.jwtPayload`.

### UserModule — `/user/*`

User profile and photo management.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/user/profile` | Yes | Get current user's profile |
| PUT | `/user/profile` | Yes | Update `displayName`, `bio`, `photoURL` (all optional) |
| GET | `/user/photos` | Yes | List user's photo records (newest first) |
| POST | `/user/photos` | Yes | Create a photo record (metadata only, no file upload) |
| DELETE | `/user/photos/:photoID` | Yes | Delete a photo record |

**Note:** Photo file upload to S3 is not yet implemented. `POST /user/photos` stores only metadata with a placeholder S3 URL.

The user model has optional fields populated via `AddUserProfileFields` migration: `displayName`, `bio`, `photoURL`, `deviceToken` (APNs).

### POIModule — `/user/pois/*`

Points of Interest — user-saved GPS locations on the map. These are used by the nightly pipeline to evaluate forecast scores and send push notifications.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/user/pois` | Yes | List user's POIs (sorted by creation date) |
| POST | `/user/pois` | Yes | Create a POI — enforces plan quota |
| DELETE | `/user/pois/:poiID` | Yes | Delete a POI (also removes notification records) |

POI creation validates: non-empty name, valid lat/lon range (-90..90, -180..180), and enforces `planEntitlements.maxPOIs` (free plan: 1 POI).

POI model: `id`, `userID`, `name`, `latitude`, `longitude`, `createdAt`.

### MapModule — `/map/*`

Serves tile images and date listings.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/map/tiles/:date/:z/:x/:y` | Yes + subscription | Historical tile PNG (zoom 6–12) |
| GET | `/map/dynamic-tiles/:date/:z/:x/:y?min_score=0.X` | Yes + subscription | Filter tiles by minimum score, rendered on-the-fly from cached raster |
| GET | `/map/forecast-tiles/:date/:z/:x/:y` | Yes + subscription | Forecast tile PNG |
| GET | `/map/dev-tiles/:date/:z/:x/:y` | No | Unauthenticated tiles, local files only, non-production only |
| GET | `/map/dates` | No | List available historical dates (newest first) |
| GET | `/map/forecast-dates` | No | List available forecast dates (future only, relative to Europe/Rome) |
| GET | `/map/score?lat=&lon=&date=` | No | Score 0–100 at a coordinate for a given date |

**Tile serving logic:**
1. Look for file at `Storage/tiles/{date}/{z}/{x}/{y}.png`
2. If not found and AWS credentials present → redirect to S3 presigned URL (1h TTL)
3. Otherwise → 404

**Dynamic tiles** (`/map/dynamic-tiles/`) are rendered on-the-fly using `RasterCache`. The raster for a date is loaded once into memory and kept in `RasterCache.shared`. Each pixel is sampled, filtered by `min_score`, and colored by `Colormap`. At `min_score=0` the output is visually identical to the pre-rendered tile.

**Zoom limits by plan:**
- Free: max zoom 9
- Pro: max zoom 12 (configured in `config/app.yaml`)

### WeatherModule — `/weather/*`

Proxies weather data from the PostgreSQL `weather_observations` table (populated by the pipeline).

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/weather/daily?lat=&lon=&from=&to=` | No | Daily weather (rain mm, mean temp °C, humidity %) for a date range at the nearest observed point |

The nearest point lookup is a `ST_DWithin` + `ST_Distance` query via SQLKit. Returns `null` if no data found within range.

### AdminModule — `/admin/*`

Protected by `AdminKeyMiddleware` which checks the `X-Admin-Key` header against the `ADMIN_KEY` environment variable.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/admin/pipeline/run` | Admin key | Trigger pipeline asynchronously. Optional body: `{ "date": "YYYY-MM-DD", "bbox": {...} }`. Defaults to today + Trentino bbox. Returns 202 immediately. |

### HealthModule

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | No | Returns `{ "status": "ok", "version": "0.1.0" }` |

---

## Subscription & entitlements

`SubscriptionMiddleware` runs after `JWTAuthMiddleware` on all protected map and POI routes. It:
1. Looks up the user's active `Subscription` in PostgreSQL
2. Loads the matching plan config from `config/app.yaml` (`subscription.plans`)
3. Writes a `PlanEntitlements` struct to `req.storage`

Any route handler reads entitlements via `req.planEntitlements`:

```swift
struct PlanEntitlements: Codable {
    let maxZoom: Int        // tile zoom ceiling
    let historyDays: Int    // how many days of history available
    let features: [String]  // feature flags (unused yet)
    let maxPOIs: Int        // max saved POIs
}

// Default (free / unauthenticated):
PlanEntitlements.free = PlanEntitlements(maxZoom: 9, historyDays: 0, features: [], maxPOIs: 1)
```

Subscription state is only mutated via Stripe webhooks (`POST /subscription/webhook`). Never by the client directly.

---

## Map tiles

### Tile URL structure

```
Storage/tiles/
  {YYYY-MM-DD}/        ← historical, computed nightly
    {z}/{x}/{y}.png
  forecast/
    {YYYY-MM-DD}/      ← forecast, computed nightly for next 5 days
      {z}/{x}/{y}.png
```

Old historical tiles are deleted by the scheduler: only the last 2 days are kept on disk (configurable in `DailyScheduler`).

### Token passing to WKWebView

The iOS app builds the map URL with the JWT access token in the query string:
```
https://funz1.duckdns.org/?lat=46&lon=11&zoom=8&date=2026-04-12&token=eyJ...
```

`index.html` reads `token` from `URLSearchParams` on load. When the token is refreshed, native Swift calls `window.setMapAuth(token, date)` via `evaluateJavaScript`. MapLibre re-fetches tiles with the new token embedded in the tile URL query string.

### Nginx caching

The production Nginx config caches tile responses. If tiles stop loading after a pipeline run, the nginx cache may be stale — flush it or reduce cache TTL.

---

## Pipeline

The pipeline computes mushroom probability scores for a 500m grid across Italy, then renders PNG tiles at zoom levels 6–12.

### Trigger options

1. **Automatic** — `DailyScheduler` at 02:45 Europe/Rome every day
2. **CLI** — `swift run App worker` inside the container (`make worker`)
3. **Admin API** — `POST /admin/pipeline/run` (async, returns 202 immediately)

### Phases

```
Phase 1 — Grid generation
  GridGenerator produces ~280k points at 500m spacing over Italy bounding box.
  Points outside the Italian boundary are filtered via PostGIS query on the
  'italy_boundary' table. Result is cached to disk (geo data is static).

Phase 2 — Geo enrichment
  BatchGeoEnrichmentClient queries PostGIS raster tables in batches:
    - copernicus_dem → altitude
    - forest_coverage → forest type and coverage %
    - soil_type → soil classification
  Points with unsuitable terrain (water, urban, wrong altitude) are filtered out.
  Enriched grid is serialized to disk — skipped on subsequent runs for the same bbox.

Phase 3 — Weather fetch
  OpenMeteoClient fetches historical or forecast weather for each grid point.
  CachedWeatherClient wraps it: checks Redis first, falls back to Open-Meteo,
  writes result to Redis (TTL from config) and to PostgreSQL weather_observations.
  Rate-limited via TokenBucketRateLimiter. Concurrent fetches via TaskGroup.

Phase 4 — Scoring
  ScoringEngine computes a score [0.0–1.0] for each point:
    score = w_forest × forest_score
          + w_rain   × rain_score (14-day precipitation)
          + w_temp   × temp_score (optimal 15–22°C)
          + w_humid  × humidity_score
          + w_alt    × altitude_score (optimal 400–1200m)
          + w_soil   × soil_score
  Weights are read from config/app.yaml (pipeline.scoringWeights).

Phase 5 — Tile rendering
  IDWInterpolator performs Inverse Distance Weighting on the scored points to
  produce a continuous score raster. TileGenerator renders PNG tiles for each
  zoom level using Colormap (transparent → green → yellow → red).
  ScoreRaster is written to disk for RasterCache to load later.

Phase 6 — Upload
  LocalTileUploader writes tiles to Storage/tiles/{date}/{z}/{x}/{y}.png.
  S3TileUploader exists but is not active (no CloudFront invalidation in current setup).
```

### Forecast pipeline

The forecast pipeline (`runForecast`) runs the same phases but using Open-Meteo forecast data (next 5 days). Output goes to `Storage/tiles/forecast/{date}/`. Then `ForecastEvaluator` samples the score at each user's POI location and sends APNs push notifications if the score exceeds a threshold (default: 0.45).

### Geo data prerequisites

Before the pipeline can run, PostGIS raster data must be imported:
```bash
make geodata-import   # runs infra/scripts/import-geodata.py — takes ~30 min
make geodata-check    # verify tables exist and have rows
```

Required tables: `copernicus_dem`, `forest_coverage`, `soil_type`, `italy_boundary`.

---

## Push notifications (APNs)

`APNsService` sends push notifications directly via Apple's HTTP/2 APNs API. Authentication uses a JWT signed with an ES256 `.p8` key (token-based auth, not certificate).

Required environment variables:
```
APNS_KEY_ID       — 10-char key ID from Apple Developer portal
APNS_TEAM_ID      — 10-char Apple team ID
APNS_BUNDLE_ID    — app bundle ID (e.g. "com.example.funz")
APNS_PRIVATE_KEY  — .p8 file contents (PEM with \n literals)
APNS_PRODUCTION   — "true" for prod APNs, anything else for sandbox
```

If any of these are missing, `APNsService.init` returns `nil` and notifications are silently disabled.

Notifications are sent by `ForecastEvaluator` (Step 3 of the daily pipeline). Payload:
```json
{
  "aps": { "alert": { "title": "...", "body": "..." }, "sound": "default" },
  "type": "forecast",
  "forecast_date": "YYYY-MM-DD",
  "poi_id": "UUID",
  "score": 72
}
```

The iOS app reads `type` and `forecast_date` from the notification payload and opens the forecast overlay for that date.

Device tokens are stored in the `users` table (`deviceToken` column, added by `AddDeviceToken` migration). Registered by the iOS app via `POST /user/device-token`.

---

## Database

### ORM strategy

- **Fluent ORM** — user domain entities (User, RefreshToken, Subscription, Photo, POI, POINotification)
- **SQLKit raw** — PostGIS queries, weather lookups, bulk weather inserts, any function involving geometry

### Schema

```sql
-- Auth
users (id UUID PK, email TEXT UNIQUE, password_hash TEXT,
       display_name TEXT, bio TEXT, photo_url TEXT,
       device_token TEXT, created_at, updated_at)
refresh_tokens (id UUID PK, user_id → users, token_hash TEXT,
                expires_at, revoked_at, created_at)

-- Subscriptions
subscriptions (id UUID PK, user_id → users,
               plan TEXT ('free'|'pro'),
               stripe_customer_id TEXT, stripe_subscription_id TEXT,
               expires_at, status TEXT, created_at, updated_at)

-- User content
photos (id UUID PK, user_id → users, s3_url TEXT,
        species TEXT, notes TEXT, latitude FLOAT, longitude FLOAT,
        taken_at, created_at, updated_at)

-- POIs
pois (id UUID PK, user_id → users, name TEXT,
      latitude FLOAT, longitude FLOAT, created_at, updated_at)
poi_notifications (id UUID PK, poi_id → pois, sent_at,
                   forecast_date TEXT, score FLOAT)

-- Pipeline (PostGIS, managed by SQLKit)
copernicus_dem           -- raster: altitude
forest_coverage          -- raster: forest type
soil_type                -- raster: soil classification
italy_boundary           -- polygon: Italian territory (for grid filtering)
weather_observations     -- partitioned by date: temp, rain, humidity per grid point
```

### Indexes

Every geometry column has a GIST index. `weather_observations` is partitioned by `date`.

### Migrations

Fluent auto-migrates on boot (dev only — use explicit migrations in prod). Migration order is enforced by `configure.swift` registration order. All migrations are in `Sources/Core/DB/` and `Sources/Modules/*/Migrations/`.

---

## Configuration

### Environment variables (required)

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection URL |
| `REDIS_URL` | Redis connection URL |
| `JWT_PRIVATE_KEY_FILE` | Path to RS256 private key PEM file |
| `ADMIN_KEY` | Secret for `X-Admin-Key` header on admin endpoints |

### Environment variables (optional)

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | Enables S3 fallback for tile serving |
| `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` | ECS-style AWS auth (alternative to key ID) |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY`, `APNS_PRODUCTION` | Push notifications |

### `config/app.yaml`

Application parameters (not secrets) — versioned in the repo:

```yaml
server:
  port: 8080

pipeline:
  gridSpacingMeters: 500
  batchSize: 5000
  tileZoomMin: 6
  tileZoomMax: 12
  scoringWeights:
    forest:      0.30
    rain14d:     0.25
    temperature: 0.20
    altitude:    0.15
    soil:        0.10

map:
  tileSignedUrlTtlSeconds: 3600

s3:
  tileBucket: funghi-map-tiles
  region: eu-central-1

subscription:
  plans:
    free:
      maxZoom: 9
      historyDays: 0
      features: []
      maxPOIs: 1
    pro:
      maxZoom: 12
      historyDays: 90
      features: ["forecast"]
      maxPOIs: 50
```

---

## Logging

All logging uses `swift-log` (`Logger`). Never use `print()`.

Each module instantiates its own logger:
```swift
private static let logger = Logger(label: "funghi.map")
// Labels: funghi.auth, funghi.pipeline, funghi.scheduler, funghi.apns, etc.
```

Log levels: `.debug` for verbose detail, `.info` for normal operations, `.warning` for recoverable anomalies, `.error` with structured metadata for failures. `.trace` only in local development.

---

## Infrastructure

### Local / beta

3 Docker containers via Docker Compose:
- `postgres` — PostgreSQL 16 + PostGIS
- `redis` — Redis
- `app` — Vapor server

Same Docker image and `.env` file for local and beta. Beta server uses Nginx reverse proxy + Certbot (SSL) + DuckDNS.

### Production (AWS ECS Fargate)

Two ECS tasks from the same Docker image:
- `api` — always running, 0.5 vCPU / 1GB RAM
- `worker` — on-demand for pipeline runs, 2 vCPU / 4GB RAM

Config via AWS Secrets Manager. RDS PostgreSQL, Upstash Redis.

### Common commands

```bash
make up              # start postgres + redis + app
make down            # stop all containers
make rebuild         # rebuild Docker image and restart
make quick           # restart app without rebuild (use for Public/ or config/ changes)
make worker          # run full pipeline inside container
make worker-trentino # run pipeline for Trentino only (faster, for testing)
make geodata-import  # import Copernicus raster data into PostGIS
make geodata-check   # verify raster tables
make db-setup        # init PostGIS + uuid-ossp extensions
make db-shell        # open psql shell
make redis-flush     # flush Redis cache
make swift-build     # native Swift build (no Docker)
make swift-test      # run tests in parallel
make logs            # tail all container logs
make app-logs        # tail app container logs only
```

---

## What is not yet implemented

- **Sign in with Apple** — `POST /auth/apple` returns 501
- **Photo file upload** — `POST /user/photos` saves metadata only, no actual file goes to S3
- **S3 tile serving** — code path exists but not active (tiles served from local disk only)
- **Stripe webhook** — `SubscriptionModule` and `StripeClient` are scaffolded but webhook handling is incomplete
- **ReportModule** — sighting reports (mentioned in early design, not in codebase)
- **CI/CD** — no GitHub Actions pipeline yet
- **Production deploy** — ECS CloudFormation stack exists in `infra/` but not actively used
