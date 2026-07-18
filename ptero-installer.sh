#!/usr/bin/env bash
# =============================================================================
# Master Ptero Script — Bootstrap one-liner
# Télécharge le projet depuis GitHub et lance l'installateur.
# =============================================================================
set -euo pipefail

REPO_OWNER="HeatzyV2"
REPO_NAME="MasterPtero"
REPO_BRANCH="main"
INSTALL_DIR="${MPS_INSTALL_DIR:-/opt/master-ptero}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[x]${NC} $*"; exit 1; }

echo -e "${BOLD}${CYAN}"
cat << 'EOF'
╔══════════════════════════════════════════╗
║     Master Ptero Script — Bootstrap      ║
╚══════════════════════════════════════════╝
EOF
echo -e "${NC}"

if [[ "${EUID}" -ne 0 ]]; then
  fail "Exécutez en root : sudo bash ptero-installer.sh"
fi

export DEBIAN_FRONTEND=noninteractive

info "Installation des prérequis (curl, ca-certificates, tar)..."
if command -v apt-get &>/dev/null; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates tar >/dev/null 2>&1 || apt-get install -y curl ca-certificates tar
elif command -v dnf &>/dev/null; then
  dnf install -y curl ca-certificates tar
else
  fail "Gestionnaire de paquets non supporté (apt/dnf requis)."
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
info "Téléchargement de ${REPO_OWNER}/${REPO_NAME}@${REPO_BRANCH}..."
if ! curl -fsSL "${ARCHIVE_URL}" -o "${TMP_DIR}/master-ptero.tar.gz"; then
  fail "Impossible de télécharger le dépôt. Vérifiez l'URL / que le repo est public."
fi

info "Extraction vers ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
tar -xzf "${TMP_DIR}/master-ptero.tar.gz" -C "${TMP_DIR}"
EXTRACTED="$(find "${TMP_DIR}" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -1)"
[[ -n "${EXTRACTED}" && -f "${EXTRACTED}/install.sh" ]] || fail "Archive invalide (install.sh introuvable)."

# Préserver secrets / état locaux s'ils existent
KEEP_ENV=""
KEEP_STATE=""
[[ -f "${INSTALL_DIR}/config/install.env" ]] && KEEP_ENV="$(mktemp)" && cp -a "${INSTALL_DIR}/config/install.env" "${KEEP_ENV}"
[[ -f "${INSTALL_DIR}/config/.install_state" ]] && KEEP_STATE="$(mktemp)" && cp -a "${INSTALL_DIR}/config/.install_state" "${KEEP_STATE}"

cp -a "${EXTRACTED}/." "${INSTALL_DIR}/"

[[ -n "${KEEP_ENV}" ]] && mkdir -p "${INSTALL_DIR}/config" && mv "${KEEP_ENV}" "${INSTALL_DIR}/config/install.env"
[[ -n "${KEEP_STATE}" ]] && mkdir -p "${INSTALL_DIR}/config" && mv "${KEEP_STATE}" "${INSTALL_DIR}/config/.install_state"

chmod +x "${INSTALL_DIR}/install.sh"
find "${INSTALL_DIR}/modules" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

ok "Projet installé dans ${INSTALL_DIR}"
info "Lancement de l'installateur..."
echo

cd "${INSTALL_DIR}"
exec bash ./install.sh "$@"
