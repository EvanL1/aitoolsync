#!/bin/bash
# aisync installer — auto-detect platform, download, install
set -e

REPO="EvanL1/aitoolsync"
INSTALL_DIR="/usr/local/bin"

OS=$(uname -s)
ARCH=$(uname -m)

case "${OS}_${ARCH}" in
  Darwin_arm64)  NAME="aisync-darwin-aarch64" ;;
  Darwin_x86_64) NAME="aisync-darwin-x86_64" ;;
  Linux_x86_64)  NAME="aisync-linux-x86_64" ;;
  Linux_aarch64) NAME="aisync-linux-aarch64" ;;
  *) echo "Unsupported platform: ${OS} ${ARCH}"; exit 1 ;;
esac

echo "Installing aisync for ${OS} ${ARCH}..."

LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
URL="https://github.com/${REPO}/releases/download/${LATEST}/${NAME}.tar.gz"

echo "Downloading ${LATEST}..."
curl -fsSL "${URL}" | tar xz

if [ -w "${INSTALL_DIR}" ]; then
  mv aisync "${INSTALL_DIR}/"
else
  sudo mv aisync "${INSTALL_DIR}/"
fi

echo "✓ aisync installed to ${INSTALL_DIR}/aisync"
aisync --version
