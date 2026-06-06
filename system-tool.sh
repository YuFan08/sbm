#!/usr/bin/env bash

set -o nounset
set -o pipefail

APP_NAME="Sing-Box 管理器"
SBM_DIR="/etc/sbm"
SBM_NODE_INFO="/etc/sbm/node-info.txt"
SBM_NODE_LINKS="/etc/sbm/node-links.txt"
SBM_CERT_ASSIGNMENTS="/etc/sbm/cert-assignments.conf"
FOUR_CERT_DIR="/etc/sing-box/certs/four"
CF_CERT_DIR="/etc/sing-box/certs/cloudflare"
SING_BOX_CONFIG_BACKUP=""
SING_BOX_CONFIG_HAD_EXISTING=0
PENDING_CERT_PROFILE=""
PENDING_CERT_NAME=""
PENDING_CERT_SNI=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$(printf '\033[0m')
  C_BOLD=$(printf '\033[1m')
  C_DIM=$(printf '\033[2m')
  C_RED=$(printf '\033[31m')
  C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m')
  C_BLUE=$(printf '\033[34m')
  C_CYAN=$(printf '\033[36m')
  C_WHITE=$(printf '\033[97m')
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_WHITE=""
fi

C_TITLE="${C_BOLD}${C_CYAN}"
C_MENU_NUM="${C_BOLD}${C_YELLOW}"
C_MENU_TEXT="${C_BOLD}${C_WHITE}"
C_MENU_EXIT="${C_DIM}"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_valid_port() {
  printf '%s' "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_domain() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' &&
    printf '%s' "$1" | grep -q '\.'
}

random_secret() {
  if has_cmd openssl; then
    openssl rand -base64 24 | tr -d '\n'
  elif [ -r /dev/urandom ]; then
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
  else
    date +%s%N
  fi
}

random_hex() {
  if has_cmd openssl; then
    openssl rand -hex "$1" | tr -d '\n'
  elif [ -r /dev/urandom ]; then
    od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'
  else
    date +%s%N | cut -c 1-"$(($1 * 2))"
  fi
}

generate_uuid() {
  if has_cmd sing-box; then
    sing-box generate uuid 2>/dev/null && return
  fi
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return
  fi
  random_hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

base64_no_wrap() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}

base64_decode() {
  if base64 --help 2>/dev/null | grep -q -- '-d'; then
    base64 -d
  else
    base64 --decode
  fi
}

node_hostname_label() {
  raw_hostname=$(hostname 2>/dev/null || printf host)
  clean_hostname=$(printf '%s' "$raw_hostname" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//')
  clean_hostname=${clean_hostname:-Host}
  printf '%s' "$clean_hostname" | awk '{print toupper(substr($0, 1, 1)) substr($0, 2)}'
}

node_display_name() {
  protocol=$1
  printf '%s-%s-SBM' "$protocol" "$(node_hostname_label)"
}

json_get_string() {
  key=$1
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\(.*\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p" | head -n 1
}

build_vmess_link() {
  vmess_name=$1
  vmess_addr=$2
  vmess_port=$3
  vmess_uuid=$4
  vmess_path=$5
  vmess_sni=$6

  vmess_name_json=$(json_escape "$vmess_name")
  vmess_addr_json=$(json_escape "$vmess_addr")
  vmess_path_json=$(json_escape "$vmess_path")
  vmess_sni_json=$(json_escape "$vmess_sni")
  vmess_json=$(mktemp)
  cat >"$vmess_json" <<EOF
{
  "v": "2",
  "ps": "$vmess_name_json",
  "add": "$vmess_addr_json",
  "port": "$vmess_port",
  "id": "$vmess_uuid",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "$vmess_sni_json",
  "path": "$vmess_path_json",
  "tls": "tls",
  "sni": "$vmess_sni_json"
}
EOF
  printf 'vmess://%s' "$(base64_no_wrap <"$vmess_json")"
  rm -f "$vmess_json"
}

url_encode() {
  old_lc_all=${LC_ALL:-}
  LC_ALL=C
  value=$1
  encoded=""
  i=0
  while [ "$i" -lt "${#value}" ]; do
    c=${value:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded="${encoded}${c}" ;;
      *) encoded="${encoded}$(printf '%%%02X' "'$c")" ;;
    esac
    i=$((i + 1))
  done
  if [ -n "$old_lc_all" ]; then
    LC_ALL=$old_lc_all
  else
    unset LC_ALL
  fi
  printf '%s' "$encoded"
}

pause() {
  printf '\n%s按 Enter 返回菜单...%s' "$C_DIM" "$C_RESET"
  read -r _
}

header() {
  clear
  printf '%s=== %s ===%s\n' "$C_TITLE" "$APP_NAME" "$C_RESET"
}

section() {
  printf '\n%s[%s]%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"
}

menu_item() {
  number=$1
  text=$2
  printf '%s%2s.%s %s%s%s\n' "$C_MENU_NUM" "$number" "$C_RESET" "$C_MENU_TEXT" "$text" "$C_RESET"
}

menu_exit_item() {
  number=$1
  text=$2
  printf '%s%2s.%s %s%s\n' "$C_MENU_EXIT" "$number" "$C_RESET" "$text" "$C_RESET"
}

show_basic_info() {
  header
  section "系统信息"
  printf '主机名:   %s\n' "$(hostname 2>/dev/null || printf unknown)"
  printf '当前用户: %s\n' "$(id -un 2>/dev/null || printf unknown)"
  printf '时间:     %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf unknown)"

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '系统版本: %s\n' "${PRETTY_NAME:-unknown}"
  fi

  printf '内核:     %s\n' "$(uname -r 2>/dev/null || printf unknown)"
  printf '架构:     %s\n' "$(uname -m 2>/dev/null || printf unknown)"
  printf '运行时间: %s\n' "$(uptime -p 2>/dev/null || uptime 2>/dev/null || printf unknown)"
  printf '本机 IP:  %s\n' "$(hostname -I 2>/dev/null | awk '{$1=$1; print}' || printf unknown)"

  section "CPU"
  if has_cmd lscpu; then
    lscpu | awk -F: '/Model name|CPU\(s\)|Architecture/ {gsub(/^[ \t]+/, "", $2); printf "%-14s %s\n", $1":", $2}'
  else
    awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print "型号:         " $2; exit}' /proc/cpuinfo 2>/dev/null
    printf 'CPU 数量:     %s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf unknown)"
  fi

  section "内存"
  if has_cmd free; then
    free -h
  else
    awk '/MemTotal|MemAvailable/ {print}' /proc/meminfo 2>/dev/null
  fi

  section "磁盘"
  df -hT 2>/dev/null | awk 'NR == 1 || $7 == "/" || $7 ~ /^\/home/ {print}'

  pause
}

show_listening_ports() {
  header
  section "监听端口"
  if has_cmd ss; then
    ss -tulpen
  elif has_cmd netstat; then
    netstat -tulpen
  else
    printf '未安装 ss 或 netstat。\n'
    printf 'Debian/Ubuntu 可执行安装: sudo apt-get install -y iproute2 net-tools\n'
  fi

  pause
}

check_port_open() {
  header
  printf '请输入要检测的主机 [默认: 127.0.0.1]: '
  read -r host
  host=${host:-127.0.0.1}

  printf '请输入要检测的端口: '
  read -r port

  if ! is_valid_port "$port"; then
    printf '\n端口无效: %s\n' "$port"
    pause
    return
  fi

  section "检测结果"
  if has_cmd nc; then
    if nc -vz -w 3 "$host" "$port"; then
      printf '\n%s:%s 已开放或可访问。\n' "$host" "$port"
    else
      printf '\n%s:%s 未开放或不可访问。\n' "$host" "$port"
    fi
  elif timeout 3 bash -c ":</dev/tcp/$host/$port" >/dev/null 2>&1; then
    printf '%s:%s 已开放或可访问。\n' "$host" "$port"
  else
    printf '%s:%s 未开放或不可访问。\n' "$host" "$port"
    printf '提示：安装 netcat 可获得更清晰的检测结果: sudo apt-get install -y netcat-openbsd\n'
  fi

  pause
}

open_firewall_port() {
  header
  printf '请输入要放行的端口: '
  read -r port

  if ! is_valid_port "$port"; then
    printf '\n端口无效: %s\n' "$port"
    pause
    return
  fi

  printf '协议 [tcp/udp，默认: tcp]: '
  read -r proto
  proto=${proto:-tcp}

  if [ "$proto" != "tcp" ] && [ "$proto" != "udp" ]; then
    printf '\n协议无效: %s\n' "$proto"
    pause
    return
  fi

  section "防火墙"
  if has_cmd ufw; then
    printf '正在执行: sudo ufw allow %s/%s\n\n' "$port" "$proto"
    sudo ufw allow "$port/$proto"
    sudo ufw status numbered
  else
    printf '未安装 ufw。可执行以下命令安装:\n'
    printf '  sudo apt-get install -y ufw\n\n'
    printf '如果这是 WSL，外部访问还可能受 Windows 防火墙控制。\n'
  fi

  pause
}

show_processes() {
  header
  section "CPU 占用最高的进程"
  ps aux --sort=-%cpu 2>/dev/null | awk 'NR <= 15 {print}'
  pause
}

install_sing_box_if_needed() {
  if has_cmd sing-box; then
    printf '已检测到 sing-box: %s\n' "$(sing-box version 2>/dev/null | head -n 1)"
    ensure_sing_box_service_unit || return 1
    return 0
  fi

  printf '未检测到 sing-box，是否从官方 GitHub Release 下载并校验安装？[Y/n]: '
  read -r install_choice
  install_choice=${install_choice:-Y}
  case "$install_choice" in
    Y|y|yes|YES) ;;
    *)
      printf '已取消安装 sing-box。\n'
      return 1
      ;;
  esac

  ensure_sing_box_core_tools || return 1
  latest_version=$(latest_sing_box_version)
  if [ -z "$latest_version" ]; then
    printf '%s无法获取 sing-box 最新稳定版本。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  download_sing_box_binary "$latest_version" || return 1
  if ! sudo install -m 755 "$DOWNLOADED_SING_BOX_BIN" /usr/local/bin/sing-box; then
    rm -rf "$DOWNLOADED_SING_BOX_DIR"
    printf '%ssing-box 二进制安装失败。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  rm -rf "$DOWNLOADED_SING_BOX_DIR"
  ensure_sing_box_service_unit || return 1

  printf 'sing-box 安装完成: %s\n' "$(sing-box version 2>/dev/null | head -n 1)"
}

ensure_sing_box_service_unit() {
  if ! has_cmd systemctl || systemctl cat sing-box >/dev/null 2>&1; then
    return 0
  fi

  service_binary=$(command -v sing-box) || return 1
  tmp_service=$(mktemp)
  cat >"$tmp_service" <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${service_binary} run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  if ! sudo install -m 644 "$tmp_service" /etc/systemd/system/sing-box.service; then
    rm -f "$tmp_service"
    printf '%ssing-box systemd 服务安装失败。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  rm -f "$tmp_service"
  sudo systemctl daemon-reload || return 1
}

sing_box_binary_path() {
  if has_cmd systemctl && systemctl cat sing-box >/dev/null 2>&1; then
    service_bin=$(systemctl cat sing-box 2>/dev/null |
      sed -n 's/^[[:space:]]*ExecStart=[-@+!]*\([^[:space:]]*sing-box\).*/\1/p' |
      head -n 1)
    if [ -n "$service_bin" ]; then
      printf '%s' "$service_bin"
      return
    fi
  fi

  if has_cmd sing-box; then
    command -v sing-box
  else
    printf '/usr/bin/sing-box'
  fi
}

