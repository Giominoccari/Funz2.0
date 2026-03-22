#!/usr/bin/env bash
# ============================================================
# Beta Server — One-time setup
# Installs and configures: nginx, certbot, DuckDNS cron
# Run from project root: bash infra/beta/setup.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Load .env.beta ──
if [ ! -f "$PROJECT_ROOT/.env.beta" ]; then
    echo "ERROR: .env.beta not found. Copy .env.beta.example and fill in values."
    exit 1
fi
# shellcheck disable=SC1091
set -a; source "$PROJECT_ROOT/.env.beta"; set +a

# Validate required vars
for var in DUCKDNS_DOMAIN DUCKDNS_TOKEN; do
    if [ -z "${!var:-}" ] || [ "${!var}" = "your_duckdns_token_here" ]; then
        echo "ERROR: $var is not set in .env.beta"
        exit 1
    fi
done

DOMAIN="${DUCKDNS_DOMAIN}.duckdns.org"

# ── Detect Homebrew prefix (Apple Silicon vs Intel) ──
if [ -d /opt/homebrew ]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi

echo "═══ Beta Server Setup ═══"
echo "Domain:      $DOMAIN"
echo "Brew prefix: $BREW_PREFIX"
echo ""

# ── 1. Install nginx & certbot ──
echo "▶ Installing nginx and certbot..."
brew install nginx certbot

# ── 2. Configure nginx ──
NGINX_SERVERS="$BREW_PREFIX/etc/nginx/servers"
mkdir -p "$NGINX_SERVERS"

# Create certbot webroot directory
CERTBOT_WEBROOT="$BREW_PREFIX/var/www/certbot"
mkdir -p "$CERTBOT_WEBROOT"

# Process template: replace DUCKDNS_DOMAIN placeholder with actual domain name
CONF_SOURCE="$PROJECT_ROOT/infra/nginx/funghimap-beta.conf"
CONF_DEST="$NGINX_SERVERS/funghimap-beta.conf"

echo "▶ Installing nginx config..."
sed "s|DUCKDNS_DOMAIN|$DUCKDNS_DOMAIN|g" "$CONF_SOURCE" > "$CONF_DEST"

# Also update certbot webroot path for Intel Macs
sed -i '' "s|/opt/homebrew/var/www/certbot|$CERTBOT_WEBROOT|g" "$CONF_DEST"

# Clean up any leftover backup from a previous run (nginx loads all files in servers/)
rm -f "$NGINX_SERVERS/funghimap-beta.conf.pre-ssl"

# Test nginx config (will fail on SSL certs not yet existing — that's expected)
echo "▶ Testing nginx config (SSL errors are expected before certbot runs)..."
nginx -t 2>&1 || true

# ── 3. Start nginx (HTTP only first for certbot challenge) ──
# Temporarily back up the full config OUTSIDE servers/ so nginx won't load it
CONF_TEMP="/tmp/funghimap-beta.conf.pre-ssl"
cp "$CONF_DEST" "$CONF_TEMP"

# Create a minimal HTTP-only config for initial certbot
cat > "$CONF_DEST" <<HTTPCONF
# Temporary HTTP-only config for certbot initial setup
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root $CERTBOT_WEBROOT;
    }

    location / {
        return 200 'Beta server setup in progress';
        add_header Content-Type text/plain;
    }
}
HTTPCONF

echo "▶ Starting nginx (HTTP only for certbot)..."
brew services restart nginx
sleep 2

# ── 4. Update DuckDNS ──
echo "▶ Updating DuckDNS record..."
DUCKDNS_RESULT=$(curl -s "https://www.duckdns.org/update?domains=$DUCKDNS_DOMAIN&token=$DUCKDNS_TOKEN&ip=")
if [ "$DUCKDNS_RESULT" = "OK" ]; then
    echo "  ✔ DuckDNS updated successfully"
else
    echo "  ✘ DuckDNS update failed: $DUCKDNS_RESULT"
    echo "  Check your DUCKDNS_TOKEN in .env.beta"
    exit 1
fi

# ── 5. Obtain SSL certificate ──
echo "▶ Requesting SSL certificate from Let's Encrypt..."
echo "  Make sure port 80 is forwarded to this machine on your router!"
read -rp "  Press Enter when port forwarding is ready (or Ctrl+C to abort)..."

sudo certbot certonly \
    --webroot \
    --webroot-path "$CERTBOT_WEBROOT" \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --email "${CERTBOT_EMAIL:-}" \
    ${CERTBOT_EMAIL:+} ${CERTBOT_EMAIL:-"--register-unsafely-without-email"}

# ── 6. Restore full nginx config with SSL ──
echo "▶ Restoring full nginx config with SSL..."
mv "$CONF_TEMP" "$CONF_DEST"
brew services restart nginx

# Verify
nginx -t && echo "  ✔ nginx config valid"

# ── 7. Setup certbot auto-renewal ──
echo "▶ Setting up certbot auto-renewal..."
RENEW_HOOK="brew services restart nginx"

# Create a renewal cron (certbot renew checks if renewal is needed)
CRON_LINE="0 3 * * * certbot renew --webroot --webroot-path $CERTBOT_WEBROOT --post-hook '$RENEW_HOOK' >> /tmp/certbot-renew.log 2>&1"

# Add to crontab if not already there
(crontab -l 2>/dev/null | grep -v 'certbot renew' ; echo "$CRON_LINE") | crontab -
echo "  ✔ Certbot renewal cron installed (daily at 3 AM)"

# ── 8. Setup DuckDNS IP update cron ──
echo "▶ Setting up DuckDNS IP update cron..."
DUCKDNS_SCRIPT="$PROJECT_ROOT/infra/beta/duckdns-update.sh"
chmod +x "$DUCKDNS_SCRIPT"

DUCK_CRON="*/15 * * * * $DUCKDNS_SCRIPT >> /tmp/duckdns.log 2>&1"
(crontab -l 2>/dev/null | grep -v 'duckdns-update' ; echo "$DUCK_CRON") | crontab -
echo "  ✔ DuckDNS update cron installed (every 15 minutes)"

# ── Done ──
echo ""
echo "═══════════════════════════════════════════════"
echo "  ✔ Beta server setup complete!"
echo ""
echo "  Domain:  https://$DOMAIN"
echo "  Nginx:   brew services restart nginx"
echo "  Certbot: sudo certbot renew --dry-run"
echo ""
echo "  Next steps:"
echo "    1. Forward ports 80 + 443 on your router"
echo "    2. cd $PROJECT_ROOT"
echo "    3. make beta-up"
echo "═══════════════════════════════════════════════"
