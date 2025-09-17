#!/usr/bin/env bash
# n8n 1-click installer (interactive, domain-only)
# Ubuntu 22.04/24.04 • Docker + PostgreSQL + Traefik(HTTPS) + systemd
set -euo pipefail

N8N_VERSION=${N8N_VERSION:-"latest"}
POSTGRES_VERSION=${POSTGRES_VERSION:-"16"}
N8N_DATA_DIR=${N8N_DATA_DIR:-"/var/lib/n8n"}

log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[~] $*\033[0m"; }
err()  { echo -e "\033[1;31m[!] $*\033[0m" >&2; }

require_root() { [[ $EUID -eq 0 ]] || { err "Запусти с sudo/от root"; exit 1; }; }

check_os() {
  . /etc/os-release || { err "Не могу определить ОС"; exit 1; }
  [[ "$ID" == "ubuntu" ]] || { err "Поддерживается только Ubuntu"; exit 1; }
  [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] || \
    warn "Рекомендованы Ubuntu 22.04/24.04 (обнаружено $VERSION_ID)"
}

ask_inputs() {
  read -rp "Домен для n8n (A-запись на IP сервера): " N8N_DOMAIN
  while [[ -z "${N8N_DOMAIN}" ]]; do read -rp "Пусто. Введи домен: " N8N_DOMAIN; done
  read -rp "Email для Let's Encrypt: " LETSENCRYPT_EMAIL
  while [[ -z "${LETSENCRYPT_EMAIL}" ]]; do read -rp "Пусто. Введи email: " LETSENCRYPT_EMAIL; done
}

install_needed_tools() {
  local need=()
  for b in curl dig openssl ss; do command -v "$b" >/dev/null || need+=("$b"); done
  if ((${#need[@]})); then
    log "Ставлю утилиты: ${need[*]}…"
    apt-get update -y
    apt-get install -y dnsutils openssl iproute2 curl
  fi
}

get_public_ip() {
  curl -fsS https://api.ipify.org || dig +short myip.opendns.com @resolver1.opendns.com || true
}

check_dns_points_here() {
  log "Проверяю DNS домена ${N8N_DOMAIN}…"
  local server_ip domain_ip
  server_ip=$(get_public_ip)
  [[ -n "$server_ip" ]] || { warn "Не получил публичный IP сервера — пропускаю строгую проверку"; return 0; }
  domain_ip=$(dig +short A "${N8N_DOMAIN}" | tail -n1)
  [[ -n "$domain_ip" ]] || { err "A-запись для ${N8N_DOMAIN} не найдена. Укажи её на IP: ${server_ip}"; exit 1; }
  if [[ "$domain_ip" != "$server_ip" ]]; then
    err "Сейчас ${N8N_DOMAIN} → ${domain_ip}, а сервер → ${server_ip}. Обнови A-запись и повтори."
    exit 1
  fi
  log "DNS ок: ${N8N_DOMAIN} → ${domain_ip}"
}

check_ports_free() {
  log "Проверяю порты 80/443…"
  if ss -tulpn 2>/dev/null | grep -E ':(80|443)\s' >/dev/null; then
    err "Порт(ы) 80/443 заняты (nginx/apache/другой прокси). Отключи их и запусти снова."
    exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    log "Docker уже установлен"; return
  fi
  log "Устанавливаю Docker + compose…"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

create_users_dirs() {
  log "Создаю пользователя и директории…"
  id -u n8n >/dev/null 2>&1 || useradd --system --home "${N8N_DATA_DIR}" --shell /usr/sbin/nologin n8n
  mkdir -p "${N8N_DATA_DIR}"/{data,postgres,traefik,dynamic}
  touch "${N8N_DATA_DIR}/traefik/acme.json"
  chmod 600 "${N8N_DATA_DIR}/traefik/acme.json"
  # Владелец для n8n-контейнера (UID 1000) — КЛЮЧЕВОЙ фикс
  chown -R 1000:1000 "${N8N_DATA_DIR}/data"
  # Остальное может принадлежать системному пользователю
  chown -R n8n:n8n "${N8N_DATA_DIR}/postgres" "${N8N_DATA_DIR}/traefik" "${N8N_DATA_DIR}/dynamic" || true
}

gen_secret() { openssl rand -base64 48 | tr -d '\n' | tr -d '=+/'; }

write_env() {
  log "Генерирую .env…"
  cat > "${N8N_DATA_DIR}/.env" <<EOF
N8N_BASIC_AUTH_ACTIVE=false
N8N_PORT=5678
N8N_ENCRYPTION_KEY=$(gen_secret)
N8N_HOST=${N8N_DOMAIN}
N8N_EDITOR_BASE_URL=https://${N8N_DOMAIN}
WEBHOOK_URL=https://${N8N_DOMAIN}
POSTGRES_USER=n8n
POSTGRES_PASSWORD=$(gen_secret)
POSTGRES_DB=n8n
# Рекомендуемые флаги
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
N8N_RUNNERS_ENABLED=true
EOF
  chown n8n:n8n "${N8N_DATA_DIR}/.env"
}

write_compose() {
  log "Пишу docker-compose.yml…"
  cat > "${N8N_DATA_DIR}/docker-compose.yml" <<YML
name: n8n
services:
  traefik:
    image: traefik:latest
    restart: unless-stopped
    command:
      - "--providers.docker=true"
      - "--providers.file.directory=/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.le.acme.email=${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.le.acme.httpchallenge=true"
      - "--certificatesresolvers.le.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik:/letsencrypt"
      - "./dynamic:/dynamic:ro"
    labels:
      - "traefik.enable=true"

  db:
    image: postgres:${POSTGRES_VERSION}
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - ./postgres:/var/lib/postgresql/data

  n8n:
    image: n8nio/n8n:${N8N_VERSION}
    restart: unless-stopped
    env_file: .env
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=db
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - N8N_DIAGNOSTICS_ENABLED=false
    volumes:
      - ./data:/home/node/.n8n
    depends_on:
      - db
    labels:
      - "traefik.enable=true"
      # HTTP -> HTTPS
      - "traefik.http.routers.n8n-web.rule=Host(\`${N8N_DOMAIN}\`)"
      - "traefik.http.routers.n8n-web.entrypoints=web"
      - "traefik.http.routers.n8n-web.middlewares=redirect@file"
      # HTTPS
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"
YML

  # middleware redirect@file (file provider)
  cat > "${N8N_DATA_DIR}/dynamic/redirect.toml" <<'TOML'
[http.middlewares.redirect.redirectScheme]
scheme = "https"
TOML
}

write_systemd() {
  log "Создаю systemd unit…"
  cat > /etc/systemd/system/n8n-compose.service <<EOF
[Unit]
Description=n8n via Docker Compose (Traefik + HTTPS)
Requires=docker.service
After=docker.service

[Service]
WorkingDirectory=${N8N_DATA_DIR}
Environment="COMPOSE_PROJECT_NAME=n8n"
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable n8n-compose.service
}

start_stack() {
  log "Запускаю стек…"
  (cd "${N8N_DATA_DIR}" && docker compose pull && docker compose up -d)
}

print_summary() {
  echo
  log "ГОТОВО ✅  Открой: https://${N8N_DOMAIN}"
  echo "Директория: ${N8N_DATA_DIR}"
  echo
  echo "Полезные команды:"
  echo "  sudo systemctl status n8n-compose"
  echo "  sudo systemctl restart n8n-compose"
  echo "  sudo docker compose -f ${N8N_DATA_DIR}/docker-compose.yml logs -f"
  echo
  echo "Если сертификат не выписался: проверь A-запись домена и доступность порта 80 извне."
}

main() {
  require_root
  check_os
  ask_inputs
  install_needed_tools
  check_dns_points_here
  check_ports_free
  install_docker
  create_users_dirs
  write_env
  write_compose
  start_stack
  write_systemd
  print_summary
}

main "$@"