sing_box_release_arch() {
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7*) printf 'armv7' ;;
    armv6l|armv6*) printf 'armv6' ;;
    i386|i686) printf '386' ;;
    *)
      printf '%s当前架构暂不支持自动下载: %s%s\n' "$C_RED" "$arch" "$C_RESET" >&2
      return 1
      ;;
  esac
}

ensure_sing_box_core_tools() {
  missing_tools=""
  for tool in curl tar sha256sum jq; do
    if ! has_cmd "$tool"; then
      missing_tools="$missing_tools $tool"
    fi
  done

  if [ -n "$missing_tools" ]; then
    if ! has_cmd apt-get; then
      printf '%s缺少依赖:%s%s\n' "$C_RED" "$missing_tools" "$C_RESET"
      return 1
    fi
    printf '正在安装依赖:%s\n' "$missing_tools"
    sudo apt-get update || return 1
    sudo apt-get install -y curl tar coreutils ca-certificates jq || return 1
  fi
}

latest_sing_box_version() {
  curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest |
    jq -r '.tag_name // empty' |
    sed 's/^v//'
}

download_sing_box_binary() {
  version=$1
  version=${version#v}
  arch=$(sing_box_release_arch) || return 1
  archive_name="sing-box-${version}-linux-${arch}.tar.gz"
  tmp_dir=$(mktemp -d)
  archive_path="${tmp_dir}/${archive_name}"
  release_json="${tmp_dir}/release.json"

  if ! curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${version}" -o "$release_json"; then
    rm -rf "$tmp_dir"
    printf '%s无法读取 sing-box Release 元数据。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  download_url=$(jq -r --arg name "$archive_name" \
    '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")
  expected_sha256=$(jq -r --arg name "$archive_name" \
    '.assets[] | select(.name == $name) | (.digest // "") | sub("^sha256:"; "")' "$release_json")
  if [ -z "$download_url" ] || [ "$download_url" = "null" ] ||
    [ -z "$expected_sha256" ] || [ "$expected_sha256" = "null" ]; then
    rm -rf "$tmp_dir"
    printf '%sRelease 中缺少安装包或 SHA256 摘要，已拒绝安装。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  printf '正在下载 sing-box %s (%s)...\n' "$version" "$arch"
  if ! curl -fL "$download_url" -o "$archive_path"; then
    rm -rf "$tmp_dir"
    printf '%s下载失败:%s %s\n' "$C_RED" "$C_RESET" "$download_url"
    return 1
  fi

  actual_sha256=$(sha256sum "$archive_path" | awk '{print $1}')
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    rm -rf "$tmp_dir"
    printf '%sSHA256 校验失败，已拒绝安装。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  if ! tar -xzf "$archive_path" -C "$tmp_dir"; then
    rm -rf "$tmp_dir"
    printf '%s解压失败。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  new_bin=$(find "$tmp_dir" -type f -name sing-box -perm -u+x | head -n 1)
  if [ -z "$new_bin" ]; then
    rm -rf "$tmp_dir"
    printf '%s未在压缩包中找到 sing-box 二进制。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  DOWNLOADED_SING_BOX_DIR=$tmp_dir
  DOWNLOADED_SING_BOX_BIN=$new_bin
}

current_sing_box_version_label() {
  if has_cmd sing-box; then
    sing-box version 2>/dev/null | head -n 1 | tr ' /' '__'
  else
    printf 'not-installed'
  fi
}

backup_sing_box_binary() {
  current_bin=$1
  if ! sudo test -f "$current_bin"; then
    BACKUP_SING_BOX_BIN=""
    return 0
  fi

  sudo install -d -m 755 /etc/sbm/sing-box-backups
  backup_name="sing-box.$(date +%Y%m%d%H%M%S).$(current_sing_box_version_label)"
  BACKUP_SING_BOX_BIN="/etc/sbm/sing-box-backups/$backup_name"
  sudo install -m 755 "$current_bin" "$BACKUP_SING_BOX_BIN"
  printf '已备份当前内核: %s\n' "$BACKUP_SING_BOX_BIN"
}

restart_sing_box_after_core_switch() {
  if ! has_cmd systemctl || ! sudo test -f /etc/sing-box/config.json; then
    return 0
  fi

  sudo systemctl restart sing-box
  sudo systemctl --no-pager --full status sing-box
}

switch_sing_box_binary() {
  new_bin=$1
  target_version=$2
  current_bin=$(sing_box_binary_path)

  section "检查新内核"
  "$new_bin" version 2>/dev/null | head -n 1 || {
    printf '%s新内核无法执行。%s\n' "$C_RED" "$C_RESET"
    return 1
  }

  if sudo test -f /etc/sing-box/config.json; then
    if ! sudo "$new_bin" check -c /etc/sing-box/config.json; then
      printf '%s新内核不兼容当前配置，已取消切换。当前节点不受影响。%s\n' "$C_RED" "$C_RESET"
      return 1
    fi
  fi

  section "切换内核"
  backup_sing_box_binary "$current_bin"
  sudo install -d -m 755 "$(dirname "$current_bin")"
  sudo install -m 755 "$new_bin" "$current_bin"
  printf '已安装 sing-box 内核到: %s\n' "$current_bin"

  if ! restart_sing_box_after_core_switch; then
    printf '%s新内核重启失败，正在回滚。%s\n' "$C_RED" "$C_RESET"
    if [ -n "${BACKUP_SING_BOX_BIN:-}" ] && sudo test -f "$BACKUP_SING_BOX_BIN"; then
      sudo install -m 755 "$BACKUP_SING_BOX_BIN" "$current_bin"
      restart_sing_box_after_core_switch || true
    fi
    return 1
  fi

  printf '%s切换完成:%s %s\n' "$C_GREEN" "$C_RESET" "$target_version"
}

upgrade_sing_box_latest() {
  header
  section "升级到最新 sing-box 内核"
  ensure_sing_box_core_tools || return 1
  latest_version=$(latest_sing_box_version)
  if [ -z "$latest_version" ]; then
    printf '%s无法获取最新版本号。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  printf '最新版本: %s\n' "$latest_version"
  download_sing_box_binary "$latest_version" || return 1
  switch_sing_box_binary "$DOWNLOADED_SING_BOX_BIN" "$latest_version"
  rm -rf "$DOWNLOADED_SING_BOX_DIR"
}

switch_sing_box_version() {
  header
  section "切换 sing-box 指定版本"
  ensure_sing_box_core_tools || return 1
  printf '请输入版本号，例如 1.13.12 或 v1.13.12: '
  read -r target_version
  target_version=${target_version#v}
  if [ -z "$target_version" ]; then
    printf '%s版本号不能为空。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  download_sing_box_binary "$target_version" || return 1
  switch_sing_box_binary "$DOWNLOADED_SING_BOX_BIN" "$target_version"
  rm -rf "$DOWNLOADED_SING_BOX_DIR"
}

rollback_sing_box_core() {
  header
  section "回滚 sing-box 内核"
  backups=$(sudo find /etc/sbm/sing-box-backups -type f -name 'sing-box.*' 2>/dev/null | sort -r || true)
  if [ -z "$backups" ]; then
    printf '%s暂无可回滚的内核备份。%s\n' "$C_YELLOW" "$C_RESET"
    return 1
  fi

  printf '可用备份:\n'
  i=1
  printf '%s\n' "$backups" | while read -r backup; do
    printf '%s. %s\n' "$i" "$backup"
    i=$((i + 1))
  done
  printf '请选择备份序号 [默认: 1]: '
  read -r backup_choice
  backup_choice=${backup_choice:-1}
  selected_backup=$(printf '%s\n' "$backups" | sed -n "${backup_choice}p")
  if [ -z "$selected_backup" ]; then
    printf '%s选择无效: %s%s\n' "$C_RED" "$backup_choice" "$C_RESET"
    return 1
  fi

  switch_sing_box_binary "$selected_backup" "rollback"
}

show_sing_box_core_status() {
  header
  section "sing-box 内核状态"
  if has_cmd sing-box; then
    printf '当前版本: %s\n' "$(sing-box version 2>/dev/null | head -n 1)"
    printf '二进制:   %s\n' "$(sing_box_binary_path)"
  else
    printf '%s未检测到 sing-box。%s\n' "$C_YELLOW" "$C_RESET"
  fi

  if has_cmd systemctl; then
    printf '\n服务状态:\n'
    systemctl --no-pager --full status sing-box 2>/dev/null || true
  fi
}

manage_sing_box_core() {
  while true; do
    header
    printf '%s  Sing-Box 内核管理%s\n' "$C_TITLE" "$C_RESET"
    menu_item 1 "查看当前内核状态"
    menu_item 2 "升级到最新内核"
    menu_item 3 "切换指定版本"
    menu_item 4 "回滚到备份内核"
    menu_exit_item 0 "返回主菜单"
    printf '%s请选择功能 [默认: 1]:%s ' "$C_YELLOW" "$C_RESET"
    if ! read -r core_choice; then
      return
    fi
    core_choice=${core_choice:-1}
    case "$core_choice" in
      1) show_sing_box_core_status; pause ;;
      2) upgrade_sing_box_latest; pause ;;
      3) switch_sing_box_version; pause ;;
      4) rollback_sing_box_core; pause ;;
      0) return ;;
      *) printf '\n无效选项: %s\n' "$core_choice"; pause ;;
    esac
  done
}

get_public_ip() {
  if ! has_cmd curl; then
    printf '服务器IP'
    return
  fi

  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null ||
    curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null ||
    printf '服务器IP'
}

install_docker() {
  header
  section "一键安装 Docker"
  printf '将按官方 apt 仓库方式安装 Docker Engine、Buildx 和 Compose 插件。\n'
  printf '是否继续？[Y/n]: '
  read -r docker_choice
  docker_choice=${docker_choice:-Y}
  case "$docker_choice" in
    Y|y|yes|YES) ;;
    *) printf '已取消。\n'; return 0 ;;
  esac

  if ! has_cmd apt-get; then
    printf '%s当前 Docker 安装功能暂只支持 apt-get 系统。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  . /etc/os-release
  docker_os_id=${ID:-}
  case "$docker_os_id" in
    ubuntu|debian) ;;
    *)
      printf '%s当前系统不是 Ubuntu/Debian，已取消。%s\n' "$C_RED" "$C_RESET"
      return 1
      ;;
  esac

  docker_codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
  if [ -z "$docker_codename" ]; then
    printf '%s无法识别系统版本代号，已取消。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  sudo apt-get remove -y docker.io docker-compose docker-doc podman-docker containerd runc 2>/dev/null || true
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL "https://download.docker.com/linux/${docker_os_id}/gpg" -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  tmp_docker_source=$(mktemp)
  cat >"$tmp_docker_source" <<EOF
Types: deb
URIs: https://download.docker.com/linux/${docker_os_id}
Suites: ${docker_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  sudo install -m 644 "$tmp_docker_source" /etc/apt/sources.list.d/docker.sources
  rm -f "$tmp_docker_source"

  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  if has_cmd systemctl; then
    sudo systemctl enable docker
    sudo systemctl restart docker
  fi

  if getent group docker >/dev/null 2>&1; then
    sudo usermod -aG docker "$USER" 2>/dev/null || true
  fi

  section "Docker 状态"
  docker --version
  docker compose version 2>/dev/null || true
  printf '%sDocker 安装完成。若刚加入 docker 用户组，请重新登录后再免 sudo 使用 docker。%s\n' "$C_GREEN" "$C_RESET"
}

