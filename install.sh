#!/usr/bin/env bash
# =============================================================================
# Master Ptero Script — Installateur Pterodactyl Production
# Compatible : Ubuntu 22.04 / 24.04 · Debian 12 / 13
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${MPS_MODULES}/docker.sh"
# shellcheck source=/dev/null
source "${MPS_MODULES}/panel.sh"
# shellcheck source=/dev/null
source "${MPS_MODULES}/wings.sh"
# shellcheck source=/dev/null
source "${MPS_MODULES}/firewall.sh"
# shellcheck source=/dev/null
source "${MPS_MODULES}/phpmyadmin.sh"
# shellcheck source=/dev/null
source "${MPS_MODULES}/optimize.sh"

readonly MPS_VERSION="1.0.0"

# -----------------------------------------------------------------------------
# Trap erreurs
# -----------------------------------------------------------------------------
on_error() {
  local line="$1" code="$2"
  log_error "Erreur ligne ${line} (exit ${code}). Journal : ${MPS_LOG_FILE}"
}
trap 'on_error ${LINENO} $?' ERR

# -----------------------------------------------------------------------------
# Pré-vol
# -----------------------------------------------------------------------------
preflight() {
  require_root
  detect_os
  detect_hardware
  check_internet
  print_system_summary
}

# -----------------------------------------------------------------------------
# Installation complète
# -----------------------------------------------------------------------------
install_full() {
  echo -e "${C_BOLD}Installation complète : Panel + Wings + Firewall + Optimisations${C_RESET}"
  echo
  if ! confirm "Lancer l'installation complète ?" "y"; then
    return 0
  fi

  install_panel
  install_wings
  configure_firewall
  optimize_vps

  if confirm "Installer phpMyAdmin ?" "n"; then
    install_phpmyadmin
  fi

  show_final_summary
}

show_final_summary() {
  load_env
  echo
  print_banner
  echo -e "${C_GREEN}${C_BOLD}  Installation terminée${C_RESET}"
  print_separator
  echo -e "  Panel URL  : ${PANEL_APP_URL:-n/a}"
  echo -e "  Admin      : ${PANEL_ADMIN_EMAIL:-n/a}"
  echo -e "  Wings      : $(state_get wings unknown)"
  echo -e "  Firewall   : $(state_get firewall unknown)"
  echo -e "  Optimize   : $(state_get optimize unknown)"
  echo -e "  Secrets    : ${MPS_ENV_FILE}"
  echo -e "  Logs       : ${MPS_LOG_FILE}"
  print_separator
  echo -e "${C_YELLOW}N'oubliez pas de :${C_RESET}"
  echo -e "  1. Créer le Node dans le Panel et coller la config Wings"
  echo -e "  2. Allocations de ports (jeux) dans le Panel + UFW"
  echo -e "  3. Sauvegarder ${MPS_ENV_FILE} hors du serveur"
  echo
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------
show_menu() {
  print_banner
  echo -e "  ${C_BOLD}Version ${MPS_VERSION}${C_RESET}  ·  ${MPS_OS_PRETTY:-?}  ·  ${MPS_RAM_GB:-?} Go RAM"
  print_separator
  echo -e "  ${C_CYAN}1)${C_RESET}  Installation complète (Panel + Wings + Firewall + Opt)"
  echo -e "  ${C_CYAN}2)${C_RESET}  Installer le Panel uniquement"
  echo -e "  ${C_CYAN}3)${C_RESET}  Installer Wings uniquement"
  echo -e "  ${C_CYAN}4)${C_RESET}  Installer Docker uniquement"
  echo -e "  ${C_CYAN}5)${C_RESET}  Installer phpMyAdmin"
  echo -e "  ${C_CYAN}6)${C_RESET}  Configurer le Firewall (UFW)"
  echo -e "  ${C_CYAN}7)${C_RESET}  Optimiser le VPS"
  echo -e "  ${C_CYAN}8)${C_RESET}  Appliquer la config Node Wings"
  echo -e "  ${C_CYAN}9)${C_RESET}  SSL Wings (Let's Encrypt)"
  echo -e "  ${C_CYAN}10)${C_RESET} Ajouter un port Firewall"
  echo -e "  ${C_CYAN}11)${C_RESET} Statut Firewall"
  echo -e "  ${C_CYAN}12)${C_RESET} Afficher le résumé / credentials"
  echo -e "  ${C_CYAN}0)${C_RESET}  Quitter"
  print_separator
}

show_credentials() {
  load_env
  print_separator
  echo -e "${C_BOLD}État & credentials${C_RESET}"
  echo -e "  Panel     : $(state_get panel not_installed)"
  echo -e "  Wings     : $(state_get wings not_installed)"
  echo -e "  Firewall  : $(state_get firewall not_configured)"
  echo -e "  phpMyAdmin: $(state_get phpmyadmin not_installed)"
  echo -e "  Optimize  : $(state_get optimize not_done)"
  echo
  if [[ -f "${MPS_ENV_FILE}" ]]; then
    echo -e "${C_DIM}Fichier secrets (permissions 600) :${C_RESET}"
    # Masquer les mots de passe dans l'affichage
    while IFS= read -r line; do
      if [[ "${line}" =~ (PASS|PASSWORD|TOKEN|KEY|BLOWFISH)= ]]; then
        local k="${line%%=*}"
        echo -e "  ${k}=********"
      else
        echo -e "  ${line}"
      fi
    done < "${MPS_ENV_FILE}"
  else
    echo -e "  Aucun fichier secrets pour le moment."
  fi
  print_separator
}

main_loop() {
  while true; do
    show_menu
    local choice
    read -r -p "$(echo -e "${C_BOLD}Choix : ${C_RESET}")" choice
    echo
    case "${choice}" in
      1)  install_full ;;
      2)  install_panel ;;
      3)  install_wings ;;
      4)  install_docker ;;
      5)  install_phpmyadmin ;;
      6)  configure_firewall ;;
      7)  optimize_vps ;;
      8)  apply_wings_config ;;
      9)  configure_wings_ssl ;;
      10) add_firewall_port ;;
      11) show_firewall_status ;;
      12) show_credentials ;;
      0)  log_info "Au revoir."; exit 0 ;;
      *)  echo -e "${C_RED}Option invalide.${C_RESET}" ;;
    esac
    echo
    read -r -p "$(echo -e "${C_DIM}Entrée pour revenir au menu...${C_RESET}")" _
  done
}

# -----------------------------------------------------------------------------
# CLI arguments
# -----------------------------------------------------------------------------
usage() {
  cat << EOF
Usage: sudo ./install.sh [commande]

Commandes :
  (aucune)       Menu interactif
  full           Installation complète
  panel          Panel uniquement
  wings          Wings uniquement
  docker         Docker uniquement
  phpmyadmin     phpMyAdmin
  firewall       UFW
  optimize       Optimisations VPS
  wings-config   Appliquer config Node
  status         Afficher l'état
  -h, --help     Aide

Variables utiles :
  MPS_DEBUG=1    Logs debug console

EOF
}

main() {
  preflight

  local cmd="${1:-}"
  case "${cmd}" in
    "")            main_loop ;;
    full)          install_full ;;
    panel)         install_panel ;;
    wings)         install_wings ;;
    docker)        install_docker ;;
    phpmyadmin)    install_phpmyadmin ;;
    firewall)      configure_firewall ;;
    optimize)      optimize_vps ;;
    wings-config)  apply_wings_config ;;
    status)        show_credentials ;;
    -h|--help|help) usage ;;
    *)
      echo "Commande inconnue : ${cmd}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
