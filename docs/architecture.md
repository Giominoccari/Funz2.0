# Funghi Map — Architettura Backend

## Indice
1. [Visione generale](#visione-generale)
2. [Principi architetturali](#principi-architetturali)
3. [Struttura del sistema](#struttura-del-sistema)
4. [Moduli API (Vapor)](#moduli-api-vapor)
5. [Pipeline di calcolo mappe](#pipeline-di-calcolo-mappe)
6. [Database](#database)
7. [Configurazione](#configurazione)
8. [Logging](#logging)
9. [Testing](#testing)
10. [Infrastruttura AWS](#infrastruttura-aws)
11. [Backup e Disaster Recovery](#backup-e-disaster-recovery)
12. [Fasi di sviluppo](#fasi-di-sviluppo)

---

## Visione generale

Backend per app iOS che fornisce:
1. **Mappe di probabilità funghi** — tile XYZ pre-calcolati con isobare di probabilità basate su dati meteo storici/previsionali, copertura forestale, altitudine e tipo di suolo.
2. **Gestione utenti completa** — autenticazione, abbonamenti, foto, percorsi GPS, segnalazioni.

Utilizzatori primari: fungaioli italiani che consultano la mappa per decidere dove e quando andare a raccogliere funghi.

**Volumi attesi**: max 10.000 utenti, poche richieste concorrenti. Il collo di bottiglia non è il traffico API ma la preparazione delle mappe (pipeline pesante e schedulata).

---

## Principi architetturali

- **Separazione sincrono/asincrono**: le mappe si calcolano offline (pipeline schedulata notturna). L'API serve solo tile pre-calcolati — latenza target < 50ms per richiesta client.
- **Monolite modulare**: un singolo processo Vapor con moduli ben separati. Nessun microservizio. Ottimale per un solo sviluppatore.
- **ORM ibrido**: Fluent per entità dominio utente, SQLKit raw per query PostGIS.
- **Config esplicita**: segreti mai in repo, config applicativa versionata in YAML.
- **Testabilità per fase**: ogni componente della pipeline è isolato e testabile indipendentemente.

---

## Struttura del sistema

```
┌─────────────────────────────────────────────────────────────┐
│                     App iOS (Swift)                         │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTPS
┌──────────────────────────▼──────────────────────────────────┐
│                  API Gateway (AWS)                          │
└──────┬──────────────────┬───────────────────┬───────────────┘
       │                  │                   │
┌──────▼──────┐  ┌────────▼───────┐  ┌────────▼──────────────┐
│ Auth/User   │  │   Map Service  │  │   Pipeline Worker     │
│ Module      │  │   Tile Proxy   │  │   (container separato)│
└──────┬──────┘  └────────┬───────┘  └────────┬──────────────┘
       │                  │                   │
┌──────▼──────┐  ┌────────▼───────┐  ┌────────▼──────────────┐
│ PostgreSQL  │  │   S3 + CDN     │  │  Open-Meteo API       │
│ + PostGIS   │  │   (tile PNG)   │  │  Copernicus/ESDAC     │
└─────────────┘  └────────────────┘  └───────────────────────┘
                          │
                   ┌──────▼──────┐
                   │    Redis    │
                   │ (cache/queue│
                   └─────────────┘
```

**Due container Docker su ECS Fargate:**
- `api` — Vapor HTTP server, sempre attivo (0.5 vCPU / 1GB RAM)
- `worker` — Pipeline scheduler, on-demand (2 vCPU / 4GB RAM)

---

## Moduli API (Vapor)

### AuthModule
- **Responsabilità**: registrazione, login, refresh token, Sign in with Apple
- **Tecnologie**: JWT RS256, bcrypt per password hashing
- **Endpoints**:
  - `POST /auth/register`
  - `POST /auth/login`
  - `POST /auth/refresh`
  - `POST /auth/apple` — Sign in with Apple (obbligatorio App Store)
- **Note**: JWT stateless. Refresh token ruotati ad ogni uso. Chiave RS256 in AWS Secrets Manager.

### UserModule
- **Responsabilità**: profilo utente, foto funghi, percorsi GPS, preferenze
- **Endpoints**:
  - `GET /user/profile` — `PUT /user/profile`
  - `POST /user/photos` — `GET /user/photos` — `DELETE /user/photos/:id`
  - `POST /user/routes` — `GET /user/routes`
- **Storage**: metadati in PostgreSQL, file binari (foto) su S3. Percorsi come `GEOMETRY(LineString, 4326)` in PostGIS.

### SubscriptionModule
- **Responsabilità**: piani free/pro, pagamenti, webhook Stripe
- **Piani**:
  - `free` — mappe zoom 6-9, nessuno storico
  - `pro` — mappe zoom 6-12, storico 90 giorni
- **Endpoints**:
  - `POST /subscription/checkout` — crea sessione Stripe
  - `POST /subscription/webhook` — webhook Stripe firmato
  - `GET /subscription/status`
- **Note**: lo stato abbonamento viene aggiornato esclusivamente via webhook Stripe, mai via chiamata diretta client.

### MapModule
- **Responsabilità**: servire tile mappe, lista date disponibili
- **Endpoints**:
  - `GET /map/tiles/:date/:z/:x/:y.png` — redirect firmato S3 (verifica subscription)
  - `GET /map/dates` — lista date con tile disponibili
- **Logica autorizzazione**: zoom ≤ 9 → tutti; zoom 10-12 → solo `pro`. Tile mancante → 404 (mai errore silenzioso).
- **URL S3**: `/{date}/{z}/{x}/{y}.png` — path deterministico, CDN-friendly.

### ReportModule
- **Responsabilità**: segnalazioni avvistamenti funghi da utenti
- **Endpoints**:
  - `POST /report/sighting` — posizione GPS + foto + specie
  - `GET /report/zone?lat=&lon=&radius=` — avvistamenti nell'area
- **Note**: dati aggregati utilizzabili per calibrare i pesi dello ScoringEngine nelle iterazioni future.

---

## Pipeline di calcolo mappe

La pipeline gira come processo separato (`worker`), schedulato di notte o on-demand via API admin. **Non è mai nel critical path delle richieste client.**

### Fase 1 — Acquisizione dati geografici statici (one-time)
Dati scaricati una volta, importati in PostGIS, aggiornati raramente (annualmente).

| Dataset | Fonte | Formato | Risoluzione |
|---------|-------|---------|-------------|
| Copertura forestale | Copernicus Land Cover (CORINE) | GeoTIFF | 100m |
| Altitudine (DTM) | Copernicus DEM | GeoTIFF | 25m |
| Tipo di suolo | ESDAC | GeoTIFF | 250m |
| Esposizione versanti | derivato da DTM con GDAL | GeoTIFF | 25m |

Strumenti: GDAL/PROJ per normalizzazione CRS (→ EPSG:4326), risampling a ~500m, import in PostGIS con `raster2pgsql`.

### Fase 2 — Generazione griglia 500m
- Genera ~280.000 punti equidistanti 500m sulla bbox Italia
- Metodo: griglia fishnet con `ST_GeneratePoints` o algoritmo custom
- Salvataggio in tabella `grid_points` (statica, ricalcolata solo se cambia risoluzione)

### Fase 3 — Lookup dati per ogni punto
Per ogni punto della griglia:
- Altitudine, tipo foresta, tipo suolo, esposizione → `ST_Value()` su raster PostGIS
- Dati meteo storici e previsionali → Open-Meteo API (batch, con cache Redis)

Strategia batch: gruppi da 5.000 punti, parallelizzabile con `TaskGroup` Swift.

### Fase 4 — Calcolo score probabilità

```
score(p) = w_forest    × forest_score(p)
         + w_rain      × rain_score(pioggia_14gg, p)
         + w_temp      × temp_score(temp_media, p)    // ottimale 15°–22°C
         + w_humidity  × humidity_score(p)
         + w_altitude  × altitude_score(p)            // ottimale 400–1200m s.l.m.
         + w_soil      × soil_score(p)

// Risultato normalizzato [0.0 – 1.0]
// Pesi configurabili in config/app.yaml → pipeline.scoringWeights
```

Output salvato in `grid_scores(location, score, computed_for_date)`.

### Fase 5 — Interpolazione e rendering tile
1. **Interpolazione IDW** (Inverse Distance Weighting) su grid_scores → superficie continua
2. **Rendering PNG tile XYZ** zoom 6-12 con colormap probabilità (verde → giallo → rosso)
3. Strumenti: GDAL (`gdal_grid`, `gdal2tiles`) via subprocess Swift o sidecar Python

### Fase 6 — Upload S3 e invalidazione CDN
- Upload tile su `s3://funghi-map-tiles/{YYYY-MM-DD}/{z}/{x}/{y}.png`
- Lifecycle policy S3: eliminazione automatica tile > 90 giorni
- CloudFront invalidation: `/*` sulla distribuzione dopo ogni run completato
- Notifica completamento: SNS → email sviluppatore

**Durata stimata run completo**: 5–20 minuti (dipende dalla parallelizzazione meteo fetch).

---

## Database

### ORM Strategy
- **Fluent ORM** → entità dominio utente (CRUD semplice, relazioni chiare)
- **SQLKit raw** → qualsiasi query con funzioni PostGIS, INSERT bulk pipeline

### Schema principale

```sql
-- Utenti e auth
users               (id, email, password_hash, apple_user_id, created_at)
refresh_tokens      (id, user_id, token_hash, expires_at, revoked_at)
subscriptions       (id, user_id, plan ENUM('free','pro'), stripe_customer_id,
                     stripe_subscription_id, expires_at, status)

-- Contenuti utente
photos              (id, user_id, s3_url, location GEOMETRY(Point,4326),
                     species, notes, taken_at)
routes              (id, user_id, path GEOMETRY(LineString,4326),
                     distance_km, elevation_gain_m, recorded_at)
sighting_reports    (id, user_id, location GEOMETRY(Point,4326),
                     species, found_at, photo_url, verified)

-- Pipeline mappe
grid_points         (id, location GEOMETRY(Point,4326), altitude_m,
                     forest_type, soil_type, aspect_deg)
grid_scores         (id, location GEOMETRY(Point,4326), score FLOAT,
                     computed_for_date DATE, created_at)
                     -- PARTITIONED BY computed_for_date dopo 90gg storico
```

### Indici obbligatori
```sql
CREATE INDEX ON photos USING GIST (location);
CREATE INDEX ON routes USING GIST (path);
CREATE INDEX ON sighting_reports USING GIST (location);
CREATE INDEX ON grid_points USING GIST (location);
CREATE INDEX ON grid_scores USING GIST (location);
CREATE INDEX ON grid_scores (computed_for_date);
```

### Note performance
- `grid_scores`: ~280k righe per data. Con 90gg storico → ~25M righe. Valutare partizionamento per `computed_for_date`.
- INSERT bulk pipeline: usare `COPY` o batch INSERT con SQLKit, mai Fluent riga per riga.

---

## Configurazione

### Strategia (12-Factor App)
- **Segreti** (DB URL, JWT key, Stripe key, AWS credentials) → AWS Secrets Manager + env vars ECS. Mai in file.
- **Config applicativa** (pesi scoring, parametri pipeline, porte) → `config/app.yaml`, versionato in repo.

### Struttura config/app.yaml
```yaml
server:
  port: 8080
  maxConnections: 200

pipeline:
  gridSpacingMeters: 500
  batchSize: 5000
  tileZoomMin: 6
  tileZoomMax: 12
  scoringWeights:
    forest:    0.30
    rain14d:   0.25
    temperature: 0.20
    altitude:  0.15
    soil:      0.10

map:
  tileSignedUrlTtlSeconds: 3600
  tileRetentionDays: 90
  freeMaxZoom: 9
  proMaxZoom: 12
```

### Librerie
- **Yams** — parsing YAML → struct Swift `Codable`
- **swift-dotenv** — caricamento `.env` in sviluppo locale
- **AWS SDK Swift** — fetch segreti da Secrets Manager all'avvio

---

## Logging

### Libreria: swift-log (Apple)
Backend swappabile senza modificare il codice applicativo.

| Ambiente | Backend | Formato |
|----------|---------|---------|
| Locale (dev) | `StreamLogHandler` | Testo colorato console |
| Produzione API | stdout → ECS log driver | JSON strutturato → CloudWatch |
| Pipeline Worker | stdout → CloudWatch (stream separato) | JSON strutturato |
| Alert | SNS topic su `.critical` o `.error` ricorrenti | Email / Slack |

### Convenzioni
- Ogni modulo istanzia `Logger(label: "funghi.<modulo>")` — es. `"funghi.auth"`, `"funghi.pipeline.scoring"`
- Mai `print()` nel codice applicativo
- Log `.error` sempre con metadata strutturati: `["error": "\(error)", "context": "..."]`
- Pipeline: log di inizio/fine per ogni fase con durata e conteggio record processati

---

## Testing

### Framework: Swift Testing (Swift 6)
Macro `@Test` e `#expect()`. Più moderno e conciso di XCTest classico.

### Strategia per livello

**Unit test** — logica pura, zero I/O:
| Target | Priorità | Note |
|--------|----------|------|
| `ScoringEngine` | CRITICO ≥90% | Input deterministici, snapshot test per regressioni pesi |
| `AuthModule (JWT)` | CRITICO | Mock clock per test scadenza token |
| `ConfigParser` | ALTO | YAML valido/malformato/campi mancanti |
| `WeatherScoreCalculator` | ALTO | Casi limite: pioggia zero, temp fuori range, dati null |
| `TilePathBuilder` | MEDIO | Funzione pura, path S3 deterministico |

**Integration test** — con Vapor `Application(.testing)` + TestContainers PostgreSQL reale:
- Flusso auth completo (register → login → JWT → profilo)
- Autorizzazione tile (pro vs free, zoom 10+ bloccato per free)
- Webhook Stripe (payload firmato → stato DB aggiornato)
- Segnalazioni con geometria PostGIS

**Pipeline test** — ogni fase isolata con dati fixture:
- `GeoDataLoader` — mock filesystem, GeoTIFF 10×10px fixture
- `GridGenerator` — bbox ridotta, verifica spaziatura 500m
- `WeatherFetcher` — URLProtocol mock, verifica retry su 429
- `ScoringEngine` — 100 punti con dati noti, output verificato punto per punto
- `TileGenerator` — tile PNG zoom 8-10 su area 50×50km, verifica 256×256px
- `S3Uploader` — mock AWS SDK, verifica path e metadata

### CI (GitHub Actions)
```yaml
on: [push, pull_request]
runs-on: ubuntu-latest  # Swift 6 Docker
services:
  postgres: postgres:16-postgis
steps:
  - swift test --parallel
  - swift test --enable-code-coverage
  # Coverage report su codecov.io (free tier)
# Target: ScoringEngine ≥ 90%, resto ≥ 60%
```

---

## Infrastruttura AWS

### Servizi utilizzati

| Servizio | Configurazione | Costo stimato |
|----------|---------------|---------------|
| ECS Fargate | 2 task: api (0.5vCPU/1GB) + worker (2vCPU/4GB on-demand) | ~€8/mese |
| RDS PostgreSQL | t3.micro, PostgreSQL 16 + PostGIS, 20GB | ~€0 (free tier 1 anno) |
| S3 Standard | Bucket tile + bucket foto utenti | ~€1/mese |
| CloudFront | CDN tile, 1TB/mese free tier | ~€0 |
| ElastiCache / Upstash | Redis, Upstash free tier (10k req/day) | ~€0 |
| Secrets Manager | ~5 segreti | ~€2/mese |
| CloudWatch Logs | Retention 30 giorni | ~€1/mese |
| **Totale stimato** | | **€8–15/mese** |

### Bucket S3

| Bucket | Contenuto | Versioning | Lifecycle |
|--------|-----------|-----------|-----------|
| `funghi-map-tiles` | Tile PNG pipeline | No | Delete > 90 giorni |
| `funghi-map-user-media` | Foto utenti | **Sì** | No |

### Sicurezza
- Nessun bucket S3 pubblico — accesso solo via CloudFront signed URL
- IAM roles per ECS task (niente access key hardcoded)
- Security groups: RDS accessibile solo da ECS, non da internet
- MFA Delete su bucket foto utenti

---

## Backup e Disaster Recovery

### Classificazione dati

| Tier | Dati | Recuperabilità |
|------|------|---------------|
| TIER 1 — Critico | Utenti, foto, percorsi, segnalazioni | Irrecuperabile senza backup |
| TIER 2 — Importante | Grid scores, log storici | Ricalcolabile ma costoso |
| TIER 3 — Ricalcolabile | Tile PNG, cache Redis, dati geo statici | Pipeline in ~15-20 min |

### Strategia backup

- **RDS**: backup automatici abilitati, retention 7 giorni, point-in-time recovery al minuto
- **RDS snapshot manuale**: ogni domenica notte via EventBridge, retention 4 settimane
- **S3 foto utenti**: versioning abilitato + MFA Delete + replica cross-region (eu-central-1)
- **CloudWatch alarm**: alert se backup RDS non eseguito nelle ultime 25h

### Obiettivi DR

| Metrica | Target |
|---------|--------|
| RTO (Recovery Time Objective) | 2 ore |
| RPO (Recovery Point Objective) | 24 ore |

### Runbook scenari principali

**DB corrotto/cancellato**: restore snapshot RDS da Console AWS (~10 min) → verifica integrità → riavvio ECS tasks.

**Tile S3 persi**: nessun dato utente coinvolto → trigger manuale pipeline → tile disponibili in ~20 min.

**Foto utenti perse**: S3 versioning → restore oggetti cancellati da Console. Se bucket distrutto: restore da replica cross-region.

**Credenziali AWS compromesse**: revocare access key da IAM → rotare tutti i segreti in Secrets Manager → audit CloudTrail → rideploy ECS.

---

## Fasi di sviluppo

### MVP (mese 1-2)
- [ ] Setup progetto Vapor + Docker Compose locale (Postgres + Redis)
- [ ] AuthModule completo (register, login, JWT, refresh)
- [ ] UserModule base (profilo, placeholder foto)
- [ ] Pipeline manuale con dati meteo mock e griglia ridotta (provincia test)
- [ ] Tile statici caricati a mano su S3
- [ ] App iOS che visualizza tile su MapLibre

### Beta (mese 3-4)
- [ ] Pipeline automatizzata con Open-Meteo reale
- [ ] ScoringEngine v1 con pesi fissi da config YAML
- [ ] SubscriptionModule + Stripe (free vs pro)
- [ ] Deploy ECS Fargate (api + worker)
- [ ] CI/CD GitHub Actions

### v1.0 (mese 5-6)
- [ ] ScoringEngine calibrato con dati reali e feedback segnalazioni
- [ ] ReportModule — segnalazioni utenti integrate nel modello
- [ ] Storico mappe 90 giorni
- [ ] Admin endpoint per trigger manuale pipeline + monitoring
- [ ] Backup automatici e monitoring CloudWatch completo

---

*Ultimo aggiornamento architettura: vedere git log*
