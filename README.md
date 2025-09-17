# n8n-1click-install

One-click скрипт для установки [n8n](https://n8n.io) на свой сервер.

- Поддержка Ubuntu 22.04 / 24.04
- Автоматически ставит Docker + PostgreSQL + Traefik (Let's Encrypt HTTPS)
- Настраивает systemd unit
- Запрашивает только **домен** и **email**

---

## 🚀 Быстрый старт

1. Создай **A-запись** у домена, которая указывает на IP твоего сервера  
   (например, `n8n.example.com → 45.12.34.56`).

2. Подключись к серверу (SSH).

3. Выполни команду:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amovei/n8n-1click-install/main/install-n8n.sh)
