#!/usr/bin/env bash
# n8n domain-only 1-click installer (Ubuntu 22.04/24.04)
# Features: Docker + compose, PostgreSQL, Traefik + HTTPS (Let's Encrypt), systemd
# NOTE: Domain is REQUIRED. No "localhost" mode.
# Usage:
#   sudo N8N_DOMAIN=n8n.example.com LETSENCRYPT_EMAIL=you@mail.ru ./install-n8n.sh
#   or
#   sudo N8N_DOMAIN=n8n.example.com LETSENCRYPT_EMAIL=you@mail.ru \
#     bash <(curl -fsSL https://raw.githubusercontent.com/amovei/n8n-1click-install/main/install-n8n.sh)

set -euo pipefail

# ================== REQUIRED PARAMS ==================
N8N_DOMAIN=${N8N_DOMAIN:-""}               # MUST be provided
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-""} # MUST be provided
N8N_VERSION=${N8N_VERSION:-"latest"}
POSTGRES_VERSION=${POSTGRES_VERSION:-"16"}
N8N_DATA_DIR=${N8N_DATA_DIR:-"/var/lib/n8n"}
# ====================================================

log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[~] $*\033[0m"; }
err()  { echo -e "\033[1;31m[!] $*\033[0m" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then err "Запусти скрипт с sudo/от root"; exit 1; fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then err "Не могу определить ОС"; exit 1; fi
  . /etc/os-release
  if [[ "${ID}" != "ubuntu" ]]; then err "Поддерживается только Ubuntu"; exit 1; fi
  if [[ "${VERSION_ID}" != "22.04" && "${VERSION_ID}" != "24.04" ]]; then
    warn "Рекомендованы Ubuntu 22.04/24.04 (обнаружено ${VERSION_ID})"
  fi
}

require_params() {
  if [[ -z "${N8N_DOMAIN}" || -z "${LETSENCRYPT_EMAIL}" ]]; then
    err "Обязательные переменные: N8N_DOMAIN и LETSENCRYPT_EMAIL. Пример:
sudo N8N_DOMAIN=n8n.example.com LETSENCRYPT_EMAIL=you@mail.ru ./install-n8n.sh"
    exit 1
  fi
}

require_tools() {
  local miss=0
  for b in curl dig openssl; do
    command -v "$b" >/dev/null 2>&1 || { warn "Не найдено: $b"; miss=1; }
  done
  if [[ $miss -eq 1 ]]; then
    log "Ставлю недостающие утилиты..."
    apt-get update -y
    apt-get install -y curl dnsutils openssl
  fi
}

get_public_ip() {
  # Пытаемся получить публичный IPv4 сервера
  local ip
  ip=$(curl -fsS https://api.ipify.org || true)
  [[ -z "$ip" ]] && ip=$(dig +short myip.opendns.com @resolver1.opendns.com || true)
  echo "$ip"
}

check_dns_points_here() {
  log "Проверяю DNS домена ${N8N_DOMAIN}…"
  local server_ip domain_ip
  server_ip=$(get_public_ip)
  if [[ -z "$server_ip" ]]; then warn "Не удалось получить публичный IP сервера — пропускаю строгую проверку DNS"; return 0; fi

  domain_ip=$(dig +short A "${N8N_DOMAIN}" | tail -n1)
  if [[ -z "$domain_ip" ]]; then
    err "A-запись для ${N8N_DOMAIN} не найдена. Настрой A-запись домена на IP сервера: ${server_ip}"; exit 1
  fi

  if [[ "$domain_ip" != "$server_ip" ]]; then
    err "A-запись ${N8N_DOMAIN} → ${domain_ip}, но IP сервера: ${server_ip}.
Обнови DNS (A-запись) и повтори запуск после применения."
    exit 1
  fi
  log "DNS ок: ${N8N_DOMAIN} → ${domain_ip}"
}

check_ports_free() {
  log "Проверяю, свободны ли порты 80/443…"
  if ss -tulpn 2>/dev/null | grep -E ':(80|443)\s' >/dev/null; then
    err "Порт(ы) 80/443 заняты. Отключи сервисы (nginx/apache/другой прокси) и попробуй снова."
    exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker уже установлен"
    return
  fi
  log "Устанавливаю Docker + compose…"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
> /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

create_user_dirs() {
  log "Готовлю пользователя и директории…"
  id -u n8n >/dev/null 2>&1 || useradd --system --home "${N8N_DATA_DIR}" --shell /usr/sbin/nologin n8n
  mkdir -p "${N8N_DATA_DIR}"/{data,postgres,traefik}
  touch "${N8N_DATA_DIR}/traefik/acme.json"
  chmod 600 "${N8N_DATA_DIR}/traefik/acme.json"
  chown -R n8n:n8n "${N8N_DATA_DIR}"
}

gen_secret() { openssl rand -base64 48 | tr -d '\n' | tr -d '=+/'; }

write_env() {
  log "Генерирую .env…"
  local ENC_KEY DB_PASS
  ENC_KEY=$(gen_secret)
  DB_PASS=$(gen_secret)

  cat > "${N8N_DATA_DIR}/.env" <<EOF
# === n8n ===
N8N_BASIC_AUTH_ACTIVE=false
N8N_PORT=5678
N8N_ENCRYPTION_KEY=${ENC_KEY}
N8N_HOST=${N8N_DOMAIN}
N8N_EDITOR_BASE_URL=https://${N8N_DOMAIN}
WEBHOOK_URL=https://${N8N_DOMAIN}

# === DB ===
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=n8n
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
    labels:
      - "traefik.enable=true"
      - "traefik.http.middlewares.redirecthttps.redirectscheme.scheme=https"

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
      - "traefik.http.routers.n8n-web.middlewares=redirecthttps@docker"
      # HTTPS
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"
YML
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
  log "ГОТОВО ✅"
  echo "Открой: https://${N8N_DOMAIN}  (сертификат появится после первого запроса)"
  echo "Директория: ${N8N_DATA_DIR}"
  echo
  echo "Команды:"
  echo "  sudo systemctl status n8n-compose"
  echo "  sudo systemctl restart n8n-compose"
  echo "  sudo docker compose -f ${N8N_DATA_DIR}/docker-compose.yml logs -f"
  echo
  echo "Если сертификат не выписался: проверь, что A-запись домена указывает на этот сервер и порт 80 открыт извне."
}

main() {
  require_root
  check_os
  require_params
  require_tools
  check_dns_points_here
  check_ports_free
  install_docker
  create_user_dirs
  write_env
  write_compose
  chown -R n8n:n8n "${N8N_DATA_DIR}"
  write_systemd
  start_stack
  print_summary
}

main "$@"
