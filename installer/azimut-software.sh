#!/usr/bin/env bash
# =============================================================================
# azimut-software — install/remove server software for AzimutCP.
#
# Called by azimut-panel through a narrow sudo rule:
#   azimut-software <install|remove> <id> <version>
#
# Every id and version is validated against a hardcoded allowlist. Never pass
# user-controlled arbitrary package names to this script.
# =============================================================================
set -euo pipefail

ACTION="${1:-}"
ID="${2:-}"
VER="${3:-latest}"

[[ "${ACTION}" == "install" || "${ACTION}" == "remove" ]] || {
    echo "usage: azimut-software <install|remove> <id> <version>" >&2
    exit 2
}
[[ "${VER}" =~ ^[A-Za-z0-9._-]{1,16}$ ]] || { echo "invalid version" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
log() { echo "[azimut-software] $*"; }

apt_update() { apt-get update -qq; }

apt_install() {
    log "Installing: $*"
    apt-get install -y -qq "$@"
}

apt_remove() {
    log "Removing: $*"
    apt-get remove -y -qq --purge "$@" || apt-get purge -y -qq "$@"
}

ensure_pgdg() {
    if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
        log "Adding PostgreSQL PGDG repository…"
        apt-get install -y -qq curl ca-certificates gnupg lsb-release
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
        echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
        apt_update
    fi
}

panel_pg_major() {
    psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true
}

case "${ID}" in
    php)
        if [[ ! "${VER}" =~ ^[578]\.[0-9]$ ]]; then
            echo "invalid PHP version" >&2
            exit 2
        fi
        if [ "${ACTION}" = "install" ]; then
            exec /usr/local/sbin/azimut-php-install "${VER}"
        fi

        # Refuse to remove a version that still has custom pools.
        pools=$(find "/etc/php/${VER}/fpm/pool.d" -maxdepth 1 -name '*.conf' \
                ! -name 'www.conf' 2>/dev/null | wc -l)
        if [ "${pools}" -gt 0 ]; then
            echo "PHP ${VER} still has ${pools} site pool(s)" >&2
            exit 4
        fi
        apt_remove "php${VER}-*" || true
        rm -rf "/etc/php/${VER}"
        systemctl stop "php${VER}-fpm" 2>/dev/null || true
        ;;

    postgresql)
        if [[ ! "${VER}" =~ ^[0-9]{2}$ ]]; then
            echo "invalid PostgreSQL version" >&2
            exit 2
        fi
        if [ "${ACTION}" = "install" ]; then
            ensure_pgdg
            apt_install "postgresql-${VER}"
            systemctl enable --now postgresql >/dev/null 2>&1 || true
        else
            current=$(panel_pg_major)
            if [ "${VER}" = "${current}" ]; then
                echo "PostgreSQL ${VER} is used by the panel and cannot be removed" >&2
                exit 4
            fi
            apt_remove "postgresql-${VER}"
        fi
        ;;

    mysql)
        if [ "${ACTION}" = "install" ]; then
            apt_install mysql-server
        else
            apt_remove mysql-server
        fi
        ;;

    mariadb)
        if [ "${ACTION}" = "install" ]; then
            apt_install mariadb-server
        else
            apt_remove mariadb-server
        fi
        ;;

    redis)
        if [ "${ACTION}" = "install" ]; then
            apt_install redis-server
        else
            echo "Redis/Valkey is used by the panel for its job queue" >&2
            exit 4
        fi
        ;;

    valkey)
        if [ "${ACTION}" = "install" ]; then
            apt_install valkey 2>/dev/null || apt_install redis-server
        else
            echo "Redis/Valkey is used by the panel for its job queue" >&2
            exit 4
        fi
        ;;

    memcached)
        if [ "${ACTION}" = "install" ]; then
            apt_install memcached
        else
            apt_remove memcached
        fi
        ;;

    nodejs)
        if [[ ! "${VER}" =~ ^[0-9]{2}$ ]]; then
            echo "invalid Node.js major version" >&2
            exit 2
        fi
        if [ "${ACTION}" = "install" ]; then
            current=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || true)
            if [ "${current}" = "${VER}" ]; then
                log "Node.js ${VER} is already installed"
                exit 0
            fi
            curl -fsSL "https://deb.nodesource.com/setup_${VER}.x" | bash - >/dev/null
            apt_install nodejs
        else
            echo "The system Node.js is used by the panel UI and cannot be removed" >&2
            exit 4
        fi
        ;;

    composer|git|fail2ban|jpegoptim|memcached|spamassassin)
        pkg="${ID}"
        if [ "${ACTION}" = "install" ]; then
            apt_install "${pkg}"
        else
            apt_remove "${pkg}"
        fi
        ;;

    sftp)
        if [ "${ACTION}" = "install" ]; then
            apt_install openssh-sftp-server
        else
            apt_remove openssh-sftp-server
        fi
        ;;

    phpmyadmin)
        if [ "${ACTION}" = "install" ]; then
            echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
            echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | debconf-set-selections
            apt_install phpmyadmin
        else
            apt_remove phpmyadmin
        fi
        ;;

    phppgadmin)
        if [ "${ACTION}" = "install" ]; then
            apt_install phppgadmin
        else
            apt_remove phppgadmin
        fi
        ;;

    roundcube)
        if [ "${ACTION}" = "install" ]; then
            echo "roundcube-core roundcube/dbconfig-install boolean false" | debconf-set-selections
            echo "roundcube-core roundcube/reconfigure-webserver multiselect" | debconf-set-selections
            apt_install roundcube
        else
            apt_remove roundcube
        fi
        ;;

    *)
        echo "unknown software id: ${ID}" >&2
        exit 2
        ;;
esac

log "Done: ${ACTION} ${ID} ${VER}"
