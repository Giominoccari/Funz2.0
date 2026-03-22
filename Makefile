# Funghi Map — Makefile
# Comandi per gestione ambiente di sviluppo locale

# .env is loaded via shell in recipes that need it (Make's include can't
# handle complex values like PEM keys with spaces). Helper:
LOAD_ENV = if [ -f .env ]; then while IFS= read -r _line || [ -n "$$_line" ]; do echo "$$_line" | grep -qE '^\s*($$|\#)' && continue; export "$$_line"; done < .env; fi

.PHONY: up down restart build test db-setup status logs clean help docker-build deploy deploy-api deploy-worker cfn-deploy \
       beta-up beta-down beta-restart beta-build beta-logs beta-status \
       beta-db-up beta-db-down beta-db-shell beta-db-setup \
       beta-redis-up beta-redis-down \
       beta-app-up beta-app-down beta-app-restart beta-app-logs \
       beta-setup beta-ssl-renew

# ─── Start everything ───────────────────────────────────────────────
up: ## Start Postgres + Redis, setup DB, build and run Vapor server
	@echo "▶ Starting Docker services..."
	docker compose -f infra/docker/docker-compose.yml up -d --wait
	@echo "▶ Setting up database..."
	@$(LOAD_ENV) && bash infra/scripts/db-setup.sh
	@echo "▶ Building Swift project..."
	swift build
	@echo "▶ Starting Vapor server on port 8080..."
	@$(LOAD_ENV) && swift run App serve --hostname 0.0.0.0 --port 8080

# ─── Stop everything ────────────────────────────────────────────────
down: ## Stop Vapor (if backgrounded) and Docker services
	@echo "▶ Stopping Docker services..."
	docker compose -f infra/docker/docker-compose.yml down
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
	@bash infra/scripts/db-setup.sh

db-shell: ## Open psql shell to dev database
	psql postgres://funghimap:funghimap_dev@localhost:5432/funghimap_dev

# ─── Docker services only ──────────────────────────────────────────
services-up: ## Start only Postgres + Redis (no Vapor)
	docker compose -f infra/docker/docker-compose.yml up -d --wait

services-down: ## Stop only Docker services
	docker compose -f infra/docker/docker-compose.yml down

# ─── Status and logs ────────────────────────────────────────────────
status: ## Show status of Docker services
	@docker compose -f infra/docker/docker-compose.yml ps

logs: ## Tail Docker service logs
	docker compose -f infra/docker/docker-compose.yml logs -f

# ─── GeoData ─────────────────────────────────────────────────────────
GEODATA_VENV = .venv/geodata
GEODATA_PYTHON = $(GEODATA_VENV)/bin/python3

$(GEODATA_VENV)/bin/hda: ## (internal) Create venv with hda installed
	@echo "▶ Creating Python venv for WEkEO downloads..."
	python3 -m venv $(GEODATA_VENV)
	$(GEODATA_VENV)/bin/pip install --quiet --upgrade pip
	$(GEODATA_VENV)/bin/pip install --quiet hda
	@echo "  ✔ venv ready at $(GEODATA_VENV) with hda installed"

geodata-import: $(GEODATA_VENV)/bin/hda ## Download and import geodata into PostGIS (WEkEO + ISRIC)
	@$(LOAD_ENV) && $(GEODATA_PYTHON) infra/scripts/import-geodata.py

geodata-check: ## Verify raster tables exist in PostGIS
	@$(LOAD_ENV) && psql "$$DATABASE_URL" \
		-c "SELECT 'corine_landcover' AS t, count(*) FROM corine_landcover UNION ALL SELECT 'esdac_soil', count(*) FROM esdac_soil UNION ALL SELECT 'copernicus_dem', count(*) FROM copernicus_dem UNION ALL SELECT 'dem_aspect', count(*) FROM dem_aspect;"

# ─── Deploy (ECS Fargate) ──────────────────────────────────
docker-build: ## Build Docker image locally (linux/amd64)
	docker build --platform linux/amd64 -f infra/docker/Dockerfile -t funghi-map:latest .

deploy: ## Build, push to ECR, deploy API + worker to ECS Fargate
	@bash infra/scripts/deploy.sh

deploy-api: ## Deploy API service only
	@bash infra/scripts/deploy.sh --api-only

deploy-worker: ## Update worker task definition only
	@bash infra/scripts/deploy.sh --worker-only

cfn-deploy: ## Deploy/update CloudFormation stack (requires parameters file)
	@echo "▶ Deploying CloudFormation stack..."
	aws cloudformation deploy \
		--template-file infra/cloudformation/stack.yaml \
		--stack-name funghi-map-$${ENVIRONMENT:-production} \
		--capabilities CAPABILITY_NAMED_IAM \
		--parameter-overrides file://infra/cloudformation/params.json

