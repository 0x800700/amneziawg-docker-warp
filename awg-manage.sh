#!/bin/bash
# AmneziaWG peer management script
# https://github.com/ProBablyWorks/amneziawg-docker-warp

set -e

# ─── Configuration ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${AWG_CONFIG_DIR:-${SCRIPT_DIR}/config}"
AWG0_CONF="${CONFIG_DIR}/awg0.conf"
CONTAINER_NAME="${AWG_CONTAINER:-amneziawg}"
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"

# Read server public key and endpoint from environment or config
SERVER_PUBLIC=$(cat "${CONFIG_DIR}/server_public" 2>/dev/null || echo "")
ENDPOINT="${AWG_ENDPOINT:-}"

# Try to read endpoint from awg0.conf if not set
if [ -z "$ENDPOINT" ]; then
    echo "Warning: AWG_ENDPOINT not set. Set it in .env or export AWG_ENDPOINT=YOUR_IP:PORT"
    echo "Example: export AWG_ENDPOINT=1.2.3.4:39814"
    echo ""
fi

# ─── Helpers ───────────────────────────────────────────────────────────────

get_peers() {
    python3 -c "
import re
with open('${AWG0_CONF}') as f:
    content = f.read()
peers = re.findall(r'\[Peer\]\n(?:# (\S+)\n)?PublicKey = [^\n]+\nAllowedIPs = ([^\n/]+)', content)
for name, ip in peers:
    print((name or 'unknown') + ' ' + ip.strip())
"
}

next_free_ip() {
    local base="10.8.8"
    local used
    used=$(grep "^AllowedIPs" "${AWG0_CONF}" | grep -oP '\d+(?=/32)' | sort -n)
    for i in $(seq 2 254); do
        if ! echo "$used" | grep -qx "$i"; then
            echo "${base}.${i}"
            return
        fi
    done
    echo ""
}

generate_qr() {
    local name="$1"
    local ip="$2"
    local priv
    priv=$(cat "${CONFIG_DIR}/${name}_private")

    cat > "/tmp/${name}_client.conf" << CONF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/24
DNS = 1.1.1.1

Jc = 4
Jmin = 40
Jmax = 70
S1 = 30
S2 = 40
H1 = 1754564590
H2 = 1387823816
H3 = 2095978365
H4 = 896699605

[Peer]
PublicKey = ${SERVER_PUBLIC}
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
    echo ""
    echo "QR code for ${name} (${ip}):"
    echo ""
    qrencode -t ansiutf8 < "/tmp/${name}_client.conf"
    rm "/tmp/${name}_client.conf"
}

save_conf() {
    local name="$1"
    local ip="$2"
    local priv
    priv=$(cat "${CONFIG_DIR}/${name}_private")
    local outfile="${CONFIG_DIR}/${name}_client.conf"

    cat > "${outfile}" << CONF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/24
DNS = 1.1.1.1

Jc = 4
Jmin = 40
Jmax = 70
S1 = 30
S2 = 40
H1 = 1754564590
H2 = 1387823816
H3 = 2095978365
H4 = 896699605

[Peer]
PublicKey = ${SERVER_PUBLIC}
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
    chmod 600 "${outfile}"
    echo "Config saved: ${outfile}"
}

