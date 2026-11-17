#!/usr/bin/env bash
# =============================================================================
# azimut-php-install — install a PHP-FPM version on the server.
#
# Called by azimut-panel (through sudo) when an administrator clicks
# "Install" on the PHP Versions screen. Validates the version, adds the
# Ondřej Surý / Sury package repository when needed and installs the usual
# extension set.
#
# Usage: azimut-php-install <7.4|8.0|8.1|8.2|8.3|8.4>
# =============================================================================
set -euo pipefail

VERSION="${1:-}"
if [[ ! "${VERSION}" =~ ^[78]\.[0-9]$ ]]; then
    echo "usage: azimut-php-install <7.4|8.0|8.1|8.2|8.3|8.4>" >&2
    exit 2
fi

export DEBIAN_FRONTEND=noninteractive
log() { echo "[azimut-php] $*"; }

if dpkg -s "php${VERSION}-fpm" >/dev/null 2>&1; then
    log "PHP ${VERSION} is already installed"
    exit 0
fi

log "Preparing package repositories…"
apt-get update -qq

. /etc/os-release

if ! apt-cache show "php${VERSION}-fpm" >/dev/null 2>&1; then
    case "${ID:-}" in
        ubuntu)
            log "Adding ppa:ondrej/php…"
            apt-get install -y -qq software-properties-common ca-certificates
            for attempt in 1 2 3; do
                if add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 \
                   && apt-get update -qq >/dev/null 2>&1; then
                    break
                fi
                log "Launchpad unavailable (attempt ${attempt}/3), retrying…"
                sleep 5
            done
            ;;
        debian)
            log "Adding packages.sury.org…"
            apt-get install -y -qq ca-certificates curl gnupg
            curl -fsSL https://packages.sury.org/php/apt.gpg \
                -o /usr/share/keyrings/sury-php.gpg
            echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME:-bookworm} main" \
                > /etc/apt/sources.list.d/sury-php.list
            apt-get update -qq
            ;;
        *)
            echo "Unsupported distribution: ${ID:-unknown}" >&2
            exit 3
            ;;
    esac
fi

if ! apt-cache show "php${VERSION}-fpm" >/dev/null 2>&1; then
    echo "PHP ${VERSION} is not available from the configured repositories" >&2
    exit 3
fi

log "Installing PHP ${VERSION}…"
apt-get install -y -qq \
    "php${VERSION}-fpm" "php${VERSION}-cli" "php${VERSION}-common"

# Optional but expected extensions. A missing one must not fail the install.
apt-get install -y -qq \
    "php${VERSION}-mysql" "php${VERSION}-pgsql" "php${VERSION}-gd" \
    "php${VERSION}-mbstring" "php${VERSION}-xml" "php${VERSION}-curl" \
    "php${VERSION}-zip" "php${VERSION}-intl" "php${VERSION}-bcmath" \
    "php${VERSION}-opcache" "php${VERSION}-redis" \
    >/dev/null 2>&1 || true

systemctl enable --now "php${VERSION}-fpm" >/dev/null 2>&1 || \
    systemctl restart "php${VERSION}-fpm" >/dev/null 2>&1 || true

log "PHP ${VERSION} installed"
