# Funghi Map — Makefile
# Unified commands for local dev and beta. Behavior differs via .env values.

COMPOSE = docker compose -f infra/docker/docker-compose.yml --env-file .env

# Load .env into shell (for host-side scripts like db-setup, geodata-import)
LOAD_ENV = if [ -f .env ]; then while IFS= read -r _line || [ -n "$$_line" ]; do echo "$$_line" | grep -qE '^\s*($$|\#)' && continue; export "$$_line"; done < .env; fi

.PHONY: up down restart status logs app-logs \
        build rebuild quick \
        db-setup db-shell db-up db-down redis-up redis-down \
        app-up app-down app-restart \
        worker worker-trentino worker-forecast worker-forecast-trentino worker-evaluate \
        geodata-import geodata-import-boundary geodata-check \
        swift-build swift-test swift-test-scoring \
        docker-build deploy deploy-api deploy-worker cfn-deploy \
        clean clean-all \
        beta-setup beta-ssl-renew beta-nginx-restart \
        help

# ═══════════════════════════════════════════════════════════════════
# Core — Start / Stop / Status
# ═══════════════════════════════════════════════════════════════════

up: ## Start all containers (postgres + redis + app) and setup DB
	@mkdir -p Storage/tiles .cache
	@echo "▶ Starting services..."
	$(COMPOSE) up -d --wait
	@echo "▶ Setting up database..."
	@$(LOAD_ENV) && DB_PASSWORD="$$DB_PASSWORD" DB_USER="$$DB_USER" DB_NAME="$$DB_NAME" bash infra/scripts/db-setup.sh
	@echo "✔ All services running on http://127.0.0.1:8080"

down: ## Stop all containers (preserves data)
	@echo "▶ Stopping services..."
	$(COMPOSE) down
	@echo "✔ All services stopped. Data preserved."

restart: down up ## Stop and restart everything

status: ## Show container status
	@$(COMPOSE) ps

logs: ## Tail all service logs (from beginning)
	$(COMPOSE) logs -f

logs-live: ## Tail only new log lines (skip history)
	$(COMPOSE) logs -f --since=1s

app-logs: ## Tail app logs only
	$(COMPOSE) logs -f app

# ═══════════════════════════════════════════════════════════════════
# Build — Docker image management
# ═══════════════════════════════════════════════════════════════════

build: ## Build app Docker image without starting
	$(COMPOSE) build app
	@echo "✔ Image rebuilt"

rebuild: ## Rebuild image and restart app (DB + Redis stay up)
	$(COMPOSE) build --no-cache app
	$(COMPOSE) up -d app --wait --force-recreate
	@echo "✔ App rebuilt and restarted"

quick: ## Restart app without rebuild (for config/Public changes)
	docker rm -f funz-app 2>/dev/null || true
	$(COMPOSE) up -d app --wait
	@echo "✔ App restarted with updated static assets"

# ═══════════════════════════════════════════════════════════════════
# Individual services
# ═══════════════════════════════════════════════════════════════════

db-up: ## Start only PostgreSQL
	$(COMPOSE) up -d postgres --wait
	@echo "✔ PostgreSQL running on 127.0.0.1:5432"

db-down: ## Stop only PostgreSQL (preserves data)
	$(COMPOSE) stop postgres

redis-up: ## Start only Redis
	$(COMPOSE) up -d redis --wait
	@echo "✔ Redis running on 127.0.0.1:6379"

redis-down: ## Stop only Redis
	$(COMPOSE) stop redis

app-up: ## Start only the app container
	$(COMPOSE) up -d app --wait
	@echo "✔ App running on 127.0.0.1:8080"

app-down: ## Stop only the app container
	$(COMPOSE) stop app

app-restart: ## Restart only the app (DB + Redis stay up)
	$(COMPOSE) stop app
	$(COMPOSE) up -d app --wait
	@echo "✔ App restarted"

# ═══════════════════════════════════════════════════════════════════
# Database
# ═══════════════════════════════════════════════════════════════════

db-setup: ## Run DB setup (create DB, enable PostGIS + uuid-ossp)
	@$(LOAD_ENV) && DB_PASSWORD="$$DB_PASSWORD" DB_USER="$$DB_USER" DB_NAME="$$DB_NAME" bash infra/scripts/db-setup.sh

db-shell: ## Open psql shell to the database
	@$(LOAD_ENV) && psql "postgres://$$DB_USER:$$DB_PASSWORD@localhost:5432/$$DB_NAME"

# ═══════════════════════════════════════════════════════════════════
# Pipeline
# ═══════════════════════════════════════════════════════════════════

worker: ## Run historical map pipeline
	docker exec funz-app /app/App worker --bbox italy

worker-trentino: ## Run historical pipeline (Trentino only, faster)
	docker exec funz-app /app/App worker --bbox trentino

worker-full: worker worker-forecast ## Run historical + forecast pipeline (Italy)

worker-forecast: ## Run forecast pipeline (generates tiles/forecast/YYYY-MM-DD/ for next 5 days)
	docker exec funz-app /app/App worker --bbox italy --mode forecast

