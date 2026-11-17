#!/usr/bin/env bash
# =============================================================================
# AzimutCP — minimal single-server test installer
#
# Intended for a FRESH Ubuntu 22.04/24.04 or Debian 12 VM. It installs only
# what is needed to open the panel and click around:
#   PostgreSQL + Valkey/Redis + nginx + Node.js + azimut-panel + UI
#
# Mail, DNS (PowerDNS), Apache/OLS, quotas and cgroups are NOT configured by
# this script — those features will report errors until the full installer is
# used. Do not run this on a production server.
#
# Usage:
#   sudo ./install-test.sh [panel-domain-or-ip]
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="/opt/azimutcp"
CONF_DIR="/etc/azimutcp"
DATA_DIR="/var/lib/azimutcp"
LOG_DIR="/var/log/azimutcp"
BACKUP_DIR="/var/backups/azimutcp"
SVC_USER="azimutcp"
ENV_FILE="${CONF_DIR}/panel.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[azimut]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo ./install-test.sh"

[ -d "${ROOT}/bin" ] || die "bin/ not found next to this script — unpack the release bundle first"
[ -f "${ROOT}/ui/ui.tar.gz" ] || die "ui/ui.tar.gz not found — unpack the release bundle first"

DOMAIN="${1:-}"
if [ -z "${DOMAIN}" ]; then
    DOMAIN="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "${DOMAIN}" ] || DOMAIN="localhost"
fi

. /etc/os-release 2>/dev/null || true
case "${ID:-}" in
    ubuntu|debian) ;;
    *) warn "Untested OS '${ID:-unknown}' — continuing anyway" ;;
esac

# ── Packages ──────────────────────────────────────────────────────────────────
log "Installing packages…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl ca-certificates openssl gnupg \
    postgresql postgresql-contrib \
    redis-server nginx \
    >/dev/null

# Node.js 20+ (SvelteKit adapter-node)
NODE_MAJOR="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || true)"
if [ -z "${NODE_MAJOR}" ] || [ "${NODE_MAJOR}" -lt 18 ]; then
    log "Installing Node.js 20 from NodeSource…"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
    apt-get install -y -qq nodejs >/dev/null
fi

systemctl enable --now postgresql >/dev/null 2>&1 || systemctl start postgresql
systemctl enable --now redis-server >/dev/null 2>&1 || systemctl start redis-server

# nginx must own port 80 on a fresh test box
if systemctl is-active --quiet apache2 2>/dev/null; then
    warn "Stopping apache2 so nginx can bind port 80"
    systemctl disable --now apache2 >/dev/null 2>&1 || true
fi

# ── System user and directories ───────────────────────────────────────────────
if ! id "${SVC_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "${PANEL_DIR}" --shell /usr/sbin/nologin "${SVC_USER}"
fi

mkdir -p "${PANEL_DIR}/bin" "${PANEL_DIR}/ui" "${PANEL_DIR}/apps" \
         "${CONF_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"

install -m755 "${ROOT}"/bin/azimut-* "${PANEL_DIR}/bin/"
tar -xzf "${ROOT}/ui/ui.tar.gz" -C "${PANEL_DIR}/ui"
if [ -d "${ROOT}/apps" ]; then
    cp -r "${ROOT}/apps/." "${PANEL_DIR}/apps/"
fi

log "Installing UI production dependencies…"
( cd "${PANEL_DIR}/ui" && npm ci --omit=dev --no-audit --no-fund >/dev/null )

# ── Database ──────────────────────────────────────────────────────────────────
DB_PASS="$(openssl rand -hex 16)"
if [ -f "${ENV_FILE}" ]; then
    EXISTING_PASS="$(sed -nE 's#^DATABASE_URL=postgresql://azimutcp:([^@]+)@.*#\1#p' "${ENV_FILE}")"
    [ -n "${EXISTING_PASS}" ] && DB_PASS="${EXISTING_PASS}"
fi

log "Configuring PostgreSQL…"
runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='azimutcp'" | grep -q 1 \
    || runuser -u postgres -- psql -qc "CREATE ROLE azimutcp LOGIN PASSWORD '${DB_PASS}'"
runuser -u postgres -- psql -qc "ALTER ROLE azimutcp WITH LOGIN PASSWORD '${DB_PASS}'"
runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='azimutcp'" | grep -q 1 \
    || runuser -u postgres -- createdb -O azimutcp azimutcp

# Migrations need these extensions; only a superuser can create them.
runuser -u postgres -- psql -q -d azimutcp -c \
    'CREATE EXTENSION IF NOT EXISTS "pgcrypto"; CREATE EXTENSION IF NOT EXISTS "citext";'

