#!/usr/bin/env bash
set -Eeuo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# Красивые сообщения
# ────────────────────────────────────────────────────────────────────────────────
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; GRAY="\033[90m"; RESET="\033[0m"
info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
err()     { echo -e "${RED}[x]${RESET} $*"; }
note()    { echo -e "${GRAY}—${RESET} $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Не найдено: $1"; exit 1; }
}

# ────────────────────────────────────────────────────────────────────────────────
# Проверка ОС
# ────────────────────────────────────────────────────────────────────────────────
if ! grep -qi 'ubuntu' /etc/os-release; then
  warn "Скрипт тестировался на Ubuntu 22.04/24.04. Продолжаем на свой риск."
fi

if [[ $EUID -ne 0 ]]; then
  err "Запусти от root: sudo -i"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────────────
# Ввод данных
# ────────────────────────────────────────────────────────────────────────────────
read -rp "Домен для n8n (А-запись на этот сервер): " DOMAIN
read -rp "Email для Let's Encrypt: " LETSENCRYPT_EMAIL

if [[ -z "${DOMAIN}" || -z "${LETSENCRYPT_EMAIL}" ]]; then
  err "Домен и email обязательны."
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────────────
# Проверка DNS → IP сервера
# ────────────────────────────────────────────────────────────────────────────────
note "Проверяю DNS домена ${DOMAIN}…"
SERVER_IP="$(curl -4s https://api.ipify.org || curl -4s https://ifconfig.me || true)"

resolve_a() {
  # стараемся обойти нестандартную резолвинг-среду
  if command -v dig >/dev/null 2>&1; then
    dig +short A "${DOMAIN}" @1.1.1.1 | head -n1
  else
    getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | head -n1
  fi
}

DOMAIN_IP="$(resolve_a)"

if [[ -z "${DOMAIN_IP}" ]]; then
  warn "Не удалось получить A-запись домена. Продолжаю без строгой проверки."
else
  info "DNS ок: ${DOMAIN} → ${DOMAIN_IP}"
  if [[ -n "${SERVER_IP}" && "${DOMAIN_IP}" != "${SERVER_IP}" ]]; then
    warn "A-запись домена (${DOMAIN_IP}) не совпадает с публичным IP сервера (${SERVER_IP})."
    read -rp "Продолжить? [y/N]: " CONT
    [[ "${CONT:-n}" =~ ^[Yy]$ ]] || exit 1
  fi
fi

# ────────────────────────────────────────────────────────────────────────────────
# Освобождение портов 80/443 (умная очистка)
# ────────────────────────────────────────────────────────────────────────────────
ensure_ports_free() {
  local ports=("80" "443")
  local p
  for p in "${ports[@]}"; do
    if ss -ltn "( sport = :$p )" | tail -n +2 | grep -q .; then
      warn "Порт ${p} занят — попробую освободить."
      # 1) Популярные веб-сервера
      local svc
      for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "${svc}"; then
          note "Останавливаю ${svc}…"
          systemctl stop "${svc}" || true
          systemctl disable "${svc}" >/dev/null 2>&1 || true
          systemctl mask "${svc}" >/dev/null 2>&1 || true
        fi
      done
      # 2) Контейнеры Docker, слушающие порт
      if command -v docker >/dev/null 2>&1; then
        local ids
        ids="$(docker ps --format '{{.ID}} {{.Ports}}' \
            | awk -vp=":${p}->" 'index($0,p){print $1}')"
        if [[ -n "${ids}" ]]; then
          note "Останавливаю контейнеры Docker на порту ${p}: ${ids}"
          docker stop ${ids} || true
        fi
      fi
      # 3) Если всё ещё занят — убиваем процесс
      if ss -ltn "( sport = :$p )" | tail -n +2 | grep -q .; then
        local pid
        pid="$(ss -ltnp "( sport = :$p )" \
              | awk 'NR>1{print $NF}' \
              | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' \
              | head -n1)"
        if [[ -n "${pid}" ]]; then
          warn "Порт ${p} держит PID ${pid}. Попробовать прибить процесс? Это безопасно."
          read -rp "Убить PID ${pid}? [y/N]: " KILLIT
          if [[ "${KILLIT:-n}" =~ ^[Yy]$ ]]; then
            kill "${pid}" || true
            sleep 1
            kill -9 "${pid}" || true
          else
            err "Порт ${p} занят — не могу продолжить."
            exit 1
          fi
        fi
      fi
      # финальная проверка
      if ss -ltn "( sport = :$p )" | tail -n +2 | grep -q .; then
        err "Не удалось освободить порт ${p}."
        exit 1
      else
        info "Порт ${p} свободен."
      fi
    else
      info "Порт ${p} свободен."
    fi
  done
}
ensure_ports_free

