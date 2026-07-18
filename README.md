# Master Ptero Script

Installateur automatique **production-ready** pour une infrastructure [Pterodactyl](https://pterodactyl.io) complète sur VPS.

Compatible avec tous les jeux supportés par Pterodactyl (Minecraft, Rust, FiveM, ARK, CS2, Palworld, etc.) via Docker + Wings.

## Prérequis

| Élément | Détail |
|--------|--------|
| OS | **Ubuntu 22.04**, **Ubuntu 24.04** ou **Debian 12** |
| Accès | Root (`sudo -i`) |
| RAM | 2 Go min. (4 Go+ recommandé) |
| Disque | 20 Go+ recommandés |
| Réseau | Domaine pointant vers l'IP du VPS (pour SSL) |

## Architecture

```
MasterPtero/
├── install.sh              # Point d'entrée CLI
├── lib/
│   └── common.sh           # Couleurs, logs, checks, helpers
├── modules/
│   ├── panel.sh            # Nginx · PHP 8.3 · MariaDB · Redis · Panel
│   ├── wings.sh            # Wings + config node
│   ├── docker.sh           # Docker Engine CE
│   ├── firewall.sh         # UFW
│   ├── phpmyadmin.sh       # phpMyAdmin sécurisé
│   └── optimize.sh         # sysctl · fail2ban · NTP · logs
├── config/
│   ├── defaults.env        # Valeurs par défaut
│   ├── ports.conf          # Ports jeux / UFW
│   └── install.env         # Secrets (généré, chmod 600)
├── logs/                   # Journaux d'installation
└── README.md
```

## Installation rapide (one-liner)

Sur un VPS Ubuntu/Debian en root :

```bash
apt install -y curl && curl -O -sL https://raw.githubusercontent.com/HeatzyV2/MasterPtero/main/ptero-installer.sh && chmod +x ptero-installer.sh && ./ptero-installer.sh && rm -f ptero-installer.sh
```

Le bootstrap télécharge le projet dans `/opt/master-ptero` et lance le menu d’installation.

### Installation manuelle

```bash
git clone https://github.com/HeatzyV2/MasterPtero.git
cd MasterPtero
chmod +x install.sh ptero-installer.sh modules/*.sh
sudo ./install.sh
```

Ou en non-interactif partiel :

```bash
sudo ./install.sh full        # Panel + Wings + Firewall + Optimisations
sudo ./install.sh panel       # Panel seul
sudo ./install.sh wings       # Wings seul
sudo ./install.sh firewall
sudo ./install.sh optimize
sudo ./install.sh status
```

## Fonctionnalités

### 1. Panel Pterodactyl
- Nginx + PHP 8.3-FPM + extensions requises
- MariaDB (base + utilisateur dédiés)
- Redis (cache / sessions / queues)
- Composer + dernière release Panel (GitHub)
- `.env` automatique, migrations, compte admin
- SSL Let's Encrypt (Certbot)
- Worker queue `pteroq` + cron scheduler

### 2. Wings
- Docker Engine CE (daemon.json optimisé)
- Binaire Wings (amd64 / arm64)
- Template `config.yml` + application de la config Panel
- Service systemd
- SSL optionnel pour le daemon

### 3. phpMyAdmin (optionnel)
- Installation paquet + vhost Nginx ou `/phpmyadmin`
- HTTP Basic Auth + durcissement (`AllowRoot=false`, etc.)

### 4. Firewall UFW
- SSH (port détecté), HTTP, HTTPS, Wings, SFTP
- Ports jeux via `config/ports.conf`
- Ajout interactif de ports / plages

### 5. Optimisation VPS
- sysctl (BBR, buffers, syn cookies, inotify)
- `limits.conf` / systemd `LimitNOFILE`
- journald + logrotate
- fail2ban (sshd, nginx)
- Docker prune hebdomadaire
- Timezone + chrony (NTP)
- Swap 2 Go si RAM &lt; 4 Go

## Workflow recommandé

1. Pointer un enregistrement DNS **A** vers l'IP du VPS (`panel.exemple.com`)
2. `sudo ./install.sh` → option **1** (installation complète)
3. Se connecter au Panel → **Admin → Nodes → Create**
4. Copier la config YAML → menu option **8** (ou éditer `/etc/pterodactyl/config.yml`)
5. `systemctl status wings`
6. Créer les **allocations** de ports dans le Panel (alignées avec `ports.conf` / UFW)
7. Déployer un serveur de jeu (egg Minecraft, Rust, FiveM…)

## Sécurité

- Secrets dans `config/install.env` (mode `600`, ignoré par git)
- Mots de passe DB / admin générés ou saisis de façon sécurisée
- UFW deny incoming par défaut
- fail2ban activé
- phpMyAdmin derrière HTTP Basic + options durcies
- Ne jamais exposer `install.env` publiquement

## Dépannage

| Problème | Action |
|----------|--------|
| SSL échoue | Vérifier DNS, puis `certbot --nginx -d panel.exemple.com` |
| Wings down | `journalctl -u wings -n 50` — config YAML invalide ? |
| Panel 502 | `systemctl status php8.3-fpm nginx` |
| Logs install | `logs/install-*.log` |

```bash
sudo ./install.sh status
docker ps
systemctl status wings pteroq nginx mariadb redis-server
ufw status verbose
```

## Licence

Usage libre pour vos infrastructures. Pterodactyl est sous licence MIT — respectez leurs conditions.