# ── Credentials ───────────────────────────────────────────────────────────────
ADMIN_EMAIL="admin@${DOMAIN}"
ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
INTERNAL_TOKEN="$(openssl rand -hex 32)"
if [ -f "${ENV_FILE}" ]; then
    OLD_EMAIL="$(grep '^AZIMUT_ADMIN_EMAIL=' "${ENV_FILE}" | cut -d= -f2- || true)"
    OLD_PASS="$(grep '^AZIMUT_ADMIN_PASSWORD=' "${ENV_FILE}" | cut -d= -f2- || true)"
    [ -n "${OLD_EMAIL}" ] && ADMIN_EMAIL="${OLD_EMAIL}"
    [ -n "${OLD_PASS}" ] && ADMIN_PASS="${OLD_PASS}"
fi

cat > "${ENV_FILE}" <<EOF
DATABASE_URL=postgresql://azimutcp:${DB_PASS}@127.0.0.1:5432/azimutcp
VALKEY_URL=redis://127.0.0.1:6379
PANEL_PORT=2087
PANEL_DOMAIN=${DOMAIN}
ALLOWED_ORIGINS=http://${DOMAIN}
AZIMUT_ENV=community
ADMIN_EMAIL=${ADMIN_EMAIL}
AZIMUT_ADMIN_EMAIL=${ADMIN_EMAIL}
AZIMUT_ADMIN_PASSWORD=${ADMIN_PASS}
AZIMUT_APPS_DIR=${PANEL_DIR}/apps
AZIMUT_MAIL_URL=http://127.0.0.1:5354
AZIMUT_DNS_URL=http://127.0.0.1:5353
AZIMUT_INTERNAL_TOKEN=${INTERNAL_TOKEN}
RUST_LOG=azimut_panel=info,tower_http=warn
EOF
chown "${SVC_USER}:${SVC_USER}" "${CONF_DIR}"
chmod 750 "${CONF_DIR}"
chown root:"${SVC_USER}" "${ENV_FILE}"
chmod 640 "${ENV_FILE}"

chown -R "${SVC_USER}:${SVC_USER}" "${PANEL_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"

# ── systemd units ─────────────────────────────────────────────────────────────
log "Installing systemd units…"
cat > /etc/systemd/system/azimut-panel.service <<'EOF'
[Unit]
Description=AzimutCP Panel
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
Type=simple
User=azimutcp
Group=azimutcp
WorkingDirectory=/opt/azimutcp
EnvironmentFile=/etc/azimutcp/panel.env
ExecStart=/opt/azimutcp/bin/azimut-panel
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/azimut-ui.service <<EOF
[Unit]
Description=AzimutCP UI
After=network.target azimut-panel.service

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${PANEL_DIR}/ui
Environment=AZIMUT_PORT=3000
Environment=AZIMUT_HOST=127.0.0.1
Environment=AZIMUT_ORIGIN=http://${DOMAIN}
ExecStart=/usr/bin/node build/index.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ── nginx ─────────────────────────────────────────────────────────────────────
log "Configuring nginx…"
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/azimutcp <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 64m;

    location /api/ {
        proxy_pass http://127.0.0.1:2087;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /ws/ {
        proxy_pass http://127.0.0.1:2087;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/azimutcp /etc/nginx/sites-enabled/azimutcp
nginx -t >/dev/null

systemctl daemon-reload
systemctl enable --now azimut-panel >/dev/null 2>&1
systemctl enable --now azimut-ui >/dev/null 2>&1 || systemctl restart azimut-ui >/dev/null 2>&1
systemctl reload nginx

# ── Wait for the panel ────────────────────────────────────────────────────────
log "Waiting for the panel to become ready…"
for _ in $(seq 1 90); do
    if curl -fsS http://127.0.0.1:2087/health >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! curl -fsS http://127.0.0.1:2087/health >/dev/null 2>&1; then
    warn "Panel did not start. Check: journalctl -u azimut-panel -n 80 --no-pager"
else
    log "Panel is up."
fi

cat <<EOF

$(printf '\033[0;32m')═══════════════════════════════════════════════════════════════$(printf '\033[0m')
  AzimutCP test installation complete
$(printf '\033[0;32m')═══════════════════════════════════════════════════════════════$(printf '\033[0m')

  Open:      http://${DOMAIN}/
  Email:     ${ADMIN_EMAIL}
  Password:  ${ADMIN_PASS}

  Logs:      journalctl -u azimut-panel -f
             journalctl -u azimut-ui -f
  Config:    ${ENV_FILE}

  Not configured by this test installer: mail, DNS/PowerDNS, OLS/Apache,
  cgroups/quotas. Use installer/install.sh for a full stack.
EOF
