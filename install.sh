#!/usr/bin/env bash
# =============================================================================
# AzimutCP — one-command installer
#
#   curl -fsSL https://raw.githubusercontent.com/xxxronelxxx/AzimutCP/main/install.sh | sudo bash
#
# Downloads the latest release bundle from GitHub and runs its installer.
# Supported: Ubuntu 22.04/24.04, Debian 12, x86_64, fresh server.
#
# Options:
#   --version <tag|latest>   release to install (default: latest)
#   --help
#
# Environment (mostly for development):
#   AZIMUT_VERSION      same as --version
#   AZIMUT_BUNDLE_URL   override the bundle download URL
#   AZIMUT_FETCH_ONLY=1 download and unpack, do not run the installer
# =============================================================================
set -euo pipefail

REPO="xxxronelxxx/AzimutCP"
BUNDLE_NAME="azimutcp-linux-x86_64.tar.gz"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[azimut]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
AzimutCP installer

  sudo ./install.sh [panel-domain-or-ip]
  curl -fsSL <raw-install.sh> | sudo bash -s -- [panel-domain-or-ip]

Options:
  --version <tag|latest>   release tag to install (default: latest)
  --help                   show this help
EOF
}

VERSION="${AZIMUT_VERSION:-latest}"
DOMAIN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || die "--version requires a value"
            VERSION="$2"; shift 2 ;;
        --version=*)
            VERSION="${1#*=}"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        --)
            shift; break ;;
        -*)
            die "unknown option: $1" ;;
        *)
            DOMAIN="$1"; shift ;;
    esac
done

FETCH_ONLY="${AZIMUT_FETCH_ONLY:-0}"

if [ "${FETCH_ONLY}" != "1" ]; then
    [ "$(id -u)" -eq 0 ] || die "Run as root: curl -fsSL ... | sudo bash"
fi

ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64) ;;
    *) die "unsupported architecture '${ARCH}' — only x86_64 builds are published" ;;
esac

# ── Base tools ────────────────────────────────────────────────────────────────
need_pkg=0
for c in curl tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || need_pkg=1
done
if [ "${need_pkg}" -eq 1 ]; then
    log "Installing base tools…"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates tar coreutils >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q curl ca-certificates tar coreutils >/dev/null
    else
        die "cannot install curl/tar — install them manually and re-run"
    fi
fi

# ── Resolve download URLs ─────────────────────────────────────────────────────
if [ "${VERSION}" = "latest" ]; then
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi

BUNDLE_URL="${AZIMUT_BUNDLE_URL:-${BASE_URL}/${BUNDLE_NAME}}"
SUMS_URL="${BASE_URL}/SHA256SUMS"

log "AzimutCP ${VERSION} (${ARCH})"
log "Downloading ${BUNDLE_NAME}…"

TMP_DIR="$(mktemp -d /tmp/azimutcp-install.XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

curl -fL --progress-bar "${BUNDLE_URL}" -o "${TMP_DIR}/${BUNDLE_NAME}" \
    || die "download failed: ${BUNDLE_URL}"

# Verify the bundle when a checksum file is available and was not overridden.
if [ -z "${AZIMUT_BUNDLE_URL:-}" ] && curl -fsL "${SUMS_URL}" -o "${TMP_DIR}/SHA256SUMS"; then
    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "${TMP_DIR}" && sha256sum -c --ignore-missing SHA256SUMS >/dev/null 2>&1 ) \
            || die "checksum verification failed — refusing to install"
        log "Checksum verified."
    fi
else
    warn "SHA256SUMS not available — skipping checksum verification"
fi

log "Unpacking…"
mkdir -p "${TMP_DIR}/bundle"
tar -xzf "${TMP_DIR}/${BUNDLE_NAME}" -C "${TMP_DIR}/bundle"
[ -f "${TMP_DIR}/bundle/install-test.sh" ] || die "invalid bundle: install-test.sh missing"
chmod +x "${TMP_DIR}/bundle/install-test.sh"

if [ "${FETCH_ONLY}" = "1" ]; then
    log "AZIMUT_FETCH_ONLY=1 — bundle unpacked at ${TMP_DIR}/bundle (kept for inspection)"
    trap - EXIT
    exit 0
fi

log "Starting installation…"
echo

if [ -n "${DOMAIN}" ]; then
    "${TMP_DIR}/bundle/install-test.sh" "${DOMAIN}"
else
    "${TMP_DIR}/bundle/install-test.sh"
fi
