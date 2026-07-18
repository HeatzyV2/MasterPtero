#!/usr/bin/env bash
# =============================================================================
# Module Docker — Installation & configuration Docker Engine (CE)
# =============================================================================

install_docker() {
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    log_ok "Docker déjà installé : $(docker --version)"
    state_set "docker" "installed"
    return 0
  fi

  log_step "Installation de Docker Engine"

  # Prérequis
  apt_install ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings

  local docker_url="https://download.docker.com/linux/${MPS_OS_ID}"

  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL "${docker_url}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local arch docker_codename
  arch="$(dpkg --print-architecture)"
  docker_codename="${MPS_OS_CODENAME}"

  # Si Docker n'a pas encore de dépôt pour ce codename (ex. trixie récent), fallback bookworm/jammy
  if ! curl -fsSL "${docker_url}/dists/${docker_codename}/Release" -o /dev/null 2>/dev/null; then
    if [[ "${MPS_OS_ID}" == "debian" ]]; then
      log_warn "Docker CE sans dépôt '${docker_codename}' — fallback bookworm"
      docker_codename="bookworm"
    else
      log_warn "Docker CE sans dépôt '${docker_codename}' — fallback jammy"
      docker_codename="jammy"
    fi
  fi

  echo \
    "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] ${docker_url} ${docker_codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  run_cmd_or_die "Docker démarré" systemctl is-active --quiet docker

  # Daemon.json optimisé pour game servers / Wings
  if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
EOF
    systemctl restart docker
    log_ok "Configuration Docker daemon.json appliquée"
  fi

  # Vérification
  docker run --rm hello-world >> "${MPS_LOG_FILE}" 2>&1 || log_warn "Test hello-world échoué (non bloquant)"

  state_set "docker" "installed"
  log_ok "Docker installé avec succès : $(docker --version)"
}

configure_docker_user() {
  local user="${1:-}"
  if [[ -n "${user}" ]] && id "${user}" &>/dev/null; then
    usermod -aG docker "${user}"
    log_ok "Utilisateur ${user} ajouté au groupe docker"
  fi
}