enable_bbr_acceleration() {
  header
  section "开启 BBR 加速"
  if [ ! -d /proc/sys/net/ipv4 ]; then
    printf '%s当前环境不支持 Linux sysctl 网络参数。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)
  current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)
  if [ "$current_cc" = "bbr" ] && [ "$current_qdisc" = "fq" ]; then
    printf '%s系统已开启 BBR + FQ，无需重复开启。%s\n' "$C_GREEN" "$C_RESET"
    section "当前状态"
    printf '拥塞控制算法: %s%s%s\n' "$C_GREEN" "$current_cc" "$C_RESET"
    printf '默认队列算法: %s%s%s\n' "$C_GREEN" "$current_qdisc" "$C_RESET"
    return 0
  fi

  sudo tee /etc/sysctl.d/99-sbm-bbr.conf >/dev/null <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sudo sysctl --system

  section "当前状态"
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)
  current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)
  printf '拥塞控制算法: %s\n' "$current_cc"
  printf '默认队列算法: %s\n' "$current_qdisc"
  if [ "$current_cc" = "bbr" ]; then
    printf 'BBR 状态: %s已开启%s\n' "$C_GREEN" "$C_RESET"
  else
    printf 'BBR 状态: %s未开启，请检查当前内核是否支持 BBR。%s\n' "$C_RED" "$C_RESET"
  fi
}

cert_profile_dir() {
  case "$1" in
    four) printf '%s' "$FOUR_CERT_DIR" ;;
    cloudflare) printf '%s' "$CF_CERT_DIR" ;;
    *) printf '%s未知证书配置: %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; return 1 ;;
  esac
}

cert_profile_key() {
  case "$1" in
    four) printf 'FOUR_CERT_DOMAIN' ;;
    cloudflare) printf 'CF_CERT_DOMAIN' ;;
    *) return 1 ;;
  esac
}

certificate_primary_domain() {
  cert_name=$1
  cert_path="/etc/letsencrypt/live/$cert_name/fullchain.pem"
  if ! has_cmd openssl || ! sudo test -f "$cert_path"; then
    return 1
  fi

  cert_domain=$(sudo openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null |
    tr ',' '\n' |
    sed -n 's/^[[:space:]]*DNS:\([^[:space:]]*\).*$/\1/p' |
    sed '/^\*\./d' |
    head -n 1)
  if [ -z "$cert_domain" ]; then
    cert_domain=$(sudo openssl x509 -in "$cert_path" -noout -subject 2>/dev/null |
      sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,\/]*\).*/\1/p' |
      head -n 1)
  fi
  case "$cert_domain" in
    \*.*) return 1 ;;
  esac
  if ! is_valid_domain "$cert_domain"; then
    return 1
  fi
  printf '%s' "$cert_domain"
}

save_cert_assignment() {
  cert_profile=$1
  cert_name=$2
  assignment_key=$(cert_profile_key "$cert_profile") || return 1
  sudo install -d -m 700 "$SBM_DIR" || return 1
  tmp_assignments=$(mktemp)
  if sudo test -f "$SBM_CERT_ASSIGNMENTS"; then
    if ! sudo awk -v key="$assignment_key" -F= '$1 != key {print}' "$SBM_CERT_ASSIGNMENTS" >"$tmp_assignments"; then
      rm -f "$tmp_assignments"
      return 1
    fi
  fi
  printf '%s=%s\n' "$assignment_key" "$cert_name" >>"$tmp_assignments"
  if ! sudo install -m 600 "$tmp_assignments" "$SBM_CERT_ASSIGNMENTS"; then
    rm -f "$tmp_assignments"
    return 1
  fi
  rm -f "$tmp_assignments"
}

commit_pending_cert_assignment() {
  if [ -z "$PENDING_CERT_PROFILE" ] || [ -z "$PENDING_CERT_NAME" ]; then
    return 0
  fi
  save_cert_assignment "$PENDING_CERT_PROFILE" "$PENDING_CERT_NAME" || return 1
  PENDING_CERT_PROFILE=""
  PENDING_CERT_NAME=""
  PENDING_CERT_SNI=""
}

discard_pending_cert_assignment() {
  PENDING_CERT_PROFILE=""
  PENDING_CERT_NAME=""
  PENDING_CERT_SNI=""
}

get_cert_assignment() {
  cert_profile=$1
  assignment_key=$(cert_profile_key "$cert_profile") || return 1
  if sudo test -f "$SBM_CERT_ASSIGNMENTS"; then
    sudo awk -F= -v key="$assignment_key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$SBM_CERT_ASSIGNMENTS"
  fi
}

get_saved_profile_cert_domain() {
  cert_profile=$1
  assigned_domain=$(get_cert_assignment "$cert_profile")
  case "$assigned_domain" in
    ""|self-signed:*|manual:*) ;;
    *) printf '%s' "$assigned_domain"; return ;;
  esac

  if ! sudo test -f "$SBM_NODE_LINKS"; then
    return
  fi
  case "$cert_profile" in
    four)
      sudo awk -F= '
        /^FOUR_TLS_SNI=/ {print $2; found=1; exit}
        /^TLS_SNI=/ {legacy=$2}
        END {if (!found && legacy != "") print legacy}
      ' "$SBM_NODE_LINKS"
      ;;
    cloudflare)
      sudo awk -F= '/^CF_TLS_SNI=/ {print $2; exit}' "$SBM_NODE_LINKS"
      ;;
  esac
}

cert_domain_is_in_use_by_other_profile() {
  cert_name=$1
  current_profile=$2
  cert_sni=$(certificate_primary_domain "$cert_name" 2>/dev/null || true)
  for checked_profile in four cloudflare; do
    [ "$checked_profile" = "$current_profile" ] && continue
    profile_domain=$(get_saved_profile_cert_domain "$checked_profile")
    if [ "$profile_domain" = "$cert_name" ] ||
      { [ -n "$cert_sni" ] && [ "$profile_domain" = "$cert_sni" ]; }; then
      return 0
    fi
  done
  return 1
}

list_local_letsencrypt_domains() {
  if ! sudo test -d /etc/letsencrypt/live; then
    return
  fi
  sudo find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    sed 's#^.*/##' |
    grep -v '^README$'
}

list_unused_letsencrypt_domains() {
  cert_profile=${1:-}
  list_local_letsencrypt_domains |
    while read -r cert_domain; do
      [ -n "$cert_domain" ] || continue
      if ! cert_domain_is_in_use_by_other_profile "$cert_domain" "$cert_profile" &&
        sudo test -f "/etc/letsencrypt/live/$cert_domain/fullchain.pem" &&
        sudo test -f "/etc/letsencrypt/live/$cert_domain/privkey.pem" &&
        certificate_primary_domain "$cert_domain" >/dev/null 2>&1; then
        printf '%s\n' "$cert_domain"
      fi
    done
}

select_unused_letsencrypt_domain() {
  cert_profile=${1:-}
  local_domains=$(list_local_letsencrypt_domains)
  local_domain_count=$(printf '%s\n' "$local_domains" | sed '/^$/d' | wc -l)
  if [ "$local_domain_count" -eq 0 ]; then
    printf '本机 /etc/letsencrypt/live 中未发现证书。\n'
    return 2
  fi

  printf '已扫描 /etc/letsencrypt/live，共发现 %s 张证书。\n' "$local_domain_count"
  domains=$(list_unused_letsencrypt_domains "$cert_profile")
  domain_count=$(printf '%s\n' "$domains" | sed '/^$/d' | wc -l)
  if [ "$domain_count" -eq 0 ]; then
    printf '%s发现的证书均不可用于当前部署:%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s\n' "$local_domains" | sed '/^$/d' | while read -r cert_domain; do
      if cert_domain_is_in_use_by_other_profile "$cert_domain" "$cert_profile"; then
        printf '  - %s: 已被另一类节点占用\n' "$cert_domain"
      elif ! sudo test -f "/etc/letsencrypt/live/$cert_domain/fullchain.pem" ||
        ! sudo test -f "/etc/letsencrypt/live/$cert_domain/privkey.pem"; then
        printf '  - %s: fullchain.pem 或 privkey.pem 缺失\n' "$cert_domain"
      elif ! certificate_primary_domain "$cert_domain" >/dev/null 2>&1; then
        printf '  - %s: 无法从证书读取可直接使用的域名/SNI\n' "$cert_domain"
      fi
    done
    return 2
  fi

  printf '检测到以下可用证书（未被另一类节点占用）:\n'
  i=1
  printf '%s\n' "$domains" | sed '/^$/d' | while read -r domain; do
    display_domain=$(certificate_primary_domain "$domain")
    if sudo test -f "/etc/letsencrypt/renewal/$domain.conf"; then
      renew_status="已配置自动续期"
    else
      renew_status="部署时补建自动续期配置"
    fi
    printf '%s. %s (证书域名: %s) [%s]\n' "$i" "$domain" "$display_domain" "$renew_status"
    i=$((i + 1))
  done
  printf '请选择证书序号 [默认: 1]: '
  read -r domain_choice
  domain_choice=${domain_choice:-1}
  if ! printf '%s' "$domain_choice" | grep -Eq '^[0-9]+$'; then
    printf '%s选择无效: %s%s\n' "$C_RED" "$domain_choice" "$C_RESET"
    return 1
  fi
  SELECTED_DOMAIN=$(printf '%s\n' "$domains" | sed '/^$/d' | sed -n "${domain_choice}p")
  if [ -z "$SELECTED_DOMAIN" ]; then
    printf '%s选择无效: %s%s\n' "$C_RED" "$domain_choice" "$C_RESET"
    return 1
  fi
}

ensure_self_signed_cert() {
  cert_profile=$1
  cert_sni=$2
  cert_dir=$(cert_profile_dir "$cert_profile") || return 1
  if ! has_cmd openssl; then
    printf '未检测到 openssl，正在安装 openssl...\n'
    sudo apt-get update || return 1
    sudo apt-get install -y openssl || return 1
  fi

  sudo install -d -m 755 "$cert_dir" || return 1
  if sudo test -s "$cert_dir/server.crt" && sudo test -s "$cert_dir/server.key"; then
    PENDING_CERT_PROFILE=$cert_profile
    PENDING_CERT_NAME="self-signed:$cert_sni"
    PENDING_CERT_SNI=$cert_sni
    return 0
  fi

  printf '正在生成自签名 TLS 证书...\n'
  if ! sudo openssl req -x509 -newkey ec \
    -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$cert_dir/server.key" \
    -out "$cert_dir/server.crt" \
    -days 3650 -nodes -subj "/CN=$cert_sni" >/dev/null 2>&1; then
    printf '%s自签名证书生成失败。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  sudo chmod 600 "$cert_dir/server.key" || return 1
  sudo chmod 644 "$cert_dir/server.crt" || return 1
  PENDING_CERT_PROFILE=$cert_profile
  PENDING_CERT_NAME="self-signed:$cert_sni"
  PENDING_CERT_SNI=$cert_sni
}

