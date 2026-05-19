#!/bin/bash
#
# Twenty CRM Provisioning Script
# Installs: Twenty CRM (Docker Compose) + Nginx reverse proxy + SSL (Let's Encrypt)
#
# Required env vars:
#   DOMAIN          - Domain name (e.g. crm.example.com) — injected by agent
#
# Optional env vars:
#   PG_PASSWORD     - PostgreSQL password (default: random)
#   APP_SECRET      - Twenty app secret (default: random)
#
# Requirements: 2GB RAM minimum
# Supports: Ubuntu 22/24, Debian 11/12

set -euo pipefail

# ─── Logging (when running manually) ─────────────────────────────────────────
LOG_FILE="/var/log/tino-template.log"
START_TIME=$(date +%s)
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== $(basename "$0") started at $(date) ==="
trap 'END_TIME=$(date +%s); ELAPSED=$((END_TIME - START_TIME)); echo "=== $(basename "$0") finished at $(date) (${ELAPSED}s) ==="' EXIT

# ─── Force non-interactive mode ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
APP_SECRET="${APP_SECRET:-$(openssl rand -base64 32)}"
TWENTY_PORT="3000"
TWENTY_DIR="/opt/twenty"
CREDS_FILE="/root/.twenty-credentials"

echo "=========================================="
echo "  Twenty CRM Provisioner"
echo "  Domain : ${DOMAIN}"
echo "=========================================="

# ─── Apt lock wait ───────────────────────────────────────────────────────────

wait_for_apt() {
    local waited=0
    echo "==> Waiting for apt lock to be released..."
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
    done
    if [ "${waited}" -gt 0 ]; then
        echo "==> Package manager lock released after ${waited}s"
    fi
}

# ─── Detect OS ───────────────────────────────────────────────────────────────

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
    else
        echo "ERROR: Cannot detect OS"
        exit 1
    fi
    echo "==> Detected: ${OS_ID} ${OS_VERSION}"
}

# ─── Install Docker ─────────────────────────────────────────────────────────

install_docker() {
    if command -v docker &>/dev/null; then
        echo "==> Docker already installed: $(docker --version)"
        return 0
    fi

    echo "==> Installing Docker..."
    curl -fsSL https://get.docker.com | bash || {
        echo "ERROR: Docker installation failed"
        exit 1
    }

    systemctl enable --now docker
    echo "==> Docker installed: $(docker --version)"
}

# ─── Install dependencies ───────────────────────────────────────────────────

install_dependencies() {
    dpkg --configure -a --force-confdef --force-confold || true

    echo "==> Installing dependencies..."
    apt-get update -y
    apt-get install "${APT_OPTS[@]}" \
        curl wget nginx certbot python3-certbot-nginx cron

    echo "==> Dependencies installed"
}

# ─── Setup Twenty ───────────────────────────────────────────────────────────

