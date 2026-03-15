# Funghi Map — Makefile
# Comandi per gestione ambiente di sviluppo locale

# .env is loaded via shell in recipes that need it (Make's include can't
# handle complex values like PEM keys with spaces). Helper:
LOAD_ENV = if [ -f .env ]; then while IFS= read -r _line || [ -n "$$_line" ]; do echo "$$_line" | grep -qE '^\s*($$|\#)' && continue; export "$$_line"; done < .env; fi

.PHONY: up down restart build test db-setup status logs clean help

# ─── Start everything ───────────────────────────────────────────────
up: ## Start Postgres + Redis, setup DB, build and run Vapor server
	@echo "▶ Starting Docker services..."
	docker compose up -d --wait
	@echo "▶ Setting up database..."
	@$(LOAD_ENV) && bash scripts/db-setup.sh
	@echo "▶ Building Swift project..."
	swift build
	@echo "▶ Starting Vapor server on port 8080..."
	@$(LOAD_ENV) && swift run App serve --hostname 0.0.0.0 --port 8080

# ─── Stop everything ────────────────────────────────────────────────
down: ## Stop Vapor (if backgrounded) and Docker services
	@echo "▶ Stopping Docker services..."
	docker compose down
	@echo "✔ All services stopped."

# ─── Restart with rebuild ───────────────────────────────────────────
restart: down ## Stop everything, rebuild, and start again
	@echo "▶ Rebuilding and restarting..."
	$(MAKE) up

# ─── Build only ─────────────────────────────────────────────────────
build: ## Build Swift project without running
	swift build

# ─── Run tests ──────────────────────────────────────────────────────
test: ## Run all tests in parallel
	swift test --parallel

test-scoring: ## Run ScoringEngine tests only
	swift test --filter ScoringEngineTests

# ─── Database ───────────────────────────────────────────────────────
db-setup: ## Run DB setup script (create DB, enable PostGIS + uuid-ossp)
	@bash scripts/db-setup.sh

db-shell: ## Open psql shell to dev database
	psql postgres://funghimap:funghimap_dev@localhost:5432/funghimap_dev

# ─── Docker services only ──────────────────────────────────────────
services-up: ## Start only Postgres + Redis (no Vapor)
	docker compose up -d --wait

services-down: ## Stop only Docker services
	docker compose down

# ─── Status and logs ────────────────────────────────────────────────
status: ## Show status of Docker services
	@docker compose ps

logs: ## Tail Docker service logs
	docker compose logs -f

# ─── GeoData ─────────────────────────────────────────────────────────
geodata-import: ## Download and import geodata into PostGIS (auto-downloads from public sources)
	@$(LOAD_ENV) && bash scripts/import-geodata.sh

geodata-check: ## Verify raster tables exist in PostGIS
	@$(LOAD_ENV) && psql "$$DATABASE_URL" \
		-c "SELECT 'corine_landcover' AS t, count(*) FROM corine_landcover UNION ALL SELECT 'esdac_soil', count(*) FROM esdac_soil UNION ALL SELECT 'copernicus_dem', count(*) FROM copernicus_dem UNION ALL SELECT 'dem_aspect', count(*) FROM dem_aspect;"

# ─── Clean ──────────────────────────────────────────────────────────
clean: ## Remove Swift build artifacts
	swift package clean
	@echo "✔ Build artifacts cleaned."

clean-all: clean ## Clean build artifacts + Docker volumes (destroys local DB data)
	@echo "⚠  This will destroy local database data."
	docker compose down -v
	@echo "✔ All cleaned."

# ─── Help ───────────────────────────────────────────────────────────
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
