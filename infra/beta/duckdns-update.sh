#!/usr/bin/env bash
# DuckDNS IP update — called by cron every 15 minutes
# Keeps the DNS record pointing to your router's public IP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load config
if [ -f "$PROJECT_ROOT/.env.beta" ]; then
    set -a; source "$PROJECT_ROOT/.env.beta"; set +a
fi

DOMAIN="${DUCKDNS_DOMAIN:-}"
TOKEN="${DUCKDNS_TOKEN:-}"

if [ -z "$DOMAIN" ] || [ -z "$TOKEN" ]; then
    echo "$(date): ERROR — DUCKDNS_DOMAIN or DUCKDNS_TOKEN not set"
    exit 1
fi

# Empty ip= lets DuckDNS auto-detect your public IP
RESULT=$(curl -s "https://www.duckdns.org/update?domains=$DOMAIN&token=$TOKEN&ip=")
echo "$(date): DuckDNS update: $RESULT"
