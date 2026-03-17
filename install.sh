#!/bin/bash
# agentsync installer — auto-detect platform, download, install
set -e

REPO="EvanL1/agentsync"
INSTALL_DIR="/usr/local/bin"

OS=$(uname -s)
ARCH=$(uname -m)

case "${OS}_${ARCH}" in
  Darwin_arm64)  NAME="agentsync-darwin-aarch64" ;;
  Darwin_x86_64) NAME="agentsync-darwin-x86_64" ;;
  Linux_x86_64)  NAME="agentsync-linux-x86_64" ;;
  Linux_aarch64) NAME="agentsync-linux-aarch64" ;;
  *) echo "Unsupported platform: ${OS} ${ARCH}"; exit 1 ;;
esac

echo "Installing agentsync for ${OS} ${ARCH}..."

LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
URL="https://github.com/${REPO}/releases/download/${LATEST}/${NAME}.tar.gz"

echo "Downloading ${LATEST}..."
curl -fsSL "${URL}" | tar xz

if [ -w "${INSTALL_DIR}" ]; then
  mv agentsync "${INSTALL_DIR}/"
else
  sudo mv agentsync "${INSTALL_DIR}/"
fi

echo "✓ agentsync installed to ${INSTALL_DIR}/agentsync"
agentsync --version
