#!/usr/bin/env bash
# =============================================================================
# Master Ptero Script — Bibliothèque commune
# =============================================================================
# Fournit : couleurs, logging, progression, vérifications système, helpers.
# Sourcé par install.sh et tous les modules.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Chemins
# -----------------------------------------------------------------------------
readonly MPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MPS_MODULES="${MPS_ROOT}/modules"
readonly MPS_CONFIG="${MPS_ROOT}/config"
readonly MPS_LOGS="${MPS_ROOT}/logs"
readonly MPS_LIB="${MPS_ROOT}/lib"

mkdir -p "${MPS_LOGS}" "${MPS_CONFIG}"

readonly MPS_LOG_FILE="${MPS_LOGS}/install-$(date +%Y%m%d-%H%M%S).log"
readonly MPS_STATE_FILE="${MPS_CONFIG}/.install_state"
readonly MPS_ENV_FILE="${MPS_CONFIG}/install.env"

# -----------------------------------------------------------------------------
# Couleurs & styles
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  readonly C_RESET='\033[0m'
  readonly C_BOLD='\033[1m'
  readonly C_DIM='\033[2m'
  readonly C_RED='\033[0;31m'
  readonly C_GREEN='\033[0;32m'
  readonly C_YELLOW='\033[0;33m'
  readonly C_BLUE='\033[0;34m'
  readonly C_MAGENTA='\033[0;35m'
  readonly C_CYAN='\033[0;36m'
  readonly C_WHITE='\033[0;37m'
  readonly C_BG_BLUE='\033[44m'
else
  readonly C_RESET='' C_BOLD='' C_DIM=''
  readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
  readonly C_MAGENTA='' C_CYAN='' C_WHITE='' C_BG_BLUE=''
fi

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
_log() {
  local level="$1" color="$2"
  shift 2
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%b[%s] [%s]%b %s\n' "${color}" "${ts}" "${level}" "${C_RESET}" "${msg}"
  printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}" >> "${MPS_LOG_FILE}"
}

log_info()    { _log "INFO " "${C_CYAN}"    "$@"; }
log_ok()      { _log "OK   " "${C_GREEN}"   "$@"; }
log_warn()    { _log "WARN " "${C_YELLOW}"  "$@"; }
log_error()   { _log "ERROR" "${C_RED}"     "$@"; }
log_step()    { _log "STEP " "${C_MAGENTA}" "$@"; }
log_debug()   {
  if [[ "${MPS_DEBUG:-0}" == "1" ]]; then
    _log "DEBUG" "${C_DIM}" "$@"
  else
    printf '[%s] [DEBUG] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${MPS_LOG_FILE}"
  fi
}

die() {
  log_error "$@"
  log_error "Consultez le journal : ${MPS_LOG_FILE}"
  exit 1
}

# -----------------------------------------------------------------------------
# Bannière & UI
# -----------------------------------------------------------------------------
print_banner() {
  clear 2>/dev/null || true
  echo -e "${C_CYAN}${C_BOLD}"
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ███╗   ███╗ █████╗ ███████╗████████╗███████╗██████╗        ║
║   ████╗ ████║██╔══██╗██╔════╝╚══██╔══╝██╔════╝██╔══██╗       ║
║   ██╔████╔██║███████║███████╗   ██║   █████╗  ██████╔╝       ║
║   ██║╚██╔╝██║██╔══██║╚════██║   ██║   ██╔══╝  ██╔══██╗       ║
║   ██║ ╚═╝ ██║██║  ██║███████║   ██║   ███████╗██║  ██║       ║
║   ╚═╝     ╚═╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝       ║
║                                                              ║
║              P T E R O   S C R I P T   v1.0.0                ║
║         Installateur Pterodactyl Production-Ready            ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
  echo -e "${C_RESET}"
}

print_separator() {
  echo -e "${C_DIM}──────────────────────────────────────────────────────────────${C_RESET}"
}

confirm() {
  local prompt="${1:-Continuer ?}"
  local default="${2:-n}"
  local reply
  if [[ "${default}" == "y" ]]; then
    read -r -p "$(echo -e "${C_YELLOW}${prompt} [Y/n] : ${C_RESET}")" reply
    reply="${reply:-y}"
  else
    read -r -p "$(echo -e "${C_YELLOW}${prompt} [y/N] : ${C_RESET}")" reply
    reply="${reply:-n}"
  fi
  [[ "${reply}" =~ ^[Yy]$ ]]
}

