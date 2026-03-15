# Pipeline — Configurazione e Avvio

Guida per configurare e avviare la pipeline di calcolo mappe probabilita funghi.

---

## Prerequisiti

| Servizio | Come avviarlo | Note |
|----------|---------------|------|
| PostgreSQL 16 + PostGIS | `make services-up` | Docker Compose, porta 5432 |
| Redis 7 | `make services-up` | Docker Compose, porta 6379 |
| GDAL (`gdalwarp`, `raster2pgsql`) | `brew install gdal` / `apt install gdal-bin` | Solo per import dati geo raster |

---

## Variabili d'ambiente (secrets)

Tutte le credenziali sono in env vars, mai in file versionati. In sviluppo locale, usare `.env` nella root del progetto.

| Variabile | Obbligatoria | Descrizione | Esempio dev |
|-----------|:---:|-------------|-------------|
| `DATABASE_URL` | Si | Connection string PostgreSQL con PostGIS | `postgres://funghimap:funghimap_dev@localhost:5432/funghimap_dev` |
| `REDIS_URL` | Si | Connection string Redis | `redis://localhost:6379` |
| `JWT_PRIVATE_KEY_FILE` | Si | Path al file PEM della chiave privata RSA per JWT | `./Keys/jwt_private.pem` |
| `ADMIN_API_KEY` | Si (per trigger pipeline) | Token Bearer per endpoint admin | Qualsiasi stringa sicura, es. `my-secret-admin-key` |
| `CLMS_SERVICE_KEY_FILE` | Si (per geodata import) | Path al file JSON service key CLMS (per CORINE, Tree Cover, Leaf Type) | `secrets/clms-key.json` |
| `AWS_ACCESS_KEY_ID` | No (solo deploy) | Credenziali AWS per S3 upload | — |
| `AWS_SECRET_ACCESS_KEY` | No (solo deploy) | Credenziali AWS per S3 upload | — |

**Per iniziare in locale**, basta aggiungere `ADMIN_API_KEY` al `.env` esistente:

```
ADMIN_API_KEY=dev-admin-key
```

---

## Configurazione applicativa (`config/app.yaml`)

Tutti i parametri operativi della pipeline sono in `config/app.yaml`, versionato nel repo. Nessun segreto in questo file.

### Parametri pipeline

```yaml
pipeline:
  gridSpacingMeters: 500        # Spaziatura griglia in metri
  batchSize: 5000               # Punti per batch (enrichment + weather)
  tileZoomMin: 6                # Zoom minimo tile XYZ
  tileZoomMax: 12               # Zoom massimo tile XYZ
```

| Parametro | Default | Effetto |
|-----------|---------|---------|
| `gridSpacingMeters` | 500 | Distanza tra punti griglia. Ridurre = piu punti = piu tempo/precisione |
| `batchSize` | 5000 | Dimensione batch per TaskGroup. Impatta parallelismo e memoria |
| `tileZoomMin`/`Max` | 6 / 12 | Range zoom dei tile PNG generati |

### Pesi scoring

```yaml
  scoringWeights:
    forest: 0.30
    rain14d: 0.25
    temperature: 0.20
    altitude: 0.15
    soil: 0.10
```

La somma deve essere 1.0. Modificare per calibrare l'importanza relativa dei fattori.

### Weather (Open-Meteo)

```yaml
  weather:
    baseURL: "https://archive-api.open-meteo.com/v1/archive"
    maxConcurrentRequests: 50     # Richieste HTTP parallele max
    retryMaxAttempts: 3           # Tentativi retry su errore 429/5xx
    retryBaseDelayMs: 500         # Delay base retry (exponential backoff)
    cacheTTLSeconds: 86400        # Cache Redis: 24 ore
```

| Parametro | Note |
|-----------|------|
| `baseURL` | Open-Meteo Archive API, gratuita, nessuna API key |
| `maxConcurrentRequests` | Ridurre se si ricevono troppi 429. Per Trentino (24k punti) 50 e sufficiente |
| `cacheTTLSeconds` | Dopo il primo run, i dati meteo per la stessa data sono in cache Redis |

### GeoData (Raster PostGIS)

Nessuna configurazione in `app.yaml` — i dati geografici (altitudine, aspetto, foresta, suolo) vengono tutti da tabelle raster PostGIS importate una tantum con `make geodata-import`:

