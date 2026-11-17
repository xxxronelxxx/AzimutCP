#!/usr/bin/env bash
# =============================================================================
# azimut-node-install — manage Node.js versions in a system-wide nvm.
#
#   azimut-node-install <install|remove> <version>
#
# Installs under /opt/azimutcp/nvm so the panel's own system Node.js is never
# replaced. Site systemd units use the full path to the selected binary.
# =============================================================================
set -euo pipefail

ACTION="${1:-}"
VER="${2:-}"
NVM_DIR="/opt/azimutcp/nvm"

[[ "${ACTION}" == "install" || "${ACTION}" == "remove" ]] || {
    echo "usage: azimut-node-install <install|remove> <version>" >&2
    exit 2
}
[[ "${VER}" =~ ^[0-9]{1,2}(\.[0-9]+){0,2}$ ]] || { echo "invalid Node.js version" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
log() { echo "[azimut-node] $*"; }

if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    log "Installing nvm into ${NVM_DIR}…"
    mkdir -p "${NVM_DIR}"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh \
        | NVM_DIR="${NVM_DIR}" bash
fi

# shellcheck disable=SC1091
. "${NVM_DIR}/nvm.sh"

if [ "${ACTION}" = "install" ]; then
    log "Installing Node.js ${VER}…"
    nvm install "${VER}"
    chmod -R a+rX "${NVM_DIR}"
else
    log "Removing Node.js ${VER}…"
    nvm uninstall "${VER}" || true
fi

log "Done: ${ACTION} Node.js ${VER}"
