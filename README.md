# remnawave-installer

Интерактивный установщик Remnawave (панель + нода) — Nginx + nftables.

## Запуск

```bash
curl -fsSL https://raw.githubusercontent.com/qellyka/remnawave-installer/main/remnawave-deploy.sh -o remnawave-deploy.sh
chmod +x remnawave-deploy.sh
sudo ./remnawave-deploy.sh
```

Дальше — полностью интерактивно, скрипт сам спросит всё нужное.

## Структура репозитория

- `remnawave-deploy.sh` — основной скрипт (режимы «панель» / «нода»)
- `decoy-cdn/index.html` — страница-камуфляж для CDN-инбаунда ноды (скачивается скриптом автоматически; при недоступности репозитория используется встроенный минимальный fallback)
- `remnawave-inbounds/` — зарезервировано под готовые шаблоны инбаундов (функция ещё не реализована)

## Что делает скрипт

**Панель:** официальные `docker-compose`/`.env` от Remnawave → автогенерация секретов → Nginx (SSL hardening, `ssl_reject_handshake`) → сертификаты → nftables → опционально: автосоздание первого администратора и API-токена → страница подписки с этим токеном.

**Нода** — выбор из 4 вариантов:
1. Просто подключить ноду
2. 4 базовых инбаунда (Reality+TCP, Reality+gRPC, Reality+XHTTP, Hysteria2)
3. Связка с CDN (TLS+XHTTP через CDN)
4. Всё сразу (2+3)
