#!/usr/bin/env bash
# =============================================================================
# AzimutCP — minimal single-server installer
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
#   sudo ./install-minimal.sh [panel-domain-or-ip]
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# runuser/psql warn when the current directory is not readable by postgres
cd /
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

APT_LOG="$(mktemp /tmp/azimut-apt.XXXXXX.log)"
trap 'rm -f "${APT_LOG}"' EXIT

# Run apt quietly; show the tail of its output only when it fails.
apt_run() {
    if ! apt-get "$@" >>"${APT_LOG}" 2>&1; then
        echo "--- apt-get $* ---" >&2
        tail -n 40 "${APT_LOG}" >&2
        die "apt-get $* failed"
    fi
}

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo ./install-minimal.sh"

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


# ── Mail stack ────────────────────────────────────────────────────────────────

setup_mail_stack() {
    log "Installing mail stack (Postfix + Dovecot + rspamd)…"

    local mail_host; mail_host="$(hostname -f 2>/dev/null || hostname)"
    debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
    debconf-set-selections <<< "postfix postfix/mailname string ${mail_host}"

    apt_run install -y -qq         postfix postfix-pgsql dovecot-core dovecot-imapd dovecot-pop3d         dovecot-lmtpd rspamd

    if ! getent group vmail >/dev/null; then
        groupadd -g 5000 vmail
    fi
    if ! id vmail >/dev/null 2>&1; then
        useradd -g vmail -u 5000 -d /var/mail/vhosts -s /usr/sbin/nologin vmail
    fi
    install -d -o vmail -g vmail -m 755 /var/mail/vhosts
    install -d -m 755 /etc/rspamd/dkim /etc/rspamd/local.d /etc/dovecot/conf.d

    postconf -e "myhostname = ${mail_host}"
    postconf -e "mydomain = ${mail_host#*.}"
    postconf -e "myorigin = \$mydomain"
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = ipv4"
    postconf -e "smtpd_banner = \$myhostname ESMTP"
    postconf -e "biff = no"
    postconf -e "virtual_mailbox_domains = pgsql:/etc/postfix/pgsql-virtual-domains.cf"
    postconf -e "virtual_mailbox_maps = pgsql:/etc/postfix/pgsql-virtual-mailbox-maps.cf"
    postconf -e "virtual_alias_maps = pgsql:/etc/postfix/pgsql-virtual-alias-maps.cf"
    postconf -e "virtual_mailbox_base = /var/mail/vhosts"
    postconf -e "virtual_uid_maps = static:5000"
    postconf -e "virtual_gid_maps = static:5000"
    postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
    postconf -e "smtpd_sasl_auth_enable = yes"
    postconf -e "smtpd_sasl_type = dovecot"
    postconf -e "smtpd_sasl_path = private/auth"
    postconf -e "smtpd_relay_restrictions = permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination"
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtp_tls_security_level = may"
    postconf -e "smtpd_milters = inet:127.0.0.1:11332"
    postconf -e "non_smtpd_milters = inet:127.0.0.1:11332"
    postconf -e "milter_default_action = accept"

    # SQL maps: the panel stores domains/accounts in PostgreSQL, so Postfix
    # must read the same source of truth.
    cat > /etc/postfix/pgsql-virtual-domains.cf <<EOF
user = azimutcp
password = ${DB_PASS}
hosts = 127.0.0.1
dbname = azimutcp
query = SELECT domain FROM email_domains WHERE domain = '%s' AND status = 'active'
EOF
    cat > /etc/postfix/pgsql-virtual-mailbox-maps.cf <<EOF
user = azimutcp
password = ${DB_PASS}
hosts = 127.0.0.1
dbname = azimutcp
query = SELECT '/var/mail/vhosts/' || split_part(address, '@', 2) || '/' || split_part(address, '@', 1) || '/' FROM email_accounts WHERE address = '%s' AND deleted_at IS NULL AND status = 'active'
EOF
    cat > /etc/postfix/pgsql-virtual-alias-maps.cf <<EOF
user = azimutcp
password = ${DB_PASS}
hosts = 127.0.0.1
dbname = azimutcp
query = SELECT to_address FROM email_forwarders WHERE from_address = '%s' AND enabled = true
EOF
    chmod 640 /etc/postfix/pgsql-virtual-*.cf
    chgrp postfix /etc/postfix/pgsql-virtual-*.cf

    # Flat files are still maintained by azimut-mail for compatibility.
    : > /etc/postfix/virtual_domains
    : > /etc/postfix/virtual_mailbox_maps
    : > /etc/postfix/virtual_alias_maps
    chmod 644 /etc/postfix/virtual_domains /etc/postfix/virtual_mailbox_maps /etc/postfix/virtual_alias_maps
    postmap /etc/postfix/virtual_domains /etc/postfix/virtual_mailbox_maps /etc/postfix/virtual_alias_maps

    # Dovecot: passwd-file auth backed by azimut-mail.
    cat > /etc/dovecot/conf.d/auth-passwdfile.conf.ext <<'EOF'
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/users
}
userdb {
  driver = passwd-file
  args = username_format=%u /etc/dovecot/users
  default_fields = uid=5000 gid=5000 home=/var/mail/vhosts/%d/%n
}
EOF

    sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true
    grep -q 'auth-passwdfile.conf.ext' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null         || echo '!include auth-passwdfile.conf.ext' >> /etc/dovecot/conf.d/10-auth.conf
    sed -i 's/^#\?disable_plaintext_auth.*/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true
    sed -i 's/^#\?auth_mechanisms.*/auth_mechanisms = plain login/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true

    cat > /etc/dovecot/conf.d/99-azimutcp.conf <<'EOF'