ensure_self_signed_renew_schedule() {
  if ! has_cmd systemctl; then
    printf '%s未检测到 systemctl，自签名证书已生成但无法安装自动重签定时器。%s\n' "$C_YELLOW" "$C_RESET"
    return 0
  fi

  tmp_script=$(mktemp)
  tmp_service=$(mktemp)
  tmp_timer=$(mktemp)
  cat >"$tmp_script" <<'EOF'
#!/usr/bin/env bash
set -e
ASSIGNMENTS="/etc/sbm/cert-assignments.conf"
CERT_DIR="/etc/sing-box/certs/four"
[ -f "$ASSIGNMENTS" ] || exit 0
assignment=$(awk -F= '$1 == "FOUR_CERT_DOMAIN" {sub(/^[^=]*=/, ""); print; exit}' "$ASSIGNMENTS")
case "$assignment" in
  self-signed:*) ;;
  *) exit 0 ;;
esac
sni=${assignment#self-signed:}
if [ -f "$CERT_DIR/server.crt" ] &&
  openssl x509 -checkend 2592000 -noout -in "$CERT_DIR/server.crt" >/dev/null 2>&1; then
  exit 0
fi
install -d -m 755 "$CERT_DIR"
openssl req -x509 -newkey ec \
  -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.crt" \
  -days 3650 -nodes -subj "/CN=$sni" >/dev/null 2>&1
chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"
systemctl restart sing-box
EOF
  cat >"$tmp_service" <<'EOF'
[Unit]
Description=Renew SBM self-signed certificate when needed

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sbm-renew-self-signed-cert
EOF
  cat >"$tmp_timer" <<'EOF'
[Unit]
Description=Check SBM self-signed certificate monthly

[Timer]
OnCalendar=monthly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if ! sudo install -m 755 "$tmp_script" /usr/local/sbin/sbm-renew-self-signed-cert ||
    ! sudo install -m 644 "$tmp_service" /etc/systemd/system/sbm-self-signed-renew.service ||
    ! sudo install -m 644 "$tmp_timer" /etc/systemd/system/sbm-self-signed-renew.timer; then
    rm -f "$tmp_script" "$tmp_service" "$tmp_timer"
    return 1
  fi
  rm -f "$tmp_script" "$tmp_service" "$tmp_timer"
  sudo systemctl daemon-reload || return 1
  sudo systemctl enable --now sbm-self-signed-renew.timer || return 1
  printf '%s已启用自签名证书自动检查/重签定时器。%s\n' "$C_GREEN" "$C_RESET"
}

update_saved_tls_sni() {
  cert_profile=$1
  new_sni=$2
  if ! sudo test -f "$SBM_NODE_LINKS"; then
    return 0
  fi

  case "$cert_profile" in
    four)
      old_sni=$(sudo awk -F= '
        /^FOUR_TLS_SNI=/ {sub(/^[^=]*=/, ""); print; found=1; exit}
        /^TLS_SNI=/ {legacy=$2}
        END {if (!found && legacy != "") print legacy}
      ' "$SBM_NODE_LINKS")
      ;;
    cloudflare)
      old_sni=$(sudo awk -F= '/^CF_TLS_SNI=/ {sub(/^[^=]*=/, ""); print; exit}' "$SBM_NODE_LINKS")
      ;;
    *) return 1 ;;
  esac
  if [ -z "$old_sni" ]; then
    return 0
  fi

  old_sni_enc=$(url_encode "$old_sni")
  new_sni_enc=$(url_encode "$new_sni")
  new_cf_vmess_link=""
  if [ "$cert_profile" = "cloudflare" ]; then
    cf_vmess_link=$(sudo awk '/^CF_VMESS=/ {sub(/^[^=]*=/, ""); print; exit}' "$SBM_NODE_LINKS")
    cf_payload=${cf_vmess_link#vmess://}
    cf_json=$(printf '%s' "$cf_payload" | base64_decode 2>/dev/null || true)
    cf_addr=$(printf '%s\n' "$cf_json" | json_get_string add)
    cf_port=$(printf '%s\n' "$cf_json" | json_get_string port)
    cf_uuid=$(printf '%s\n' "$cf_json" | json_get_string id)
    cf_path=$(printf '%s\n' "$cf_json" | json_get_string path)
    cf_name=$(printf '%s\n' "$cf_json" | json_get_string ps)
    cf_name=${cf_name:-$(node_display_name "VMess")}
    if [ -n "$cf_addr" ] && [ -n "$cf_port" ] && [ -n "$cf_uuid" ] && [ -n "$cf_path" ]; then
      new_cf_vmess_link=$(build_vmess_link "$cf_name" "$cf_addr" "$cf_port" "$cf_uuid" "$cf_path" "$new_sni")
    else
      printf '%s警告: 未能解析已保存的 CF VMess 链接，已保留原链接。%s\n' "$C_YELLOW" "$C_RESET"
    fi
  fi

  tmp_links=$(mktemp)
  sudo awk \
    -v profile="$cert_profile" \
    -v old_enc="$old_sni_enc" \
    -v new_enc="$new_sni_enc" \
    -v new_raw="$new_sni" \
    -v new_cf_vmess="$new_cf_vmess_link" '
      profile == "four" && /^FOUR_TLS_SNI=/ { print "FOUR_TLS_SNI=" new_raw; next }
      profile == "four" && /^TLS_SNI=/ { print "TLS_SNI=" new_raw; next }
      profile == "four" && /^(TUIC_V5|HYSTERIA2|ANYTLS)=/ {
        gsub("sni=" old_enc, "sni=" new_enc)
        gsub("&allow_insecure=1", "")
        gsub("&insecure=1", "")
        print
        next
      }
      profile == "cloudflare" && /^CF_TLS_SNI=/ { print "CF_TLS_SNI=" new_raw; next }
      profile == "cloudflare" && /^CF_VMESS=/ && new_cf_vmess != "" {
        print "CF_VMESS=" new_cf_vmess
        next
      }
      {
        print
      }
    ' "$SBM_NODE_LINKS" >"$tmp_links"
  sudo install -m 600 "$tmp_links" "$SBM_NODE_LINKS"
  sudo install -m 600 "$tmp_links" "$SBM_NODE_INFO"
  rm -f "$tmp_links"
}

install_certbot_if_needed() {
  if has_cmd certbot; then
    return 0
  fi

  if ! has_cmd apt-get; then
    printf '%s自动申请证书暂只支持 apt-get 系统。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  sudo apt-get update || return 1
  sudo apt-get install -y certbot || return 1
}

install_cloudflare_certbot_if_needed() {
  install_certbot_if_needed || return 1
  if certbot plugins 2>/dev/null | grep -q 'dns-cloudflare'; then
    return 0
  fi

  if ! has_cmd apt-get; then
    printf '%sCloudflare DNS 证书申请暂只支持 apt-get 系统。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  sudo apt-get update || return 1
  sudo apt-get install -y python3-certbot-dns-cloudflare || return 1
}

install_issued_cert() {
  cert_name=$1
  restart_mode=${2:-restart}
  cert_profile=${3:-four}
  cert_dir=$(cert_profile_dir "$cert_profile") || return 1
  cert_live_dir="/etc/letsencrypt/live/$cert_name"
  if ! sudo test -f "$cert_live_dir/fullchain.pem" || ! sudo test -f "$cert_live_dir/privkey.pem"; then
    printf '%s未找到申请后的证书文件: %s%s\n' "$C_RED" "$cert_live_dir" "$C_RESET"
    return 1
  fi
  cert_domain=$(certificate_primary_domain "$cert_name") || {
    printf '%s无法从证书中读取有效域名: %s%s\n' "$C_RED" "$cert_name" "$C_RESET"
    return 1
  }

  sudo install -d -m 755 "$cert_dir" || return 1
  sudo install -m 644 "$cert_live_dir/fullchain.pem" "$cert_dir/server.crt" || return 1
  sudo install -m 600 "$cert_live_dir/privkey.pem" "$cert_dir/server.key" || return 1

  TLS_SNI="$cert_domain"
  TLS_INSECURE=0
  SERVER_ADDR="$cert_domain"
  PENDING_CERT_PROFILE=$cert_profile
  PENDING_CERT_NAME=$cert_name
  PENDING_CERT_SNI=$cert_domain

  printf '%s证书已同步，节点启动成功后才会正式分配: %s (%s)%s\n' \
    "$C_GREEN" "$cert_name" "$cert_domain" "$C_RESET"

  if [ "$restart_mode" = "restart" ] && sudo test -f /etc/sing-box/config.json && has_cmd systemctl; then
    if ! sudo systemctl restart sing-box; then
      discard_pending_cert_assignment
      printf '%ssing-box 重启失败，证书未分配。%s\n' "$C_RED" "$C_RESET"
      return 1
    fi
    commit_pending_cert_assignment || return 1
    printf '%ssing-box 已重启，证书分配完成。%s\n' "$C_GREEN" "$C_RESET"
  fi
}

validate_letsencrypt_live_symlinks() {
  cert_domain=$1
  live_dir="/etc/letsencrypt/live/$cert_domain"
  broken_items=""

  for cert_file in cert.pem chain.pem fullchain.pem privkey.pem; do
    if ! sudo test -L "$live_dir/$cert_file"; then
      broken_items="${broken_items} $cert_file"
    fi
  done

  if [ -n "$broken_items" ]; then
    printf '%s检测到 certbot 证书结构异常:%s %s\n' "$C_RED" "$C_RESET" "$live_dir"
    printf '以下文件不是符号链接:%s\n' "$broken_items"
    printf 'certbot 续期要求 live 目录里的 pem 文件是指向 archive 目录的符号链接。\n'
    printf '请重新迁移完整 /etc/letsencrypt，并确保保留符号链接、archive 和 renewal 目录。\n'
    return 1
  fi
}

