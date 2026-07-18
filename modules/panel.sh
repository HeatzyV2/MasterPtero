#!/usr/bin/env bash
# =============================================================================
# Module Panel — Installation Pterodactyl Panel (Nginx, PHP 8.3, MariaDB, Redis)
# =============================================================================

PANEL_DIR="/var/www/pterodactyl"
PANEL_USER="www-data"

# -----------------------------------------------------------------------------
# Dépendances système
# -----------------------------------------------------------------------------
_panel_install_deps() {
  log_step "Installation des dépendances Panel"

  apt_install curl apt-transport-https ca-certificates gnupg
  # Présent sur Ubuntu ; optionnel sur Debian
  apt-get install -y software-properties-common >> "${MPS_LOG_FILE}" 2>&1 || true

  # PHP 8.3 — PPA Ondrej (Ubuntu) / Sury (Debian 12 & 13)
  if [[ "${MPS_OS_ID}" == "ubuntu" ]]; then
    if ! apt-cache show php8.3 &>/dev/null; then
      add-apt-repository -y ppa:ondrej/php >> "${MPS_LOG_FILE}" 2>&1 || true
    fi
  else
    # Debian 12 (bookworm) / 13 (trixie) — dépôt Sury
    if [[ ! -f /etc/apt/sources.list.d/php.list ]]; then
      curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/php.gpg
      local php_codename="${MPS_OS_CODENAME}"
      # Fallback si codename Sury indisponible
      if ! curl -fsSL "https://packages.sury.org/php/dists/${php_codename}/Release" -o /dev/null 2>/dev/null; then
        log_warn "Sury n'a pas de dépôt '${php_codename}' — fallback bookworm"
        php_codename="bookworm"
      fi
      echo "deb https://packages.sury.org/php/ ${php_codename} main" > /etc/apt/sources.list.d/php.list
    fi
  fi

  apt_update

  apt_install \
    php8.3 php8.3-cli php8.3-fpm php8.3-common \
    php8.3-mysql php8.3-mbstring php8.3-bcmath php8.3-xml \
    php8.3-zip php8.3-curl php8.3-gd php8.3-intl php8.3-redis \
    php8.3-readline php8.3-gmp \
    mariadb-server mariadb-client \
    redis-server \
    nginx \
    git unzip zip tar \
    certbot python3-certbot-nginx

  # Composer
  if ! command -v composer &>/dev/null; then
    log_info "Installation de Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
    log_ok "Composer installé : $(composer --version 2>/dev/null | head -1)"
  else
    log_ok "Composer déjà présent"
  fi

  systemctl enable --now php8.3-fpm redis-server mariadb nginx
}

# -----------------------------------------------------------------------------
# MariaDB — base & utilisateur
# -----------------------------------------------------------------------------
_panel_setup_database() {
  log_step "Configuration MariaDB"

  local db_name="${PANEL_DB_NAME:-panel}"
  local db_user="${PANEL_DB_USER:-pterodactyl}"
  local db_pass="${PANEL_DB_PASS:-$(generate_password 32)}"

  # Sécurisation basique MariaDB root (socket unix auth sur Debian/Ubuntu)
  mysql -e "SELECT 1" &>/dev/null || die "Impossible de se connecter à MariaDB"

  mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';"
  mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
  # Si l'utilisateur existe déjà, mettre à jour le mot de passe
  mysql -e "ALTER USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';" 2>/dev/null || true
  mysql -e "ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';" 2>/dev/null || true
  mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"

  PANEL_DB_NAME="${db_name}"
  PANEL_DB_USER="${db_user}"
  PANEL_DB_PASS="${db_pass}"

  save_env "PANEL_DB_NAME" "${db_name}"
  save_env "PANEL_DB_USER" "${db_user}"
  save_env "PANEL_DB_PASS" "${db_pass}"

  log_ok "Base de données '${db_name}' prête"
}