show_peers() {
    echo ""
    echo "=== Client status ==="
    echo ""

    declare -A key_to_name
    for pub_file in "${CONFIG_DIR}"/*_public; do
        [ -f "$pub_file" ] || continue
        fname=$(basename "$pub_file")
        [ "$fname" = "server_public" ] && continue
        name="${fname%_public}"
        key=$(cat "$pub_file")
        key_to_name["$key"]="$name"
    done

    docker exec "${CONTAINER_NAME}" awg show | while IFS= read -r line; do
        if [[ "$line" =~ ^peer:\ (.+)$ ]]; then
            current_key="${BASH_REMATCH[1]}"
            name="${key_to_name[$current_key]:-unknown}"
            echo "peer: ${current_key}  [${name}]"
        else
            echo "$line"
        fi
    done
    echo ""
}

select_peer() {
    local prompt="$1"
    local peers=()
    while IFS=' ' read -r name ip; do
        peers+=("$name $ip")
    done < <(get_peers)

    if [ ${#peers[@]} -eq 0 ]; then
        echo "No clients found"
        return 1
    fi

    echo ""
    echo "Client list:"
    echo "────────────────────────────────"
    local i=1
    for entry in "${peers[@]}"; do
        local pname pip
        pname=$(echo "$entry" | awk '{print $1}')
        pip=$(echo "$entry" | awk '{print $2}')
        printf "  %d) %-15s %s\n" "$i" "$pname" "$pip"
        i=$((i+1))
    done
    echo "────────────────────────────────"
    echo ""

    read -rp "${prompt} (0 to cancel): " choice

    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return 1
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt "${#peers[@]}" ]; then
        echo "Invalid selection"
        return 1
    fi

    SELECTED_NAME=$(echo "${peers[$((choice-1))]}" | awk '{print $1}')
    SELECTED_IP=$(echo "${peers[$((choice-1))]}" | awk '{print $2}')
    return 0
}

# ─── Actions ───────────────────────────────────────────────────────────────

action_add() {
    echo ""
    read -rp "Enter client name: " CLIENT_NAME

    if [ -z "$CLIENT_NAME" ]; then
        echo "Name cannot be empty"
        return
    fi

    if [ -f "${CONFIG_DIR}/${CLIENT_NAME}_private" ]; then
        echo "Error: client ${CLIENT_NAME} already exists"
        return
    fi

    CLIENT_IP=$(next_free_ip)
    if [ -z "$CLIENT_IP" ]; then
        echo "Error: no free IP addresses available"
        return
    fi

    echo "Creating client: ${CLIENT_NAME} → ${CLIENT_IP}"

    docker run --rm --entrypoint="" \
      -v "${CONFIG_DIR}:/keys" \
      amneziawg-local:latest \
      sh -c "awg genkey | tee /keys/${CLIENT_NAME}_private | awg pubkey > /keys/${CLIENT_NAME}_public"

    sudo chown "${CURRENT_USER}:${CURRENT_GROUP}" \
        "${CONFIG_DIR}/${CLIENT_NAME}_private" \
        "${CONFIG_DIR}/${CLIENT_NAME}_public"
    chmod 600 "${CONFIG_DIR}/${CLIENT_NAME}_private"

    CLIENT_PUBLIC=$(cat "${CONFIG_DIR}/${CLIENT_NAME}_public")

    cat >> "${AWG0_CONF}" << PEER

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC}
AllowedIPs = ${CLIENT_IP}/32
PEER

    echo "Restarting amneziawg..."
    docker restart "${CONTAINER_NAME}"
    sleep 8

    if ! docker ps | grep -q "${CONTAINER_NAME}.*Up"; then
        echo "Error: container failed to start"
        return
    fi

    echo ""
    echo "Client ${CLIENT_NAME} created, IP: ${CLIENT_IP}"
    generate_qr "$CLIENT_NAME" "$CLIENT_IP"
}

action_remove() {
    SELECTED_NAME=""
    SELECTED_IP=""
    select_peer "Enter client number to remove" || return

    echo ""
    read -rp "Remove client ${SELECTED_NAME} (${SELECTED_IP})? [y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled"
        return
    fi

    python3 - << PYEOF
import re

with open('${AWG0_CONF}', 'r') as f:
    content = f.read()

# Remove peer block with or without name comment
pattern = r'\n\[Peer\]\n(?:# ${SELECTED_NAME}\n)?PublicKey = [^\n]+\nAllowedIPs = ${SELECTED_IP}/32'
content = re.sub(pattern, '', content)

with open('${AWG0_CONF}', 'w') as f:
    f.write(content)

print("awg0.conf updated")
PYEOF

    sudo rm -f "${CONFIG_DIR}/${SELECTED_NAME}_private" \
               "${CONFIG_DIR}/${SELECTED_NAME}_public" \
               "${CONFIG_DIR}/${SELECTED_NAME}_client.conf"

    echo "Restarting amneziawg..."
    docker restart "${CONTAINER_NAME}"
    sleep 8

    echo "Client ${SELECTED_NAME} removed"
}

action_show() {
    SELECTED_NAME=""
    SELECTED_IP=""
    select_peer "Enter client number" || return

    if [ ! -f "${CONFIG_DIR}/${SELECTED_NAME}_private" ]; then
        echo "Error: key file ${SELECTED_NAME}_private not found"
        return
    fi

    echo ""
    echo "What to do for client ${SELECTED_NAME} (${SELECTED_IP})?"
    echo "  1) Show QR code"
    echo "  2) Save .conf file"
    echo "  3) Both"
    read -rp "Choice: " subchoice

    case "$subchoice" in
        1) generate_qr "$SELECTED_NAME" "$SELECTED_IP" ;;
        2) save_conf "$SELECTED_NAME" "$SELECTED_IP" ;;
        3) generate_qr "$SELECTED_NAME" "$SELECTED_IP"
           save_conf "$SELECTED_NAME" "$SELECTED_IP" ;;
        *) echo "Invalid choice" ;;
    esac
}

# ─── Main menu ─────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        echo ""
        echo "╔══════════════════════════════╗"
        echo "║   AmneziaWG Management       ║"
        echo "╠══════════════════════════════╣"
        echo "║  1) Add client               ║"
        echo "║  2) Remove client            ║"
        echo "║  3) QR / .conf for client    ║"
        echo "║  4) Client status            ║"
        echo "║  0) Exit                     ║"
        echo "╚══════════════════════════════╝"
        read -rp "Choice: " choice

        case "$choice" in
            1) action_add ;;
            2) action_remove ;;
            3) action_show ;;
            4) show_peers ;;
            0) echo "Exit"; exit 0 ;;
            *) echo "Invalid choice" ;;
        esac
    done
}

main_menu
