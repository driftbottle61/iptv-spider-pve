#!/usr/bin/env bash
set -euo pipefail

VERSION="1.2.7"
REPO_TAG="v0.3.6"
REPOSITORY="driftbottle61/iptv-spider-pve"
ARCHIVE="iptv-spider-app-${VERSION}-linux-amd64.tar.gz"
ARCHIVE_URL="https://github.com/${REPOSITORY}/releases/download/${REPO_TAG}/${ARCHIVE}"
CHECKSUM_URL="https://github.com/${REPOSITORY}/releases/download/${REPO_TAG}/${ARCHIVE}.sha256"

if [ "$(uname -m)" != "x86_64" ]; then
  echo "目前仅支持 Linux amd64。" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "缺少 curl，请先执行：apt-get update && apt-get install -y curl" >&2
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "缺少 sha256sum，无法校验安装包。" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d /tmp/iptv-spider-install.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "正在下载 IPTV Spider ${VERSION}..."
curl -fL --retry 3 --retry-delay 2 -o "${WORK_DIR}/${ARCHIVE}" "$ARCHIVE_URL"
curl -fL --retry 3 --retry-delay 2 -o "${WORK_DIR}/${ARCHIVE}.sha256" "$CHECKSUM_URL"
(cd "$WORK_DIR" && sha256sum -c "${ARCHIVE}.sha256")

tar -xzf "${WORK_DIR}/${ARCHIVE}" -C "$WORK_DIR"
INSTALL_DIR="${WORK_DIR}/app"

if [ ! -f "${INSTALL_DIR}/install.sh" ]; then
  echo "下载的安装包中缺少 install.sh。" >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  exec bash "${INSTALL_DIR}/install.sh" </dev/tty
fi

exec sudo bash "${INSTALL_DIR}/install.sh" </dev/tty