normalize_letsencrypt_certificate_layout() {
  cert_domain=$1
  live_dir="/etc/letsencrypt/live/$cert_domain"
  archive_dir="/etc/letsencrypt/archive/$cert_domain"
  needs_normalize=0

  if ! sudo test -f "$live_dir/fullchain.pem" || ! sudo test -f "$live_dir/privkey.pem"; then
    printf '%s证书文件缺失，至少需要 fullchain.pem 和 privkey.pem。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  if ! sudo test -f "$live_dir/cert.pem" || ! sudo test -f "$live_dir/chain.pem"; then
    tmp_fullchain=$(mktemp)
    tmp_cert=$(mktemp)
    tmp_chain=$(mktemp)
    sudo cat "$live_dir/fullchain.pem" >"$tmp_fullchain"
    awk '
      /-----BEGIN CERTIFICATE-----/ {count++}
      count == 1 {print}
      /-----END CERTIFICATE-----/ && count == 1 {exit}
    ' "$tmp_fullchain" >"$tmp_cert"
    awk '
      /-----BEGIN CERTIFICATE-----/ {count++}
      count >= 2 {print}
    ' "$tmp_fullchain" >"$tmp_chain"
    if [ ! -s "$tmp_cert" ] || [ ! -s "$tmp_chain" ]; then
      rm -f "$tmp_fullchain" "$tmp_cert" "$tmp_chain"
      printf '%s无法从 fullchain.pem 拆分站点证书和中间证书链。%s\n' "$C_RED" "$C_RESET"
      return 1
    fi
    sudo install -m 644 "$tmp_cert" "$live_dir/cert.pem"
    sudo install -m 644 "$tmp_chain" "$live_dir/chain.pem"
    rm -f "$tmp_fullchain" "$tmp_cert" "$tmp_chain"
  fi

  for cert_file in cert.pem chain.pem fullchain.pem privkey.pem; do
    if ! sudo test -f "$live_dir/$cert_file"; then
      printf '%s证书文件缺失，无法补建自动续期配置:%s %s/%s\n' \
        "$C_RED" "$C_RESET" "$live_dir" "$cert_file"
      return 1
    fi
    if ! sudo test -L "$live_dir/$cert_file"; then
      needs_normalize=1
    fi
  done

  if [ "$needs_normalize" -eq 0 ]; then
    return 0
  fi

  backup_dir="/etc/letsencrypt/sbm-backups/${cert_domain}-$(date +%Y%m%d%H%M%S)"
  sudo install -d -m 700 "$backup_dir"
  sudo cp -a "$live_dir/." "$backup_dir/"
  sudo install -d -m 700 "$archive_dir"

  cert_version=1
  while sudo test -e "$archive_dir/cert${cert_version}.pem" ||
    sudo test -e "$archive_dir/fullchain${cert_version}.pem"; do
    cert_version=$((cert_version + 1))
  done

  for cert_file in cert.pem chain.pem fullchain.pem privkey.pem; do
    if sudo test -L "$live_dir/$cert_file"; then
      continue
    fi
    cert_base=${cert_file%.pem}
    archive_file="${cert_base}${cert_version}.pem"
    file_mode=644
    [ "$cert_file" = "privkey.pem" ] && file_mode=600
    sudo install -m "$file_mode" "$live_dir/$cert_file" "$archive_dir/$archive_file"
    sudo rm -f "$live_dir/$cert_file"
    sudo ln -s "../../archive/$cert_domain/$archive_file" "$live_dir/$cert_file"
  done

  printf '%s已整理为 Certbot 标准证书结构，原文件备份在:%s %s\n' \
    "$C_GREEN" "$C_RESET" "$backup_dir"
}

get_certbot_account_id() {
  account_root="/etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory"
  certbot_account=$(sudo find "$account_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    sed 's#^.*/##' |
    head -n 1)
  if [ -n "$certbot_account" ]; then
    printf '%s' "$certbot_account"
    return 0
  fi

  printf '未检测到 Certbot ACME 账户，正在自动注册...\n' >&2
  sudo certbot register --non-interactive --agree-tos --register-unsafely-without-email >/dev/null ||
    return 1
  sudo find "$account_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    sed 's#^.*/##' |
    head -n 1
}

create_certbot_renewal_config() {
  cert_domain=$1
  renewal_conf="/etc/letsencrypt/renewal/$cert_domain.conf"
  renewal_backup=""

  if sudo test -f "$renewal_conf" &&
    sudo grep -Eqi 'authenticator[[:space:]]*=[[:space:]]*dns-cloudflare|dns_cloudflare_credentials' "$renewal_conf"; then
    return 0
  fi

  if sudo test -f "$renewal_conf"; then
    renewal_backup="${renewal_conf}.previous-backup.$(date +%Y%m%d%H%M%S)"
    sudo cp "$renewal_conf" "$renewal_backup"
    printf '证书 %s 当前不是 Cloudflare DNS 续期方式，正在转换。\n' "$cert_domain"
    printf '旧配置已备份: %s\n' "$renewal_backup"
  else
    printf '证书 %s 缺少 renewal 配置，正在使用 Cloudflare DNS 接管自动续期。\n' "$cert_domain"
  fi
  install_certbot_if_needed || return 1
  normalize_letsencrypt_certificate_layout "$cert_domain" || return 1

  certbot_account=$(get_certbot_account_id) || {
    printf '%sCertbot ACME 账户创建失败。%s\n' "$C_RED" "$C_RESET"
    return 1
  }
  if [ -z "$certbot_account" ]; then
    printf '%s未能获取 Certbot ACME 账户。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  install_cloudflare_certbot_if_needed || return 1
  printf '请输入用于续期 %s 的 Cloudflare API Token: ' "$cert_domain"
  read -rs cf_token
  printf '\n'
  if [ -z "$cf_token" ]; then
    printf '%sAPI Token 不能为空。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  cf_credentials="/etc/letsencrypt/cloudflare-${cert_domain}.ini"
  tmp_cf=$(mktemp)
  printf 'dns_cloudflare_api_token = %s\n' "$cf_token" >"$tmp_cf"
  if ! sudo install -m 600 "$tmp_cf" "$cf_credentials"; then
    rm -f "$tmp_cf"
    return 1
  fi
  rm -f "$tmp_cf"
  authenticator=dns-cloudflare
  renewal_extra=$(printf 'dns_cloudflare_credentials = %s\ndns_cloudflare_propagation_seconds = 60' "$cf_credentials")

  certbot_version=$(certbot --version 2>/dev/null | awk '{print $2}')
  certbot_version=${certbot_version:-unknown}
  tmp_renewal=$(mktemp)
  cat >"$tmp_renewal" <<EOF
version = $certbot_version
archive_dir = /etc/letsencrypt/archive/$cert_domain
cert = /etc/letsencrypt/live/$cert_domain/cert.pem
privkey = /etc/letsencrypt/live/$cert_domain/privkey.pem
chain = /etc/letsencrypt/live/$cert_domain/chain.pem
fullchain = /etc/letsencrypt/live/$cert_domain/fullchain.pem

[renewalparams]
account = $certbot_account
authenticator = $authenticator
server = https://acme-v02.api.letsencrypt.org/directory
${renewal_extra}
EOF
  if ! sudo install -d -m 755 /etc/letsencrypt/renewal ||
    ! sudo install -m 600 "$tmp_renewal" "$renewal_conf"; then
    rm -f "$tmp_renewal"
    return 1
  fi
  rm -f "$tmp_renewal"
  if ! sudo certbot certificates --cert-name "$cert_domain" >/dev/null 2>&1; then
    sudo rm -f "$renewal_conf"
    if [ -n "$renewal_backup" ]; then
      sudo cp "$renewal_backup" "$renewal_conf"
    fi
    printf '%sCertbot 无法解析生成的 renewal 配置，已撤销。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
  printf '%s已创建 Certbot renewal 配置:%s %s\n' "$C_GREEN" "$C_RESET" "$renewal_conf"
}

validate_certbot_managed_cert() {
  cert_domain=$1
  live_dir="/etc/letsencrypt/live/$cert_domain"
  renewal_conf="/etc/letsencrypt/renewal/$cert_domain.conf"

  if ! sudo test -f "$live_dir/fullchain.pem" || ! sudo test -f "$live_dir/privkey.pem"; then
    printf '%s未找到 certbot 管理的证书:%s %s\n' "$C_RED" "$C_RESET" "$live_dir"
    printf '请先使用 Cloudflare DNS 申请证书，或者完整迁移 /etc/letsencrypt。\n'
    return 1
  fi

  if ! sudo test -f "$renewal_conf"; then
    printf '%s未找到 certbot renewal 配置:%s %s\n' "$C_RED" "$C_RESET" "$renewal_conf"
    printf '没有 renewal 配置时 certbot.timer 不会自动续期这个域名。\n'
    printf '请先使用 Cloudflare DNS 申请证书，或者完整迁移 /etc/letsencrypt。\n'
    return 1
  fi

  validate_letsencrypt_live_symlinks "$cert_domain"
}

ensure_certbot_renewal_dependencies() {
  cert_domain=$1
  renewal_conf="/etc/letsencrypt/renewal/$cert_domain.conf"
  if sudo grep -Eqi 'authenticator[[:space:]]*=[[:space:]]*dns-cloudflare|dns_cloudflare_credentials' "$renewal_conf"; then
    install_cloudflare_certbot_if_needed || return 1
    cf_credentials_path=$(sudo awk -F= '
      /dns_cloudflare_credentials/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        print $2
        exit
      }
    ' "$renewal_conf")
    if [ -z "$cf_credentials_path" ] || ! sudo test -f "$cf_credentials_path"; then
      printf '%sCloudflare 续期凭据不存在，无法保证自动续期:%s %s\n' \
        "$C_RED" "$C_RESET" "${cf_credentials_path:-未配置}"
      return 1
    fi
  fi
}

take_over_issued_cert() {
  cert_name=$1
  restart_mode=${2:-restart}
  cert_profile=${3:-four}

  create_certbot_renewal_config "$cert_name" "$cert_profile" || return 1
  validate_certbot_managed_cert "$cert_name" || return 1
  ensure_certbot_renewal_dependencies "$cert_name" || return 1
  install_issued_cert "$cert_name" "$restart_mode" "$cert_profile" || return 1
  write_cert_renew_hook || return 1
  ensure_certbot_renew_schedule || return 1

  section "证书接管完成"
  printf '证书名称: %s\n' "$cert_name"
  printf '证书域名: %s\n' "$TLS_SNI"
  printf '证书目录: /etc/letsencrypt/live/%s\n' "$cert_name"
  printf '同步目录: %s\n' "$(cert_profile_dir "$cert_profile")"
  printf '以后 certbot 续期成功后会自动同步证书并重启 sing-box。\n'
}

