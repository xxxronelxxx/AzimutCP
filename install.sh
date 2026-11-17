#!/usr/bin/env bash
# ============================================================
# AzimutCP — One-Command Installer
# https://github.com/xxxronelxxx/AzimutCP
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[AzimutCP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

AZIMUTCP_VERSION="0.1.0"
INSTALL_DIR="/opt/azimutcp"
DATA_DIR="/var/lib/azimutcp"
BACKUP_DIR="/var/backups/azimutcp"
LOG_DIR="/var/log/azimutcp"

banner() {
cat << 'BANNER'
  ___       _     _ _  ____  ____
 / _ \ _ __| |__ (_) |/ ___||  _ \
| | | | '__| '_ \| | | |    | |_) |
| |_| | |  | |_) | | | |___ |  __/
 \___/|_|  |_.__/|_|_|\____||_|
BANNER
echo -e "${BLUE}AzimutCP v${AZIMUTCP_VERSION} — Rust-Powered Web Hosting Panel${NC}"
echo -e "${YELLOW}https://github.com/xxxronelxxx/AzimutCP${NC}"
echo ""
}

check_root() {
  [ "$(id -u)" -eq 0 ] || err "Run as root: sudo bash install.sh"
}

check_os() {
  . /etc/os-release 2>/dev/null || err "Cannot detect OS"
  case "$ID" in
    ubuntu) [[ "$VERSION_ID" =~ ^(22|24) ]] || warn "Ubuntu 22.04/24.04 recommended" ;;
    debian) [[ "$VERSION_ID" =~ ^(11|12) ]] || warn "Debian 11/12 recommended" ;;
    *) warn "Untested OS: $ID $VERSION_ID — proceeding anyway" ;;
  esac
  log "OS: $PRETTY_NAME"
}

install_deps() {
  log "Installing system dependencies..."
  apt-get update -qq
  apt-get install -y -qq \
    curl wget git build-essential pkg-config \
    libssl-dev libpq-dev \
    postgresql postgresql-client \
    redis-server \
    nginx \
    certbot python3-certbot-nginx \
    nftables \
    ca-certificates gnupg lsb-release 2>&1 | tail -5
  log "Dependencies installed"
}

install_rust() {
  if command -v cargo &>/dev/null; then
    log "Rust already installed: $(cargo --version)"
    return
  fi
  log "Installing Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  source "$HOME/.cargo/env"
  log "Rust installed: $(cargo --version)"
}

setup_database() {
  log "Setting up PostgreSQL database..."
  local DB_PASS
  DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

  systemctl start postgresql
  systemctl enable postgresql

  sudo -u postgres psql -c "CREATE USER azimutcp WITH PASSWORD '${DB_PASS}';" 2>/dev/null || true
  sudo -u postgres psql -c "CREATE DATABASE azimutcp OWNER azimutcp;" 2>/dev/null || true
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE azimutcp TO azimutcp;" 2>/dev/null || true

  echo "DATABASE_URL=postgresql://azimutcp:${DB_PASS}@127.0.0.1:5432/azimutcp"
}

setup_valkey() {
  log "Configuring Redis/Valkey..."
  systemctl start redis-server 2>/dev/null || systemctl start redis 2>/dev/null || true
  systemctl enable redis-server 2>/dev/null || systemctl enable redis 2>/dev/null || true
}

build_azimutcp() {
  log "Building AzimutCP from source..."
  source "$HOME/.cargo/env" 2>/dev/null || true

  [ -d "${INSTALL_DIR}" ] || git clone https://github.com/xxxronelxxx/AzimutCP.git "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"
  cargo build --release --workspace 2>&1 | tail -10
  log "Build complete"
}

setup_env() {
  local DB_URL="$1"
  local PDNS_KEY
  PDNS_KEY=$(openssl rand -hex 16)
  local INTERNAL_TOKEN
  INTERNAL_TOKEN=$(openssl rand -hex 32)

  cat > "${INSTALL_DIR}/.env" << EOF
DATABASE_URL=${DB_URL}
VALKEY_URL=redis://127.0.0.1:6379
PANEL_PORT=2087
PANEL_DOMAIN=${DOMAIN:-localhost}
ALLOWED_ORIGINS=https://${DOMAIN:-localhost}
AZIMUT_ENV=community
ADMIN_EMAIL=admin@${DOMAIN:-localhost}
AZIMUT_APPS_DIR=${INSTALL_DIR}/apps
PDNS_API_URL=http://127.0.0.1:8081
PDNS_API_KEY=${PDNS_KEY}
AZIMUT_INTERNAL_TOKEN=${INTERNAL_TOKEN}
EOF
  chmod 600 "${INSTALL_DIR}/.env"
  log "Environment configured (secrets auto-generated)"
}

setup_systemd() {
  log "Installing systemd services..."

  cat > /etc/systemd/system/azimut-panel.service << 'SVC'
[Unit]
Description=AzimutCP Panel API
After=network.target postgresql.service redis.service
Requires=postgresql.service

[Service]
Type=exec
User=azimutcp
WorkingDirectory=/opt/azimutcp
EnvironmentFile=/opt/azimutcp/.env
ExecStart=/opt/azimutcp/target/release/azimut-panel
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC

  systemctl daemon-reload
  systemctl enable azimut-panel
}

setup_nginx() {
  local DOMAIN="${1:-localhost}"
  log "Configuring nginx for domain: ${DOMAIN}..."

  cat > /etc/nginx/sites-available/azimutcp << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /api/ {
        proxy_pass http://127.0.0.1:2087;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  ln -sf /etc/nginx/sites-available/azimutcp /etc/nginx/sites-enabled/azimutcp
  nginx -t && systemctl reload nginx
}

print_success() {
  echo ""
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}${BOLD}  ✅  AzimutCP Installation Complete!${NC}"
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  Panel URL:   ${BLUE}http://${DOMAIN:-localhost}${NC}"
  echo -e "  First login: ${YELLOW}Create admin at /setup${NC}"
  echo -e "  Logs:        ${BLUE}journalctl -u azimut-panel -f${NC}"
  echo -e "  Docs:        ${BLUE}https://github.com/xxxronelxxx/AzimutCP#documentation${NC}"
  echo ""
  echo -e "  ${GREEN}Community edition — AGPL-3.0. Source: https://github.com/xxxronelxxx/AzimutCP${NC}"
  echo ""
}

main() {
  banner
  check_root
  check_os

  DOMAIN="${1:-}"

  install_deps
  install_rust
  DB_URL=$(setup_database)
  setup_valkey
  build_azimutcp
  setup_env "$DB_URL"
  setup_systemd

  [ -n "$DOMAIN" ] && setup_nginx "$DOMAIN"

  mkdir -p "${DATA_DIR}" "${BACKUP_DIR}" "${LOG_DIR}"
  useradd -r -s /bin/false azimutcp 2>/dev/null || true
  chown -R azimutcp:azimutcp "${INSTALL_DIR}" "${DATA_DIR}" "${BACKUP_DIR}" "${LOG_DIR}"

  systemctl start azimut-panel

  print_success
}

main "$@"