protocols = imap pop3 lmtp
mail_location = maildir:/var/mail/vhosts/%d/%n
mail_privileged_group = vmail
mail_uid = 5000
mail_gid = 5000

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
EOF

    touch /etc/dovecot/users
    chown "${SVC_USER}:${SVC_USER}" /etc/dovecot/users
    chmod 640 /etc/dovecot/users

    cat > /etc/rspamd/local.d/worker-milter.inc <<'EOF'
bind_socket = "127.0.0.1:11332";
EOF
    cat > /etc/rspamd/local.d/dkim_signing.conf <<'EOF'
enabled = true;
selector = "mail";
path = "/etc/rspamd/dkim/$domain.$selector.key";
EOF
    cat > /etc/rspamd/local.d/actions.conf <<'EOF'
reject = 15;
add_header = 6;
greylist = 4;
EOF

    cat > /etc/systemd/system/azimut-mail.service <<'EOF'
[Unit]
Description=AzimutCP Mail Management Daemon
After=network.target postfix.service dovecot.service rspamd.service
Wants=postfix.service dovecot.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/azimutcp
ExecStart=/opt/azimutcp/bin/azimut-mail
EnvironmentFile=-/etc/azimutcp/mail.env
Restart=always
RestartSec=5
NoNewPrivileges=false
PrivateTmp=false
ProtectSystem=false
ReadWritePaths=/etc/postfix /etc/dovecot /var/mail /etc/rspamd

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now postfix dovecot rspamd >/dev/null 2>&1 || true
    systemctl enable --now azimut-mail >/dev/null 2>&1 || true
    log "Mail stack configured (SMTP/IMAP, DKIM selector: mail)"
}

# ── Packages ──────────────────────────────────────────────────────────────────
log "Installing packages…"
export DEBIAN_FRONTEND=noninteractive
apt_run update -qq
# apt-utils keeps debconf quiet during the installs below.
apt_run install -y -qq apt-utils
apt_run install -y -qq \
    curl ca-certificates openssl gnupg sudo \
    postgresql postgresql-contrib \
    redis-server nginx

# Node.js 20+ (SvelteKit adapter-node). We require /usr/bin/node explicitly
# because systemd units reference that path.
NODE_OK=0
if [ -x /usr/bin/node ]; then
    NODE_MAJOR="$(/usr/bin/node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || echo 0)"
    [ "${NODE_MAJOR:-0}" -ge 18 ] 2>/dev/null && NODE_OK=1
