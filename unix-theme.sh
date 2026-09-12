#!/usr/bin/env bash
# =============================================================================
# MasterPtero — Unix Theme (v2.71)
# One-liner : installe Unix après backup, retire les autres thèmes, restore
# si l'install plante.
#
#   curl -fsSL -o /tmp/unix-theme.sh https://raw.githubusercontent.com/HeatzyV2/MasterPtero/main/unix-theme.sh && bash /tmp/unix-theme.sh -y
#   bash /tmp/unix-theme.sh restore -y
# =============================================================================
set -euo pipefail

REPO_OWNER="HeatzyV2"
REPO_NAME="MasterPtero"
RELEASE_TAG="unix-v2.71"
ZIP_NAME="UnixTheme-v2.71.zip"
THEME_URL_DEFAULT="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}/${ZIP_NAME}"

BACKUP_DIR="/var/backups/pterodactyl-themes"
BACKUP_KEEP=5
WORKDIR=""
BACKUP_FILE=""
PTERO=""
WEB_USER="www-data"
DOING_RESTORE=0
FAIL_HANDLED=0
ASSUME_YES=0
CMD="install"
ZIP_PATH=""
THEME_URL="${THEME_URL:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[x]${NC} $*"; exit 1; }

banner() {
  echo -e "${BOLD}${CYAN}"
  cat << 'EOF'
╔════════════════════════════════════════════════════╗
║     MasterPtero · Unix Theme v2.71 installer       ║
╚════════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"
}

usage() {
  cat << EOF
Usage: sudo bash unix-theme.sh [install|restore] [-y] [--zip FICHIER] [--url URL]

  install   Backup → retire les thèmes → installe Unix (défaut)
  restore   Restaure le dernier backup du panel

Options :
  -y, --yes          Sans confirmation
  --zip CHEMIN       Zip Unix déjà présent sur le serveur
  --url URL          Télécharger le zip depuis cette URL
  --skip-build       Ne pas lancer yarn build:production
  -h, --help         Aide

Variables :
  THEME_URL          URL du zip (prioritaire si --url absent)
  SKIP_BUILD=1       Identique à --skip-build

Le zip n'est pas dans le dépôt (licence Unix). Place-le sur le VPS
(/root/${ZIP_NAME}) ou passe THEME_URL / --url / --zip.
EOF
}

