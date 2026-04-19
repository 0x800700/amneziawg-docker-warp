# AmneziaWG + Docker + Cloudflare WARP

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%20%7C%20Debian%20ARM64-green)](https://www.raspberrypi.com/)
[![Docker](https://img.shields.io/badge/Docker-required-blue)](https://www.docker.com/)

**[English]** | **[Русский](README.ru.md)**

A self-hosted VPN server using [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) — an obfuscated fork of WireGuard that bypasses DPI-based VPN blocking (used in Russia, Iran, and other countries). All client traffic is routed through **Cloudflare WARP**, hiding your real IP address.

## Why this exists

As of early 2026, the following protocols are blocked in Russia by ТСПУ (deep packet inspection):

| Protocol | Status |
|---|---|
| WireGuard | ❌ Blocked |
| OpenVPN | ❌ Blocked |
| Shadowsocks / Outline | ❌ Blocked |
| AmneziaWG (old) | ❌ Blocked |
| **AmneziaWG 2.0** | ✅ Works |
| XRay (VLESS+Reality) | ✅ Works |

This project implements AmneziaWG 2.0 in Docker without using the official Amnezia app (which requires root SSH access to your server).

## Architecture

```
iOS / Android client (Russia)
    ↓  AmneziaWG UDP obfuscated traffic
Router (public IP)
    ↓  NAT → Raspberry Pi:39814
Raspberry Pi
    └── Docker: amneziawg container
            ↓  network_mode: service:gluetun
        Docker: gluetun container
            ↓  WireGuard tunnel
    Cloudflare WARP (104.28.x.x)
            ↓
        Internet
```

**Key design decisions:**

- `amneziawg` container shares the network namespace of `gluetun` via `network_mode: service:gluetun`
- Client traffic exits through Cloudflare WARP — your real IP is never exposed
- The `amneziawg.ko` kernel module is built via DKMS on the host, so the container only needs `NET_ADMIN` (no `--privileged`)
- MASQUERADE is applied to `eth0` (Docker bridge), not `tun0`, to avoid conntrack conflicts with gluetun's policy routing

## Requirements

- **Hardware:** Raspberry Pi 4 or 5 (aarch64)
- **OS:** Debian Bookworm (12)
- **Kernel:** 6.12.x with matching headers (`linux-headers-rpi-2712`)
- **Software:** Docker, Docker Compose, DKMS, Python 3, qrencode
- **Network:** Port forwarding on your router (UDP port 39814)
- **Cloudflare WARP private key** (see below)

## Installation

### Step 1 — Get Cloudflare WARP private key

Install `wgcf` and register a free WARP account:

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

Copy the `PrivateKey` value — you will need it in the next step.

> Note: `gluetun` requires a numeric IP endpoint, not a domain. Use `162.159.192.1:2408` (Cloudflare WARP).

### Step 2 — Install DKMS kernel module

The AmneziaWG kernel module must be built on the host. This is a one-time operation. DKMS will rebuild it automatically on kernel updates.

```bash
git clone https://github.com/ProBablyWorks/amneziawg-docker-warp.git
cd amneziawg-docker-warp
chmod +x install-dkms.sh
./install-dkms.sh
```

Verify:
```bash
lsmod | grep amneziawg
dkms status | grep amneziawg
```

### Step 3 — Configure

```bash
# Copy example configs
cp config/wg0.conf.example config/wg0.conf
cp config/awg0.conf.example config/awg0.conf
cp .env.example .env
```

Edit `config/wg0.conf` — paste your WARP private key:
```ini
[Interface]
PrivateKey = YOUR_WARP_PRIVATE_KEY_HERE   # ← replace this
Address = 172.16.0.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:2408
PersistentKeepalive = 25
```

Edit `.env`:
```bash
AWG_ENDPOINT=YOUR_PUBLIC_IP:39814   # ← your router's public IP
AWG_PORT=39814
```

### Step 4 — Generate server keys and build Docker image

```bash
# Build the Docker image
docker build -t amneziawg-local:latest .

# Generate server keypair
docker run --rm --entrypoint="" \
  -v "$(pwd)/config:/keys" \
  amneziawg-local:latest \
  sh -c "awg genkey | tee /keys/server_private | awg pubkey > /keys/server_public"

# Fix ownership
sudo chown $(id -u):$(id -g) config/server_private config/server_public
chmod 600 config/server_private

# Put the private key into awg0.conf
SERVER_PRIVATE=$(cat config/server_private)
sed -i "s|YOUR_SERVER_PRIVATE_KEY_HERE|${SERVER_PRIVATE}|" config/awg0.conf
```

### Step 5 — Configure router (NAT + firewall)

For **MikroTik** (RouterOS), run in terminal:

```routeros
/ip firewall nat add \
    chain=dstnat protocol=udp dst-port=39814 \
    action=dst-nat to-addresses=YOUR_RPI_IP to-ports=39814 \
    comment="AmneziaWG"

/ip firewall filter add \
    chain=input protocol=udp dst-port=39814 \
    action=accept comment="AmneziaWG" \
    place-before=[find comment="defconf: drop all not coming from LAN"]
```

For other routers: forward UDP port `39814` to your Raspberry Pi's LAN IP.

### Step 6 — Start

```bash
docker compose up -d
docker logs amneziawg
```

Expected output:
```
[#] ip link add awg0 type amneziawg
[#] ip -4 address add 10.8.8.1/24 dev awg0
[#] ip link set mtu 1420 up dev awg0
AmneziaWG started
```

### Step 7 — Add first client

```bash
# Install qrencode if needed
sudo apt-get install -y qrencode

chmod +x awg-manage.sh
source .env
./awg-manage.sh
```

Select **1) Add client**, enter a name. The script will:
- Generate client keypair
- Add peer to `awg0.conf`
- Restart the container
- Display a QR code to scan with AmneziaVPN app

**Client app:** [AmneziaVPN](https://amnezia.org) — available for iOS, Android, Windows, macOS, Linux.

## Managing clients

```bash
./awg-manage.sh
```

| Option | Description |
|---|---|
| 1) Add client | Generates keys, assigns next free IP, shows QR |
| 2) Remove client | Select from list, removes keys and config |
| 3) QR / .conf | Re-show QR or save .conf file for existing client |
| 4) Client status | Shows live connection info (handshake, transfer) |

