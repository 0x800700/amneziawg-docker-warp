# AmneziaWG + Docker + Cloudflare WARP

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%20%7C%20Debian%20ARM64-green)](https://www.raspberrypi.com/)
[![Docker](https://img.shields.io/badge/Docker-required-blue)](https://www.docker.com/)

**[English](README.md)** | **[Русский]**

VPN-сервер на базе [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) — обфусцированного форка WireGuard, обходящего блокировки по DPI (ТСПУ в России и аналоги в других странах). Весь трафик клиентов выходит через **Cloudflare WARP**, скрывая ваш реальный IP-адрес.

## Зачем это нужно

По состоянию на начало 2026 года в России заблокированы следующие протоколы:

| Протокол | Статус |
|---|---|
| WireGuard | ❌ Заблокирован |
| OpenVPN | ❌ Заблокирован |
| Shadowsocks / Outline | ❌ Заблокирован |
| AmneziaWG (старый) | ❌ Заблокирован |
| **AmneziaWG 2.0** | ✅ Работает |
| XRay (VLESS+Reality) | ✅ Работает |

Этот проект реализует AmneziaWG 2.0 в Docker **без использования официального приложения Amnezia** — которое требует root SSH-доступ к серверу, что небезопасно для production-машин с данными.

## Архитектура

```
iOS / Android клиент (Россия)
    ↓  AmneziaWG UDP обфусцированный трафик
Роутер (публичный IP)
    ↓  NAT → Raspberry Pi:39814
Raspberry Pi
    └── Docker: контейнер amneziawg
            ↓  network_mode: service:gluetun
        Docker: контейнер gluetun
            ↓  WireGuard туннель
    Cloudflare WARP (104.28.x.x)
            ↓
        Интернет
```

**Ключевые решения:**

- Контейнер `amneziawg` разделяет сетевой namespace с `gluetun` через `network_mode: service:gluetun`
- Трафик клиентов выходит через Cloudflare WARP — реальный IP не светится
- Модуль ядра `amneziawg.ko` собирается через DKMS на хосте, поэтому контейнеру нужен только `NET_ADMIN` (без `--privileged`)
- MASQUERADE применяется к `eth0` (Docker bridge), а не к `tun0`, чтобы избежать конфликта с policy routing gluetun

## Требования

- **Железо:** Raspberry Pi 4 или 5 (aarch64)
- **ОС:** Debian Bookworm (12)
- **Ядро:** 6.12.x с заголовками (`linux-headers-rpi-2712`)
- **Софт:** Docker, Docker Compose, DKMS, Python 3, qrencode
- **Сеть:** Проброс порта на роутере (UDP 39814)
- **Приватный ключ Cloudflare WARP** (см. ниже)

## Установка

### Шаг 1 — Получить приватный ключ Cloudflare WARP

Устанавливаем `wgcf` и регистрируем бесплатный аккаунт WARP:

**Linux ARM64 (Raspberry Pi):**
```bash
wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.29/wgcf_2.2.29_linux_armv7
chmod +x wgcf
./wgcf register
./wgcf generate
cat wgcf-profile.conf
```

**macOS:**
```bash
brew install wgcf
wgcf register
wgcf generate
cat wgcf-profile.conf
```

**Windows (PowerShell):**
```powershell
cd $HOME\Downloads
.\wgcf_2.2.29_windows_amd64.exe register
.\wgcf_2.2.29_windows_amd64.exe generate
cat wgcf-profile.conf
```

Скопируйте значение `PrivateKey` — оно понадобится в следующем шаге.

> Важно: `gluetun` требует числовой IP в Endpoint, а не доменное имя. Используйте `162.159.192.1:2408`.

### Шаг 2 — Установить модуль ядра через DKMS

Модуль ядра AmneziaWG должен быть собран на хосте. Это делается один раз. При обновлении ядра DKMS пересоберёт модуль автоматически.

```bash
git clone https://github.com/ProBablyWorks/amneziawg-docker-warp.git
cd amneziawg-docker-warp
chmod +x install-dkms.sh
./install-dkms.sh
```

Проверяем:
```bash
lsmod | grep amneziawg
dkms status | grep amneziawg
```

### Шаг 3 — Настройка конфигов

```bash
cp config/wg0.conf.example config/wg0.conf
cp config/awg0.conf.example config/awg0.conf
cp .env.example .env
```

Редактируем `config/wg0.conf` — вставляем приватный ключ WARP:
```ini
[Interface]
PrivateKey = ВАШ_ПРИВАТНЫЙ_КЛЮЧ_WARP   # ← заменить
Address = 172.16.0.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:2408
PersistentKeepalive = 25
```

Редактируем `.env`:
```bash
AWG_ENDPOINT=ВАШ_ПУБЛИЧНЫЙ_IP:39814   # ← внешний IP роутера
AWG_PORT=39814
```

### Шаг 4 — Собрать образ и сгенерировать ключи сервера

```bash
# Собираем Docker образ
docker build -t amneziawg-local:latest .

# Генерируем ключи сервера
docker run --rm --entrypoint="" \
  -v "$(pwd)/config:/keys" \
  amneziawg-local:latest \
  sh -c "awg genkey | tee /keys/server_private | awg pubkey > /keys/server_public"

# Исправляем владельца файлов
sudo chown $(id -u):$(id -g) config/server_private config/server_public
chmod 600 config/server_private

# Вставляем приватный ключ в awg0.conf
SERVER_PRIVATE=$(cat config/server_private)
sed -i "s|YOUR_SERVER_PRIVATE_KEY_HERE|${SERVER_PRIVATE}|" config/awg0.conf
```

### Шаг 5 — Настройка роутера (NAT + firewall)

**MikroTik** (RouterOS), выполнить в терминале:

```routeros
/ip firewall nat add \
    chain=dstnat protocol=udp dst-port=39814 \
    action=dst-nat to-addresses=IP_RASPBERRY_PI to-ports=39814 \
    comment="AmneziaWG"

/ip firewall filter add \
    chain=input protocol=udp dst-port=39814 \
    action=accept comment="AmneziaWG" \
    place-before=[find comment="defconf: drop all not coming from LAN"]
```

Для других роутеров: проброс UDP порта `39814` на LAN IP Raspberry Pi.

### Шаг 6 — Запуск

```bash
docker compose up -d
docker logs amneziawg
```

Ожидаемый вывод:
```
[#] ip link add awg0 type amneziawg
[#] ip -4 address add 10.8.8.1/24 dev awg0
[#] ip link set mtu 1420 up dev awg0
AmneziaWG started
```

### Шаг 7 — Добавить первого клиента

```bash
# Установить qrencode если нет
sudo apt-get install -y qrencode

chmod +x awg-manage.sh
source .env
./awg-manage.sh
```

Выбрать **1) Add client**, ввести имя. Скрипт:
- Сгенерирует ключи клиента
- Добавит peer в `awg0.conf`
- Перезапустит контейнер
- Покажет QR-код для сканирования в приложении AmneziaVPN

**Приложение для клиентов:** [AmneziaVPN](https://amnezia.org) — iOS, Android, Windows, macOS, Linux.

## Управление клиентами

```bash
./awg-manage.sh
```

| Пункт | Описание |
|---|---|
| 1) Add client | Генерирует ключи, назначает следующий свободный IP, показывает QR |
| 2) Remove client | Выбор из списка, удаление ключей и конфига |
| 3) QR / .conf | Повторный QR или сохранение .conf файла |
| 4) Client status | Статус подключений (handshake, трафик) |