# ─── Clean ──────────────────────────────────────────────────────────
clean: ## Remove Swift build artifacts
	swift package clean
	@echo "✔ Build artifacts cleaned."

clean-all: clean ## Clean build artifacts + Docker volumes (destroys local DB data)
	@echo "⚠  This will destroy local database data."
	docker compose -f infra/docker/docker-compose.yml down -v
	@echo "✔ All cleaned."

# ═══════════════════════════════════════════════════════════════════
# Beta Server (self-hosted Mac)
# Nginx + certbot run on host; app, DB, Redis in Docker.
# ═══════════════════════════════════════════════════════════════════
BETA_COMPOSE = docker compose -f infra/docker/docker-compose.beta.yml --env-file .env.beta

# ─── Beta: All services ──────────────────────────────────────────
beta-up: ## Start all beta services (DB + Redis + App)
	@echo "▶ Starting beta services..."
	$(BETA_COMPOSE) up -d --wait
	@echo "▶ Setting up database..."
	@DB_HOST=127.0.0.1 DB_USER=funghimap DB_NAME=funghimap_beta DB_PASSWORD=funghimap_beta bash infra/scripts/db-setup.sh
	@echo "✔ Beta server running on http://127.0.0.1:8080"

beta-down: ## Stop all beta services (preserves data volumes)
	@echo "▶ Stopping beta services..."
	$(BETA_COMPOSE) down
	@echo "✔ Beta services stopped. Data volumes preserved."

beta-restart: ## Restart all beta services
	$(MAKE) beta-down
	$(MAKE) beta-up

beta-status: ## Show status of all beta containers
	@$(BETA_COMPOSE) ps

beta-logs: ## Tail logs for all beta services
	$(BETA_COMPOSE) logs -f

# ─── Beta: Database only ─────────────────────────────────────────
beta-db-up: ## Start only PostgreSQL
	$(BETA_COMPOSE) up -d postgres --wait
	@echo "✔ PostgreSQL running on 127.0.0.1:5432"

beta-db-down: ## Stop only PostgreSQL (preserves data)
	$(BETA_COMPOSE) stop postgres

beta-db-shell: ## Open psql shell to beta database
	psql postgres://funghimap:funghimap_beta@127.0.0.1:5432/funghimap_beta

beta-db-setup: ## Run DB setup on beta (PostGIS + uuid-ossp)
	@DB_HOST=127.0.0.1 DB_USER=funghimap DB_NAME=funghimap_beta DB_PASSWORD=funghimap_beta bash infra/scripts/db-setup.sh

# ─── Beta: Redis only ────────────────────────────────────────────
beta-redis-up: ## Start only Redis
	$(BETA_COMPOSE) up -d redis --wait
	@echo "✔ Redis running on 127.0.0.1:6379"

beta-redis-down: ## Stop only Redis
	$(BETA_COMPOSE) stop redis

# ─── Beta: App only (requires DB + Redis running) ────────────────
beta-app-up: ## Start only the Vapor app container
	$(BETA_COMPOSE) up -d app --wait
	@echo "✔ Vapor app running on 127.0.0.1:8080"

beta-app-down: ## Stop only the Vapor app container
	$(BETA_COMPOSE) stop app

beta-app-restart: ## Restart only the Vapor app (DB + Redis stay up)
	$(BETA_COMPOSE) stop app
	$(BETA_COMPOSE) up -d app --wait
	@echo "✔ Vapor app restarted"

beta-app-logs: ## Tail logs for the Vapor app only
	$(BETA_COMPOSE) logs -f app

# ─── Beta: Build & Deploy ────────────────────────────────────────
beta-build: ## Rebuild the Vapor Docker image without starting
	$(BETA_COMPOSE) build app
	@echo "✔ Beta image rebuilt"

beta-rebuild: ## Rebuild image and restart app only (DB + Redis stay up)
	$(BETA_COMPOSE) build app
	$(BETA_COMPOSE) up -d app --wait --force-recreate
	@echo "✔ App rebuilt and restarted"

# ─── Beta: Infrastructure ────────────────────────────────────────
beta-setup: ## One-time setup: install nginx, certbot, DuckDNS (run on beta Mac)
	@bash infra/beta/setup.sh

beta-ssl-renew: ## Manually trigger certbot renewal
	sudo certbot renew --post-hook "brew services restart nginx"

beta-nginx-restart: ## Restart nginx
	brew services restart nginx

beta-clean: ## Remove beta Docker volumes (DESTROYS beta data)
	@echo "⚠  This will destroy beta database data."
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	$(BETA_COMPOSE) down -v
	@echo "✔ Beta volumes removed."

# ─── Help ───────────────────────────────────────────────────────────
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