| Tabella | Sorgente | Dati |
|---------|----------|------|
| `copernicus_dem` | Copernicus DEM GLO-25 (AWS S3) | Elevazione (metri) |
| `dem_aspect` | Derivato da DEM con `gdaldem aspect` | Esposizione (gradi 0-360) |
| `corine_landcover` | CORINE CLC 2018 (CLMS API) | Copertura forestale (codici CLC) |
| `esdac_soil` | ISRIC SoilGrids WRB | Tipo di suolo |
| `tree_cover_density` | HRL Tree Cover Density 2018 (CLMS API) | Densita copertura arborea (0-100%) |
| `dominant_leaf_type` | HRL Dominant Leaf Type 2018 (CLMS API) | Tipo foglia dominante (0=non-albero, 1=latifoglie, 2=conifere) |

Query sub-millisecondo via `ST_Value()`, nessuna dipendenza internet, nessuna cache Redis necessaria.

### S3

```yaml
s3:
  tileBucket: funghi-map-tiles
  region: eu-south-1
  uploadBatchSize: 50
```

Rilevante solo con S3 uploader reale (non il mock). Richiede credenziali AWS.

---

## Setup dati geografici (one-time)

I dati raster (foresta, suolo, altitudine, aspetto) devono essere importati in PostGIS una volta sola.

In assenza di raster, la pipeline usa valori di default (`.none` per foresta, `.other` per suolo, `0` per altitudine/aspetto).

**Nota**: all'avvio l'app verifica che la tabella `copernicus_dem` esista e contenga dati. Se mancante, logga un warning.

### Prerequisito: CLMS Service Key

CORINE, Tree Cover Density e Dominant Leaf Type richiedono autenticazione CLMS:

1. Creare account EU Login gratuito su https://land.copernicus.eu
2. Profile → API Tokens → Create → scaricare il file JSON service key
3. Aggiungere a `.env`: `CLMS_SERVICE_KEY_FILE=path/to/key.json`
4. **Non versionare il file key** — aggiungerlo a `.gitignore`

Docs: https://eea.github.io/clms-api-docs/authentication.html

### Fonti dati

1. **CORINE Land Cover CLC 2018** (copertura forestale):
   - Fonte: CLMS Download API (richiede `CLMS_SERVICE_KEY_FILE`)
   - Risoluzione: 100m, codici classificazione CLC (311=latifoglie, 312=conifere, 313=misto)
   - Fallback: download manuale da https://land.copernicus.eu/en/products/corine-land-cover/clc2018

2. **Tree Cover Density HRL 2018** (densita copertura arborea):
   - Fonte: CLMS Download API (richiede `CLMS_SERVICE_KEY_FILE`)
   - Risoluzione: 10m, valori 0-100 (percentuale copertura)
   - Opzionale: complemento a CORINE per scoring piu preciso

3. **Dominant Leaf Type HRL 2018** (tipo foglia dominante):
   - Fonte: CLMS Download API (richiede `CLMS_SERVICE_KEY_FILE`)
   - Risoluzione: 10m, classificazione 0=non-albero, 1=latifoglie, 2=conifere
   - Opzionale: complemento a CORINE a risoluzione maggiore

4. **Classificazione suolo** (tipo di suolo):
   - Fonte: ISRIC SoilGrids WRB (open access, no auth)
   - Risoluzione: 250m, copertura globale
   - Codici WRB mappati a calcareous/siliceous/mixed in `PostGISForestClient.swift`
   - Alternativa manuale: ESDAC (richiede registrazione JRC gratuita)

5. **Copernicus DEM GLO-25** (altitudine 25m + aspetto derivato):
   - Fonte: AWS Open Data `s3://copernicus-dem-25m/` (public, no auth)
   - Risoluzione: 25m, ~144 tile da 1° per l'Italia
   - Genera automaticamente il raster aspetto via `gdaldem aspect`
   - Tabelle PostGIS: `copernicus_dem` (elevazione in metri), `dem_aspect` (gradi 0-360, 0=flat)

### Import in PostGIS

```bash
make geodata-import
```

Oppure manualmente:

```bash
bash scripts/import-geodata.sh
```

Lo script verifica la presenza dei file in `data/geodata/`, riprojetta a EPSG:4326, e importa con `raster2pgsql`.

### Verifica import

```bash
make geodata-check
```

Deve mostrare il conteggio tile per tutte le tabelle raster: `corine_landcover`, `esdac_soil`, `copernicus_dem`, `dem_aspect`. Le tabelle opzionali `tree_cover_density` e `dominant_leaf_type` vengono mostrate se presenti.

---

## Avviare la pipeline

### 1. Avvio servizi + server

```bash
make up
```

Avvia Docker (Postgres + Redis), esegue setup DB, builda e avvia Vapor.

### 2. Trigger pipeline via API