worker-forecast-trentino: ## Run forecast pipeline (Trentino only, faster)
	docker exec funz-app /app/App worker --bbox trentino --mode forecast

worker-evaluate: ## Evaluate forecast scores at POIs and send push notifications
	docker exec funz-app /app/App evaluate

GEODATA_VENV = .venv/geodata
GEODATA_PYTHON = $(GEODATA_VENV)/bin/python3

$(GEODATA_VENV)/bin/hda:
	@echo "▶ Creating Python venv for WEkEO downloads..."
	python3 -m venv $(GEODATA_VENV)
	$(GEODATA_VENV)/bin/pip install --quiet --upgrade pip
	$(GEODATA_VENV)/bin/pip install --quiet hda
	@echo "  ✔ venv ready at $(GEODATA_VENV)"

geodata-import: $(GEODATA_VENV)/bin/hda ## Download and import geodata into PostGIS (pass DATASETS=name to import one)
	@$(LOAD_ENV) && \
		DATABASE_URL="postgres://$$DB_USER:$$DB_PASSWORD@localhost:5432/$$DB_NAME" \
		PYTHONUNBUFFERED=1 \
		$(GEODATA_PYTHON) infra/scripts/import-geodata.py $(DATASETS)

geodata-import-boundary: $(GEODATA_VENV)/bin/hda ## Import only Italy boundary polygon (fast, no WEkEO needed)
	@$(LOAD_ENV) && \
		DATABASE_URL="postgres://$$DB_USER:$$DB_PASSWORD@localhost:5432/$$DB_NAME" \
		PYTHONUNBUFFERED=1 \
		$(GEODATA_PYTHON) infra/scripts/import-geodata.py italy_boundary

geodata-check: ## Verify raster tables exist in PostGIS
	@$(LOAD_ENV) && psql "postgres://$$DB_USER:$$DB_PASSWORD@localhost:5432/$$DB_NAME" \
		-c "SELECT 'corine_landcover' AS t, count(*) FROM corine_landcover UNION ALL SELECT 'tree_cover_density', count(*) FROM tree_cover_density UNION ALL SELECT 'dominant_leaf_type', count(*) FROM dominant_leaf_type UNION ALL SELECT 'esdac_soil', count(*) FROM esdac_soil UNION ALL SELECT 'copernicus_dem', count(*) FROM copernicus_dem UNION ALL SELECT 'dem_aspect', count(*) FROM dem_aspect;"

redis-flush: ## Flush all Redis data (weather cache etc.)
	docker exec funz-redis redis-cli FLUSHALL

# ═══════════════════════════════════════════════════════════════════
# Swift — Native build/test (without Docker)
# ═══════════════════════════════════════════════════════════════════

swift-build: ## Build Swift project natively
	swift build

swift-test: ## Run all tests in parallel
	swift test --parallel

swift-test-scoring: ## Run ScoringEngine tests only
	swift test --filter ScoringEngineTests

# ═══════════════════════════════════════════════════════════════════
# Deploy — AWS ECS Fargate (production)
# ═══════════════════════════════════════════════════════════════════

docker-build: ## Build Docker image for linux/amd64
	docker build --platform linux/amd64 -f infra/docker/Dockerfile -t funghi-map:latest .

deploy: ## Build, push to ECR, deploy API + worker to ECS
	@bash infra/scripts/deploy.sh

deploy-api: ## Deploy API service only
	@bash infra/scripts/deploy.sh --api-only

deploy-worker: ## Update worker task definition only
	@bash infra/scripts/deploy.sh --worker-only

cfn-deploy: ## Deploy/update CloudFormation stack
	@echo "▶ Deploying CloudFormation stack..."
	aws cloudformation deploy \
		--template-file infra/cloudformation/stack.yaml \
		--stack-name funghi-map-$${ENVIRONMENT:-production} \
		--capabilities CAPABILITY_NAMED_IAM \
		--parameter-overrides file://infra/cloudformation/params.json

# ═══════════════════════════════════════════════════════════════════
# Clean
# ═══════════════════════════════════════════════════════════════════

clean: ## Remove Swift build artifacts
	swift package clean
	@echo "✔ Build artifacts cleaned."

clean-all: clean ## Clean build artifacts + Docker volumes (DESTROYS DB data)
	@echo "⚠  This will destroy database data."
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	$(COMPOSE) down -v
	@echo "✔ All cleaned."

# ═══════════════════════════════════════════════════════════════════
# Beta infrastructure — Only relevant on the beta Mac
# ═══════════════════════════════════════════════════════════════════

beta-setup: ## One-time setup: install nginx, certbot, DuckDNS (beta Mac only)
	@bash infra/beta/setup.sh

beta-ssl-renew: ## Manually trigger certbot renewal
	sudo certbot renew --post-hook "brew services restart nginx"

beta-nginx-restart: ## Restart nginx
	brew services restart nginx

# ═══════════════════════════════════════════════════════════════════
# Help
# ═══════════════════════════════════════════════════════════════════

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
