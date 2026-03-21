# Funghi Map — Progress Tracker

Stato avanzamento rispetto alle fasi definite in `architecture.md`.

---

## MVP (mese 1-2)

- [x] Setup progetto Vapor + Docker Compose locale (Postgres + Redis)
- [x] AuthModule completo (register, login, JWT, refresh)
- [x] UserModule base (profilo, placeholder foto)
- [x] Pipeline manuale con dati meteo mock e griglia ridotta (provincia test)
- [x] Tile statici caricati a mano su S3
- [x] Pagina web MapLibre che visualizza i tile overlay su mappa base (hosted come static page o servita da Vapor)

## Beta (mese 3-4)

- [x] Pipeline automatizzata con Open-Meteo reale + GeoDataLoader reale
- [x] ScoringEngine v1 con pesi fissi da config YAML
- [x] SubscriptionModule + Stripe (free vs pro)
- [x] Deploy ECS Fargate (api + worker)
- [x] CI/CD GitHub Actions

## v1.0 (mese 5-6)

- [ ] ScoringEngine calibrato con dati reali e feedback segnalazioni
- [ ] ReportModule — segnalazioni utenti integrate nel modello
- [ ] Storico mappe 90 giorni
- [ ] Admin endpoint per trigger manuale pipeline + monitoring
- [ ] Backup automatici e monitoring CloudWatch completo

---

## Decisioni tecniche

### async-kit pinned a branch `main` (2026-03-07)

`async-kit` 1.21.0 (ultima release) ha un bug di compatibilita con Swift 6.2: mancano gli import espliciti di `OrderedCollections` e `DequeModule`, richiesti dalla nuova regola `MemberImportVisibility`. Il fix esiste sul branch `main` (commit `8b940b7 — "Solve missing transitive imports error"`) ma non e stato ancora rilasciato come tag.

**Azione**: in `Package.swift` async-kit e pinned a `branch: "main"`. Quando verra rilasciato async-kit >= 1.22.0, sostituire con `.package(url: ..., from: "1.22.0")`.

### swift-tools-version 6.0 con Swift 6 language mode

Il progetto usa `swift-tools-version:6.0` e compila con strict concurrency di default (Swift 6 mode). I target `App` e `AppTests` ereditano il language mode dal tools-version senza override.

### Entry point Vapor 4 con @main

Usato il pattern `@main enum Entrypoint` con `Application.make()` e `app.execute()` (API async Vapor 4.x moderna), invece del vecchio `main.swift` imperativo.

### Struttura monolite modulare

Il target SPM `App` ha `path: "Sources"` — compila tutto sotto `Sources/`. La struttura segue CLAUDE.md: `Sources/App/` (entrypoint, configure, routes), `Sources/Modules/`, `Sources/Pipeline/`, `Sources/Core/`. Cartelle future hanno `.gitkeep` come placeholder.

### AuthModule (2026-03-07)

Implementato il modulo di autenticazione completo:
- **Endpoints**: `POST /auth/register`, `/auth/login`, `/auth/refresh`, `/auth/apple` (stub 501)
- **JWT RS256**: payload con claims sub/iss/iat/exp/email, lifetime 15 min. Chiave RSA da file PEM via env var `JWT_PRIVATE_KEY_FILE`
- **Refresh token**: opaco (32 byte random, base64url), SHA-256 hash salvato in DB, rotazione ad ogni uso, lifetime 30 giorni
- **Modelli Fluent**: `User` (email, password_hash bcrypt, apple_user_id) + `RefreshToken` (token_hash, expires_at, revoked_at)
- **Middleware JWT**: `JWTAuthMiddleware` pronto per proteggere route future (User, Map, etc.)
- **Test target**: usa `VaporTesting` (non XCTVapor) con Swift Testing framework
- **Package.swift**: aggiunto `VaporTesting` al test target al posto di `XCTVapor`

### UserModule (2026-03-07)