write_cert_renew_hook() {
  hook_path="/etc/letsencrypt/renewal-hooks/deploy/sbm-sync-sing-box.sh"
  tmp_hook=$(mktemp)
  cat >"$tmp_hook" <<'EOF'
#!/usr/bin/env bash
set -e
ASSIGNMENTS="/etc/sbm/cert-assignments.conf"
[ -f "$ASSIGNMENTS" ] || exit 0
[ -n "${RENEWED_LINEAGE:-}" ] || exit 0
renewed_name=${RENEWED_LINEAGE##*/}
synced=0

sync_profile() {
  key=$1
  target_dir=$2
  cert_name=$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$ASSIGNMENTS")
  case "$cert_name" in
    ""|self-signed:*) return 0 ;;
  esac
  [ "$cert_name" = "$renewed_name" ] || return 0
  live_dir="/etc/letsencrypt/live/$cert_name"
  [ -f "$live_dir/fullchain.pem" ] && [ -f "$live_dir/privkey.pem" ] || return 0
  install -d -m 755 "$target_dir"
  install -m 644 "$live_dir/fullchain.pem" "$target_dir/server.crt"
  install -m 600 "$live_dir/privkey.pem" "$target_dir/server.key"
  synced=1
}

sync_profile FOUR_CERT_DOMAIN /etc/sing-box/certs/four
sync_profile CF_CERT_DOMAIN /etc/sing-box/certs/cloudflare
if [ "$synced" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
  systemctl restart sing-box
fi
EOF
  if ! sudo install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy ||
    ! sudo install -m 755 "$tmp_hook" "$hook_path"; then
    rm -f "$tmp_hook"
    return 1
  fi
  rm -f "$tmp_hook"
  printf '%s已安装续期后同步 Hook:%s %s\n' "$C_GREEN" "$C_RESET" "$hook_path"
}

ensure_certbot_renew_schedule() {
  certbot_path=$(command -v certbot 2>/dev/null || printf /usr/bin/certbot)

  if has_cmd systemctl; then
    sudo systemctl daemon-reload || return 1
    if systemctl cat certbot.timer >/dev/null 2>&1 || systemctl list-unit-files certbot.timer 2>/dev/null | grep -q '^certbot.timer'; then
      if systemctl cat sbm-certbot-renew.timer >/dev/null 2>&1; then
        sudo systemctl disable --now sbm-certbot-renew.timer 2>/dev/null || true
        sudo rm -f /etc/systemd/system/sbm-certbot-renew.timer /etc/systemd/system/sbm-certbot-renew.service
        sudo systemctl daemon-reload
        printf '%s检测到原生 certbot.timer，已移除 sbm-certbot-renew.timer。%s\n' "$C_GREEN" "$C_RESET"
      fi
      sudo systemctl enable --now certbot.timer || return 1
      sudo systemctl --no-pager status certbot.timer || true
      return 0
    fi

    tmp_service=$(mktemp)
    tmp_timer=$(mktemp)
    cat >"$tmp_service" <<EOF
[Unit]
Description=SBM Certbot Renew
Documentation=man:certbot(1)

[Service]
Type=oneshot
ExecStart=${certbot_path} renew --quiet
EOF
    cat >"$tmp_timer" <<'EOF'
[Unit]
Description=Run SBM Certbot Renew Daily

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    if ! sudo install -m 644 "$tmp_service" /etc/systemd/system/sbm-certbot-renew.service ||
      ! sudo install -m 644 "$tmp_timer" /etc/systemd/system/sbm-certbot-renew.timer; then
      rm -f "$tmp_service" "$tmp_timer"
      return 1
    fi
    rm -f "$tmp_service" "$tmp_timer"
    sudo systemctl daemon-reload || return 1
    sudo systemctl enable --now sbm-certbot-renew.timer || return 1
    sudo systemctl --no-pager status sbm-certbot-renew.timer || true
    printf '%s未检测到 certbot.timer，已创建 sbm-certbot-renew.timer。%s\n' "$C_GREEN" "$C_RESET"
    return 0
  fi

  tmp_cron=$(mktemp)
  cat >"$tmp_cron" <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root ${certbot_path} renew --quiet
EOF
  if ! sudo install -m 644 "$tmp_cron" /etc/cron.d/sbm-certbot-renew; then
    rm -f "$tmp_cron"
    return 1
  fi
  rm -f "$tmp_cron"
  printf '%s未检测到 systemctl，已创建 /etc/cron.d/sbm-certbot-renew。%s\n' "$C_GREEN" "$C_RESET"
}

select_letsencrypt_domain() {
  domains=$(sudo find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's#^.*/##' | grep -v '^README$')
  domain_count=$(printf '%s\n' "$domains" | sed '/^$/d' | wc -l)

  if [ "$domain_count" -eq 0 ]; then
    printf '%s未在 /etc/letsencrypt/live 中找到证书域名。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  if [ "$domain_count" -eq 1 ]; then
    SELECTED_DOMAIN=$(printf '%s\n' "$domains" | sed '/^$/d' | head -n 1)
    printf '检测到证书域名: %s\n' "$SELECTED_DOMAIN"
    return 0
  fi

  printf '检测到多个证书域名:\n'
  i=1
  printf '%s\n' "$domains" | sed '/^$/d' | while read -r domain; do
    printf '%s. %s\n' "$i" "$domain"
    i=$((i + 1))
  done
  printf '请选择域名序号或输入域名 [默认: 1]: '
  read -r domain_choice
  domain_choice=${domain_choice:-1}
  if printf '%s' "$domain_choice" | grep -Eq '^[0-9]+$'; then
    SELECTED_DOMAIN=$(printf '%s\n' "$domains" | sed '/^$/d' | sed -n "${domain_choice}p")
  else
    SELECTED_DOMAIN=$domain_choice
  fi
  if [ -z "$SELECTED_DOMAIN" ]; then
    printf '%s选择无效: %s%s\n' "$C_RED" "$domain_choice" "$C_RESET"
    return 1
  fi
}

request_cloudflare_dns_cert() {
  restart_mode=${1:-restart}
  cert_profile=${2:-issue-only}
  header
  section "使用Cloudflare申请证书"
  printf '请输入 Cloudflare 托管的域名: '
  read -r cert_domain
  if ! is_valid_domain "$cert_domain"; then
    printf '%s域名格式无效: %s%s\n' "$C_RED" "$cert_domain" "$C_RESET"
    return 1
  fi

  printf '请输入 Cloudflare API Token: '
  read -rs cf_token
  printf '\n'
  if [ -z "$cf_token" ]; then
    printf '%sAPI Token 不能为空。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  printf '请输入邮箱 [可留空]: '
  read -r cert_email

  printf '%sToken 需要 Cloudflare 权限: Zone:DNS:Edit，建议只授权目标域名 Zone。%s\n' "$C_YELLOW" "$C_RESET"
  printf '是否开始申请证书？[Y/n]: '
  read -r cf_choice
  cf_choice=${cf_choice:-Y}
  case "$cf_choice" in
    Y|y|yes|YES) ;;
    *) printf '已取消申请证书。\n'; return 1 ;;
  esac

  install_cloudflare_certbot_if_needed || return 1

  sudo install -d -m 700 /etc/letsencrypt || return 1
  cf_credentials="/etc/letsencrypt/cloudflare-${cert_domain}.ini"
  tmp_cf=$(mktemp)
  printf 'dns_cloudflare_api_token = %s\n' "$cf_token" >"$tmp_cf"
  if ! sudo install -m 600 "$tmp_cf" "$cf_credentials"; then
    rm -f "$tmp_cf"
    return 1
  fi
  rm -f "$tmp_cf"

  certbot_ok=0
  if [ -n "$cert_email" ]; then
    sudo certbot certonly --dns-cloudflare \
      --dns-cloudflare-credentials "$cf_credentials" \
      --dns-cloudflare-propagation-seconds 60 \
      --cert-name "$cert_domain" \
      --non-interactive --agree-tos --no-eff-email \
      --email "$cert_email" -d "$cert_domain" || certbot_ok=$?
  else
    sudo certbot certonly --dns-cloudflare \
      --dns-cloudflare-credentials "$cf_credentials" \
      --dns-cloudflare-propagation-seconds 60 \
      --cert-name "$cert_domain" \
      --non-interactive --agree-tos \
      --register-unsafely-without-email -d "$cert_domain" || certbot_ok=$?
  fi

  if [ "$certbot_ok" -ne 0 ]; then
    printf '\n%sCloudflare DNS 证书申请失败。%s\n' "$C_RED" "$C_RESET"
    printf '请重点检查:\n'
    printf '1. 域名是否托管在 Cloudflare。\n'
    printf '2. API Token 是否有 Zone:DNS:Edit 权限。\n'
    printf '3. Token 是否授权了目标域名所在 Zone。\n'
    printf '4. 服务器时间和 DNS 解析是否正常。\n'
    printf '详细日志: /var/log/letsencrypt/letsencrypt.log\n'
    return 1
  fi

  if [ "$cert_profile" = "issue-only" ]; then
    ensure_certbot_renew_schedule || return 1
    section "证书申请完成"
    printf '域名: %s\n' "$cert_domain"
    printf '证书目录: /etc/letsencrypt/live/%s\n' "$cert_domain"
    printf '该证书未分配给任何节点，也未同步到 sing-box。\n'
    return 0
  fi

  take_over_issued_cert "$cert_domain" "$restart_mode" "$cert_profile"
}

backup_letsencrypt_certificates() {
  header
  section "打包 Let's Encrypt 证书"
  if ! sudo test -d /etc/letsencrypt; then
    printf '%s证书目录不存在: /etc/letsencrypt%s\n' "$C_RED" "$C_RESET"
    return 1
  fi

  backup_path="$PWD/letsencrypt.tar.gz"
  if sudo tar -czpf "$backup_path" /etc/letsencrypt; then
    sudo chown "$(id -u):$(id -g)" "$backup_path" || return 1
    chmod 600 "$backup_path" || return 1
    printf '%s证书已打包:%s %s\n' "$C_GREEN" "$C_RESET" "$backup_path"
  else
    printf '%s证书打包失败。%s\n' "$C_RED" "$C_RESET"
    return 1
  fi
}

prepare_existing_cert_for_profile() {
  cert_profile=$1
  select_unused_letsencrypt_domain "$cert_profile"
  select_status=$?
  if [ "$select_status" -ne 0 ]; then
    return "$select_status"
  fi
  cert_name=$SELECTED_DOMAIN
  take_over_issued_cert "$cert_name" no-restart "$cert_profile" || return 1
}

choose_four_node_tls_cert() {
  printf '%s四协议节点证书模式%s\n' "$C_TITLE" "$C_RESET"
  menu_item 1 "自签名部署"
  menu_item 2 "真实域名部署"
  printf '%s请选择部署方式 [默认: 1]:%s ' "$C_YELLOW" "$C_RESET"
  read -r cert_choice
  cert_choice=${cert_choice:-1}
  case "$cert_choice" in
    1)
      TLS_SNI=sbm.local
      TLS_INSECURE=1
      ensure_self_signed_cert four "$TLS_SNI" || return 1
      ensure_self_signed_renew_schedule || return 1
      ;;
    2)
      prepare_existing_cert_for_profile four
      prepare_status=$?
      if [ "$prepare_status" -eq 0 ]; then
        return 0
      fi
      if [ "$prepare_status" -ne 2 ]; then
        return 1
      fi
      printf '%s没有可用的未占用证书，进入 Cloudflare DNS 证书申请流程。%s\n' "$C_YELLOW" "$C_RESET"
      request_cloudflare_dns_cert no-restart four || return 1
      ;;
    *)
      printf '%s无效选项: %s%s\n' "$C_RED" "$cert_choice" "$C_RESET"
      return 1
      ;;
  esac
}

choose_cloudflare_tls_cert() {
  printf '%sCloudflare 节点证书准备%s\n' "$C_TITLE" "$C_RESET"
  prepare_existing_cert_for_profile cloudflare
  prepare_status=$?
  if [ "$prepare_status" -eq 0 ]; then
    return 0
  fi
  if [ "$prepare_status" -ne 2 ]; then
    return 1
  fi
  printf '%s没有可用的未占用证书，进入 Cloudflare DNS 证书申请流程。%s\n' "$C_YELLOW" "$C_RESET"
  request_cloudflare_dns_cert no-restart cloudflare || return 1
}

write_sing_box_config() {
  config_file=$1
  SING_BOX_CONFIG_BACKUP=""
  SING_BOX_CONFIG_HAD_EXISTING=0
  section "检查新配置"
  if ! sudo sing-box check -c "$config_file"; then
    rm -f "$config_file"
    printf '\n新配置检查失败，已保留现有 sing-box 配置。\n'
    return 1
  fi

  section "写入配置"
  if ! sudo install -d -m 755 /etc/sing-box; then
    rm -f "$config_file"
    return 1
  fi
  if sudo test -f /etc/sing-box/config.json; then
    backup_path="/etc/sing-box/config.json.bak.$(date +%Y%m%d%H%M%S)"
    if ! sudo cp /etc/sing-box/config.json "$backup_path"; then
      rm -f "$config_file"
      return 1
    fi
    SING_BOX_CONFIG_BACKUP=$backup_path
    SING_BOX_CONFIG_HAD_EXISTING=1
    printf '已备份旧配置: %s\n' "$backup_path"
  fi

  if ! sudo install -m 600 "$config_file" /etc/sing-box/config.json; then
    rm -f "$config_file"
    return 1
  fi
  rm -f "$config_file"
  printf '已写入配置: /etc/sing-box/config.json\n'
}