fi
if [ "${NODE_OK}" -ne 1 ]; then
    log "Installing Node.js 20 from NodeSource…"
    if ! { curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; apt-get install -y -qq nodejs; } >>"${APT_LOG}" 2>&1; then
        tail -n 40 "${APT_LOG}" >&2
        die "Node.js installation failed"
    fi
fi
[ -x /usr/bin/node ] || die "node was not installed correctly"

systemctl enable --now postgresql >/dev/null 2>&1 || systemctl start postgresql
systemctl enable --now redis-server >/dev/null 2>&1 || systemctl start redis-server

# nginx must own port 80 on a fresh server
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
if [ -f "${ROOT}/bin/azimut" ]; then
    install -m755 "${ROOT}/bin/azimut" "${PANEL_DIR}/bin/azimut"
    ln -sf "${PANEL_DIR}/bin/azimut" /usr/local/bin/azimut
fi
tar -xzf "${ROOT}/ui/ui.tar.gz" -C "${PANEL_DIR}/ui"
if [ -d "${ROOT}/apps" ]; then
    cp -r "${ROOT}/apps/." "${PANEL_DIR}/apps/"
fi

# Root helper used by the panel to install PHP versions on demand.
if [ -f "${ROOT}/bin/azimut-php-install" ]; then
    install -m755 "${ROOT}/bin/azimut-php-install" /usr/local/sbin/azimut-php-install
    cat > /etc/sudoers.d/azimutcp-php <<'SUDOERS'
azimutcp ALL=(root) NOPASSWD: /usr/local/sbin/azimut-php-install *
SUDOERS
    chmod 440 /etc/sudoers.d/azimutcp-php
    visudo -cf /etc/sudoers.d/azimutcp-php >/dev/null 2>&1 || {
        rm -f /etc/sudoers.d/azimutcp-php
        warn "Could not validate the PHP installer sudo rule — in-panel PHP installs are disabled"
    }
fi

# Root helper for installing PHP extension packages per version.
if [ -f "${ROOT}/bin/azimut-php-module" ]; then
    install -m755 "${ROOT}/bin/azimut-php-module" /usr/local/sbin/azimut-php-module
    cat > /etc/sudoers.d/azimutcp-php-module <<'SUDOERS'
azimutcp ALL=(root) NOPASSWD: /usr/local/sbin/azimut-php-module *
SUDOERS
    chmod 440 /etc/sudoers.d/azimutcp-php-module
    visudo -cf /etc/sudoers.d/azimutcp-php-module >/dev/null 2>&1 || {
        rm -f /etc/sudoers.d/azimutcp-php-module
        warn "Could not validate the PHP module sudo rule — in-panel module installs are disabled"
    }
fi

# Root helper used by the panel to install server software (databases, caches, tools).
if [ -f "${ROOT}/bin/azimut-software" ]; then
    install -m755 "${ROOT}/bin/azimut-software" /usr/local/sbin/azimut-software
    cat > /etc/sudoers.d/azimutcp-software <<'SUDOERS'
azimutcp ALL=(root) NOPASSWD: /usr/local/sbin/azimut-software *
SUDOERS
    chmod 440 /etc/sudoers.d/azimutcp-software
    visudo -cf /etc/sudoers.d/azimutcp-software >/dev/null 2>&1 || {
        rm -f /etc/sudoers.d/azimutcp-software
        warn "Could not validate the software installer sudo rule — in-panel installs are disabled"
    }
fi

# Helpers called by azimut-software (root) — no separate sudo rule needed.
for helper in azimut-node-install azimut-webapp; do
    if [ -f "${ROOT}/bin/${helper}" ]; then
        install -m755 "${ROOT}/bin/${helper}" "/usr/local/sbin/${helper}"
    fi
done

log "Installing MariaDB 11.4…"
if [ -x /usr/local/sbin/azimut-software ]; then
    if ! /usr/local/sbin/azimut-software install mariadb 11.4 >>"${APT_LOG}" 2>&1; then
        warn "MariaDB 11.4 installation failed — install it later from Server Software"
    fi
else
    warn "Software helper is missing — MariaDB was not installed"
