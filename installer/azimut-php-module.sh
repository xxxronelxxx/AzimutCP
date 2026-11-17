#!/usr/bin/env bash
# =============================================================================
# azimut-php-module — install/remove a PHP extension package for one version.
#
#   azimut-php-module <install|remove> <php-version> <module>
#
# Only modules from the hardcoded allowlist are accepted.
# =============================================================================
set -euo pipefail

ACTION="${1:-}"
VER="${2:-}"
MOD="${3:-}"

[[ "${ACTION}" == "install" || "${ACTION}" == "remove" ]] || {
    echo "usage: azimut-php-module <install|remove> <version> <module>" >&2
    exit 2
}
[[ "${VER}" =~ ^[578]\.[0-9]$ ]] || { echo "invalid PHP version" >&2; exit 2; }

ALLOWED=" bcmath curl gd gmp imagick intl ldap mbstring memcached mongodb mysql opcache pgsql redis soap sqlite3 ssh2 tidy xml xdebug yaml zip "
case "${ALLOWED}" in
    *" ${MOD} "*) ;;
    *) echo "module not allowed: ${MOD}" >&2; exit 2 ;;
esac

export DEBIAN_FRONTEND=noninteractive
PKG="php${VER}-${MOD}"

echo "[azimut-php-module] ${ACTION} ${PKG}"
apt-get update -qq

if [ "${ACTION}" = "install" ]; then
    apt-get install -y -qq "${PKG}"
else
    apt-get remove -y -qq --purge "${PKG}" || true
fi

systemctl restart "php${VER}-fpm" >/dev/null 2>&1 || \
    systemctl reload "php${VER}-fpm" >/dev/null 2>&1 || true

echo "[azimut-php-module] done"