```bash
# Run pipeline con bbox Trentino e data odierna (default)
curl -X POST http://localhost:8080/admin/pipeline/run \
  -H "Authorization: Bearer dev-admin-key" \
  -H "Content-Type: application/json"

# Run con data e bbox specifici
curl -X POST http://localhost:8080/admin/pipeline/run \
  -H "Authorization: Bearer dev-admin-key" \
  -H "Content-Type: application/json" \
  -d '{
    "date": "2026-03-14",
    "bbox": {
      "minLat": 45.8, "maxLat": 46.5,
      "minLon": 10.8, "maxLon": 11.8
    }
  }'
```

La risposta e immediata (202 Accepted). La pipeline gira in background.

### Parametri endpoint

| Campo | Tipo | Default | Descrizione |
|-------|------|---------|-------------|
| `date` | string `YYYY-MM-DD` | Oggi (Europe/Rome) | Data per cui calcolare la mappa |
| `bbox` | oggetto | Trentino (45.8-46.5 N, 10.8-11.8 E) | Area geografica |
| `bbox.minLat` | double | 45.8 | Latitudine minima |
| `bbox.maxLat` | double | 46.5 | Latitudine massima |
| `bbox.minLon` | double | 10.8 | Longitudine minima |
| `bbox.maxLon` | double | 11.8 | Longitudine massima |

### Risposta

```json
{
  "status": "accepted",
  "date": "2026-03-14",
  "message": "Pipeline run started asynchronously"
}
```

---

## Fasi della pipeline

| Fase | Sorgente dati | Richiede internet | Richiede raster PostGIS |
|------|---------------|:-:|:-:|
| 1. Grid generation | Calcolo locale | No | No |
| 2. Geo enrichment (altitudine, aspect) | PostGIS raster (Copernicus DEM) | No | Si |
| 2. Geo enrichment (foresta, suolo) | PostGIS raster (CORINE/ESDAC) | No | Si |
| 3. Weather fetch | Open-Meteo Archive API | Si | No |
| 4. Scoring | Calcolo locale | No | No |
| 5. Tile generation | Calcolo locale | No | No |
| 6. S3 upload | AWS S3 | Si | No |

### Resilienza errori

Se una chiamata API o una query fallisce per un singolo punto:
- Il punto riceve valori di default (altitudine 0, foresta `.none`, suolo `.other`, meteo zero)
- Un warning viene loggato con coordinate e errore
- La pipeline continua con gli altri punti
- A fine fase, un log sommario riporta il numero di fallimenti

---

## Tempi stimati (Trentino, ~24k punti)

| Fase | Prima esecuzione | Esecuzioni successive (cache) |
|------|:---:|:---:|
| Weather fetch | ~2-5 min | < 10 sec |
| PostGIS raster query (altitudine + aspetto + foresta + suolo) | ~30-60 sec | ~30-60 sec (locale, nessuna cache necessaria) |
| Tile generation | ~10-15 sec | ~10-15 sec |
| **Totale** | **~3-10 min** | **~1-2 min** |

La cache Redis riduce drasticamente i tempi meteo dopo il primo run per la stessa data. I dati geo (altitudine, foresta, suolo) sono locali in PostGIS e non richiedono cache.

---

## Logging

La pipeline logga ogni fase con label `funghi.pipeline.*`:

```
funghi.pipeline          — Orchestratore (durata fasi, conteggio punti)
funghi.pipeline.weather.openmeteo — Richieste HTTP Open-Meteo
funghi.pipeline.weather.cache     — Hit/miss cache Redis meteo
funghi.pipeline.geodata.altitude  — Query PostGIS altitudine/aspetto (o HTTP se openmeteo)
funghi.pipeline.geodata.postgis   — Query raster PostGIS
funghi.admin             — Trigger endpoint, autorizzazione
```

---

## Troubleshooting

| Problema | Causa | Soluzione |
|----------|-------|-----------|
| `401 Unauthorized` su `/admin/pipeline/run` | `ADMIN_API_KEY` mancante o errata | Verificare env var e header `Authorization: Bearer <key>` |
| Weather fetch 100% fallimenti | Nessuna connessione internet | La pipeline continua con score 0 per tutti i punti |
| Foresta/suolo tutti `.none`/`.other` | Tabelle raster non importate | Eseguire `make geodata-import` |
| `postgis_raster extension not found` | PostGIS raster non installato | Usare immagine Docker `postgis/postgis:16-3.5` (gia configurata) |
| Redis connection refused | Redis non avviato | `make services-up` |
| Troppi errori 429 da Open-Meteo | Rate limiting | Ridurre `maxConcurrentRequests` in `app.yaml` |