setup_twenty() {
    echo "==> Setting up Twenty CRM..."

    mkdir -p "${TWENTY_DIR}"

    # Create .env file
    cat > "${TWENTY_DIR}/.env" <<ENV
TAG=latest
SERVER_URL=https://${DOMAIN}
PG_DATABASE_PASSWORD=${PG_PASSWORD}
PG_DATABASE_USER=postgres
PG_DATABASE_NAME=default
APP_SECRET=${APP_SECRET}
STORAGE_TYPE=local
ENV

    # Create docker-compose.yml
    cat > "${TWENTY_DIR}/docker-compose.yml" <<'COMPOSE'
name: twenty

services:
  server:
    image: twentycrm/twenty:${TAG:-latest}
    volumes:
      - server-local-data:/app/packages/twenty-server/.local-storage
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      NODE_PORT: 3000
      PG_DATABASE_URL: postgres://${PG_DATABASE_USER:-postgres}:${PG_DATABASE_PASSWORD:-postgres}@db:5432/${PG_DATABASE_NAME:-default}
      SERVER_URL: ${SERVER_URL}
      REDIS_URL: redis://redis:6379
      APP_SECRET: ${APP_SECRET}
      STORAGE_TYPE: ${STORAGE_TYPE:-local}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: curl --fail http://localhost:3000/healthz
      interval: 10s
      timeout: 10s
      start_period: 120s
      retries: 30
    restart: always

  worker:
    image: twentycrm/twenty:${TAG:-latest}
    volumes:
      - server-local-data:/app/packages/twenty-server/.local-storage
    command: ["yarn", "worker:prod"]
    environment:
      PG_DATABASE_URL: postgres://${PG_DATABASE_USER:-postgres}:${PG_DATABASE_PASSWORD:-postgres}@db:5432/${PG_DATABASE_NAME:-default}
      SERVER_URL: ${SERVER_URL}
      REDIS_URL: redis://redis:6379
      DISABLE_DB_MIGRATIONS: "true"
      DISABLE_CRON_JOBS_REGISTRATION: "true"
      APP_SECRET: ${APP_SECRET}
      STORAGE_TYPE: ${STORAGE_TYPE:-local}
    depends_on:
      db:
        condition: service_healthy
      server:
        condition: service_healthy
    restart: always

  db:
    image: postgres:16
    volumes:
      - db-data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: ${PG_DATABASE_NAME:-default}
      POSTGRES_PASSWORD: ${PG_DATABASE_PASSWORD:-postgres}
      POSTGRES_USER: ${PG_DATABASE_USER:-postgres}
    healthcheck:
      test: pg_isready -U ${PG_DATABASE_USER:-postgres} -h localhost -d postgres
      interval: 5s
      timeout: 5s
      retries: 10
    restart: always

  redis:
    image: redis
    restart: always
    command: ["--maxmemory-policy", "noeviction"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  db-data:
  server-local-data:
COMPOSE

    # Pull and start
    echo "==> Pulling Docker images..."
    cd "${TWENTY_DIR}"
    docker compose pull

    echo "==> Starting Twenty CRM..."
    docker compose up -d

    # Wait for Twenty to be healthy
    echo "==> Waiting for Twenty CRM to initialize..."
    local retries=0
    while ! curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${TWENTY_PORT}/healthz" 2>/dev/null | grep -q "200"; do
        sleep 5
        retries=$((retries + 1))
        if [ "${retries}" -ge 30 ]; then
            echo "WARNING: Twenty may not have started yet, continuing..."
            break
        fi
        echo "==> Waiting for Twenty... (${retries}/30)"
    done

    echo "==> Twenty CRM is running"
}

# ─── Configure Nginx ────────────────────────────────────────────────────────

configure_nginx() {
    echo "==> Configuring Nginx reverse proxy"

    cat > "/etc/nginx/sites-available/${DOMAIN}.conf" <<'NGINX'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX

    sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "/etc/nginx/sites-available/${DOMAIN}.conf"

    ln -sf "/etc/nginx/sites-available/${DOMAIN}.conf" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default

    nginx -t && systemctl reload nginx

    echo "==> Nginx configured for ${DOMAIN}"
}

# ─── SSL (Let's Encrypt) ────────────────────────────────────────────────────

configure_ssl() {
    echo "==> Requesting SSL certificate for ${DOMAIN}"

    certbot --nginx \
        -d "${DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect || {
        echo "WARNING: SSL certificate request failed, continuing without SSL"
        return 0
    }

    # Auto-renewal cron
    local existing_cron=""
    existing_cron=$(crontab -l 2>/dev/null || true)
    if ! echo "${existing_cron}" | grep -q "certbot renew"; then
        (echo "${existing_cron}"; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    fi

    echo "==> SSL configured with auto-renewal"
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > "${CREDS_FILE}" <<CREDS
==========================================
  Twenty CRM
  Created: $(date)
==========================================

  Web Access:
    URL            : https://${DOMAIN}

  Database:
    DB Host        : localhost (Docker)
    DB Name        : default
    DB User        : postgres
    DB Password    : ${PG_PASSWORD}

  App Secret     : ${APP_SECRET}

  Paths:
    Install Dir    : ${TWENTY_DIR}
    Compose File   : ${TWENTY_DIR}/docker-compose.yml
    Env File       : ${TWENTY_DIR}/.env

  Server IP      : ${server_ip}
  Domain         : ${DOMAIN}

  First Steps:
    1. Open https://${DOMAIN}
    2. Create your admin account
    3. Start using Twenty CRM

==========================================
CREDS

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ──────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    local motd_script='#!/bin/bash
CREDS_FILE="/root/.twenty-credentials"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    TWENTY CRM SERVER                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
if [ -f "${CREDS_FILE}" ]; then
    cat "${CREDS_FILE}"
else
    echo "  Credentials file not found: ${CREDS_FILE}"
fi
echo ""
echo "  Useful Commands:"
echo "  ─────────────────────────────────────────────"
echo "  cd /opt/twenty && docker compose ps       Status"
echo "  cd /opt/twenty && docker compose logs -f   Logs"
echo "  cd /opt/twenty && docker compose restart   Restart"
echo "  cd /opt/twenty && docker compose pull && docker compose up -d   Update"
echo "  certbot certificates                       SSL info"
echo ""
'

    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    printf '%s' "${motd_script}" > /etc/update-motd.d/99-twenty-info
    chmod +x /etc/update-motd.d/99-twenty-info

    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    wait_for_apt
    install_dependencies
    install_docker
    setup_twenty
    configure_nginx
    configure_ssl
    save_credentials
    setup_motd

    echo ""
    echo "=========================================="
    echo "  Twenty CRM installed!"
    echo "  Website : https://${DOMAIN}"
    echo "  Creds   : ${CREDS_FILE}"
    echo "=========================================="
}

main "$@"