Implementato il modulo utente base con placeholder foto:
- **Endpoints**: `GET /user/profile`, `PUT /user/profile`, `GET /user/photos`, `POST /user/photos`, `DELETE /user/photos/:photoID`
- **Tutte le route protette** da `JWTAuthMiddleware`
- **Profilo utente**: aggiunto `display_name`, `bio`, `photo_url` al modello `User` (migration `AddUserProfileFields`)
- **Modello Photo**: Fluent model con `s3_url`, `species`, `notes`, `latitude`/`longitude` (scalari, PostGIS per query geo in futuro), `taken_at`
- **Foto placeholder**: `POST /user/photos` salva con `s3_url = "placeholder://pending-upload"` — upload S3 reale da implementare
- **Migration**: `CreatePhoto` con foreign key `user_id` → `users(id)` con `onDelete: .cascade`

### Pipeline MVP con mock data (2026-03-08)

Implementata la pipeline completa con dati mock e griglia ridotta (provincia Trentino):
- **Core/Config**: `AppConfig` structs Codable + `ConfigLoader` che decodifica `config/app.yaml` con Yams. Validazione con crash `.critical` su file mancante o malformato
- **GeoDataLoader**: protocolli `ForestCoverageClient` e `AltitudeClient` con mock implementations. Enums `ForestType` (broadleaf/coniferous/mixed/none) e `SoilType` (calcareous/siliceous/mixed/other) con scoring helpers. Clienti pensati come download one-time (non parte della pipeline giornaliera)
- **GridGenerator**: genera griglia equidistante ~500m su bbox arbitraria. Compensazione longitudine per latitudine. Trentino test bbox: ~24k punti
- **WeatherFetcher**: protocollo `WeatherClient` + `MockWeatherClient` con dati deterministici. `WeatherData`: rain14d, avgTemperature, avgHumidity
- **ScoringEngine**: struct pura, nessun side effect. Formula da architecture.md con 5 pesi da config + moltiplicatore umidità. Funzioni score individuali con curve realistiche (rain ottimale 40-80mm, temp ottimale 15-22°C, altitude ottimale 400-1200m)
- **PipelineRunner**: actor orchestratore con dependency injection dei 3 client. Fasi: grid → geo enrichment → weather fetch → scoring. Batch processing con `TaskGroup`. Log dettagliati per fase con durata e conteggio record
- **Test**: 34 test (ScoringEngine 20, ConfigLoader 5, GridGenerator 6) — tutti passing

### TileGenerator + S3Uploader (2026-03-08)

Implementati generazione tile PNG e upload S3, completando la pipeline end-to-end:
- **TileMath**: funzioni pure per conversione coordinate ↔ tile XYZ (Web Mercator). `tilesForBBox` calcola tile necessari per bbox a ogni zoom level
- **Colormap**: mapping score [0–1] → RGBA con gradiente green→yellow→red, trasparente per score 0/no data
- **IDWInterpolator**: interpolazione Inverse Distance Weighting con indice spaziale grid-based (bucket per cella lat/lon). Ricerca 9 celle vicine, power=2, raggio ~2km. Performante su ~24k punti
- **TileGenerator**: struct Sendable. Per ogni zoom level (6–12), enumera tile, renderizza 256×256 pixel via IDW + colormap, codifica PNG con swift-png. Skip tile completamente trasparenti. ~350-400 tile per Trentino
- **S3TileUploader**: protocollo `TileUploader` + implementazione Soto S3. Upload batch con `TaskGroup`, path `{date}/{z}/{x}/{y}.png`, Content-Type `image/png`
- **MockTileUploader**: mock per test, registra path uploadati
- **PipelineRunner esteso**: nuovo metodo `runFull(bbox:date:)` che esegue fasi 1-4 (scoring) + fase 5 (tile generation) + fase 6 (S3 upload). Backward-compatible con `run(bbox:)` esistente
- **Config**: aggiunto `S3Config` (tileBucket, region, uploadBatchSize) in `AppConfig` + `config/app.yaml`
- **Dipendenze**: `swift-png` 4.4+ (PNG encoding pure Swift, cross-platform) + `soto` 7.0+ (AWS SDK, solo SotoS3)
- **Test**: 56 test totali (+22 nuovi: TileMath 9, Colormap 5, IDW 3, TileGenerator 3, MockUploader 1, ScoringEngine 20 esistenti) — tutti passing

### MapModule + MapLibre viewer (2026-03-14)

