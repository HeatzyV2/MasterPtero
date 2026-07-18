#!/usr/bin/env bash
# =============================================================================
# Module Wings — Daemon Pterodactyl (Docker + Wings binary + config)
# =============================================================================

WINGS_DIR="/etc/pterodactyl"
WINGS_BIN="/usr/local/bin/wings"
WINGS_USER="pterodactyl"

install_wings() {
  progress_init 7

  progress_step "Prérequis Docker"
  # shellcheck source=/dev/null
  source "${MPS_MODULES}/docker.sh"
  install_docker

  progress_step "Dépendances Wings"
  _wings_install_deps

  progress_step "Téléchargement binaire Wings"
  _wings_download

  progress_step "Utilisateur & répertoires"
  _wings_setup_dirs

  progress_step "Configuration Wings"
  _wings_configure

  progress_step "Service systemd"
  _wings_systemd

  progress_step "Finalisation"
  state_set "wings" "installed"

  echo
  print_separator
  echo -e "${C_GREEN}${C_BOLD}Wings installé avec succès !${C_RESET}"
  echo -e "  Binaire  : ${WINGS_BIN}"
  echo -e "  Config   : ${WINGS_DIR}/config.yml"
  echo -e "  Logs     : journalctl -u wings -f"
  echo
  echo -e "${C_YELLOW}Prochaines étapes :${C_RESET}"
  echo -e "  1. Créez un Node dans le Panel (Admin → Nodes → Create New)"
  echo -e "  2. Copiez la configuration YAML générée"
  echo -e "  3. Collez-la dans ${WINGS_DIR}/config.yml"
  echo -e "     ou utilisez l'option 'Générer / appliquer config node' du menu"
  echo -e "  4. systemctl restart wings"
  print_separator
}

_wings_install_deps() {
  apt_install curl tar unzip git
}

_wings_download() {
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Architecture non supportée pour Wings : $(uname -m)" ;;
  esac

  local url
  url="$(curl -fsSL https://api.github.com/repos/pterodactyl/wings/releases/latest \
    | grep -oP "\"browser_download_url\":\\s*\"\\K[^\"]+wings_linux_${arch}\"" | head -1 | tr -d '"')"

  if [[ -z "${url}" ]]; then
    url="https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}"
  fi

  log_info "Téléchargement Wings (${arch})..."
  curl -fsSL -o "${WINGS_BIN}" "${url}"
  chmod +x "${WINGS_BIN}"

  log_ok "Wings installé : $(${WINGS_BIN} --version 2>/dev/null || echo 'OK')"
}

_wings_setup_dirs() {
  mkdir -p "${WINGS_DIR}" /var/lib/pterodactyl /var/log/pterodactyl /tmp/pterodactyl

  # Utilisateur système pour les containers (souvent créé par Wings, on s'assure)
  if ! id "${WINGS_USER}" &>/dev/null; then
    useradd -r -m -d /var/lib/pterodactyl -s /bin/false "${WINGS_USER}" 2>/dev/null || true
  fi

  # Groupe docker pour wings si besoin
  usermod -aG docker root 2>/dev/null || true

  log_ok "Répertoires Wings créés"
}

_wings_configure() {
  load_env

  prompt_input "FQDN / IP publique de ce node" "${WINGS_FQDN:-$(hostname -f 2>/dev/null || hostname)}" WINGS_FQDN
  prompt_input "Port Wings (HTTPS API)" "${WINGS_PORT:-8080}" WINGS_PORT
  prompt_input "Port SFTP" "${WINGS_SFTP_PORT:-2022}" WINGS_SFTP_PORT

  save_env "WINGS_FQDN" "${WINGS_FQDN}"
  save_env "WINGS_PORT" "${WINGS_PORT}"
  save_env "WINGS_SFTP_PORT" "${WINGS_SFTP_PORT}"

  if [[ -f "${WINGS_DIR}/config.yml" ]]; then
    log_warn "config.yml existe déjà — conservation du fichier actuel."
    if confirm "Remplacer par un template vide ?" "n"; then
      _wings_write_template
    fi
  else
    _wings_write_template
  fi

  log_ok "Configuration Wings préparée"
}

