#!/usr/bin/env bash

set -euo pipefail

REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/YuFan08/sbm/main}"
INSTALL_NAME="${INSTALL_NAME:-sbm}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
TARGET_PATH="${INSTALL_DIR}/${INSTALL_NAME}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '缺少依赖命令: %s\n' "$1" >&2
    exit 1
  fi
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

need_cmd curl

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

printf '正在下载系统工具脚本...\n'
curl -fsSL "${REPO_RAW_URL}/system-tool.sh" -o "$tmp_file"

printf '正在安装到 %s ...' "$TARGET_PATH"
run_as_root install -d -m 755 "$INSTALL_DIR"
run_as_root install -m 755 "$tmp_file" "$TARGET_PATH"

printf '安装完成。\n'
printf '运行命令: %s\n' "$INSTALL_NAME"
