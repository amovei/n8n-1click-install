# n8n-1click-install

One-click скрипт для установки [n8n](https://n8n.io) на свой сервер.  

- Поддержка Ubuntu 22.04 / 24.04  
- Автоматическая установка Docker + PostgreSQL + Traefik (с HTTPS Let's Encrypt)  
- Настраивается systemd unit  
- Запрашивает только **домен** и **email**  

---

## 🚀 Быстрый старт

1. Создай **A-запись** у домена, которая указывает на IP твоего сервера  
   *(например, `n8n.example.com → 45.12.34.56`).*

2. Подключись к серверу (**SSH**).  

3. Выполни команду:  

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amovei/n8n-1click-install/main/install-n8n.sh)
```

Укажи свой домен и email для Let's Encrypt.  

Через пару минут открывай:  

```
https://твой_домен
```

---

## 🔄 Обновление n8n

Чтобы обновить контейнеры до последней версии:  

```bash
cd /opt/n8n
sudo docker compose pull
sudo systemctl restart n8n-compose
```

---

## 📂 Структура

- **install-n8n.sh** — скрипт автоматической установки  
- **README.md** — инструкция по запуску и обновлению  

---

✨ Всё, готово. Открывай n8n и работай! 🚀