parse_args() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|restore) CMD="$1"; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      --zip)
        [[ $# -ge 2 ]] || fail "--zip nécessite un chemin"
        ZIP_PATH="$2"; shift 2 ;;
      --url)
        [[ $# -ge 2 ]] || fail "--url nécessite une URL"
        THEME_URL="$2"; shift 2 ;;
      --skip-build) SKIP_BUILD=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ ${#args[@]} -gt 0 ]]; then
    fail "Argument inconnu : ${args[0]}"
  fi
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Exécute en root : sudo bash unix-theme.sh"
}

confirm_or_yes() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return 0
  fi
  local reply
  read -r -p "$(echo -e "${YELLOW}${prompt} [y/N] : ${NC}")" reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

find_panel() {
  local d
  for d in /var/www/pterodactyl /var/www/panel /var/www/ptero; do
    if [[ -f "${d}/artisan" && -f "${d}/.env" ]]; then
      PTERO="${d}"
      return 0
    fi
  done
  fail "Panel Pterodactyl introuvable (/var/www/pterodactyl). Installe le panel d'abord."
}

detect_web_user() {
  if id www-data &>/dev/null; then
    WEB_USER="www-data"
  elif id nginx &>/dev/null; then
    WEB_USER="nginx"
  elif id apache &>/dev/null; then
    WEB_USER="apache"
  else
    WEB_USER="www-data"
  fi
}

ensure_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  local need=()
  command -v curl >/dev/null || need+=(curl ca-certificates)
  command -v unzip >/dev/null || need+=(unzip)
  command -v tar >/dev/null || need+=(tar)
  command -v rsync >/dev/null || need+=(rsync)
  if [[ ${#need[@]} -eq 0 ]]; then
    return 0
  fi
  info "Installation paquets : ${need[*]}"
  if command -v apt-get >/dev/null; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${need[@]}" >/dev/null
  elif command -v dnf >/dev/null; then
    dnf install -y "${need[@]}"
  else
    fail "Installe manuellement : ${need[*]}"
  fi
}

panel_version() {
  local ver=""
  if [[ -f "${PTERO}/config/app.php" ]]; then
    ver="$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+" "${PTERO}/config/app.php" | head -1 || true)"
  fi
  if [[ -z "${ver}" && -f "${PTERO}/composer.json" ]]; then
    ver="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "${PTERO}/composer.json" | grep -oE "[0-9.]+" | head -1 || true)"
  fi
  echo "${ver}"
}

# Webpack du panel (loader-utils MD4) casse sur OpenSSL 3 / Node 17+.
setup_node_env() {
  local opts="${NODE_OPTIONS:-}"
  [[ "${opts}" == *openssl-legacy-provider* ]] || opts="${opts} --openssl-legacy-provider"
  [[ "${opts}" == *max-old-space-size* ]] || opts="${opts} --max-old-space-size=2048"
  export NODE_OPTIONS="${opts# }"
}

ensure_node_yarn() {
  setup_node_env
  if command -v yarn >/dev/null && command -v node >/dev/null; then
    ok "Node $(node -v) · Yarn $(yarn --version 2>/dev/null || echo '?')"
    return 0
  fi
  info "Installation Node.js 20 + Yarn (build du panel)..."
  if command -v apt-get >/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1 || \
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs >/dev/null
  elif command -v dnf >/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    dnf install -y nodejs
  fi
  command -v node >/dev/null || fail "Node.js introuvable après installation"
  npm i -g yarn >/dev/null 2>&1 || npm i -g yarn
  command -v yarn >/dev/null || fail "Yarn introuvable après installation"
  setup_node_env
}

# Si Blueprint a été à moitié désinstallé, artisan casse. Stub minimal pour
# pouvoir relancer php artisan, puis on retire proprement les providers.
stub_blueprint_if_broken() {
  local need=0
  if [[ -f "${PTERO}/app/Providers/Blueprint/ExtensionfsConfigProvider.php" ]]; then
    if [[ ! -f "${PTERO}/.blueprint/extensions/blueprint/private/extensionfs.php" ]]; then
      need=1
    fi
  fi
  [[ "${need}" -eq 1 ]] || return 0
  warn "Blueprint cassé détecté — stub temporaire extensionfs.php"
  mkdir -p "${PTERO}/.blueprint/extensions/blueprint/private"
  printf '%s\n' '<?php' 'return [];' \
    > "${PTERO}/.blueprint/extensions/blueprint/private/extensionfs.php"
}

artisan() {
  stub_blueprint_if_broken
  (cd "${PTERO}" && php artisan "$@")
}

panel_down() {
  artisan down --retry=60 >/dev/null 2>&1 || artisan down || true
}

panel_up() {
  artisan up >/dev/null 2>&1 || artisan up || true
}

fix_perms() {
  chown -R "${WEB_USER}:${WEB_USER}" "${PTERO}"
  chmod -R u+rwX,g+rX,o-rwx "${PTERO}/storage" "${PTERO}/bootstrap/cache" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Backup / restore
# -----------------------------------------------------------------------------
create_backup() {
  mkdir -p "${BACKUP_DIR}"
  local stamp ts
  ts="$(date +%Y%m%d-%H%M%S)"
  BACKUP_FILE="${BACKUP_DIR}/panel-${ts}.tar.gz"
  info "Backup du panel → ${BACKUP_FILE}"
  tar -czf "${BACKUP_FILE}" \
    --exclude='node_modules' \
    --exclude='vendor' \
    --exclude='storage/logs' \
    --exclude='storage/framework/cache/data' \
    --exclude='storage/framework/views' \
    --exclude='.git' \
    -C "$(dirname "${PTERO}")" "$(basename "${PTERO}")"
  ln -sfn "${BACKUP_FILE}" "${BACKUP_DIR}/LATEST.tar.gz"
  echo "${BACKUP_FILE}" > "${BACKUP_DIR}/LATEST"
  ok "Backup OK ($(du -h "${BACKUP_FILE}" | awk '{print $1}'))"

  local extras=()
  shopt -s nullglob
  extras=("${BACKUP_DIR}"/panel-*.tar.gz)
  shopt -u nullglob
  if [[ ${#extras[@]} -gt ${BACKUP_KEEP} ]]; then
    local sorted=()
    mapfile -t sorted < <(ls -1t "${extras[@]}")
    rm -f "${sorted[@]:${BACKUP_KEEP}}"
  fi
}

latest_backup() {
  if [[ -L "${BACKUP_DIR}/LATEST.tar.gz" && -f "${BACKUP_DIR}/LATEST.tar.gz" ]]; then
    readlink -f "${BACKUP_DIR}/LATEST.tar.gz"
    return 0
  fi
  if [[ -f "${BACKUP_DIR}/LATEST" ]]; then
    local p
    p="$(cat "${BACKUP_DIR}/LATEST")"
    [[ -f "${p}" ]] && echo "${p}" && return 0
  fi
  ls -1t "${BACKUP_DIR}"/panel-*.tar.gz 2>/dev/null | head -1 || true
}

restore_from() {
  local archive="$1"
  [[ -f "${archive}" ]] || fail "Backup introuvable : ${archive}"
  DOING_RESTORE=1
  info "Restore depuis ${archive} (tar d'abord — artisan peut être cassé)"
  tar -xzf "${archive}" -C "$(dirname "${PTERO}")"
  # Backup peut avoir été pris avec .blueprint déjà manquant
  stub_blueprint_if_broken
  rm -f "${PTERO}/bootstrap/cache/packages.php" \
        "${PTERO}/bootstrap/cache/services.php" \
        "${PTERO}/bootstrap/cache/config.php" 2>/dev/null || true
  (cd "${PTERO}" && composer dump-autoload -o >/dev/null 2>&1 || true)
  if [[ "${SKIP_BUILD}" != "1" ]] && [[ -f "${PTERO}/package.json" ]]; then
    info "Rebuild des assets après restore..."
    ensure_node_yarn
    (cd "${PTERO}" && yarn >/dev/null && yarn build:production) || warn "Rebuild yarn a échoué — fichiers PHP/views quand même restaurés"
  fi
  artisan view:clear >/dev/null 2>&1 || true
  artisan config:clear >/dev/null 2>&1 || true
  artisan cache:clear >/dev/null 2>&1 || true
  artisan queue:restart >/dev/null 2>&1 || true
  fix_perms
  panel_up
  ok "Panel restauré."
}

on_fail() {
  local code="$1"
  [[ "${code}" -eq 0 ]] && return 0
  [[ "${FAIL_HANDLED}" -eq 1 ]] && return 0
  FAIL_HANDLED=1
  panel_up
  if [[ "${DOING_RESTORE}" -eq 1 ]]; then
    echo -e "${RED}[x] Restore elle-même a échoué (code ${code}).${NC}"
    return 0
  fi
  if [[ -n "${BACKUP_FILE}" && -f "${BACKUP_FILE}" ]]; then
    echo
    echo -e "${RED}${BOLD}Installation plantée — restore automatique du backup...${NC}"
    restore_from "${BACKUP_FILE}" || true
    echo -e "${YELLOW}Le panel est revenu à l'état d'avant Unix.${NC}"
    echo -e "${DIM}Backup : ${BACKUP_FILE}${NC}"
  else
    echo -e "${RED}[x] Échec sans backup à restaurer.${NC}"
  fi
  [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
}

# -----------------------------------------------------------------------------
# Zip Unix (licence : pas dans le git public)
# -----------------------------------------------------------------------------
find_zip() {
  local candidates=()
  [[ -n "${ZIP_PATH}" ]] && candidates+=("${ZIP_PATH}")
  candidates+=(
    "/root/${ZIP_NAME}"
    "/root/Unix Theme v2.71.zip"
    "/opt/master-ptero/assets/${ZIP_NAME}"
    "$(pwd)/${ZIP_NAME}"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "${c}" ]]; then
      ZIP_PATH="${c}"
      ok "Zip local : ${ZIP_PATH}"
      return 0
    fi
  done
  return 1
}

download_zip() {
  local dest="$1"
  local urls=()
  [[ -n "${THEME_URL}" ]] && urls+=("${THEME_URL}")
  urls+=("${THEME_URL_DEFAULT}")

  local u
  for u in "${urls[@]}"; do
    info "Téléchargement ${u}"
    if curl -fL --retry 3 --retry-delay 2 -o "${dest}" "${u}"; then
      if [[ -s "${dest}" ]] && unzip -t "${dest}" >/dev/null 2>&1; then
        ok "Zip téléchargé"
        ZIP_PATH="${dest}"
        return 0
      fi
      warn "Fichier téléchargé invalide (pas un zip Unix)"
      rm -f "${dest}"
    else
      warn "Téléchargement impossible : ${u}"
      rm -f "${dest}"
    fi
  done
  return 1
}

resolve_zip() {
  if find_zip; then
    return 0
  fi
  local dest="${WORKDIR}/${ZIP_NAME}"
  if download_zip "${dest}"; then
    return 0
  fi
  cat << EOF

${RED}Zip UnixTheme-v2.71 introuvable.${NC}

La licence Unix interdit de republier le thème dans le dépôt public.
Envoie ton zip sur le VPS puis relance :

  scp UnixTheme-v2.71.zip root@TON_VPS:/root/${ZIP_NAME}
  curl -fsSL -o /tmp/unix-theme.sh https://raw.githubusercontent.com/HeatzyV2/MasterPtero/main/unix-theme.sh && bash /tmp/unix-theme.sh -y

Ou passe une URL que tu contrôles :

  THEME_URL='https://exemple.com/${ZIP_NAME}' bash /tmp/unix-theme.sh -y

EOF
  fail "Zip Unix manquant"
}

extract_theme_src() {
  local zip="$1"
  local out="${WORKDIR}/theme"
  mkdir -p "${out}"
  unzip -q "${zip}" -d "${out}"
  local src
  src="$(find "${out}" -type d -name pterodactyl | head -1 || true)"
  if [[ -z "${src}" || ! -d "${src}/app" || ! -d "${src}/resources" ]]; then
    fail "Zip Unix invalide (dossier pterodactyl/app introuvable)"
  fi
  echo "${src}"
}

# -----------------------------------------------------------------------------
# Retirer les thèmes existants
# -----------------------------------------------------------------------------
# Blueprint : stub si cassé → retire providers → vide les caches → rm .blueprint
disable_blueprint() {
  stub_blueprint_if_broken
  if [[ ! -d "${PTERO}/app/Providers/Blueprint" && ! -d "${PTERO}/.blueprint" ]]; then
    # Providers peuvent encore être listés dans le cache Laravel
    if ! grep -Rqs 'Blueprint\\\\' "${PTERO}/bootstrap/cache" "${PTERO}/config/app.php" 2>/dev/null; then
      return 0
    fi
  fi
  info "Retrait de Blueprint (providers d'abord, sinon artisan casse)..."
  rm -rf "${PTERO}/app/Providers/Blueprint"
  find "${PTERO}/app/Providers" -maxdepth 1 -iname '*blueprint*' -exec rm -rf {} + 2>/dev/null || true
  rm -f "${PTERO}/.blueprintrc" /usr/local/bin/blueprint 2>/dev/null || true
  if [[ -f "${PTERO}/config/app.php" ]]; then
    sed -i '/Blueprint/d' "${PTERO}/config/app.php" || true
  fi
  if [[ -f "${PTERO}/bootstrap/providers.php" ]]; then
    sed -i '/Blueprint/d' "${PTERO}/bootstrap/providers.php" || true
  fi
  if [[ -f "${PTERO}/composer.json" ]]; then
    # Retire les providers Blueprint du package discovery Laravel
    php -r '
      $f = $argv[1];
      $j = json_decode(file_get_contents($f), true);
      if (!is_array($j)) exit(0);
      $changed = false;
      foreach (["providers","aliases"] as $k) {
        if (!isset($j["extra"]["laravel"][$k]) || !is_array($j["extra"]["laravel"][$k])) continue;
        $n = array_values(array_filter($j["extra"]["laravel"][$k], function ($v) {
          return stripos((string)$v, "Blueprint") === false;
        }));
        if ($n !== $j["extra"]["laravel"][$k]) { $j["extra"]["laravel"][$k] = $n; $changed = true; }
      }
      if ($changed) file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n");
    ' "${PTERO}/composer.json" || true
  fi
  rm -f "${PTERO}/bootstrap/cache/packages.php" \
        "${PTERO}/bootstrap/cache/services.php" \
        "${PTERO}/bootstrap/cache/config.php" 2>/dev/null || true
  rm -rf "${PTERO}/.blueprint" "${PTERO}/public/assets/blueprint"
  # Confirme que plus aucun provider Blueprint ne peut charger
  if [[ -e "${PTERO}/app/Providers/Blueprint" ]]; then
    fail "Impossible de supprimer app/Providers/Blueprint"
  fi
  ok "Blueprint retiré"
}

run_theme_uninstallers() {
  info "Désinstallation des thèmes connus (artisan / leftovers)..."
  # Toujours Blueprint en premier — sinon artisan est mort
  disable_blueprint

  (
    cd "${PTERO}"
    php artisan unix restore --no-interaction >/dev/null 2>&1 || true
    php artisan unix remove --no-interaction >/dev/null 2>&1 || true
    php artisan unix:restore --no-interaction >/dev/null 2>&1 || true
    php artisan unix:uninstall --no-interaction >/dev/null 2>&1 || true
    php artisan nerm:restore --no-interaction >/dev/null 2>&1 || true
    php artisan nebula:restore --no-interaction >/dev/null 2>&1 || true
  ) || true

  # Au cas où un artisan theme aurait remis des trucs Blueprint
  disable_blueprint

  rm -rf \
    "${PTERO}/app/Http/Controllers/Admin/Unix" \
    "${PTERO}/app/Http/Controllers/Admin/Nerm" \
    "${PTERO}/app/Http/Controllers/Admin/Nebula" \
    "${PTERO}/resources/views/admin/unix" \
    "${PTERO}/resources/views/partials/unix" \
    "${PTERO}/resources/views/admin/nerm" \
    2>/dev/null || true

  if [[ -d "${PTERO}/public/themes" ]]; then
    find "${PTERO}/public/themes" -mindepth 1 -maxdepth 1 ! -name 'pterodactyl' -exec rm -rf {} + 2>/dev/null || true
  fi
}

overlay_stock_frontend() {
  local ver tarball tmp
  ver="$(panel_version)"
  tmp="${WORKDIR}/stock"
  mkdir -p "${tmp}"
  if [[ -n "${ver}" ]]; then
    tarball="https://github.com/pterodactyl/panel/releases/download/v${ver}/panel.tar.gz"
    info "Remise du frontend officiel Pterodactyl v${ver} (retire les thèmes)..."
    if curl -fL --retry 3 -o "${tmp}/panel.tar.gz" "${tarball}"; then
      tar -xzf "${tmp}/panel.tar.gz" -C "${tmp}"
      local stock="${tmp}"
      [[ -d "${tmp}/resources" ]] || stock="$(find "${tmp}" -maxdepth 2 -type d -name resources -printf '%h\n' | head -1)"
      if [[ -d "${stock}/resources/scripts" ]]; then
        rsync -a --delete "${stock}/resources/scripts/" "${PTERO}/resources/scripts/"
      fi
      if [[ -d "${stock}/resources/views" ]]; then
        rsync -a "${stock}/resources/views/" "${PTERO}/resources/views/"
      fi
      if [[ -d "${stock}/public/themes/pterodactyl" ]]; then
        mkdir -p "${PTERO}/public/themes"
        rsync -a --delete "${stock}/public/themes/pterodactyl/" "${PTERO}/public/themes/pterodactyl/"
      fi
      if [[ -d "${stock}/app/Providers" ]]; then
        rsync -a --delete "${stock}/app/Providers/" "${PTERO}/app/Providers/"
      fi
      ok "Frontend stock appliqué"
      return 0
    fi
    warn "Tarball officiel v${ver} indisponible — on continue avec nettoyage local uniquement"
  else
    warn "Version panel inconnue — skip overlay stock GitHub"
  fi
}

# -----------------------------------------------------------------------------
# Install Unix
# -----------------------------------------------------------------------------
inject_unix_routes() {
  local f="${PTERO}/app/Providers/RouteServiceProvider.php"
  [[ -f "${f}" ]] || fail "RouteServiceProvider.php manquant"
  if grep -q "routes/unix.php" "${f}"; then
    ok "Routes Unix déjà enregistrées"
    return 0
  fi
  info "Injection des routes Unix (sans écraser RouteServiceProvider du panel)"
  UNIX_RSP="${f}" php <<'PHP'
<?php
$f = getenv('UNIX_RSP');
$c = file_get_contents($f);
if ($c === false) { fwrite(STDERR, "Lecture RouteServiceProvider impossible\n"); exit(1); }
if (strpos($c, 'unix.php') !== false) { exit(0); }
$snippet = <<<'SNIP'

            Route::middleware(['web', 'auth', 'admin', 'csrf'])->prefix('/admin')
                ->namespace("$this->namespace\\Admin")
                ->group(base_path('routes/unix.php'));
SNIP;
$needles = [
    "base_path('routes/admin.php'));",
    'base_path("routes/admin.php"));',
];
$pos = false;
$needle = '';
foreach ($needles as $n) {
    $p = strrpos($c, $n);
    if ($p !== false) { $pos = $p; $needle = $n; break; }
}
if ($pos === false) {
    fwrite(STDERR, "Impossible d'injecter routes/unix.php dans RouteServiceProvider\n");
    exit(1);
}
$pos += strlen($needle);
$c = substr($c, 0, $pos) . $snippet . substr($c, $pos);
if (file_put_contents($f, $c) === false) { exit(1); }
PHP
  grep -q "routes/unix.php" "${f}" || fail "Injection des routes Unix échouée"
  ok "Routes Unix injectées"
}

apply_unix_files() {
  local src="$1"
  info "Copie des fichiers Unix Theme v2.71..."
  mkdir -p "${PTERO}/public/themes"

  # Ne pas écraser RouteServiceProvider (panel récent incompatible avec celui de Unix 2.71)
  rsync -a \
    --exclude 'app/Providers/RouteServiceProvider.php' \
    "${src}/" "${PTERO}/"

  inject_unix_routes
  ok "Fichiers Unix copiés"
}

run_unix_migrate() {
  local mig="database/migrations/2021_05_30_141248_create_unix_settings_table.php"
  if [[ -f "${PTERO}/${mig}" ]]; then
    info "Migration table unix_settings..."
    artisan migrate --force --path="${mig}"
  else
    warn "Migration Unix introuvable — skip"
  fi
}

build_assets() {
  if [[ "${SKIP_BUILD}" == "1" ]]; then
    warn "SKIP_BUILD=1 — yarn build ignoré"
    return 0
  fi
  [[ -f "${PTERO}/package.json" ]] || fail "package.json absent — frontend source manquant"
  ensure_node_yarn
  info "yarn install (peut prendre quelques minutes)..."
  (cd "${PTERO}" && yarn)
  info "yarn build:production (souvent 3–10 min)..."
  setup_node_env
  info "NODE_OPTIONS=${NODE_OPTIONS}"
  (cd "${PTERO}" && yarn build:production)
  ok "Assets compilés"
}

clear_caches() {
  artisan view:clear >/dev/null 2>&1 || true
  artisan config:clear >/dev/null 2>&1 || true
  artisan cache:clear >/dev/null 2>&1 || true
  artisan route:clear >/dev/null 2>&1 || true
  artisan queue:restart >/dev/null 2>&1 || true
}

cmd_install() {
  if ! confirm_or_yes "Backup + retrait des thèmes + install Unix v2.71 ?"; then
    info "Annulé."
    exit 0
  fi

  WORKDIR="$(mktemp -d /tmp/unix-theme.XXXXXX)"
  resolve_zip
  local src
  src="$(extract_theme_src "${ZIP_PATH}")"

  panel_down
  create_backup
  run_theme_uninstallers
  overlay_stock_frontend
  apply_unix_files "${src}"

  # Re-purge Blueprint au cas où l'overlay / rsync aurait laissé des restes
  disable_blueprint

  if [[ -x "${PTERO}/vendor/bin/composer" ]] || command -v composer >/dev/null; then
    info "composer dump-autoload..."
    (cd "${PTERO}" && composer dump-autoload -o) || warn "dump-autoload a échoué (on continue)"
  fi
  rm -f "${PTERO}/bootstrap/cache/packages.php" \
        "${PTERO}/bootstrap/cache/services.php" \
        "${PTERO}/bootstrap/cache/config.php" 2>/dev/null || true

  run_unix_migrate
  build_assets
  clear_caches
  fix_perms
  panel_up
  rm -rf "${WORKDIR}"

  echo
  print_done_install
}

print_done_install() {
  ok "Unix Theme v2.71 installé"
  echo
  echo -e "  Panel     : ${PTERO}"
  echo -e "  Backup    : ${BACKUP_FILE}"
  echo -e "  Admin     : ${BOLD}/admin/unix${NC}  (réglages Unix)"
  echo
  echo -e "${YELLOW}Restore si ça plante plus tard :${NC}"
  echo -e "  curl -fsSL -o /tmp/unix-theme.sh https://raw.githubusercontent.com/HeatzyV2/MasterPtero/main/unix-theme.sh && bash /tmp/unix-theme.sh restore -y"
  echo
  echo -e "${DIM}Unix v2.71 cible Pterodactyl ~1.6.x. Sur un panel récent, vide le cache navigateur.${NC}"
  echo -e "${DIM}Si la page blanche : relance le restore ci-dessus.${NC}"
}

cmd_restore() {
  local archive
  archive="$(latest_backup)"
  [[ -n "${archive}" && -f "${archive}" ]] || fail "Aucun backup dans ${BACKUP_DIR}"
  if ! confirm_or_yes "Restaurer ${archive} ?"; then
    info "Annulé."
    exit 0
  fi
  restore_from "${archive}"
}

main() {
  parse_args "$@"
  banner
  require_root
  find_panel
  detect_web_user
  ensure_pkgs

  info "Panel : ${PTERO}  ·  user : ${WEB_USER}  ·  version : $(panel_version || echo '?')"
  stub_blueprint_if_broken
  trap 'on_fail $?' EXIT

  case "${CMD}" in
    install) cmd_install ;;
    restore) cmd_restore ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