## File structure

```
amneziawg-docker-warp/
├── Dockerfile              # Builds awg/awg-quick from source
├── docker-compose.yml      # gluetun + amneziawg services
├── entrypoint.sh           # Container startup script
├── awg-manage.sh           # Client management
├── install-dkms.sh         # Kernel module installer
├── .env.example            # Environment template
├── .env                    # Your settings (not in git)
└── config/
    ├── wg0.conf            # Cloudflare WARP config (not in git)
    ├── awg0.conf           # AmneziaWG server config (not in git)
    ├── server_private      # Server private key (not in git)
    ├── server_public       # Server public key (not in git)
    └── *_private / *_public  # Client keys (not in git)
```

## Troubleshooting

**Container keeps restarting:**
```bash
docker logs amneziawg
# If you see "awg0 already exists":
docker exec gluetun ip link delete awg0 2>/dev/null || true
docker restart amneziawg
```

**Clients connect but no internet:**
```bash
# Check routing table
docker exec amneziawg ip route show table 51820
# Should contain: 10.8.8.0/24 dev awg0

# Check WARP is working
docker exec amneziawg wget -qO- https://ifconfig.me
# Should return a Cloudflare IP, not your home IP
```

**Check if traffic is flowing:**
```bash
docker exec amneziawg awg show
# Watch "transfer" counter — received should grow when client is active
```

## How to remove

```bash
# Stop containers
docker compose down

# Remove DKMS module
sudo dkms remove amneziawg/1.0.20260329-2 --all
sudo rm -rf /usr/src/amneziawg-1.0.20260329-2
sudo modprobe -r amneziawg

# Remove Docker image
docker rmi amneziawg-local:latest
```

## Credits

Built by [ProBablyWorks](https://github.com/ProBablyWorks)

Based on:
- [AmneziaVPN](https://github.com/amnezia-vpn) — AmneziaWG kernel module and tools
- [qdm12/gluetun](https://github.com/qdm12/gluetun) — VPN client in Docker
- [ViRb3/wgcf](https://github.com/ViRb3/wgcf) — Cloudflare WARP CLI

## License

MIT — see [LICENSE](LICENSE)