prompt_input() {
  local prompt="$1"
  local default="${2:-}"
  local var_name="$3"
  local value
  if [[ -n "${default}" ]]; then
    read -r -p "$(echo -e "${C_CYAN}${prompt} [${default}] : ${C_RESET}")" value
    value="${value:-${default}}"
  else
    while true; do
      read -r -p "$(echo -e "${C_CYAN}${prompt} : ${C_RESET}")" value
      [[ -n "${value}" ]] && break
      echo -e "${C_RED}Valeur requise.${C_RESET}"
    done
  fi
  printf -v "${var_name}" '%s' "${value}"
}

prompt_secret() {
  local prompt="$1"
  local var_name="$2"
  local value confirm_val
  while true; do
    read -r -s -p "$(echo -e "${C_CYAN}${prompt} : ${C_RESET}")" value
    echo
    [[ -n "${value}" ]] || { echo -e "${C_RED}Mot de passe requis.${C_RESET}"; continue; }
    read -r -s -p "$(echo -e "${C_CYAN}Confirmer : ${C_RESET}")" confirm_val
    echo
    if [[ "${value}" == "${confirm_val}" ]]; then
      printf -v "${var_name}" '%s' "${value}"
      return 0
    fi
    echo -e "${C_RED}Les mots de passe ne correspondent pas.${C_RESET}"
  done
}

# -----------------------------------------------------------------------------
# Progression
# -----------------------------------------------------------------------------
MPS_PROGRESS_CURRENT=0
MPS_PROGRESS_TOTAL=1

progress_init() {
  MPS_PROGRESS_CURRENT=0
  MPS_PROGRESS_TOTAL="${1:-1}"
}

progress_step() {
  local label="$1"
  MPS_PROGRESS_CURRENT=$((MPS_PROGRESS_CURRENT + 1))
  local pct=$((MPS_PROGRESS_CURRENT * 100 / MPS_PROGRESS_TOTAL))
  [[ "${pct}" -gt 100 ]] && pct=100
  local filled=$((pct / 5))
  local empty=$((20 - filled))
  local bar="" spaces="" i
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  for ((i = 0; i < empty; i++)); do spaces+="░"; done
  echo -e "${C_BLUE}[${bar}${spaces}] ${pct}%${C_RESET} ${C_BOLD}${label}${C_RESET}"
  log_step "[${MPS_PROGRESS_CURRENT}/${MPS_PROGRESS_TOTAL}] ${label}"
}

# -----------------------------------------------------------------------------
# Exécution sécurisée de commandes
# -----------------------------------------------------------------------------
run_cmd() {
  local desc="$1"
  shift
  log_debug "CMD: $*"
  if "$@" >> "${MPS_LOG_FILE}" 2>&1; then
    log_ok "${desc}"
    return 0
  else
    local rc=$?
    log_error "${desc} (code ${rc})"
    return "${rc}"
  fi
}

run_cmd_or_die() {
  local desc="$1"
  shift
  run_cmd "${desc}" "$@" || die "Échec : ${desc}"
}

# -----------------------------------------------------------------------------
# Vérifications préalables
# -----------------------------------------------------------------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Ce script doit être exécuté en tant que root (sudo -i ou sudo ./install.sh)."
  fi
  log_ok "Exécution root confirmée"
}

check_internet() {
  log_info "Vérification de la connexion Internet..."
  local hosts=("1.1.1.1" "8.8.8.8" "github.com")
  local ok=0
  for h in "${hosts[@]}"; do
    if ping -c 1 -W 3 "${h}" &>/dev/null || curl -fsSL --max-time 5 "https://${h}" -o /dev/null 2>/dev/null; then
      ok=1
      break
    fi
  done
  if [[ "${ok}" -eq 0 ]]; then
    # Fallback HTTP
    if curl -fsSL --max-time 10 "https://github.com" -o /dev/null 2>/dev/null; then
      ok=1
    fi
  fi
  [[ "${ok}" -eq 1 ]] || die "Aucune connexion Internet détectée."
  log_ok "Connexion Internet disponible"
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "Impossible de détecter l'OS (/etc/os-release manquant)."
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  export MPS_OS_ID="${ID:-unknown}"
  export MPS_OS_VERSION="${VERSION_ID:-unknown}"
  export MPS_OS_CODENAME="${VERSION_CODENAME:-}"
  export MPS_OS_PRETTY="${PRETTY_NAME:-unknown}"

  case "${MPS_OS_ID}" in
    ubuntu)
      case "${MPS_OS_VERSION}" in
        22.04|24.04) ;;
        *) die "Ubuntu ${MPS_OS_VERSION} non supporté. Requis : 22.04 ou 24.04." ;;
      esac
      ;;
    debian)
      case "${MPS_OS_VERSION}" in
        12*) ;;
        *) die "Debian ${MPS_OS_VERSION} non supporté. Requis : Debian 12." ;;
      esac
      ;;
    *)
      die "OS non supporté : ${MPS_OS_PRETTY}. Requis : Ubuntu 22.04/24.04 ou Debian 12."
      ;;
  esac
  log_ok "OS détecté : ${MPS_OS_PRETTY}"
}

