#!/bin/bash
# AmneziaWG DKMS kernel module installer
# Tested on: Raspberry Pi 4/5, Debian Bookworm, kernel 6.12.x
#
# This script builds and installs the amneziawg.ko kernel module via DKMS.
# The module persists across kernel updates (DKMS rebuilds it automatically).
#
# To uninstall:
#   sudo dkms remove amneziawg/VERSION --all
#   sudo rm -rf /usr/src/amneziawg-VERSION

set -e

AWG_VERSION="v1.0.20260329-2"
AWG_PKG_VERSION="1.0.20260329-2"
KERNEL=$(uname -r)
ARCH=$(uname -m)

echo "=== AmneziaWG DKMS installer ==="
echo "Kernel: ${KERNEL}"
echo "Arch:   ${ARCH}"
echo "Module version: ${AWG_PKG_VERSION}"
echo ""

# Check arch
if [ "$ARCH" != "aarch64" ]; then
    echo "Warning: this script was tested on aarch64 (Raspberry Pi)."
    echo "Continuing anyway..."
    echo ""
fi

# Check dependencies
echo "[1/5] Checking dependencies..."
if ! command -v dkms &>/dev/null; then
    echo "Installing dkms..."
    sudo apt-get install -y dkms
fi

if ! dpkg -l | grep -q "linux-headers-${KERNEL}"; then
    echo "Installing kernel headers for ${KERNEL}..."
    sudo apt-get install -y "linux-headers-${KERNEL}" || \
    sudo apt-get install -y linux-headers-rpi-2712 || \
    { echo "Error: could not install kernel headers. Install manually."; exit 1; }
fi

echo "Dependencies OK"
echo ""

# Check if already installed
if dkms status 2>/dev/null | grep -q "amneziawg/${AWG_PKG_VERSION}.*installed"; then
    echo "amneziawg/${AWG_PKG_VERSION} already installed for kernel ${KERNEL}"
    lsmod | grep -q amneziawg || sudo modprobe amneziawg
    echo "Module loaded: $(lsmod | grep amneziawg | awk '{print $1}')"
    exit 0
fi

# Download sources
echo "[2/5] Downloading sources ${AWG_VERSION}..."
TMP_DIR=$(mktemp -d)
trap "rm -rf ${TMP_DIR}" EXIT

curl -L \
    "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/refs/tags/${AWG_VERSION}.tar.gz" \
    -o "${TMP_DIR}/amneziawg.tar.gz"

tar -xzf "${TMP_DIR}/amneziawg.tar.gz" -C "${TMP_DIR}"
echo "Downloaded OK"
echo ""

# Install to /usr/src
echo "[3/5] Installing sources to /usr/src..."
DEST="/usr/src/amneziawg-${AWG_PKG_VERSION}"
sudo rm -rf "${DEST}"
sudo cp -r "${TMP_DIR}/amneziawg-linux-kernel-module-${AWG_PKG_VERSION}/src/" "${DEST}"

# Write dkms.conf
sudo tee "${DEST}/dkms.conf" > /dev/null << EOF
PACKAGE_NAME="amneziawg"
PACKAGE_VERSION="${AWG_PKG_VERSION}"
AUTOINSTALL=yes
REMAKE_INITRD=no

BUILT_MODULE_NAME="amneziawg"
BUILT_MODULE_LOCATION="."
DEST_MODULE_LOCATION="/kernel/net"

MAKE="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
EOF

echo "Sources installed OK"
echo ""

# Register, build, install
echo "[4/5] Building module (this may take a few minutes)..."
sudo dkms add "amneziawg/${AWG_PKG_VERSION}"
sudo dkms build "amneziawg/${AWG_PKG_VERSION}" -k "${KERNEL}"
sudo dkms install "amneziawg/${AWG_PKG_VERSION}" -k "${KERNEL}"
echo "Build OK"
echo ""

# Load module
echo "[5/5] Loading module..."
sudo modprobe amneziawg
echo ""

# Verify
if lsmod | grep -q amneziawg; then
    echo "=== Installation complete ==="
    echo ""
    dkms status | grep amneziawg
    echo ""
    echo "Module will load automatically on boot."
    echo "On kernel update DKMS will rebuild it automatically."
else
    echo "Error: module did not load. Check dmesg for details."
    exit 1
fi
