#!/usr/bin/env bash
# =============================================================================
# Module phpMyAdmin — Installation optionnelle + Nginx + sécurisation
# =============================================================================

PMA_DIR="/usr/share/phpmyadmin"
PMA_WEB="/var/www/phpmyadmin"

install_phpmyadmin() {
  progress_init 6

  # Prérequis Panel / PHP / Nginx
  if [[ "$(state_get panel)" != "installed" ]] && ! command -v nginx &>/dev/null; then
    log_warn "Nginx/PHP non détectés. Installation des dépendances minimales..."
  fi

  load_env

  progress_step "Collecte informations"
  prompt_input "Sous-domaine ou chemin phpMyAdmin" "${PMA_DOMAIN:-pma.${PANEL_DOMAIN:-localhost}}" PMA_DOMAIN
  prompt_input "Utiliser un sous-chemin /phpmyadmin sur le panel ?" "n" PMA_PATH_MODE
  local blowfish
  blowfish="$(generate_password 32)"

  progress_step "Installation paquets"
  export DEBIAN_FRONTEND=noninteractive
  # Pré-répondre aux questions debconf
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | debconf-set-selections

  apt_install phpmyadmin php8.3-mbstring php8.3-zip php8.3-gd php8.3-curl php8.3-mysql

  progress_step "Déploiement fichiers"
  # Lien web
  if [[ -d "${PMA_DIR}" ]]; then
    mkdir -p "${PMA_WEB}"
    # Utiliser le package systeme
    ln -sfn "${PMA_DIR}" "${PMA_WEB}/public" 2>/dev/null || true
  fi

  # Config blowfish secret
  local pma_config="/etc/phpmyadmin/config.inc.php"
  if [[ -f /var/lib/phpmyadmin/blowfish_secret.inc.php ]]; then
    cat > /var/lib/phpmyadmin/blowfish_secret.inc.php << EOF
<?php
\$cfg['blowfish_secret'] = '${blowfish}';
EOF
    chmod 640 /var/lib/phpmyadmin/blowfish_secret.inc.php
    chown root:www-data /var/lib/phpmyadmin/blowfish_secret.inc.php
  fi

  progress_step "Sécurisation"
  _pma_harden

  progress_step "Configuration Nginx"
  _pma_nginx

  progress_step "Finalisation"
  systemctl reload nginx
  state_set "phpmyadmin" "installed"
  save_env "PMA_DOMAIN" "${PMA_DOMAIN}"
  save_env "PMA_BLOWFISH" "${blowfish}"

  echo
  print_separator
  echo -e "${C_GREEN}${C_BOLD}phpMyAdmin installé${C_RESET}"
  if [[ "${PMA_PATH_MODE}" =~ ^[Yy]$ ]]; then
    echo -e "  URL : https://${PANEL_DOMAIN}/phpmyadmin"
  else
    echo -e "  URL : http(s)://${PMA_DOMAIN}"
  fi
  echo -e "  Auth HTTP Basic : utilisateur défini ci-dessous"
  echo -e "  Auth MySQL : utilisez un compte MariaDB (ex: root via socket / user panel)"
  print_separator
}

_pma_harden() {
  # Désactiver fonctionnalités dangereuses via config
  local extra="/etc/phpmyadmin/conf.d/master-ptero.php"
  mkdir -p /etc/phpmyadmin/conf.d
  cat > "${extra}" << 'EOF'
<?php
// Master Ptero Script — durcissement phpMyAdmin
$cfg['AllowRoot'] = false;
$cfg['AllowArbitraryServer'] = false;
$cfg['LoginCookieValidity'] = 1800;
$cfg['MaxNavigationItems'] = 100;
$cfg['ShowPhpInfo'] = false;
$cfg['ShowServerInfo'] = false;
$cfg['VersionCheck'] = false;
$cfg['Servers'][1]['auth_type'] = 'cookie';
$cfg['Servers'][1]['AllowNoPassword'] = false;
EOF
  chmod 644 "${extra}"

  # Mot de passe HTTP Basic
  apt_install apache2-utils
  local htuser htpass
  prompt_input "Utilisateur HTTP Basic (accès phpMyAdmin)" "pmaadmin" htuser
  prompt_secret "Mot de passe HTTP Basic" htpass

  htpasswd -bBc /etc/phpmyadmin/.htpasswd "${htuser}" "${htpass}" >> "${MPS_LOG_FILE}" 2>&1
  chmod 640 /etc/phpmyadmin/.htpasswd
  chown root:www-data /etc/phpmyadmin/.htpasswd

  save_env "PMA_HTUSER" "${htuser}"
  log_ok "HTTP Basic + durcissement appliqués"
}

_pma_nginx() {
  local conf="/etc/nginx/sites-available/phpmyadmin.conf"

  if [[ "${PMA_PATH_MODE}" =~ ^[Yy]$ ]]; then
    # Snippet location à inclure dans le vhost panel
    local snippet="/etc/nginx/snippets/phpmyadmin.conf"
    cat > "${snippet}" << 'EOF'
location /phpmyadmin {
    alias /usr/share/phpmyadmin/;
    index index.php;

    auth_basic "phpMyAdmin Restricted";
    auth_basic_user_file /etc/phpmyadmin/.htpasswd;

    location ~ ^/phpmyadmin/(.+\.php)$ {
        alias /usr/share/phpmyadmin/$1;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $request_filename;
        include fastcgi_params;
        fastcgi_param HTTP_PROXY "";
    }

    location ~* ^/phpmyadmin/(.+\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
        alias /usr/share/phpmyadmin/$1;
    }
}

location ~ ^/phpmyadmin/(libraries|setup|templates|locale|vendor)/ {
    deny all;
}
EOF
    # Injecter include dans le vhost panel si absent
    local panel_conf="/etc/nginx/sites-available/pterodactyl.conf"
    if [[ -f "${panel_conf}" ]] && ! grep -q "snippets/phpmyadmin" "${panel_conf}"; then
      sed -i '/server_name/a\    include /etc/nginx/snippets/phpmyadmin.conf;' "${panel_conf}"
    fi
    log_ok "phpMyAdmin monté sur /phpmyadmin"
  else
    cat > "${conf}" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PMA_DOMAIN};

    root /usr/share/phpmyadmin;
    index index.php;

    access_log /var/log/nginx/phpmyadmin.access.log;
    error_log  /var/log/nginx/phpmyadmin.error.log;

    auth_basic "phpMyAdmin Restricted";
    auth_basic_user_file /etc/phpmyadmin/.htpasswd;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param HTTP_PROXY "";
    }

    location ~ /(libraries|setup|templates|locale|vendor)/ {
        deny all;
        return 404;
    }

    location ~ /\\.ht {
        deny all;
    }
}
EOF
    ln -sfn "${conf}" /etc/nginx/sites-enabled/phpmyadmin.conf
    nginx -t >> "${MPS_LOG_FILE}" 2>&1 || die "Nginx phpMyAdmin invalide"

    if [[ "${PANEL_SSL:-n}" == "y" ]] || confirm "Obtenir SSL Let's Encrypt pour ${PMA_DOMAIN} ?" "y"; then
      certbot --nginx -d "${PMA_DOMAIN}" --non-interactive --agree-tos \
        -m "${PANEL_ADMIN_EMAIL:-admin@${PMA_DOMAIN}}" --redirect \
        >> "${MPS_LOG_FILE}" 2>&1 \
        || log_warn "SSL phpMyAdmin échoué — DNS à vérifier"
    fi
    log_ok "Vhost phpMyAdmin : ${PMA_DOMAIN}"
  fi
}