## Структура файлов

```
amneziawg-docker-warp/
├── Dockerfile              # Сборка awg/awg-quick из исходников
├── docker-compose.yml      # Сервисы gluetun + amneziawg
├── entrypoint.sh           # Скрипт запуска контейнера
├── awg-manage.sh           # Управление клиентами
├── install-dkms.sh         # Установка модуля ядра
├── .env.example            # Шаблон переменных окружения
├── .env                    # Ваши настройки (не в git)
└── config/
    ├── wg0.conf            # Конфиг Cloudflare WARP (не в git)
    ├── awg0.conf           # Конфиг AmneziaWG сервера (не в git)
    ├── server_private      # Приватный ключ сервера (не в git)
    ├── server_public       # Публичный ключ сервера (не в git)
    └── *_private / *_public  # Ключи клиентов (не в git)
```

## Решение проблем

**Контейнер постоянно перезапускается:**
```bash
docker logs amneziawg
# Если видите "awg0 already exists":
docker exec gluetun ip link delete awg0 2>/dev/null || true
docker restart amneziawg
```

**Клиенты подключаются, но интернет не работает:**
```bash
# Проверяем routing table
docker exec amneziawg ip route show table 51820
# Должна быть строка: 10.8.8.0/24 dev awg0

# Проверяем что WARP работает
docker exec amneziawg wget -qO- https://ifconfig.me
# Должен вернуть IP Cloudflare, а не ваш домашний
```

**Проверить что трафик идёт:**
```bash
docker exec amneziawg awg show
# Смотреть счётчик transfer — received должен расти когда клиент активен
```

## Как удалить

```bash
# Остановить контейнеры
docker compose down

# Удалить DKMS модуль
sudo dkms remove amneziawg/1.0.20260329-2 --all
sudo rm -rf /usr/src/amneziawg-1.0.20260329-2
sudo modprobe -r amneziawg

# Удалить Docker образ
docker rmi amneziawg-local:latest
```

## Благодарности

Создано [ProBablyWorks](https://github.com/ProBablyWorks)

На основе:
- [AmneziaVPN](https://github.com/amnezia-vpn) — модуль ядра и утилиты AmneziaWG
- [qdm12/gluetun](https://github.com/qdm12/gluetun) — VPN клиент в Docker
- [ViRb3/wgcf](https://github.com/ViRb3/wgcf) — CLI для Cloudflare WARP

## Лицензия

MIT — см. [LICENSE](LICENSE)