Implementata pagina web MapLibre e modulo Map per servire tile, completando l'MVP:
- **Pagina web**: `Public/index.html` — MapLibre GL JS v4 (CDN, zero build step). Base map OpenStreetMap + overlay XYZ raster da `/map/tiles/{date}/{z}/{x}/{y}`. Centrata su Trentino (46.07°N, 11.12°E, zoom 8). Controlli: date picker + opacity slider
- **MapModule**: bootstrap module (pattern identico ad AuthModule/UserModule)
- **MapController**: 2 endpoint:
  - `GET /map/tiles/:date/:z/:x/:y` — local-first (`Storage/tiles/`) con fallback S3 presigned URL redirect. Validazione zoom 6–12. Nessuna auth per MVP
  - `GET /map/dates` — scan directory locali, ritorna array JSON date disponibili
- **FileMiddleware**: aggiunto in `configure.swift` per servire `Public/` come static files
- **Storage/tiles/**: directory locale per tile cache in sviluppo (con `.gitkeep`)

### Makefile (2026-03-14)

Aggiunto `Makefile` in root con comandi per gestione ambiente di sviluppo locale:
- **`make up`**: avvia Docker services (Postgres + Redis), esegue setup DB, builda e avvia Vapor server
- **`make down`**: ferma tutti i servizi Docker
- **`make restart`**: stop + rebuild + riavvio completo
- **`make build`** / **`make test`**: build e test Swift
- **`make test-scoring`**: test solo ScoringEngine
- **`make db-setup`** / **`make db-shell`**: setup DB e shell psql
- **`make services-up`** / **`make services-down`**: gestione solo Docker (senza Vapor)
- **`make status`** / **`make logs`**: stato e log dei container
- **`make clean`** / **`make clean-all`**: pulizia build artifacts e opzionalmente volumi Docker
- **`make help`**: lista comandi disponibili

### Pipeline automatizzata con Open-Meteo + GeoDataLoader reale (2026-03-14)

Sostituiti tutti i client mock della pipeline con implementazioni reali, prima task della fase Beta:

**WeatherFetcher — Open-Meteo Archive API**:
- **`OpenMeteoClient`**: implementa `WeatherClient`, chiama `archive-api.open-meteo.com/v1/archive` con finestra 14 giorni. Calcola: `rain14d` (somma pioggia), `avgTemperature` (media ultimi 7gg), `avgHumidity` (media ultimi 7gg). Coordinate arrotondate a 3 decimali. Retry con exponential backoff su 429/5xx
- **`AsyncSemaphore`**: actor per limitare richieste HTTP concorrenti (default 50)
- **`CachedWeatherClient`**: wrapper con Redis cache (TTL 24h). Chiave: `weather:{lat}:{lon}:{date}`. Protocollo `WeatherCache` + `RedisWeatherCache`
- **`OpenMeteoResponse`**: modello Codable per JSON Open-Meteo. `WeatherData` ora `Codable` per serializzazione Redis
- **`WeatherFetchError`**: error enum con contesto (statusCode, coordinate)
- **Config**: aggiunto `WeatherConfig` in `PipelineConfig` + sezione `weather:` in `app.yaml`

**GeoDataLoader — Open-Meteo Elevation API + PostGIS Raster**:
- **`OpenMeteoAltitudeClient`**: implementa `AltitudeClient` via Open-Meteo Elevation API. Aspect calcolato da gradiente di 4 punti vicini (±200m) con `atan2`
- **`CachedAltitudeClient`**: wrapper Redis cache (TTL 7 giorni, dati statici)
- **`PostGISForestClient`**: implementa `ForestCoverageClient` con query `ST_Value()` su raster PostGIS via SQLKit. Mapping CORINE CLC (311→broadleaf, 312→coniferous, 313→mixed) e ESDAC soil
- **`CreateRasterExtensions`**: migration per abilitare `postgis` + `postgis_raster` extensions
- **`scripts/import-geodata.sh`**: script per download e import GeoTIFF CORINE/ESDAC in PostGIS con `raster2pgsql`
- **Config**: aggiunto `GeoDataConfig` in `PipelineConfig` + sezione `geoData:` in `app.yaml`

**Pipeline resilienza errori**:
- `PipelineRunner.enrichWithGeoData()` e `fetchWeather()`: da `withThrowingTaskGroup` a `withTaskGroup`. Errori per-punto catturati, log warning, fallback a valori default. Log sommario dei fallimenti a fine fase. Conforme a CLAUDE.md: "On partial error: log, continue, notify at end"

**AdminModule — Trigger pipeline**:
- **`POST /admin/pipeline/run`**: endpoint protetto da `AdminKeyMiddleware` (Bearer token da env `ADMIN_API_KEY`). Parametri opzionali: `bbox`, `date` (default Trentino, oggi). Esegue pipeline in background `Task`, risponde 202 Accepted
- **`AdminModule`**: bootstrap pattern identico ad Auth/User/MapModule
- Registrato in `configure.swift`

**Makefile**: aggiunti `make geodata-import` e `make geodata-check`

**Test**: 94 test totali (+38 nuovi: OpenMeteoClient 6, CachedWeatherClient 4, OpenMeteoAltitudeClient 5, PostGISForestClient 10, + 13 test esistenti confermati) — tutti passing

### Altitude migrata a PostGIS raster (2026-03-14)

Migrata sorgente dati altitudine da Open-Meteo Elevation API a raster Copernicus DEM locale in PostGIS, allineando l'implementazione all'architettura (Phase 1: dati statici one-time):

- **`PostGISAltitudeClient`**: implementa `AltitudeClient` con query `ST_Value()` su tabelle `copernicus_dem` e `dem_aspect`. Pattern identico a `PostGISForestClient`. Zero dipendenza internet, query sub-millisecondo
- **`import-geodata.sh` esteso**: download automatico tile Copernicus DEM GLO-25 (25m) da AWS Open Data, merge con `gdal_merge.py`, generazione raster aspetto con `gdaldem aspect`, import in PostGIS con `raster2pgsql`
- **Startup validation**: all'avvio l'app verifica che `copernicus_dem` esista e contenga dati
- **Cleanup**: rimossi `OpenMeteoAltitudeClient`, `CachedAltitudeClient`, `ElevationResponse` e relativi test. Rimossa `GeoDataConfig` e sezione `geoData` da `app.yaml` (non piu necessarie). AdminController usa direttamente `PostGISAltitudeClient`

### ScoringEngine v1 — Two-Layer Model (2026-03-15)

Reimplementato lo ScoringEngine con modello a due livelli calibrato su ricerca micologica per Porcini (Boletus edulis):

**Modello two-layer multiplicativo**: `finalScore = baseScore × weatherScore`
- **Base score** (habitat statico): forest type (40%) + altitude (25%) + soil type (20%) + aspect/esposizione (15%). Cambia solo quando cambiano i dati geo statici
- **Weather score** (fenologia meteo): rain14d (55%) + temperature (45%), con moltiplicatore umidità [0.4–1.0]. Cambia ad ogni run giornaliero
- Modello multiplicativo: zero habitat (no foresta) → zero score indipendentemente dal meteo. Zero pioggia → near-zero indipendentemente dall'habitat

**Curve calibrate su ricerca Porcini**:
- **ForestType**: coniferous alzato da 0.6 a 0.80 (abete rosso/pino/abete sono ospiti primari). Broadleaf 0.85 (quercia/faggio/castagno). Mixed 1.0
- **SoilType**: mixed humus-rich ora top (1.0, era 0.8). Calcareous 0.85 (era 1.0). Siliceous 0.70 (era 0.5). pH ideale 5.5–6.5
- **Temperature**: plateau ottimale 12–20°C (era 15–22°C). Range autunnale 4–12°C con score parziale (porcini autunnali). Soglia freddo abbassata a 4°C
- **Pioggia**: plateau ottimale 50–90mm/14gg (era 40–80mm). Floor a 0.1 per pioggia estrema (mai zero se c'è acqua)
- **Altitudine**: plateau ottimale 400–1800m (era 400–1200m). Porcini trovati fino a 2400m nelle Alpi. Sopra 2400m: 0.1 (raro ma possibile)
- **Aspect** (NUOVA funzione): curva coseno — nord=1.0 (trattiene umidità), est/ovest=0.65, sud=0.30 (asciuga). Terreno piano=0.7

**Config ristrutturata**: `scoringWeights` in `app.yaml` ora nested con `base:` (4 pesi, sum=1.0) e `weather:` (2 pesi, sum=1.0) + `humidityMultiplierMin: 0.4`

**Diagnostica**: `ScoringEngine.Result` ora espone `baseScore` e `weatherScore` oltre al `score` finale. `PipelineRunner` logga medie per layer

**Test**: 32 test ScoringEngine (+12 nuovi: aspectScore 4, layer independence 2, multiplicative model 2, result fields 1, existing updated 3). ConfigLoader tests aggiornati per struttura nested. TileGenerator tests aggiornati per nuovi campi Result

### SubscriptionModule + Stripe (2026-03-15)

Implementato il modulo abbonamenti con sistema di entitlements config-driven per gating flessibile:

**Architettura entitlements**:
- **`PlanEntitlements`**: struct Codable che definisce i limiti di ogni piano (`maxZoom`, `historyDays`, `features: [String]`). Tutti i piani sono definiti in `config/app.yaml` sotto `subscription.plans`. Per aggiungere nuovi gate in futuro (es. map variety, API access), basta aggiungere campi a `PlanEntitlements` e configurarli in YAML
- **`SubscriptionMiddleware`**: dopo `JWTAuthMiddleware`, carica la subscription dell'utente dal DB, risolve il piano → entitlements da config, e li attacca a `req.planEntitlements`. Qualsiasi controller downstream può verificare i limiti senza conoscere Stripe
- Fallback automatico a entitlements `free` se l'utente non ha subscription o è scaduta

**Subscription model + migration**:
- Tabella `subscriptions` con FK → `users(id)`, unique su `user_id` e `stripe_customer_id`
- Campi: `plan`, `status`, `stripe_customer_id`, `stripe_subscription_id`, `current_period_end`
- `isActive` computed: verifica sia `status == "active"` che `currentPeriodEnd > now`

**SubscriptionController** — 3 endpoint:
- `GET /subscription/status` — piano corrente + entitlements (JWT protetto)
- `POST /subscription/checkout` — crea sessione Stripe Checkout (JWT protetto). Valida che il piano richiesto esista in config
- `POST /subscription/webhook` — webhook Stripe con verifica firma HMAC-SHA256. Gestisce: `checkout.session.completed` (upsert subscription), `customer.subscription.updated` (sync stato/scadenza), `customer.subscription.deleted` (downgrade a free)

**StripeClient**: client HTTP leggero che usa `Vapor.Client` (nessuna dipendenza SDK esterna). Verifica firma webhook con `Crypto.HMAC<SHA256>` + tolleranza timestamp 5 minuti

**MapController aggiornato**: endpoint tile ora richiede JWT + `SubscriptionMiddleware`. Zoom > `planEntitlements.maxZoom` → 403 Forbidden. Endpoint `/map/dates` resta pubblico

**Config**: aggiunta sezione `subscription` in `app.yaml` con `checkoutSuccessURL`, `checkoutCancelURL`, `stripePriceIDs` (per piano), e `plans` (entitlements per piano)

**Test**: 13 test (PlanEntitlements 2, Subscription model 4, SubscriptionConfig 3, Stripe webhook signature 4) — tutti passing

### Deploy ECS Fargate — api + worker (2026-03-15)

Infrastruttura completa per deploy su AWS ECS Fargate con due container (api always-on + worker on-demand):

**Dockerfile multi-stage** (`infra/Dockerfile`):
- Stage 1: build Swift 6 release con static linking su `swift:6.0-jammy`
- Stage 2: runtime minimale `ubuntu:22.04` (~80MB). Binary + config + Public/ copiati dal build stage
- Singola immagine, due modalità: `CMD ["serve", ...]` (default, API) oppure override `["worker", "--bbox", "italy"]` per pipeline
- Health check integrato per API mode

**WorkerCommand** (`Sources/App/Commands/WorkerCommand.swift`):
- `AsyncCommand` Vapor registrato come `worker`. Esegue la pipeline synchronous e poi esce (ideale per ECS scheduled task)
- Opzioni CLI: `--bbox` (italy/trentino, default italy), `--date` (YYYY-MM-DD, default oggi Rome TZ)
- Stesso setup client di `AdminController`: OpenMeteo → Redis cache, PostGIS forest/altitude
- `BoundingBox.italy` aggiunto (bbox 36.6–47.1°N, 6.6–18.5°E)

**ECS Task Definitions** (`infra/ecs/`):
- `task-def-api.json`: 0.5 vCPU / 1 GB RAM, porta 8080, health check `/health`. Segreti da Secrets Manager (DATABASE_URL, REDIS_URL, JWT, Stripe, admin key)
- `task-def-worker.json`: 2 vCPU / 4 GB RAM, nessuna porta esposta. Segreti ridotti (no Stripe). Command override: `["worker", "--bbox", "italy"]`

**CloudFormation stack** (`infra/cloudformation/stack.yaml`):
- ECR repository con lifecycle policy (10 immagini max)
- ECS cluster con Container Insights
- CloudWatch log groups (30 giorni retention) per api e worker
- IAM roles: execution (pull image + read secrets), api-task (S3 read tile), worker-task (S3 upload + CloudFront invalidation), EventBridge → RunTask
- Security groups: ALB (80/443 pubblico) → ECS (8080 solo da ALB)
- ALB internet-facing con target group e health check su `/health`
- API service (always-on, 1 task, rolling deploy 100-200%)
- EventBridge rule: `cron(0 2 * * ? *)` lancia worker task ogni notte alle 02:00 UTC
- Parametri: VPC/subnet IDs, image URI, ARN di tutti i segreti

**Deploy script** (`infra/scripts/deploy.sh`):
- ECR login → Docker build (linux/amd64) → push con tag git SHA + latest
- Registra nuove task definition da template JSON (sostituisce ACCOUNT_ID e image)
- Force new deployment su API service + wait for stability
- Opzioni: `--api-only`, `--worker-only`

**Makefile**: aggiunti `make docker-build`, `make deploy`, `make deploy-api`, `make deploy-worker`, `make cfn-deploy`

### GeoData import consolidato in singolo script Python (2026-03-16)

Consolidati `scripts/download-geodata.py` + `scripts/import-geodata.sh` in un unico `scripts/import-geodata.py` — download WEkEO HDA + reproject + clip Italia + import PostGIS:

- **`scripts/import-geodata.py`**: script Python unico che sostituisce entrambi i vecchi script. Usa WEkEO HDA (`hda`) per download CORINE/TCD/DLT/DEM, ISRIC SoilGrids per suolo, GDAL CLI per reproject/clip, `raster2pgsql | psql` per import PostGIS
- **Timeout su WEkEO**: `client.search()` e `download()` wrappati con `ThreadPoolExecutor` + timeout (120s search, 30min download) per prevenire hang infiniti
- **DEM con bbox Italia**: query WEkEO con `bbox: [6.5, 36.5, 18.5, 47.5]` per scaricare solo tile che coprono l'Italia. Supporta anche tile WEkEO gia scaricati (ZIP in `data/geodata/dem_tiles/`)
- **Soil da ISRIC SoilGrids**: cascade VRT → WCS → COG (invariato, non su WEkEO)
- **Tutti i raster clippati a bbox Italia** e riproiettati a EPSG:4326
- **Aspect derivato**: `gdaldem aspect` dal DEM, gestito come dataset a se stante
- **Import PostGIS**: `raster2pgsql | psql` con tile 100x100, indice spaziale, verifica finale
- **Idempotente**: skip se file finali gia esistono, supporto dataset selettivi via CLI
- **Rimosso bash**: eliminato `import-geodata.sh` (~320 righe bash) — tutta la logica ora in Python

### CI/CD GitHub Actions (2026-03-15)

Configurata pipeline CI con GitHub Actions, ultimo task della fase Beta:

**Workflow** (`.github/workflows/ci.yml`):
- **Trigger**: push su `main`/`Pipeline` + pull request su `main`
- **Runner**: `ubuntu-latest` con container `swift:6.0-jammy` (Swift 6, coerente con Dockerfile deploy)
- **Services**: PostgreSQL 16 + PostGIS 3.5 (`postgis/postgis:16-3.5`) e Redis 7 Alpine — health check integrati
- **Setup DB**: installa `postgresql-client`, abilita extensions `postgis`, `postgis_raster`, `uuid-ossp` sul DB di test
- **Steps**: `swift package resolve` → `swift build` → `swift test --parallel` → `swift test --enable-code-coverage`
- **Coverage**: export LCOV con `llvm-cov`, upload su Codecov (free tier) via `codecov/codecov-action@v4`. Richiede secret `CODECOV_TOKEN` nel repo GitHub
- **Env vars CI**: `DATABASE_URL` e `REDIS_URL` puntano ai container service. `JWT_PRIVATE_KEY_FILE` vuoto (test che non necessitano di JWT reale). `LOG_LEVEL=warning` per output pulito
