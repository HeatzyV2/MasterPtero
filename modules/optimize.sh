#!/usr/bin/env bash
# =============================================================================
# Module Optimisation VPS — sysctl, limites, logs, Docker, fail2ban, NTP
# =============================================================================

optimize_vps() {
  progress_init 8

  load_env
  prompt_input "Timezone" "${PANEL_TIMEZONE:-Europe/Paris}" OPT_TIMEZONE

  progress_step "Timezone & NTP"
  _opt_timezone_ntp

  progress_step "sysctl réseau / performances"
  _opt_sysctl

  progress_step "Limites utilisateurs (limits.conf)"
  _opt_limits

  progress_step "Gestion des logs (journald + logrotate)"
  _opt_logs

  progress_step "fail2ban"
  _opt_fail2ban

  progress_step "Docker cleanup timer"
  _opt_docker_cleanup

  progress_step "Swap (si RAM < 4 Go et absente)"
  _opt_swap

  progress_step "Finalisation"
  state_set "optimize" "done"
  save_env "PANEL_TIMEZONE" "${OPT_TIMEZONE}"

  log_ok "Optimisations VPS appliquées"
  print_separator
  echo -e "${C_GREEN}Optimisations actives :${C_RESET}"
  echo -e "  • sysctl réseau (bbr, buffers, syn cookies)"
  echo -e "  • nofile 65535"
  echo -e "  • journald limité + logrotate"
  echo -e "  • fail2ban (sshd + nginx)"
  echo -e "  • Docker prune hebdomadaire"
  echo -e "  • Timezone : ${OPT_TIMEZONE}"
  print_separator
}

_opt_timezone_ntp() {
  timedatectl set-timezone "${OPT_TIMEZONE}" >> "${MPS_LOG_FILE}" 2>&1 || \
    ln -sfn "/usr/share/zoneinfo/${OPT_TIMEZONE}" /etc/localtime

  apt_install chrony
  systemctl enable --now chrony
  timedatectl set-ntp true >> "${MPS_LOG_FILE}" 2>&1 || true

  log_ok "Timezone=${OPT_TIMEZONE} — NTP (chrony) actif"
}

_opt_sysctl() {
  local conf="/etc/sysctl.d/99-master-ptero.conf"
  cat > "${conf}" << 'EOF'
# Master Ptero Script — Optimisations réseau / game servers
# Connexions
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Sécurité réseau
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# File descriptors / mmap
fs.file-max = 2097152
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Inotify (utile Docker / Wings)
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF

  # Charger BBR si module dispo
  modprobe tcp_bbr 2>/dev/null || true
  sysctl --system >> "${MPS_LOG_FILE}" 2>&1 || sysctl -p "${conf}" >> "${MPS_LOG_FILE}" 2>&1

  log_ok "sysctl appliqué (${conf})"
}

_opt_limits() {
  local conf="/etc/security/limits.d/99-master-ptero.conf"
  cat > "${conf}" << 'EOF'
# Master Ptero Script — Limites fichiers / process
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
root soft nofile 65535
root hard nofile 65535
www-data soft nofile 65535
www-data hard nofile 65535
EOF

  # systemd default limits
  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/99-master-ptero.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=65535
DefaultLimitNPROC=65535
EOF

  systemctl daemon-reload
  log_ok "Limites nofile/nproc configurées"
}

_opt_logs() {
  # journald
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-master-ptero.conf << 'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=14day
Compress=yes
EOF
  systemctl restart systemd-journald

  # logrotate nginx / pterodactyl
  cat > /etc/logrotate.d/master-ptero << 'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 "$(cat /var/run/nginx.pid)"
    endscript
}

/var/www/pterodactyl/storage/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data www-data
    sharedscripts
}
EOF

  log_ok "journald + logrotate configurés"
}

_opt_fail2ban() {
  apt_install fail2ban

  cat > /etc/fail2ban/jail.d/master-ptero.conf << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ssh
maxretry = 4

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF

  # Jail optionnelle pour Wings SFTP (si logs standard)
  cat > /etc/fail2ban/filter.d/wings-sftp.conf << 'EOF'
[Definition]
failregex = ^.*failed authentication.*from <HOST>.*$
ignoreregex =
EOF

  systemctl enable --now fail2ban
  systemctl restart fail2ban
  log_ok "fail2ban actif (sshd, nginx)"
}

_opt_docker_cleanup() {
  if ! command -v docker &>/dev/null; then
    log_info "Docker absent — cleanup timer ignoré"
    return 0
  fi

  cat > /etc/systemd/system/docker-cleanup.service << 'EOF'
[Unit]
Description=Docker system prune (Master Ptero)
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -af --filter "until=168h"
EOF

  cat > /etc/systemd/system/docker-cleanup.timer << 'EOF'
[Unit]
Description=Weekly Docker cleanup

[Timer]
OnCalendar=Sun 03:30
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now docker-cleanup.timer
  log_ok "Timer Docker cleanup hebdomadaire (dimanche 03:30)"
}

_opt_swap() {
  local ram_mb="${MPS_RAM_MB:-0}"
  if [[ "${ram_mb}" -ge 4096 ]]; then
    log_info "RAM ≥ 4 Go — swap optionnel ignoré"
    return 0
  fi

  if swapon --show | grep -q .; then
    log_ok "Swap déjà présent"
    return 0
  fi

  if ! confirm "Créer un fichier swap de 2 Go ?" "y"; then
    return 0
  fi

  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile >> "${MPS_LOG_FILE}" 2>&1
  swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  log_ok "Swap 2 Go créé"
}