rollback_sing_box_config() {
  section "恢复旧配置"
  if [ "$SING_BOX_CONFIG_HAD_EXISTING" -eq 1 ] && [ -n "$SING_BOX_CONFIG_BACKUP" ]; then
    if sudo cp "$SING_BOX_CONFIG_BACKUP" /etc/sing-box/config.json; then
      printf '已恢复旧配置: %s\n' "$SING_BOX_CONFIG_BACKUP"
      if has_cmd systemctl; then
        sudo systemctl restart sing-box 2>/dev/null || true
      fi
    else
      printf '%s旧配置恢复失败，请手动恢复: %s%s\n' \
        "$C_RED" "$SING_BOX_CONFIG_BACKUP" "$C_RESET"
    fi
  else
    sudo rm -f /etc/sing-box/config.json
    if has_cmd systemctl; then
      sudo systemctl stop sing-box 2>/dev/null || true
    fi
    printf '首次部署失败，已移除无效配置。\n'
  fi
  discard_pending_cert_assignment
}

check_and_restart_sing_box() {
  section "复查配置"
  if ! sudo sing-box check -c /etc/sing-box/config.json; then
    printf '\n配置检查失败，正在恢复旧配置。\n'
    rollback_sing_box_config
    return 1
  fi

  section "启动服务"
  if has_cmd systemctl; then
    if ! sudo systemctl enable sing-box || ! sudo systemctl restart sing-box; then
      printf '%ssing-box 启动失败，正在恢复旧配置。%s\n' "$C_RED" "$C_RESET"
      sudo systemctl --no-pager --full status sing-box 2>/dev/null || true
      rollback_sing_box_config
      return 1
    fi
    if ! sudo systemctl is-active --quiet sing-box; then
      printf '%ssing-box 未处于运行状态，正在恢复旧配置。%s\n' "$C_RED" "$C_RESET"
      sudo systemctl --no-pager --full status sing-box 2>/dev/null || true
      rollback_sing_box_config
      return 1
    fi
    sudo systemctl --no-pager --full status sing-box || true
  else
    printf '未检测到 systemctl，可手动运行:\n'
    printf '  sudo sing-box run -c /etc/sing-box/config.json\n'
  fi
}

maybe_allow_four_node_ports() {
  printf '\n是否尝试用 ufw 放行四节点端口？[Y/n]: '
  read -r allow_choice
  allow_choice=${allow_choice:-Y}
  case "$allow_choice" in
    Y|y|yes|YES)
      if has_cmd ufw; then
        sudo ufw allow "$REALITY_PORT/tcp"
        sudo ufw allow "$TUIC_PORT/udp"
        sudo ufw allow "$HY2_PORT/udp"
        sudo ufw allow "$ANYTLS_PORT/tcp"
        sudo ufw status numbered
      else
        printf '未安装 ufw，已跳过防火墙放行。\n'
      fi
      ;;
    *) printf '已跳过防火墙放行。\n' ;;
  esac
}

ask_named_port() {
  label=$1
  default_port=$2
  printf '%s 端口 [默认: %s]: ' "$label" "$default_port"
  read -r port
  port=${port:-$default_port}
  if ! is_valid_port "$port"; then
    printf '\n端口无效: %s\n' "$port"
    return 1
  fi
  ASK_PORT_RESULT=$port
}

show_all_node_links() {
  if ! sudo test -f "$SBM_NODE_LINKS"; then
    printf '%s暂无节点信息，请先部署节点。%s\n' "$C_YELLOW" "$C_RESET"
    return 1
  fi

  sudo awk '/^(VLESS_REALITY|TUIC_V5|HYSTERIA2|ANYTLS|CF_VMESS)=/ {sub(/^[^=]*=/, ""); print}' "$SBM_NODE_LINKS"
}

