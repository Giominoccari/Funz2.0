# Funghi Map — Backend

API backend + pipeline di calcolo mappe probabilità funghi per app iOS.
Architettura di riferimento: `docs/architecture.md` (non duplicare qui).

## Stack
- **Linguaggio**: Swift 6 con concurrency nativa (async/await, actors)
- **Framework API**: Vapor 4
- **Database**: PostgreSQL 16 + PostGIS — ORM Fluent per entità utente, SQLKit raw per query geografiche
- **Cache / Queue**: Redis (Upstash free tier)
- **Storage**: AWS S3 + CloudFront (tile mappe e foto utenti)
- **Meteo**: Open-Meteo API (gratuita, no API key)
- **Deploy**: AWS ECS Fargate — 2 container: `api` (sempre attivo) + `worker` (pipeline on-demand)

## Struttura del progetto
```
Sources/
  App/              # Entry point Vapor
  Modules/
    Auth/           # JWT RS256 + Sign in with Apple
    User/           # Profilo, foto, percorsi GPS
    Subscription/   # Stripe webhook e piani
    Map/            # Proxy tile S3, lista date disponibili
    Report/         # Segnalazioni avvistamenti utenti
  Pipeline/
    GeoDataLoader/  # Lettura GeoTIFF via GDAL
    GridGenerator/  # Griglia 500m su bbox Italia
    WeatherFetcher/ # Open-Meteo con cache Redis
    ScoringEngine/  # Calcolo score probabilità funghi
    TileGenerator/  # Rendering PNG tile XYZ
    S3Uploader/     # Upload tile + invalidazione CloudFront
  Core/
    Config/         # Parsing YAML con Yams + env vars
    Logging/        # swift-log, JSON in produzione
    DB/             # Migrations, connessione PostGIS
Tests/
  UnitTests/
  IntegrationTests/
config/
  app.yaml          # Config applicativa (versionata)
  # secrets.yaml    # MAI in repo — usare AWS Secrets Manager
docs/
  architecture.md   # Documento architetturale completo
```

## Regole di sviluppo

### Generale
- Swift 6 strict concurrency: nessun `@unchecked Sendable` senza commento esplicito
- Preferire `async/await` a callback o Combine
- Ogni modulo ha la propria cartella con file separati per routes, models, controllers
- Nessun segreto hardcoded — sempre da `Environment` o AWS Secrets Manager

### Database
- Fluent ORM per: `User`, `Subscription`, `Photo`, `Route`, `SightingReport`
- SQLKit raw per: qualsiasi query con funzioni PostGIS (`ST_Value`, `ST_Intersects`, `ST_DWithin`)
- Indice GIST obbligatorio su ogni colonna `GEOMETRY`
- INSERT bulk nella pipeline: usare batch da 5.000 righe, mai riga per riga

### Logging
- Usare sempre `Logger` da `swift-log`, mai `print()`
- Ogni modulo istanzia il proprio logger: `Logger(label: "funghi.auth")`
- In sviluppo: `StreamLogHandler` (console). In produzione: JSON stdout → CloudWatch
- Livelli: `.trace` solo locale, `.error` sempre con metadata strutturati

### Configurazione
- Config applicativa (pesi scoring, parametri griglia, porte): `config/app.yaml` decodificato in struct `Codable`
- Segreti (DB URL, JWT key, Stripe key): solo env vars o AWS Secrets Manager, mai in file
- All'avvio validare la config completa e crashare con `.critical` se mancano valori obbligatori

### Pipeline (Worker)
- Ogni fase è una struct/actor indipendente e testabile in isolamento
- I pesi dello `ScoringEngine` sono letti da `config/app.yaml`, non hardcoded
- La pipeline scrive log dettagliati su ogni fase con durata e conteggio record
- In caso di errore parziale: loggare, continuare sulle fasi successive, notificare al termine

### Testing
- Framework: Swift Testing (`@Test`, `#expect()`) — non XCTest classico
- `ScoringEngine`: copertura ≥ 90%, test deterministici con input/output noti
- Integration test Vapor con `Application(.testing)` + PostgreSQL reale (TestContainers)
- Mock HTTP con `URLProtocol` per Open-Meteo e Stripe webhook
- Nessun test che chiama servizi esterni reali

### Sicurezza
- JWT firmati RS256, refresh token ruotati ad ogni uso
- Stripe webhook: verificare sempre la firma `Stripe-Signature`
- S3 tile premium: URL firmati con scadenza 1h, mai bucket pubblico
- Pre-commit hook: bloccare commit con pattern `password:`, `secret:`, chiavi PEM

## Comandi frequenti
```bash
swift build                          # Build progetto
swift test --parallel                # Tutti i test in parallelo
swift test --filter ScoringEngineTests  # Test specifici
vapor run serve --port 8080          # Avvio server locale
docker compose up                    # Postgres + Redis locali
```

## Cosa NON fare
- Non usare `print()` per il logging
- Non scrivere query PostGIS con Fluent — usare SQLKit
- Non mettere segreti in `config/app.yaml` o in qualsiasi file versionato
- Non fare INSERT riga per riga nella pipeline (usare batch)
- Non esporre tile S3 senza verifica subscription dell'utente