# -----------------------------------------------------------------------------
# Téléchargement & installation Panel
# -----------------------------------------------------------------------------
_panel_download() {
  log_step "Téléchargement Pterodactyl Panel"

  mkdir -p "${PANEL_DIR}"
  cd /var/www

  local latest_url
  latest_url="$(curl -fsSL https://api.github.com/repos/pterodactyl/panel/releases/latest \
    | grep -oP '"browser_download_url":\s*"\K[^"]+panel\.tar\.gz' | head -1)"

  if [[ -z "${latest_url}" ]]; then
    latest_url="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
  fi

  log_info "URL : ${latest_url}"
  curl -fsSL -o /tmp/panel.tar.gz "${latest_url}"

  # Nettoyage si réinstall
  find "${PANEL_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

  tar -xzf /tmp/panel.tar.gz -C "${PANEL_DIR}"
  rm -f /tmp/panel.tar.gz

  chmod -R 755 "${PANEL_DIR}/storage" "${PANEL_DIR}/bootstrap/cache"
  chown -R "${PANEL_USER}:${PANEL_USER}" "${PANEL_DIR}"

  log_ok "Panel extrait dans ${PANEL_DIR}"
}

_panel_configure_env() {
  log_step "Configuration .env Panel"

  cd "${PANEL_DIR}"

  if [[ ! -f .env ]]; then
    cp .env.example .env
  fi

  local app_url="${PANEL_APP_URL}"
  local app_timezone="${PANEL_TIMEZONE:-Europe/Paris}"
  local app_key
  app_key="$(generate_app_key)"

  # Remplacements .env
  _env_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" .env; then
      # Utiliser | comme délimiteur pour éviter conflits avec /
      sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
      echo "${key}=${val}" >> .env
    fi
  }

  _env_set "APP_ENV" "production"
  _env_set "APP_DEBUG" "false"
  _env_set "APP_URL" "${app_url}"
  _env_set "APP_TIMEZONE" "${app_timezone}"
  _env_set "APP_SERVICE_AUTHOR" "${PANEL_ADMIN_EMAIL}"
  _env_set "APP_KEY" "${app_key}"

  _env_set "DB_CONNECTION" "mysql"
  _env_set "DB_HOST" "127.0.0.1"
  _env_set "DB_PORT" "3306"
  _env_set "DB_DATABASE" "${PANEL_DB_NAME}"
  _env_set "DB_USERNAME" "${PANEL_DB_USER}"
  _env_set "DB_PASSWORD" "${PANEL_DB_PASS}"

  _env_set "CACHE_DRIVER" "redis"
  _env_set "SESSION_DRIVER" "redis"
  _env_set "QUEUE_CONNECTION" "redis"
  _env_set "REDIS_HOST" "127.0.0.1"
  _env_set "REDIS_PASSWORD" "null"
  _env_set "REDIS_PORT" "6379"

  # Mail (log driver par défaut — configurable après)
  _env_set "MAIL_MAILER" "${PANEL_MAIL_MAILER:-log}"
  _env_set "MAIL_FROM_ADDRESS" "${PANEL_ADMIN_EMAIL}"
  _env_set "MAIL_FROM_NAME" "Pterodactyl Panel"

  chown "${PANEL_USER}:${PANEL_USER}" .env
  chmod 640 .env

  save_env "PANEL_APP_URL" "${app_url}"
  save_env "PANEL_APP_KEY" "${app_key}"

  log_ok "Fichier .env configuré"
}

_panel_composer_migrate() {
  log_step "Composer install & migrations"

  cd "${PANEL_DIR}"

  # Composer en tant que www-data
  run_cmd_or_die "Composer install" \
    sudo -u "${PANEL_USER}" composer install --no-dev --optimize-autoloader --no-interaction

  # Clé déjà définie dans .env — regenerer si besoin
  if ! grep -q '^APP_KEY=base64:' .env; then
    sudo -u "${PANEL_USER}" php artisan key:generate --force >> "${MPS_LOG_FILE}" 2>&1
  fi

  run_cmd_or_die "Migrations BDD" \
    sudo -u "${PANEL_USER}" php artisan migrate --force --seed

  # Permissions storage
  chown -R "${PANEL_USER}:${PANEL_USER}" "${PANEL_DIR}"
  chmod -R 755 storage bootstrap/cache

  log_ok "Dépendances et migrations OK"
}