deploy_four_sing_box_nodes() {
  header
  section "一键部署四个 sing-box 节点"
  printf '将同时部署以下四个节点:\n'
  printf '  1. Vless Reality\n'
  printf '  2. Tuic5\n'
  printf '  3. Hysteria2\n'
  printf '  4. Anytls\n'

  choose_four_node_tls_cert || return 1
  install_sing_box_if_needed || return 1

  if [ "${TLS_INSECURE:-1}" = "0" ]; then
    default_server_addr=$TLS_SNI
  else
    default_server_addr=$(get_public_ip)
  fi
  printf '服务器地址/IP [默认: %s]: ' "$default_server_addr"
  read -r SERVER_ADDR
  SERVER_ADDR=${SERVER_ADDR:-$default_server_addr}

  printf 'Reality 伪装域名/SNI [默认: www.microsoft.com]: '
  read -r REALITY_SNI
  REALITY_SNI=${REALITY_SNI:-www.microsoft.com}

  ask_named_port "Reality TCP" 443 || return 1
  REALITY_PORT=$ASK_PORT_RESULT
  ask_named_port "TUIC v5 UDP" 8443 || return 1
  TUIC_PORT=$ASK_PORT_RESULT
  ask_named_port "Hysteria2 UDP" 8444 || return 1
  HY2_PORT=$ASK_PORT_RESULT
  ask_named_port "AnyTLS TCP" 8445 || return 1
  ANYTLS_PORT=$ASK_PORT_RESULT

  REALITY_UUID=$(generate_uuid)
  REALITY_SHORT_ID=$(random_hex 8)
  REALITY_KEYPAIR=$(sing-box generate reality-keypair)
  REALITY_PRIVATE_KEY=$(printf '%s\n' "$REALITY_KEYPAIR" | awk -F: '/PrivateKey/ {gsub(/^[ \t]+/, "", $2); print $2}')
  REALITY_PUBLIC_KEY=$(printf '%s\n' "$REALITY_KEYPAIR" | awk -F: '/PublicKey/ {gsub(/^[ \t]+/, "", $2); print $2}')

  TUIC_UUID=$(generate_uuid)
  TUIC_PASSWORD=$(random_secret)
  HY2_PASSWORD=$(random_secret)
  HY2_OBFS_PASSWORD=$(random_secret)
  ANYTLS_PASSWORD=$(random_secret)

  REALITY_SNI_JSON=$(json_escape "$REALITY_SNI")
  TUIC_PASSWORD_JSON=$(json_escape "$TUIC_PASSWORD")
  HY2_PASSWORD_JSON=$(json_escape "$HY2_PASSWORD")
  HY2_OBFS_PASSWORD_JSON=$(json_escape "$HY2_OBFS_PASSWORD")
  ANYTLS_PASSWORD_JSON=$(json_escape "$ANYTLS_PASSWORD")

  tmp_config=$(mktemp)
  cat >"$tmp_config" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "name": "reality",
          "uuid": "$REALITY_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI_JSON",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SNI_JSON",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [
        {
          "name": "tuic",
          "uuid": "$TUIC_UUID",
          "password": "$TUIC_PASSWORD_JSON"
        }
      ],
      "congestion_control": "bbr",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/certs/four/server.crt",
        "key_path": "/etc/sing-box/certs/four/server.key"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "obfs": {
        "type": "salamander",
        "password": "$HY2_OBFS_PASSWORD_JSON"
      },
      "users": [
        {
          "name": "hy2",
          "password": "$HY2_PASSWORD_JSON"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/certs/four/server.crt",
        "key_path": "/etc/sing-box/certs/four/server.key"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $ANYTLS_PORT,
      "users": [
        {
          "name": "anytls",
          "password": "$ANYTLS_PASSWORD_JSON"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/sing-box/certs/four/server.crt",
        "key_path": "/etc/sing-box/certs/four/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  if sudo test -f /etc/sing-box/config.json &&
    sudo grep -q '"tag"[[:space:]]*:[[:space:]]*"cf-vmess-in"' /etc/sing-box/config.json; then
    if ! has_cmd jq; then
      printf '检测到已部署的优选 Cloudflare IP 节点，正在安装 jq 以保留其配置...\n'
      if ! has_cmd apt-get; then
        rm -f "$tmp_config"
        printf '%s缺少 jq，且当前系统不支持自动安装。%s\n' "$C_RED" "$C_RESET"
        return 1
      fi
      sudo apt-get update
      sudo apt-get install -y jq || {
        rm -f "$tmp_config"
        printf '%sjq 安装失败，已取消部署。%s\n' "$C_RED" "$C_RESET"
        return 1
      }
    fi
    old_config=$(mktemp)
    merged_config=$(mktemp)
    sudo cat /etc/sing-box/config.json >"$old_config"
    if ! jq --slurpfile old "$old_config" \
      '.inbounds += [$old[0].inbounds[] | select(.tag == "cf-vmess-in")]' \
      "$tmp_config" >"$merged_config"; then
      rm -f "$old_config" "$merged_config" "$tmp_config"
      printf '%s保留已有 Cloudflare 节点配置失败，已取消部署。%s\n' "$C_RED" "$C_RESET"
      return 1
    fi
    mv "$merged_config" "$tmp_config"
    rm -f "$old_config"
  fi

  write_sing_box_config "$tmp_config" || return 1
  check_and_restart_sing_box || return 1
  if ! commit_pending_cert_assignment; then
    printf '%s证书分配信息保存失败，正在恢复旧配置。%s\n' "$C_RED" "$C_RESET"
    rollback_sing_box_config
    return 1
  fi

  section "保存节点信息"
  sudo install -d -m 700 "$SBM_DIR" || return 1

  SERVER_ADDR_ENC=$(url_encode "$SERVER_ADDR")
  REALITY_SNI_ENC=$(url_encode "$REALITY_SNI")
  TLS_SNI_ENC=$(url_encode "$TLS_SNI")
  TUIC_PASSWORD_ENC=$(url_encode "$TUIC_PASSWORD")
  HY2_PASSWORD_ENC=$(url_encode "$HY2_PASSWORD")
  HY2_OBFS_PASSWORD_ENC=$(url_encode "$HY2_OBFS_PASSWORD")
  ANYTLS_PASSWORD_ENC=$(url_encode "$ANYTLS_PASSWORD")
  TUIC_INSECURE_PARAM=""
  HY2_INSECURE_PARAM=""
  ANYTLS_INSECURE_PARAM=""
  if [ "${TLS_INSECURE:-1}" = "1" ]; then
    TUIC_INSECURE_PARAM="&allow_insecure=1"
    HY2_INSECURE_PARAM="&insecure=1"
    ANYTLS_INSECURE_PARAM="&insecure=1"
  fi

  REALITY_NAME=$(node_display_name "Reality")
  TUIC_NAME=$(node_display_name "Tuic5")
  HY2_NAME=$(node_display_name "Hysteria2")
  ANYTLS_NAME=$(node_display_name "AnyTLS")
  REALITY_NAME_ENC=$(url_encode "$REALITY_NAME")
  TUIC_NAME_ENC=$(url_encode "$TUIC_NAME")
  HY2_NAME_ENC=$(url_encode "$HY2_NAME")
  ANYTLS_NAME_ENC=$(url_encode "$ANYTLS_NAME")

  VLESS_LINK="vless://${REALITY_UUID}@${SERVER_ADDR_ENC}:${REALITY_PORT}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SNI_ENC}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}#${REALITY_NAME_ENC}"
  TUIC_LINK="tuic://${TUIC_UUID}:${TUIC_PASSWORD_ENC}@${SERVER_ADDR_ENC}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${TLS_SNI_ENC}${TUIC_INSECURE_PARAM}#${TUIC_NAME_ENC}"
  HY2_LINK="hysteria2://${HY2_PASSWORD_ENC}@${SERVER_ADDR_ENC}:${HY2_PORT}?sni=${TLS_SNI_ENC}${HY2_INSECURE_PARAM}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD_ENC}#${HY2_NAME_ENC}"
  ANYTLS_LINK="anytls://${ANYTLS_PASSWORD_ENC}@${SERVER_ADDR_ENC}:${ANYTLS_PORT}?security=tls&sni=${TLS_SNI_ENC}${ANYTLS_INSECURE_PARAM}#${ANYTLS_NAME_ENC}"

  tmp_info=$(mktemp)
  cat >"$tmp_info" <<EOF
SERVER_ADDR=$SERVER_ADDR
TLS_SNI=$TLS_SNI
FOUR_TLS_SNI=$TLS_SNI
REALITY_SNI=$REALITY_SNI

VLESS_REALITY=$VLESS_LINK
TUIC_V5=$TUIC_LINK
HYSTERIA2=$HY2_LINK
ANYTLS=$ANYTLS_LINK
EOF
  if sudo test -f "$SBM_NODE_LINKS"; then
    sudo awk '/^(CF_TLS_SNI|CF_VMESS_ADDR|CF_VMESS_PORT|CF_VMESS_UUID|CF_VMESS_PATH|CF_VMESS_NAME|CF_VMESS)=/' \
      "$SBM_NODE_LINKS" >>"$tmp_info"
  fi
  if ! sudo install -m 600 "$tmp_info" "$SBM_NODE_LINKS" ||
    ! sudo install -m 600 "$tmp_info" "$SBM_NODE_INFO"; then
    rm -f "$tmp_info"
    return 1
  fi
  rm -f "$tmp_info"
  printf '已保存节点信息: %s\n' "$SBM_NODE_LINKS"

  maybe_allow_four_node_ports
  show_all_node_links
}

deploy_cloudflare_ip_node() {
  header
  section "优选Cloudflare IP节点"
  printf '此功能部署 VMess+WebSocket+TLS，并通过 Cloudflare 橘色云代理实现 CDN 加速。\n'
  printf '%s部署前必须把节点域名托管到 Cloudflare，并开启橘色云代理。%s\n' "$C_YELLOW" "$C_RESET"

  choose_cloudflare_tls_cert || return 1
  install_sing_box_if_needed || return 1

  printf '请确认域名 %s 已开启 Cloudflare 橘色云代理 [y/N]: ' "$TLS_SNI"
  read -r cf_proxy_confirm
  case "$cf_proxy_confirm" in
    Y|y|yes|YES) ;;
    *)
      discard_pending_cert_assignment
      printf '已取消部署。请开启橘色云后重试。\n'
      return 0
      ;;
  esac

  ask_named_port "CF VMess TCP" 2053 || return 1
  CF_VMESS_PORT=$ASK_PORT_RESULT
  printf 'Cloudflare 优选 IP [默认: 104.16.0.1]: '
  read -r CF_VMESS_ADDR
  CF_VMESS_ADDR=${CF_VMESS_ADDR:-104.16.0.1}
  default_vmess_path="/$(random_hex 8)"
  printf 'WebSocket 路径 [默认: %s]: ' "$default_vmess_path"
  read -r CF_VMESS_PATH
  CF_VMESS_PATH=${CF_VMESS_PATH:-$default_vmess_path}
  case "$CF_VMESS_PATH" in
    /*) ;;
    *) CF_VMESS_PATH="/$CF_VMESS_PATH" ;;
  esac

  CF_VMESS_UUID=$(generate_uuid)
  CF_VMESS_NAME=$(node_display_name "Cloudflare")
  TLS_SNI_JSON=$(json_escape "$TLS_SNI")
  CF_VMESS_PATH_JSON=$(json_escape "$CF_VMESS_PATH")

  tmp_inbound=$(mktemp)
  cat >"$tmp_inbound" <<EOF
{
  "type": "vmess",
  "tag": "cf-vmess-in",
  "listen": "::",
  "listen_port": $CF_VMESS_PORT,
  "users": [
    {
      "name": "cf-vmess",
      "uuid": "$CF_VMESS_UUID",
      "alterId": 0
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$TLS_SNI_JSON",
    "certificate_path": "/etc/sing-box/certs/cloudflare/server.crt",
    "key_path": "/etc/sing-box/certs/cloudflare/server.key"
  },
  "transport": {
    "type": "ws",
    "path": "$CF_VMESS_PATH_JSON"
  }
}
EOF

  if ! has_cmd jq; then
    if ! has_cmd apt-get; then
      rm -f "$tmp_inbound"
      printf '%s缺少 jq，且当前系统不支持自动安装。%s\n' "$C_RED" "$C_RESET"
      return 1
    fi
    sudo apt-get update
    sudo apt-get install -y jq || {
      rm -f "$tmp_inbound"
      printf '%sjq 安装失败，已取消部署。%s\n' "$C_RED" "$C_RESET"
      return 1
    }
  fi

  tmp_config=$(mktemp)
  if sudo test -f /etc/sing-box/config.json; then
    old_config=$(mktemp)
    sudo cat /etc/sing-box/config.json >"$old_config"
    if ! jq --slurpfile inbound "$tmp_inbound" \
      '.inbounds = (((.inbounds // []) | map(select(.tag != "cf-vmess-in"))) + [$inbound[0]]) |
       .outbounds = (.outbounds // [{"type":"direct","tag":"direct"}])' \
      "$old_config" >"$tmp_config"; then
      rm -f "$tmp_inbound" "$old_config" "$tmp_config"
      printf '%s合并 Cloudflare 节点配置失败。%s\n' "$C_RED" "$C_RESET"
      return 1
    fi
    rm -f "$old_config"
  else
    jq -n --slurpfile inbound "$tmp_inbound" \
      '{"log":{"level":"info","timestamp":true},"inbounds":[$inbound[0]],"outbounds":[{"type":"direct","tag":"direct"}]}' \
      >"$tmp_config"
  fi
  rm -f "$tmp_inbound"

  write_sing_box_config "$tmp_config" || return 1
  check_and_restart_sing_box || return 1
  if ! commit_pending_cert_assignment; then
    printf '%s证书分配信息保存失败，正在恢复旧配置。%s\n' "$C_RED" "$C_RESET"
    rollback_sing_box_config
    return 1
  fi

  CF_VMESS_LINK=$(build_vmess_link "$CF_VMESS_NAME" "$CF_VMESS_ADDR" "$CF_VMESS_PORT" "$CF_VMESS_UUID" "$CF_VMESS_PATH" "$TLS_SNI")
  tmp_info=$(mktemp)
  if sudo test -f "$SBM_NODE_LINKS"; then
    sudo awk '!/^(CF_TLS_SNI|CF_VMESS_ADDR|CF_VMESS_PORT|CF_VMESS_UUID|CF_VMESS_PATH|CF_VMESS_NAME|CF_VMESS)=/' \
      "$SBM_NODE_LINKS" >"$tmp_info"
  fi
  cat >>"$tmp_info" <<EOF
CF_TLS_SNI=$TLS_SNI
CF_VMESS_ADDR=$CF_VMESS_ADDR
CF_VMESS_PORT=$CF_VMESS_PORT
CF_VMESS_UUID=$CF_VMESS_UUID
CF_VMESS_PATH=$CF_VMESS_PATH
CF_VMESS_NAME=$CF_VMESS_NAME
CF_VMESS=$CF_VMESS_LINK
EOF
  if ! sudo install -d -m 700 "$SBM_DIR" ||
    ! sudo install -m 600 "$tmp_info" "$SBM_NODE_LINKS" ||
    ! sudo install -m 600 "$tmp_info" "$SBM_NODE_INFO"; then
    rm -f "$tmp_info"
    return 1
  fi
  rm -f "$tmp_info"

  if has_cmd ufw; then
    printf '是否用 ufw 放行 %s/tcp？[Y/n]: ' "$CF_VMESS_PORT"
    read -r allow_cf_port
    allow_cf_port=${allow_cf_port:-Y}
    case "$allow_cf_port" in
      Y|y|yes|YES) sudo ufw allow "$CF_VMESS_PORT/tcp" ;;
      *) printf '已跳过 ufw 放行。\n' ;;
    esac
  fi

  section "Cloudflare 节点链接"
  printf '%s\n' "$CF_VMESS_LINK"
}

view_sing_box_nodes() {
  header
  show_all_node_links
}

purge_sing_box_nodes() {
  header
  section "Purge sing-box 节点"
  printf '此操作将停止 sing-box，并删除脚本生成的配置、证书和节点信息。\n'
  printf '是否继续？[y/N]: '
  read -r purge_choice
  case "$purge_choice" in
    Y|y|yes|YES) ;;
    *) printf '已取消 purge。\n'; return 0 ;;
  esac

  if has_cmd systemctl; then
    sudo systemctl stop sing-box 2>/dev/null || true
    sudo systemctl disable sing-box 2>/dev/null || true
  fi

  sudo rm -f /etc/sing-box/config.json
  sudo rm -f /etc/sing-box/config.json.bak.*
  sudo rm -rf /etc/sing-box/certs
  sudo rm -f "$SBM_NODE_LINKS" "$SBM_NODE_INFO" "$SBM_CERT_ASSIGNMENTS"
  if has_cmd systemctl; then
    sudo systemctl disable --now sbm-self-signed-renew.timer 2>/dev/null || true
  fi

  printf '已删除节点配置和节点信息。sing-box 内核本身未卸载，可直接重新部署。\n'
}

deploy_sing_box_proxy() {
  while true; do
    header
    menu_item 1 "部署四协议节点"
    menu_item 2 "查看所有节点信息"
    menu_item 3 "Purge所有节点"
    menu_item 4 "开启BBR加速"
    menu_item 5 "申请CloudflareDNS证书"
    menu_item 6 "打包证书"
    menu_exit_item 0 "返回上级菜单"
    printf '%s请选择功能 [默认: 1]:%s ' "$C_YELLOW" "$C_RESET"
    if ! read -r sing_box_choice; then
      return
    fi
    sing_box_choice=${sing_box_choice:-1}
    case "$sing_box_choice" in
      1) deploy_four_sing_box_nodes; pause ;;
      2) view_sing_box_nodes; pause ;;
      3) purge_sing_box_nodes; pause ;;
      4) enable_bbr_acceleration; pause ;;
      5) request_cloudflare_dns_cert; pause ;;
      6) backup_letsencrypt_certificates; pause ;;
      0) return ;;
      *) printf '\n无效选项: %s\n' "$sing_box_choice"; pause ;;
    esac
  done
}

show_menu() {
  header
  menu_item 1 "部署Sing-Box节点"
  menu_item 2 "部署Cloudflare优选IP节点"
  menu_item 3 "管理Sing-Box内核"
  menu_item 4 "安装Docker"
  menu_item 5 "查看基本系统信息"
  menu_item 6 "使用UFW放行端口"
  menu_exit_item 0 "退出"
  printf '%s请选择功能 [默认: 1]:%s ' "$C_YELLOW" "$C_RESET"
}

main() {
  while true; do
    show_menu
    if ! read -r choice; then
      printf '\n'
      return
    fi
    choice=${choice:-1}
    case "$choice" in
      1) deploy_sing_box_proxy ;;
      2) deploy_cloudflare_ip_node; pause ;;
      3) manage_sing_box_core ;;
      4) install_docker; pause ;;
      5) show_basic_info ;;
      6) open_firewall_port ;;
      0) exit 0 ;;
      *) printf '\n无效选项: %s\n' "$choice"; pause ;;
    esac
  done
}

main "$@"
