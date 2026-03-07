# Funghi Map — Progress Tracker

Stato avanzamento rispetto alle fasi definite in `architecture.md`.

---

## MVP (mese 1-2)

- [x] Setup progetto Vapor + Docker Compose locale (Postgres + Redis)
- [x] AuthModule completo (register, login, JWT, refresh)
- [ ] UserModule base (profilo, placeholder foto)
- [ ] Pipeline manuale con dati meteo mock e griglia ridotta (provincia test)
- [ ] Tile statici caricati a mano su S3
- [ ] App iOS che visualizza tile su MapLibre

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