# ────────────────────────────────────────────────────────────────────────────────
# Установка Docker + compose plugin
# ────────────────────────────────────────────────────────────────────────────────
info "Ставлю Docker…"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release; echo "$VERSION_CODENAME")"
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
info "Docker установлен."

# ────────────────────────────────────────────────────────────────────────────────
# Каталоги стека
# ────────────────────────────────────────────────────────────────────────────────
STACK_DIR="/opt/n8n"
mkdir -p "${STACK_DIR}/traefik/letsencrypt"
mkdir -p "${STACK_DIR}/n8n"
touch "${STACK_DIR}/traefik/letsencrypt/acme.json"
chmod 600 "${STACK_DIR}/traefik/letsencrypt/acme.json"

# ────────────────────────────────────────────────────────────────────────────────
# .env и docker-compose.yml
# ────────────────────────────────────────────────────────────────────────────────
cat > "${STACK_DIR}/.env" <<EOF
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
EOF

cat > "${STACK_DIR}/docker-compose.yml" <<'EOF'
version: "3.9"

services:
  traefik:
    image: traefik:v3.0
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.tlschallenge=true
      - --certificatesresolvers.le.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --log.level=INFO
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/letsencrypt:/letsencrypt
    networks:
      - proxy
    restart: unless-stopped

  n8n:
    image: n8nio/n8n:latest
    environment:
      - N8N_HOST=${DOMAIN}
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${DOMAIN}/
      - N8N_PORT=5678
      # полезное поведение при рестартах
      - GENERIC_TIMEZONE=Europe/Moscow
    labels:
      - "traefik.enable=true"
      # HTTPS-роутер
      - "traefik.http.routers.n8n.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      # HTTP→HTTPS редирект
      - "traefik.http.middlewares.redirect2https.redirectscheme.scheme=https"
      - "traefik.http.routers.n8n-plain.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.n8n-plain.entrypoints=web"
      - "traefik.http.routers.n8n-plain.middlewares=redirect2https"
    volumes:
      - ./n8n:/home/node/.n8n
    networks:
      - proxy
    restart: unless-stopped

networks:
  proxy:
    name: n8n-proxy
EOF

# ────────────────────────────────────────────────────────────────────────────────
# UFW (если включён)
# ────────────────────────────────────────────────────────────────────────────────
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  info "Открываю порты в ufw (80,443)…"
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi

# ────────────────────────────────────────────────────────────────────────────────
# Запуск стека
# ────────────────────────────────────────────────────────────────────────────────
( cd "${STACK_DIR}" && docker compose pull )
( cd "${STACK_DIR}" && docker compose up -d )

# ────────────────────────────────────────────────────────────────────────────────
# systemd unit для автозапуска
# ────────────────────────────────────────────────────────────────────────────────
cat > /etc/systemd/system/n8n-stack.service <<EOF
[Unit]
Description=n8n + Traefik Stack (Docker Compose)
After=network-online.target docker.service
Wants=docker.service

[Service]
Type=oneshot
WorkingDirectory=${STACK_DIR}
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now n8n-stack.service

info "Готово!"
echo
echo -e "Открой: ${GREEN}https://${DOMAIN}${RESET}"
echo -e "Папка со стеком: ${GRAY}${STACK_DIR}${RESET}"
echo
echo "Обновить n8n до последней версии:"
echo -e "  cd ${STACK_DIR} && docker compose pull && docker compose up -d"
echo
echo "Удалить всё (осторожно!):"
echo -e "  systemctl stop n8n-stack && cd ${STACK_DIR} && docker compose down -v && rm -rf ${STACK_DIR}"
