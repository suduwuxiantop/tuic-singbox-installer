#!/usr/bin/env bash
# TUIC v5 one-click installer based on sing-box (>= 1.14)
# Uses the official sing-box APT repository and the sing-box 1.14
# certificate provider (ACME) to obtain a real Let's Encrypt certificate.
#
# Usage:
#   bash install.sh install -d tuic.example.com -e you@example.com [-p 443]
#   bash install.sh info
#   bash install.sh uninstall
#
# Supported systems: Debian 11+ / Ubuntu 20.04+ (systemd)

set -euo pipefail

MIN_VERSION="1.14.0"
CONF_DIR="/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
INFO_FILE="${CONF_DIR}/tuic-client-info.txt"
ACME_DIR="/var/lib/sing-box/acme"

DOMAIN=""
EMAIL=""
PORT="443"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
die()    { red "错误：$*"; exit 1; }

usage() {
  cat <<'EOF'
用法：
  bash install.sh install -d <域名> -e <邮箱> [-p <端口，默认443>]
  bash install.sh info        # 重新显示客户端连接信息
  bash install.sh uninstall   # 停止服务并删除配置

示例：
  bash install.sh install -d tuic.example.com -e you@example.com
EOF
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行（或在命令前加 sudo）"
}

check_os() {
  [ -r /etc/os-release ] || die "无法识别系统，仅支持 Debian / Ubuntu"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-} ${ID_LIKE:-}" in
    *debian*|*ubuntu*) ;;
    *) die "当前系统为 ${PRETTY_NAME:-未知}，本脚本仅支持 Debian / Ubuntu" ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "系统未使用 systemd，无法继续"
}

version_ge() {
  # returns 0 if $1 >= $2
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

installed_version() {
  if command -v sing-box >/dev/null 2>&1; then
    sing-box version 2>/dev/null | awk 'NR==1{print $3}'
  fi
}

install_deps() {
  green "==> 安装依赖（curl、ca-certificates）"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates >/dev/null
}

install_singbox() {
  local cur
  cur="$(installed_version)"
  if [ -n "$cur" ] && version_ge "$cur" "$MIN_VERSION"; then
    green "==> 已安装 sing-box ${cur}，满足要求（>= ${MIN_VERSION}）"
    return
  fi
  green "==> 通过 sing-box 官方 APT 源安装 / 升级 sing-box"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y sing-box >/dev/null
  cur="$(installed_version)"
  [ -n "$cur" ] || die "sing-box 安装失败"
  version_ge "$cur" "$MIN_VERSION" || die "安装到的 sing-box 版本为 ${cur}，低于 ${MIN_VERSION}"
  green "==> sing-box ${cur} 安装完成"
}

ask_params() {
  if [ -z "$DOMAIN" ]; then
    read -r -p "请输入已解析到本机的域名（如 tuic.example.com）：" DOMAIN
  fi
  if [ -z "$EMAIL" ]; then
    read -r -p "请输入用于申请证书的邮箱：" EMAIL
  fi
  [ -n "$DOMAIN" ] || die "域名不能为空"
  [ -n "$EMAIL" ] || die "邮箱不能为空"
  case "$PORT" in
    ''|*[!0-9]*) die "端口必须是数字" ;;
  esac
  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "端口范围应为 1-65535"
  fi
}

check_dns() {
  local server_ip domain_ips
  server_ip="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  domain_ips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  if [ -z "$domain_ips" ]; then
    die "域名 ${DOMAIN} 无法解析，请先在 DNS 中添加 A 记录指向本机 IP"
  fi
  if [ -z "$server_ip" ]; then
    yellow "提示：无法获取本机公网 IP，跳过解析校验（域名当前解析到：${domain_ips}）"
    return
  fi
  if ! printf '%s' "$domain_ips" | grep -qw "$server_ip"; then
    yellow "警告：域名 ${DOMAIN} 解析到 ${domain_ips}，但本机公网 IP 是 ${server_ip}"
    yellow "      如果使用 Cloudflare，请把这条记录设置为「仅 DNS」（灰色云朵），否则证书会申请失败"
    read -r -p "仍然继续？[y/N] " ans
    case "$ans" in y|Y) ;; *) exit 1 ;; esac
  else
    green "==> 域名解析正确：${DOMAIN} -> ${server_ip}"
  fi
}

check_ports() {
  if ss -H -ltn 'sport = :80' 2>/dev/null | grep -q .; then
    yellow "警告：TCP 80 端口已被占用，Let's Encrypt 的 HTTP 验证可能失败"
    yellow "      sing-box 还会尝试 TCP 443 的 TLS-ALPN 验证；若两者都被占用，证书无法签发"
  fi
  if ss -H -lun "sport = :${PORT}" 2>/dev/null | grep -q .; then
    die "UDP ${PORT} 端口已被占用，请换一个端口（-p 参数）或先停止占用它的程序"
  fi
}

