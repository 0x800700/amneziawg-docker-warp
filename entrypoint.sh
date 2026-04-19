#!/bin/bash
# AmneziaWG container entrypoint
# Loads kernel module, brings up awg0 interface,
# and fixes routing inside gluetun network namespace.

if ! lsmod | grep -q amneziawg; then
    modprobe amneziawg
fi

awg-quick down /etc/amnezia/amneziawg/awg0.conf 2>/dev/null || true
sleep 1
awg-quick up /etc/amnezia/amneziawg/awg0.conf

# gluetun uses policy routing table 51820 for all traffic.
# Without this route, return packets destined to VPN clients
# would loop back into tun0 instead of going to awg0.
ip route replace 10.8.8.0/24 dev awg0 table 51820

echo "AmneziaWG started"
tail -f /dev/null