detect_hardware() {
  export MPS_CPU_CORES
  MPS_CPU_CORES="$(nproc 2>/dev/null || echo 1)"

  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  export MPS_RAM_MB=$((mem_kb / 1024))
  export MPS_RAM_GB
  MPS_RAM_GB="$(awk -v m="${mem_kb}" 'BEGIN { printf "%.1f", m/1024/1024 }')"

  local disk_avail
  disk_avail="$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
  export MPS_DISK_GB="${disk_avail:-0}"

  export MPS_ARCH
  MPS_ARCH="$(uname -m)"

  log_info "CPU    : ${MPS_CPU_CORES} cœur(s) (${MPS_ARCH})"
  log_info "RAM    : ${MPS_RAM_GB} Go (${MPS_RAM_MB} Mo)"
  log_info "Disque : ${MPS_DISK_GB} Go libres sur /"

  if [[ "${MPS_RAM_MB}" -lt 1024 ]]; then
    log_warn "RAM < 1 Go — installation possible mais déconseillée en production."
  fi
  if [[ "${MPS_DISK_GB}" -lt 10 ]]; then
    log_warn "Espace disque < 10 Go — risque de saturation."
  fi
}

check_ports() {
  local ports=("$@")
  local busy=()
  for p in "${ports[@]}"; do
    if ss -tuln 2>/dev/null | grep -qE ":${p}\\s" || netstat -tuln 2>/dev/null | grep -qE ":${p}\\s"; then
      busy+=("${p}")
    fi
  done
  if [[ ${#busy[@]} -gt 0 ]]; then
    log_warn "Ports déjà utilisés : ${busy[*]}"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# État d'installation
# -----------------------------------------------------------------------------
state_set() {
  local key="$1" value="$2"
  touch "${MPS_STATE_FILE}"
  if grep -q "^${key}=" "${MPS_STATE_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${MPS_STATE_FILE}"
  else
    echo "${key}=${value}" >> "${MPS_STATE_FILE}"
  fi
}

state_get() {
  local key="$1" default="${2:-}"
  if [[ -f "${MPS_STATE_FILE}" ]] && grep -q "^${key}=" "${MPS_STATE_FILE}"; then
    grep "^${key}=" "${MPS_STATE_FILE}" | cut -d= -f2-
  else
    echo "${default}"
  fi
}

save_env() {
  local key="$1" value="$2"
  touch "${MPS_ENV_FILE}"
  chmod 600 "${MPS_ENV_FILE}"
  if grep -q "^${key}=" "${MPS_ENV_FILE}" 2>/dev/null; then
    # Échapper pour sed
    local escaped
    escaped="$(printf '%s' "${value}" | sed 's/[&/\]/\\&/g')"
    sed -i "s|^${key}=.*|${key}=${escaped}|" "${MPS_ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${MPS_ENV_FILE}"
  fi
}

load_env() {
  if [[ -f "${MPS_ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "${MPS_ENV_FILE}"
    set +a
  fi
}

# -----------------------------------------------------------------------------
# Générateurs
# -----------------------------------------------------------------------------
generate_password() {
  local length="${1:-32}"
  if command -v openssl &>/dev/null; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${length}"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${length}"
  fi
  echo
}

generate_app_key() {
  # Clé Laravel base64:32
  echo "base64:$(openssl rand -base64 32)"
}

# -----------------------------------------------------------------------------
# Apt helpers
# -----------------------------------------------------------------------------
apt_update() {
  export DEBIAN_FRONTEND=noninteractive
  run_cmd_or_die "Mise à jour des index apt" apt-get update -y
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  run_cmd_or_die "Installation : $*" apt-get install -y "$@"
}

# -----------------------------------------------------------------------------
# Résumé système
# -----------------------------------------------------------------------------
print_system_summary() {
  print_separator
  echo -e "${C_BOLD}Résumé système${C_RESET}"
  echo -e "  OS     : ${MPS_OS_PRETTY}"
  echo -e "  Arch   : ${MPS_ARCH}"
  echo -e "  CPU    : ${MPS_CPU_CORES} cœur(s)"
  echo -e "  RAM    : ${MPS_RAM_GB} Go"
  echo -e "  Disque : ${MPS_DISK_GB} Go libres"
  echo -e "  Logs   : ${MPS_LOG_FILE}"
  print_separator
}
