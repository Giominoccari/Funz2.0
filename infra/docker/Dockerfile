# ============================================================
# Funghi Map — Multi-stage Dockerfile
# Produces a single image used by both ECS tasks:
#   api    → App serve --hostname 0.0.0.0 --port 8080
#   worker → App worker --bbox italy --date today
# ============================================================

# ── Stage 1: Build ──────────────────────────────────────────
FROM swift:6.0-jammy AS build

WORKDIR /app

# Cache dependency resolution
COPY Package.swift Package.resolved ./
RUN swift package resolve

# Copy only what affects compilation (order matters for cache!)
COPY Sources/ Sources/
COPY Tests/ Tests/

RUN --mount=type=cache,target=/app/.build,size=5368709120 \
    swift build -c release \
    --static-swift-stdlib \
    -Xlinker -lstdc++ \
    && cp .build/release/App /app/App

# ── Stage 2: Runtime ────────────────────────────────────────
FROM ubuntu:22.04 AS runtime

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libcurl4 \
        libxml2 \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app

# Copy binary from build stage
COPY --from=build /app/App /app/App

# Copy static assets directly (changes here don't invalidate the Swift build cache)
COPY config/ /app/config/
COPY Public/ /app/Public/

RUN chown -R appuser:appuser /app
USER appuser

# Health check for API mode (ignored by worker tasks)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080

# Default: API mode. Override CMD in ECS task definition for worker.
ENTRYPOINT ["/app/App"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