fi

log "Installing PHP 8.4…"
if [ -x /usr/local/sbin/azimut-php-install ]; then
    if ! /usr/local/sbin/azimut-php-install 8.4 >>"${APT_LOG}" 2>&1; then
        tail -n 40 "${APT_LOG}" >&2
        warn "PHP 8.4 unavailable (package repo issue) — installing the distribution default PHP instead"
        apt_run install -y -qq \
            php-fpm php-cli php-common php-mysql php-pgsql php-gd \
            php-mbstring php-xml php-curl php-zip php-intl php-bcmath
        apt-get install -y -qq php-opcache >>"${APT_LOG}" 2>&1 || true
        systemctl enable --now php*-fpm >/dev/null 2>&1 || true
    fi
else
    warn "PHP installer helper is missing from the bundle — PHP was not installed"
fi

# The SvelteKit adapter-node build is self-contained: it runs with just
# `package.json` + `build/`, no node_modules and no npm install required.

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

setup_mail_stack

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
# The panel runs as an unprivileged user but must manage site users, nginx
# and PHP-FPM configs. Grant only the specific commands it needs.
for dir in /etc/nginx/sites-available /etc/nginx/sites-enabled; do
    if [ -d "${dir}" ]; then
        chgrp "${SVC_USER}" "${dir}"
        chmod 775 "${dir}"
    fi
done
for dir in /etc/php/*/fpm/pool.d; do
    if [ -d "${dir}" ]; then
        chgrp "${SVC_USER}" "${dir}"
        chmod 775 "${dir}"
    fi
done

cat > /etc/sudoers.d/azimutcp-provision <<'SUDOERS'
azimutcp ALL=(root) NOPASSWD: /usr/sbin/useradd *, /usr/sbin/userdel *
azimutcp ALL=(root) NOPASSWD: /usr/bin/install *
azimutcp ALL=(root) NOPASSWD: /usr/bin/chown *, /usr/bin/chmod *
azimutcp ALL=(root) NOPASSWD: /usr/bin/setfacl *
azimutcp ALL=(root) NOPASSWD: /usr/sbin/setquota *
azimutcp ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload
azimutcp ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
azimutcp ALL=(root) NOPASSWD: /usr/bin/systemctl restart nginx
azimutcp ALL=(root) NOPASSWD: /usr/bin/systemctl reload php*-fpm
azimutcp ALL=(root) NOPASSWD: /usr/bin/systemctl restart php*-fpm
azimutcp ALL=(root) NOPASSWD: /usr/bin/systemctl start website-*.slice
azimutcp ALL=(root) NOPASSWD: /usr/bin/systemctl stop website-*.slice
azimutcp ALL=(root) NOPASSWD: /usr/sbin/nginx -t
azimutcp ALL=(root) NOPASSWD: /usr/bin/crontab *
azimutcp ALL=(root) NOPASSWD: /usr/bin/doveadm reload
SUDOERS
chmod 440 /etc/sudoers.d/azimutcp-provision
visudo -cf /etc/sudoers.d/azimutcp-provision >/dev/null 2>&1 || {
    rm -f /etc/sudoers.d/azimutcp-provision
    warn "Could not validate the site provisioning sudo rules"
}

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
systemctl enable --now azimut-panel >/dev/null 2>&1 || true
systemctl enable --now azimut-ui >/dev/null 2>&1 || systemctl restart azimut-ui >/dev/null 2>&1 || true
systemctl enable --now nginx >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
systemctl reload nginx || systemctl restart nginx

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
  AzimutCP installation complete
$(printf '\033[0;32m')═══════════════════════════════════════════════════════════════$(printf '\033[0m')

  Open:      http://${DOMAIN}/
  Email:     ${ADMIN_EMAIL}
  Password:  ${ADMIN_PASS}

  Logs:      journalctl -u azimut-panel -f
             journalctl -u azimut-ui -f
  Config:    ${ENV_FILE}

  Minimal profile — not configured: mail, DNS/PowerDNS, OLS/Apache,
  cgroups/quotas. Use installer/install.sh for a full stack.
EOF
