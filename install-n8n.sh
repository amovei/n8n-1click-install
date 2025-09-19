#!/usr/bin/env bash
# n8n 1-click installer with Traefik (HTTPS), www-domain support and port auto-fix
# OS: Ubuntu 22.04/24.04 (root)

set -u
export DEBIAN_FRONTEND=noninteractive

# ---------- helpers ----------
green() { printf "\e[32m%s\e[0m\n" "$*"; }
yellow(){ printf "\e[33m%s\e[0m\n" "$*"; }
red()   { printf "\e[31m%s\e[0m\n" "$*"; }
die()   { red "[!] $*"; exit 1; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Запусти скрипт от root (sudo -i)."
  fi
}

ask_input() {
  read -rp "Домен для n8n (A-запись на IP сервера): " DOMAIN
  DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/$##')
  [ -z "$DOMAIN" ] && die "Домен не может быть пустым."
  read -rp "Email для Let's Encrypt: " EMAIL
  [ -z "$EMAIL" ] && die "Email не может быть пустым."
}

server_ip_guess() {
  # стараемся получить внешний IP
  if ! SERVER_IP=$(curl -fsS https://api.ipify.org 2>/dev/null); then
    SERVER_IP=$(hostname -I | awk '{print $1}')
  fi
  [ -z "$SERVER_IP" ] && SERVER_IP="(не удалось определить)"
}

dns_warn_if_mismatch() {
  yellow "[i] Проверяю DNS домена $DOMAIN…"
  RESOLVE_MAIN=$(getent ahosts "$DOMAIN" | awk '/STREAM/ {print $1; exit}')
  RESOLVE_WWW=$(getent ahosts "www.$DOMAIN" | awk '/STREAM/ {print $1; exit}')

  if [ -n "$RESOLVE_MAIN" ]; then
    green "[+] $DOMAIN -> $RESOLVE_MAIN"
  else
    yellow "[i] Не удалось разрешить $DOMAIN (возможно, DNS ещё не обновился)."
  fi

  if [ -n "$RESOLVE_WWW" ]; then
    green "[+] www.$DOMAIN -> $RESOLVE_WWW"
  else
    yellow "[i] Не удалось разрешить www.$DOMAIN (не обязательно, просто предупреждение)."
  fi

  if [ "$SERVER_IP" != "(не удалось определить)" ] && [ -n "$RESOLVE_MAIN" ] && [ "$RESOLVE_MAIN" != "$SERVER_IP" ]; then
    yellow "[i] Внимание: A-запись $DOMAIN указывает на $RESOLVE_MAIN, а сервер считает свой IP $SERVER_IP."
  fi
}

free_ports_80_443() {
  yellow "[i] Проверяю занятость портов 80/443…"
  for svc in nginx apache2 httpd caddy; do
    if systemctl is-active --quiet "$svc"; then
      yellow "[i] Останавливаю сервис $svc…"
      systemctl stop "$svc" || true
      systemctl disable "$svc" || true
    fi
  done

  # убиваем процессы, слушающие 80/443
  fuser -k 80/tcp  2>/dev/null || true
  fuser -k 443/tcp 2>/dev/null || true
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    yellow "[i] Устанавливаю Docker…"
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  if ! command -v docker >/dev/null 2>&1; then
    die "Docker не установлен."
  fi

  # docker compose plugin
  if ! docker compose version >/dev/null 2>&1; then
    die "Не найден docker compose plugin."
  fi
}

prepare_dirs() {
  mkdir -p /opt/n8n/traefik
  touch /opt/n8n/traefik/acme.json
  chmod 600 /opt/n8n/traefik/acme.json
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      yellow "[i] Открываю 80/443 в UFW…"
      ufw allow 80/tcp || true
      ufw allow 443/tcp || true
    fi
  fi
}

write_env() {
  cat > /opt/n8n/.env <<EOF
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
EOF
}

write_compose() {
  cat > /opt/n8n/docker-compose.yml <<'EOF'
services:
  traefik:
    image: traefik:v2.11
    container_name: traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.email=${EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
      - --api.dashboard=true
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/acme.json:/letsencrypt/acme.json
    networks:
      - web

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_HOST=${DOMAIN}
      - WEBHOOK_URL=https://${DOMAIN}/
      - GENERIC_TIMEZONE=Europe/Moscow
      - TZ=Europe/Moscow
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${DOMAIN}`, `www.${DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      # редирект HTTP -> HTTPS
      - "traefik.http.routers.n8n-redirect.rule=Host(`${DOMAIN}`, `www.${DOMAIN}`)"
      - "traefik.http.routers.n8n-redirect.entrypoints=web"
      - "traefik.http.routers.n8n-redirect.middlewares=redirect-to-https"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      - traefik
    networks:
      - web

volumes:
  n8n_data:

networks:
  web:
    external: false
EOF
}

up_stack() {
  (cd /opt/n8n && docker compose pull && docker compose up -d)
}

print_summary() {
  cat <<MSG

$(green "[✔] Установка завершена.")
Домен:      $(green "$DOMAIN")
Панель n8n: https://$DOMAIN/

Полезные команды:
  cd /opt/n8n
  docker compose logs -f traefik
  docker compose logs -f n8n
  docker compose restart n8n

Если сертификат не выпустился сразу — проверь, что A-запись домена указывает на IP сервера ($SERVER_IP),
и подожди пару минут — Traefik попробует снова.

MSG
}

# ---------- flow ----------
need_root
ask_input
server_ip_guess
dns_warn_if_mismatch
free_ports_80_443
install_docker
prepare_dirs
open_firewall
write_env
write_compose
up_stack
print_summary