write_config() {
  local uuid password
  uuid="$(sing-box generate uuid)"
  password="$(sing-box generate rand --hex 16)"

  mkdir -p "$CONF_DIR" "$ACME_DIR"
  if [ -f "$CONF_FILE" ]; then
    cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    yellow "==> 已备份原有配置文件"
  fi

  cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "acme-cert",
      "domain": ["${DOMAIN}"],
      "email": "${EMAIL}",
      "data_directory": "${ACME_DIR}"
    }
  ],
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "user1",
          "uuid": "${uuid}",
          "password": "${password}"
        }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"],
        "certificate_provider": "acme-cert"
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
  chmod 600 "$CONF_FILE"

  # If the packaged service runs as a dedicated user, give it access.
  local svc_user
  svc_user="$(systemctl show -p User --value sing-box 2>/dev/null || true)"
  if [ -n "$svc_user" ] && [ "$svc_user" != "root" ] && id "$svc_user" >/dev/null 2>&1; then
    chown -R "$svc_user" "$ACME_DIR"
    chown "$svc_user" "$CONF_FILE"
  fi

  sing-box check -c "$CONF_FILE" || die "配置文件校验未通过"
  write_client_info "$uuid" "$password"
}

write_client_info() {
  local uuid="$1" password="$2" name
  name="TUIC-${DOMAIN}"
  cat > "$INFO_FILE" <<EOF
================ TUIC v5 客户端连接信息 ================
服务器地址 (server) : ${DOMAIN}
端口 (port)         : ${PORT}  (UDP)
UUID                : ${uuid}
密码 (password)     : ${password}
拥塞控制            : bbr
ALPN                : h3
SNI                 : ${DOMAIN}
UDP 转发模式        : native

---------------- 分享链接（v2rayN / NekoBox 可直接导入）----------------
tuic://${uuid}:${password}@${DOMAIN}:${PORT}?congestion_control=bbr&alpn=h3&sni=${DOMAIN}&udp_relay_mode=native#${name}

---------------- Clash Verge / Mihomo 内核 ----------------
proxies:
  - name: "${name}"
    type: tuic
    server: ${DOMAIN}
    port: ${PORT}
    uuid: ${uuid}
    password: ${password}
    alpn: [h3]
    congestion-controller: bbr
    udp-relay-mode: native
    reduce-rtt: false
    sni: ${DOMAIN}

---------------- sing-box 客户端 outbound ----------------
{
  "type": "tuic",
  "tag": "tuic-out",
  "server": "${DOMAIN}",
  "server_port": ${PORT},
  "uuid": "${uuid}",
  "password": "${password}",
  "congestion_control": "bbr",
  "udp_relay_mode": "native",
  "zero_rtt_handshake": false,
  "heartbeat": "10s",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}",
    "alpn": ["h3"]
  }
}
========================================================
EOF
  chmod 600 "$INFO_FILE"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    green "==> 检测到 ufw，放行 80/tcp、443/tcp（证书验证）和 ${PORT}/udp（TUIC）"
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow "${PORT}/udp" >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    green "==> 检测到 firewalld，放行 80/tcp、443/tcp 和 ${PORT}/udp"
    firewall-cmd --permanent --add-port=80/tcp >/dev/null
    firewall-cmd --permanent --add-port=443/tcp >/dev/null
    firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
  yellow "提示：云服务商控制台里的「安全组 / 防火墙」需要你手动放行 80/tcp、443/tcp 和 ${PORT}/udp"
}

start_service() {
  green "==> 启动 sing-box"
  systemctl enable sing-box >/dev/null 2>&1
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box || {
    journalctl -u sing-box --output cat -n 30 --no-pager || true
    die "sing-box 启动失败，请查看上面的日志"
  }
}

wait_cert() {
  green "==> 等待证书签发（最长 120 秒）"
  local _
  for _ in $(seq 1 60); do
    if find "$ACME_DIR" -type f -name "${DOMAIN}.crt" 2>/dev/null | grep -q .; then
      green "==> 证书已签发"
      return 0
    fi
    sleep 2
  done
  yellow "警告：120 秒内未检测到证书文件。常见原因："
  yellow "  1. 云服务商安全组没有放行 TCP 80 / 443"
  yellow "  2. 域名没有解析到本机，或开启了 Cloudflare 代理（橙色云朵）"
  yellow "  3. 80 和 443 TCP 端口都被其他程序占用"
  yellow "查看日志：journalctl -u sing-box --output cat -e"
  return 1
}

do_install() {
  require_root
  check_os
  ask_params
  install_deps
  check_dns
  check_ports
  install_singbox
  write_config
  open_firewall
  start_service
  wait_cert || true
  echo
  cat "$INFO_FILE"
  echo
  green "以上信息已保存到 ${INFO_FILE}，之后可运行：bash install.sh info"
}

do_info() {
  [ -f "$INFO_FILE" ] || die "未找到连接信息文件，请先执行安装"
  cat "$INFO_FILE"
}

do_uninstall() {
  require_root
  read -r -p "确定要停止 sing-box 并删除 TUIC 配置和证书数据吗？[y/N] " ans
  case "$ans" in y|Y) ;; *) exit 0 ;; esac
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  if [ -f "$CONF_FILE" ]; then
    mv "$CONF_FILE" "${CONF_FILE}.removed.$(date +%Y%m%d%H%M%S)"
  fi
  rm -f "$INFO_FILE"
  rm -rf "$ACME_DIR"
  green "已停止 sing-box 并移除配置（原配置已改名备份在 ${CONF_DIR}）"
  yellow "如需彻底卸载程序本身：apt-get remove -y sing-box"
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    install)
      while getopts ":d:e:p:h" opt; do
        case "$opt" in
          d) DOMAIN="$OPTARG" ;;
          e) EMAIL="$OPTARG" ;;
          p) PORT="$OPTARG" ;;
          h) usage; exit 0 ;;
          *) usage; exit 1 ;;
        esac
      done
      do_install
      ;;
    info) do_info ;;
    uninstall) do_uninstall ;;
    ""|-h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