_panel_create_admin() {
  log_step "Création du compte administrateur"

  cd "${PANEL_DIR}"

  # artisan p:user:make — non-interactif via arguments si disponibles
  # Fallback : echo piped pour versions plus anciennes
  if sudo -u "${PANEL_USER}" php artisan p:user:make --help 2>&1 | grep -q '\-\-email'; then
    sudo -u "${PANEL_USER}" php artisan p:user:make \
      --email="${PANEL_ADMIN_EMAIL}" \
      --username="${PANEL_ADMIN_USER}" \
      --name-first="${PANEL_ADMIN_FIRST:-Admin}" \
      --name-last="${PANEL_ADMIN_LAST:-Panel}" \
      --password="${PANEL_ADMIN_PASS}" \
      --admin=1 \
      --no-interaction >> "${MPS_LOG_FILE}" 2>&1 \
      || log_warn "Création admin via flags — tentative alternative"
  fi

  # Vérifier si l'utilisateur existe ; sinon méthode interactive via expect/printf
  local exists
  exists="$(mysql -N -e "SELECT COUNT(*) FROM \`${PANEL_DB_NAME}\`.users WHERE email='${PANEL_ADMIN_EMAIL}';" 2>/dev/null || echo 0)"

  if [[ "${exists}" == "0" ]]; then
    log_info "Création admin via artisan interactif..."
    printf '%s\n%s\n%s\n%s\n%s\nyes\n' \
      "${PANEL_ADMIN_EMAIL}" \
      "${PANEL_ADMIN_USER}" \
      "${PANEL_ADMIN_FIRST:-Admin}" \
      "${PANEL_ADMIN_LAST:-Panel}" \
      "${PANEL_ADMIN_PASS}" \
      | sudo -u "${PANEL_USER}" php artisan p:user:make >> "${MPS_LOG_FILE}" 2>&1 \
      || die "Impossible de créer le compte administrateur"
  fi

  save_env "PANEL_ADMIN_EMAIL" "${PANEL_ADMIN_EMAIL}"
  save_env "PANEL_ADMIN_USER" "${PANEL_ADMIN_USER}"

  log_ok "Administrateur créé : ${PANEL_ADMIN_EMAIL}"
}

# -----------------------------------------------------------------------------
# Nginx
# -----------------------------------------------------------------------------
_panel_configure_nginx() {
  log_step "Configuration Nginx"

  local domain="${PANEL_DOMAIN}"
  local conf="/etc/nginx/sites-available/pterodactyl.conf"

  cat > "${conf}" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log;

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\\.ht {
        deny all;
    }
}
EOF

  ln -sfn "${conf}" /etc/nginx/sites-enabled/pterodactyl.conf

  # Désactiver default si présent
  rm -f /etc/nginx/sites-enabled/default

  nginx -t >> "${MPS_LOG_FILE}" 2>&1 || die "Configuration Nginx invalide"
  systemctl reload nginx
  log_ok "Nginx configuré pour ${domain}"
}

_panel_configure_ssl() {
  if [[ "${PANEL_SSL:-y}" != "y" ]]; then
    log_info "SSL ignoré (désactivé)"
    return 0
  fi

  log_step "Obtention certificat Let's Encrypt"

  local domain="${PANEL_DOMAIN}"
  local email="${PANEL_ADMIN_EMAIL}"

  # Vérifier résolution DNS basique
  if ! getent hosts "${domain}" &>/dev/null; then
    log_warn "Le domaine ${domain} ne résout pas encore — SSL reporté."
    log_warn "Exécutez plus tard : certbot --nginx -d ${domain} --non-interactive --agree-tos -m ${email}"
    return 0
  fi

  if certbot --nginx \
      -d "${domain}" \
      --non-interactive \
      --agree-tos \
      -m "${email}" \
      --redirect \
      >> "${MPS_LOG_FILE}" 2>&1; then
    log_ok "SSL Let's Encrypt actif pour ${domain}"
    # Forcer HTTPS dans APP_URL
    cd "${PANEL_DIR}"
    sed -i "s|^APP_URL=.*|APP_URL=https://${domain}|" .env
    save_env "PANEL_APP_URL" "https://${domain}"
    systemctl reload nginx
  else
    log_warn "Échec Certbot — le panel reste en HTTP. Vérifiez le DNS et relancez certbot."
  fi
}

# -----------------------------------------------------------------------------
# Queue worker & cron
# -----------------------------------------------------------------------------
_panel_setup_services() {
  log_step "Services systemd (queue, cron, schedule)"

  # Cron Laravel scheduler
  local cron_line="* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1"
  if ! crontab -u "${PANEL_USER}" -l 2>/dev/null | grep -qF "artisan schedule:run"; then
    (crontab -u "${PANEL_USER}" -l 2>/dev/null; echo "${cron_line}") | crontab -u "${PANEL_USER}" -
  fi

  # Queue worker systemd
  cat > /etc/systemd/system/pteroq.service << EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=${PANEL_USER}
Group=${PANEL_USER}
Restart=always
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now pteroq.service

  # Optimisations Laravel prod
  cd "${PANEL_DIR}"
  sudo -u "${PANEL_USER}" php artisan config:cache >> "${MPS_LOG_FILE}" 2>&1 || true
  sudo -u "${PANEL_USER}" php artisan route:cache >> "${MPS_LOG_FILE}" 2>&1 || true
  sudo -u "${PANEL_USER}" php artisan view:cache >> "${MPS_LOG_FILE}" 2>&1 || true

  log_ok "Queue worker et scheduler configurés"
}

# -----------------------------------------------------------------------------
# Point d'entrée module
# -----------------------------------------------------------------------------
install_panel() {
  progress_init 10

  progress_step "Collecte des informations Panel"
  _panel_collect_info

  progress_step "Dépendances (Nginx, PHP 8.3, MariaDB, Redis)"
  _panel_install_deps

  progress_step "Base de données MariaDB"
  _panel_setup_database

  progress_step "Téléchargement Panel"
  _panel_download

  progress_step "Configuration .env"
  _panel_configure_env

  progress_step "Composer & migrations"
  _panel_composer_migrate

  progress_step "Compte administrateur"
  _panel_create_admin

  progress_step "Nginx"
  _panel_configure_nginx

  progress_step "SSL Let's Encrypt"
  _panel_configure_ssl

  progress_step "Services queue & cron"
  _panel_setup_services

  state_set "panel" "installed"
  save_env "PANEL_DOMAIN" "${PANEL_DOMAIN}"

  echo
  print_separator
  echo -e "${C_GREEN}${C_BOLD}Panel Pterodactyl installé avec succès !${C_RESET}"
  echo -e "  URL      : ${PANEL_APP_URL:-http://${PANEL_DOMAIN}}"
  echo -e "  Admin    : ${PANEL_ADMIN_EMAIL}"
  echo -e "  User     : ${PANEL_ADMIN_USER}"
  echo -e "  DB       : ${PANEL_DB_NAME} / ${PANEL_DB_USER}"
  echo -e "  Mot de passe admin & DB : enregistrés dans ${MPS_ENV_FILE}"
  print_separator
}

_panel_collect_info() {
  load_env

  prompt_input "Nom de domaine du Panel (ex: panel.exemple.com)" "${PANEL_DOMAIN:-}" PANEL_DOMAIN
  prompt_input "Email administrateur" "${PANEL_ADMIN_EMAIL:-admin@${PANEL_DOMAIN}}" PANEL_ADMIN_EMAIL
  prompt_input "Nom d'utilisateur admin" "${PANEL_ADMIN_USER:-admin}" PANEL_ADMIN_USER
  prompt_secret "Mot de passe administrateur" PANEL_ADMIN_PASS
  prompt_input "Prénom" "${PANEL_ADMIN_FIRST:-Admin}" PANEL_ADMIN_FIRST
  prompt_input "Nom" "${PANEL_ADMIN_LAST:-Panel}" PANEL_ADMIN_LAST
  prompt_input "Timezone (ex: Europe/Paris)" "${PANEL_TIMEZONE:-Europe/Paris}" PANEL_TIMEZONE

  if confirm "Activer SSL Let's Encrypt ?" "y"; then
    PANEL_SSL="y"
  else
    PANEL_SSL="n"
  fi

  if [[ "${PANEL_SSL}" == "y" ]]; then
    PANEL_APP_URL="https://${PANEL_DOMAIN}"
  else
    PANEL_APP_URL="http://${PANEL_DOMAIN}"
  fi

  # DB credentials (auto-générés si absents)
  PANEL_DB_NAME="${PANEL_DB_NAME:-panel}"
  PANEL_DB_USER="${PANEL_DB_USER:-pterodactyl}"
  PANEL_DB_PASS="${PANEL_DB_PASS:-$(generate_password 32)}"

  export PANEL_DOMAIN PANEL_ADMIN_EMAIL PANEL_ADMIN_USER PANEL_ADMIN_PASS
  export PANEL_ADMIN_FIRST PANEL_ADMIN_LAST PANEL_TIMEZONE PANEL_SSL PANEL_APP_URL
  export PANEL_DB_NAME PANEL_DB_USER PANEL_DB_PASS
}
