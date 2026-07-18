#!/usr/bin/env bash
# =============================================================================
# Module Firewall — UFW (SSH, HTTP/S, Wings, SFTP, ports jeux)
# =============================================================================

# Ports jeux courants Pterodactyl (allocations typiques)
# L'utilisateur peut étendre via config/ports.conf

configure_firewall() {
  progress_init 5

  progress_step "Installation UFW"
  apt_install ufw

  load_env

  local ssh_port
  ssh_port="$(_detect_ssh_port)"
  local wings_port="${WINGS_PORT:-8080}"
  local sftp_port="${WINGS_SFTP_PORT:-2022}"

  progress_step "Politique par défaut"
  # IMPORTANT : autoriser SSH avant enable
  ufw --force reset >> "${MPS_LOG_FILE}" 2>&1
  ufw default deny incoming >> "${MPS_LOG_FILE}" 2>&1
  ufw default allow outgoing >> "${MPS_LOG_FILE}" 2>&1

  progress_step "Règles essentielles"
  ufw allow "${ssh_port}/tcp" comment 'SSH' >> "${MPS_LOG_FILE}" 2>&1
  ufw allow 80/tcp comment 'HTTP' >> "${MPS_LOG_FILE}" 2>&1
  ufw allow 443/tcp comment 'HTTPS' >> "${MPS_LOG_FILE}" 2>&1
  ufw allow "${wings_port}/tcp" comment 'Wings API' >> "${MPS_LOG_FILE}" 2>&1
  ufw allow "${sftp_port}/tcp" comment 'Wings SFTP' >> "${MPS_LOG_FILE}" 2>&1

  progress_step "Ports jeux / personnalisés"
  _firewall_game_ports
  _firewall_custom_ports

  progress_step "Activation UFW"
  ufw --force enable >> "${MPS_LOG_FILE}" 2>&1
  ufw status verbose | tee -a "${MPS_LOG_FILE}"

  state_set "firewall" "configured"
  save_env "UFW_SSH_PORT" "${ssh_port}"
  save_env "WINGS_PORT" "${wings_port}"
  save_env "WINGS_SFTP_PORT" "${sftp_port}"

  log_ok "Firewall UFW configuré (SSH:${ssh_port}, Wings:${wings_port}, SFTP:${sftp_port})"
}

_detect_ssh_port() {
  local port=22
  if [[ -f /etc/ssh/sshd_config ]]; then
    local detected
    detected="$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config | awk '{print $2}' | tail -1)"
    [[ -n "${detected}" ]] && port="${detected}"
  fi
  # Détecter aussi via ss
  if ss -tlnp 2>/dev/null | grep -q sshd; then
    local listen
    listen="$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | head -1 | grep -oE '[0-9]+$')"
    [[ -n "${listen}" ]] && port="${listen}"
  fi
  echo "${port}"
}

_firewall_game_ports() {
  # Plages d'allocations Pterodactyl recommandées
  # TCP/UDP 25565 (Minecraft), 7777 (ARK/Rust), 27015 (Source), etc.
  local ports_file="${MPS_CONFIG}/ports.conf"

  if [[ ! -f "${ports_file}" ]]; then
    cat > "${ports_file}" << 'EOF'
# Master Ptero Script — Ports personnalisés / jeux
# Format : PORT[/tcp|/udp|/both]  [commentaire]
# Exemples :
# 25565/both    Minecraft
# 7777/both     ARK / Rust
# 27015/both    Source / CS2
# 30120/tcp     FiveM
# 8211/udp      Palworld
# 25565:25600/tcp  Plage Minecraft

# Plage d'allocations Wings par défaut (modifiable)
25565:25700/both
27015:27050/both
7777:7800/both
30120/tcp
8211/udp
EOF
    log_info "Fichier ports créé : ${ports_file}"
  fi

  if confirm "Ouvrir les ports jeux définis dans config/ports.conf ?" "y"; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      # Ignorer commentaires / vides
      [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
      local spec comment
      spec="$(echo "${line}" | awk '{print $1}')"
      comment="$(echo "${line}" | cut -d' ' -f2- | sed 's/^#\s*//')"
      _ufw_allow_spec "${spec}" "${comment:-game}"
    done < "${ports_file}"
  fi

  # Ports additionnels interactifs
  if confirm "Ajouter des ports personnalisés maintenant ?" "n"; then
    while true; do
      local custom
      prompt_input "Port ou plage (ex: 25565, 25565:25600/tcp, vide pour finir)" "" custom
      [[ -z "${custom}" ]] && break
      _ufw_allow_spec "${custom}" "custom"
    done
  fi
}

_firewall_custom_ports() {
  # Rien de plus — géré dans _firewall_game_ports
  :
}

_ufw_allow_spec() {
  local spec="$1"
  local comment="${2:-custom}"
  local proto="tcp"
  local range="${spec}"

  if [[ "${spec}" == */* ]]; then
    range="${spec%/*}"
    proto="${spec#*/}"
  fi

  case "${proto}" in
    tcp)
      ufw allow "${range}/tcp" comment "${comment}" >> "${MPS_LOG_FILE}" 2>&1
      log_ok "UFW allow ${range}/tcp"
      ;;
    udp)
      ufw allow "${range}/udp" comment "${comment}" >> "${MPS_LOG_FILE}" 2>&1
      log_ok "UFW allow ${range}/udp"
      ;;
    both|all)
      ufw allow "${range}/tcp" comment "${comment}" >> "${MPS_LOG_FILE}" 2>&1
      ufw allow "${range}/udp" comment "${comment}" >> "${MPS_LOG_FILE}" 2>&1
      log_ok "UFW allow ${range}/tcp+udp"
      ;;
    *)
      log_warn "Protocole inconnu '${proto}' pour ${spec} — ignoré"
      ;;
  esac
}

show_firewall_status() {
  echo -e "${C_BOLD}Statut UFW${C_RESET}"
  ufw status verbose
}

add_firewall_port() {
  prompt_input "Spécification (ex: 25565/both ou 30120/tcp)" "" spec
  [[ -z "${spec}" ]] && die "Spécification vide"
  _ufw_allow_spec "${spec}" "manual"
  echo "${spec}" >> "${MPS_CONFIG}/ports.conf"
  log_ok "Port ajouté et persisté dans ports.conf"
}
