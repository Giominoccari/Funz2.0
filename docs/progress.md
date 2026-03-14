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

- [ ] Pipeline automatizzata con Open-Meteo reale
- [ ] ScoringEngine v1 con pesi fissi da config YAML
- [ ] SubscriptionModule + Stripe (free vs pro)
- [ ] Deploy ECS Fargate (api + worker)
- [ ] CI/CD GitHub Actions

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
- **JWT RS256**: payload con claims sub/iss/iat/exp/email, lifetime 15 min. Chiave RSA da env var `JWT_PRIVATE_KEY`
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