_wings_write_template() {
  cat > "${WINGS_DIR}/config.yml" << EOF
# =============================================================================
# Master Ptero Script — Template Wings
# Remplacez ce fichier par la config générée depuis le Panel
# (Admin → Nodes → votre node → Configuration)
# =============================================================================
debug: false
uuid: CHANGE_ME_UUID
token_id: CHANGE_ME_TOKEN_ID
token: CHANGE_ME_TOKEN
api:
  host: 0.0.0.0
  port: ${WINGS_PORT}
  ssl:
    enabled: false
    cert: /etc/letsencrypt/live/${WINGS_FQDN}/fullchain.pem
    key: /etc/letsencrypt/live/${WINGS_FQDN}/privkey.pem
  upload_limit: 100
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: ${WINGS_SFTP_PORT}
allowed_mounts: []
remote: '${PANEL_APP_URL:-https://panel.example.com}'
EOF
  chmod 600 "${WINGS_DIR}/config.yml"
  log_info "Template écrit — à remplacer par la config Panel"
}

_wings_systemd() {
  cat > /etc/systemd/system/wings.service << 'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wings

  # Ne démarre que si config valide (pas CHANGE_ME)
  if grep -q "CHANGE_ME" "${WINGS_DIR}/config.yml" 2>/dev/null; then
    log_warn "Config placeholder détectée — wings non démarré. Appliquez la config Panel puis : systemctl start wings"
  else
    systemctl restart wings
    sleep 2
    if systemctl is-active --quiet wings; then
      log_ok "Service wings actif"
    else
      log_warn "Wings n'a pas démarré — vérifiez : journalctl -u wings -n 50"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Appliquer une config node (collée ou fichier)
# -----------------------------------------------------------------------------
apply_wings_config() {
  mkdir -p "${WINGS_DIR}"

  echo -e "${C_CYAN}Collez la configuration YAML du Panel, puis Ctrl+D (EOF) :${C_RESET}"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}"

  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    die "Configuration vide."
  fi

  # Validation basique YAML
  if ! grep -qE '^(uuid|token):' "${tmp}"; then
    rm -f "${tmp}"
    die "Fichier invalide : uuid/token introuvables."
  fi

  cp -a "${WINGS_DIR}/config.yml" "${WINGS_DIR}/config.yml.bak.$(date +%s)" 2>/dev/null || true
  mv "${tmp}" "${WINGS_DIR}/config.yml"
  chmod 600 "${WINGS_DIR}/config.yml"

  systemctl restart wings
  sleep 2
  if systemctl is-active --quiet wings; then
    log_ok "Config appliquée — Wings démarré"
    state_set "wings_config" "applied"
  else
    log_error "Wings a échoué au démarrage"
    journalctl -u wings -n 30 --no-pager | tee -a "${MPS_LOG_FILE}"
    die "Vérifiez la configuration YAML."
  fi
}

# SSL pour Wings (optionnel, si FQDN dédié)
configure_wings_ssl() {
  load_env
  prompt_input "FQDN Wings pour SSL" "${WINGS_FQDN}" WINGS_FQDN
  prompt_input "Email Let's Encrypt" "${PANEL_ADMIN_EMAIL:-admin@${WINGS_FQDN}}" email

  apt_install certbot
  # Mode standalone nécessite arrêt temporaire si port 80 libre
  if systemctl is-active --quiet nginx; then
    certbot certonly --nginx -d "${WINGS_FQDN}" --non-interactive --agree-tos -m "${email}" \
      >> "${MPS_LOG_FILE}" 2>&1 \
      || certbot certonly --standalone -d "${WINGS_FQDN}" --non-interactive --agree-tos -m "${email}" \
      >> "${MPS_LOG_FILE}" 2>&1 \
      || die "Échec obtention certificat Wings"
  else
    certbot certonly --standalone -d "${WINGS_FQDN}" --non-interactive --agree-tos -m "${email}" \
      >> "${MPS_LOG_FILE}" 2>&1 \
      || die "Échec obtention certificat Wings"
  fi

  if [[ -f "${WINGS_DIR}/config.yml" ]]; then
    # Activer SSL dans config (best-effort sed)
    sed -i '/^api:/,/^system:/{s/enabled: false/enabled: true/}' "${WINGS_DIR}/config.yml" || true
  fi

  systemctl restart wings 2>/dev/null || true
  log_ok "SSL Wings configuré pour ${WINGS_FQDN}"
}
