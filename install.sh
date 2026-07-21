#!/usr/bin/env bash
# TLS 节点大厂 SNI 分流管理脚本
set -Eeuo pipefail

APP="tls-sni"
LEGACY_APP="anytls-sni"
BASE_DIR="/etc/${APP}"
STATE_FILE="${BASE_DIR}/state.env"
NGINX_CONF="${BASE_DIR}/nginx.conf"
FW_HELPER="/usr/local/sbin/${APP}-fw"
SERVICE_FILE="/etc/systemd/system/${APP}.service"
LEGACY_BASE_DIR="/etc/${LEGACY_APP}"
LEGACY_STATE_FILE="${LEGACY_BASE_DIR}/state.env"
LEGACY_FW_HELPER="/usr/local/sbin/${LEGACY_APP}-fw"
LEGACY_SERVICE_FILE="/etc/systemd/system/${LEGACY_APP}.service"

info() {
  printf '[信息] %s\n' "$*"
}

ok() {
  printf '[成功] %s\n' "$*"
}

warn() {
  printf '[注意] %s\n' "$*" >&2
}

die() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行此脚本。"
  [[ $(uname -s) == "Linux" ]] || die "此脚本只能在 Linux 服务器上运行。"
  command -v systemctl >/dev/null 2>&1 || die "系统必须使用 systemd。"
}

valid_port() {
  [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

valid_hostname() {
  [[ ${1:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ $1 == *.* ]]
}

port_is_listening() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

load_state() {
  NODE_PORT=""
  PROXY_PORT=""
  FAKE_SNI=""
  if [[ -r $STATE_FILE ]]; then
    # 状态文件只允许 root 写入，并且值在写入前已经校验。
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  elif [[ -r $LEGACY_STATE_FILE ]]; then
    # 读取旧版配置作为重新安装时的默认值。
    # shellcheck disable=SC1090
    source "$LEGACY_STATE_FILE"
  fi
}

legacy_install_exists() {
  [[ -f $LEGACY_SERVICE_FILE || -d $LEGACY_BASE_DIR || -x $LEGACY_FW_HELPER ]]
}

cleanup_legacy_install() {
  legacy_install_exists || return 0

  if [[ -x $LEGACY_FW_HELPER ]]; then
    "$LEGACY_FW_HELPER" stop >/dev/null 2>&1 || true
  fi
  systemctl disable --now "$LEGACY_APP" >/dev/null 2>&1 || true
  rm -f "$LEGACY_SERVICE_FILE" "$LEGACY_FW_HELPER"
  rm -f "/var/log/${LEGACY_APP}.log" "/run/${LEGACY_APP}.pid"
  rm -rf "$LEGACY_BASE_DIR"
  systemctl daemon-reload
  info "已清理旧版 ${LEGACY_APP} 配置。"
}

confirm() {
  local answer
  read -r -p "${1:-确认继续吗？} [y/N]: " answer
  [[ $answer == "y" || $answer == "Y" ]]
}

pause_menu() {
  printf '\n'
  read -r -p "按回车键返回菜单..." _
}

find_stream_module() {
  local candidate
  for candidate in \
    /usr/lib/nginx/modules/ngx_stream_module.so \
    /usr/lib64/nginx/modules/ngx_stream_module.so \
    /usr/share/nginx/modules/ngx_stream_module.so; do
    if [[ -f $candidate ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v nginx >/dev/null 2>&1 &&
    nginx -V 2>&1 | grep -Eq -- '(^|[[:space:]])--with-stream([[:space:]]|$)'; then
    return 0
  fi
  return 1
}

install_dependencies() {
  local nginx_was_active=0

  if command -v nginx >/dev/null 2>&1 &&
    command -v iptables >/dev/null 2>&1 &&
    command -v ss >/dev/null 2>&1 &&
    find_stream_module >/dev/null 2>&1; then
    info "所需组件已经安装。"
    return
  fi

  systemctl is-active --quiet nginx 2>/dev/null && nginx_was_active=1
  info "正在安装 Nginx Stream、iptables 和网络工具..."

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nginx libnginx-mod-stream iptables iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx nginx-mod-stream iptables iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx nginx-mod-stream iptables iproute
  else
    die "仅支持 apt、dnf 或 yum 软件包管理器。"
  fi

  # 使用独立的 Stream 实例，不让新安装的系统 Nginx 占用 80 端口，
  # 从而避免影响节点后端的 HTTP-01 证书续期。
  if (( nginx_was_active == 0 )); then
    systemctl disable --now nginx >/dev/null 2>&1 || true
  fi

  command -v nginx >/dev/null 2>&1 || die "Nginx 安装失败。"
  command -v iptables >/dev/null 2>&1 || die "iptables 安装失败。"
  command -v ss >/dev/null 2>&1 || die "iproute2 安装失败。"
  find_stream_module >/dev/null 2>&1 || die "没有找到 Nginx Stream 模块。"
}

choose_proxy_port() {
  local node_port=$1
  local candidate=$((node_port + 1))

  if (( candidate > 65535 )); then
    candidate=39001
  fi

  while port_is_listening "$candidate" || [[ $candidate -eq $node_port ]]; do
    candidate=$((candidate + 1))
    if (( candidate > 65535 )); then
      candidate=39001
    fi
  done
  printf '%s\n' "$candidate"
}

write_state() {
  umask 077
  mkdir -p "$BASE_DIR"
  cat >"$STATE_FILE" <<EOF
NODE_PORT=$NODE_PORT
PROXY_PORT=$PROXY_PORT
FAKE_SNI=$FAKE_SNI
EOF
  chmod 0600 "$STATE_FILE"
}

write_nginx_config() {
  local module_path=$1
  local load_module=""
  local ipv6_listen=""

  if [[ -n $module_path ]]; then
    load_module="load_module ${module_path};"
  fi
  if [[ -s /proc/net/if_inet6 ]]; then
    ipv6_listen="        listen [::]:${PROXY_PORT} ipv6only=on reuseport;"
  fi

  mkdir -p "$BASE_DIR"
  cat >"$NGINX_CONF" <<EOF
${load_module}
worker_processes auto;
pid /run/${APP}.pid;
error_log /dev/null crit;

events {
    worker_connections 4096;
}

stream {
    map \$ssl_preread_server_name \$selected_backend {
        "${FAKE_SNI}" tls_backend;
        default       cover_backend;
    }

    upstream tls_backend {
        server 127.0.0.1:${NODE_PORT};
    }

    upstream cover_backend {
        server ${FAKE_SNI}:443;
    }

    server {
        listen 0.0.0.0:${PROXY_PORT} reuseport;
${ipv6_listen}

        ssl_preread on;
        proxy_pass \$selected_backend;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        tcp_nodelay on;
    }
}
EOF
}

write_firewall_helper() {
  cat >"$FW_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP="tls-sni"
STATE_FILE="/etc/${APP}/state.env"
[[ -r $STATE_FILE ]] || exit 0
# shellcheck disable=SC1090
source "$STATE_FILE"

manage_family() {
  local action=$1
  local ipt=$2
  command -v "$ipt" >/dev/null 2>&1 || return 0
  "$ipt" -t nat -L PREROUTING -n >/dev/null 2>&1 || return 0

  local -a redirect_rule=(
    -p tcp --dport "$NODE_PORT"
    -m addrtype --dst-type LOCAL
    -m comment --comment "${APP}-redirect"
    -j REDIRECT --to-ports "$PROXY_PORT"
  )
  local -a direct_drop_rule=(
    -p tcp --dport "$PROXY_PORT"
    -m conntrack --ctorigdstport "$PROXY_PORT"
    -m comment --comment "${APP}-direct-drop"
    -j DROP
  )

  if [[ $action == start ]]; then
    "$ipt" -t nat -C PREROUTING "${redirect_rule[@]}" >/dev/null 2>&1 ||
      "$ipt" -t nat -I PREROUTING 1 "${redirect_rule[@]}"
    "$ipt" -C INPUT "${direct_drop_rule[@]}" >/dev/null 2>&1 ||
      "$ipt" -I INPUT 1 "${direct_drop_rule[@]}"
  else
    while "$ipt" -t nat -C PREROUTING "${redirect_rule[@]}" >/dev/null 2>&1; do
      "$ipt" -t nat -D PREROUTING "${redirect_rule[@]}"
    done
    while "$ipt" -C INPUT "${direct_drop_rule[@]}" >/dev/null 2>&1; do
      "$ipt" -D INPUT "${direct_drop_rule[@]}"
    done
  fi
}

case "${1:-}" in
  start)
    manage_family start iptables
    manage_family start ip6tables
    ;;
  stop)
    manage_family stop iptables
    manage_family stop ip6tables
    ;;
  *)
    echo "用法: $0 {start|stop}" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "$FW_HELPER"
}

write_service() {
  local nginx_bin
  nginx_bin=$(command -v nginx)

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TLS 节点 SNI 分流服务
After=network-online.target firewalld.service nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${nginx_bin} -t -c ${NGINX_CONF} -p ${BASE_DIR}/
ExecStart=${nginx_bin} -c ${NGINX_CONF} -p ${BASE_DIR}/ -g "daemon off;"
ExecStartPost=${FW_HELPER} start
ExecStopPost=${FW_HELPER} stop
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
}

read_sni_value() {
  local old_sni=${1:-}
  local choice custom_sni

  while true; do
    printf '\n请选择大厂 SNI：\n'
    printf '  1) www.epicgames.com  (Epic 游戏商城)\n'
    printf '  2) www.nvidia.com     (NVIDIA 官网)\n'
    printf '  3) www.amd.com        (AMD 官网)\n'
    printf '  4) www.speedtest.net  (全球测速网)\n'
    printf '  5) www.itunes.com     (Apple iTunes)\n'
    printf '  6) 自定义域名\n'
    if [[ -n $old_sni ]]; then
      printf '  直接回车：保持当前值 %s\n' "$old_sni"
    else
      printf '  直接回车：默认选择 www.epicgames.com\n'
    fi
    read -r -p "请选择 [1-6]: " choice

    if [[ -z $choice && -n $old_sni ]]; then
      FAKE_SNI=$old_sni
    else
      case "${choice:-1}" in
        1) FAKE_SNI="www.epicgames.com" ;;
        2) FAKE_SNI="www.nvidia.com" ;;
        3) FAKE_SNI="www.amd.com" ;;
        4) FAKE_SNI="www.speedtest.net" ;;
        5) FAKE_SNI="www.itunes.com" ;;
        6)
          read -r -p "请输入自定义 SNI 域名: " custom_sni
          FAKE_SNI=$custom_sni
          ;;
        *)
          warn "请输入 1 到 6。"
          continue
          ;;
      esac
    fi

    FAKE_SNI=${FAKE_SNI,,}
    if valid_hostname "$FAKE_SNI"; then
      return
    fi
    warn "SNI 格式不正确，请重新选择或输入。"
  done
}

read_install_values() {
  local old_node_port old_sni input

  load_state
  old_node_port=$NODE_PORT
  old_sni=$FAKE_SNI

  printf '\n请填写节点端口并选择大厂 SNI。\n\n'

  while true; do
    if [[ -n $old_node_port ]]; then
      read -r -p "请输入 TLS 节点端口 [$old_node_port]: " input
      NODE_PORT=${input:-$old_node_port}
    else
      read -r -p "请输入 TLS 节点端口: " NODE_PORT
    fi
    valid_port "$NODE_PORT" && break
    warn "端口必须是 1 到 65535 之间的数字。"
  done

  read_sni_value "$old_sni"
}

install_or_reconfigure() {
  local module_path old_proxy_port summary_proxy

  load_state
  old_proxy_port=$PROXY_PORT
  read_install_values

  printf '\n准备应用以下配置：\n'
  printf '  TLS 节点公网端口：%s\n' "$NODE_PORT"
  printf '  大厂 SNI：%s\n' "$FAKE_SNI"
  printf '  原节点地址、端口、密码：保持不变\n'
  printf '  HTTP 申请证书及 80 端口：不修改\n\n'
  confirm "确认安装或重新配置吗？" || {
    info "操作已取消。"
    return
  }

  install_dependencies

  if ! port_is_listening "$NODE_PORT"; then
    die "TCP 端口 $NODE_PORT 没有服务监听。请先确认面板节点已对接成功且 TLS 节点正常运行。"
  fi

  # 先撤销旧转发，保证重新配置时不会残留规则或占用内部端口。
  cleanup_legacy_install
  if systemctl is-active --quiet "$APP" 2>/dev/null; then
    systemctl stop "$APP"
  fi
  if [[ -x $FW_HELPER ]]; then
    "$FW_HELPER" stop >/dev/null 2>&1 || true
  fi
  rm -f "/var/log/${APP}.log" "/run/${APP}.pid"

  if valid_port "$old_proxy_port" &&
    [[ $old_proxy_port -ne $NODE_PORT ]] &&
    ! port_is_listening "$old_proxy_port"; then
    PROXY_PORT=$old_proxy_port
  else
    PROXY_PORT=$(choose_proxy_port "$NODE_PORT")
  fi
  summary_proxy=$PROXY_PORT

  module_path=$(find_stream_module) || die "没有找到 Nginx Stream 模块。"
  write_state
  write_nginx_config "$module_path"
  write_firewall_helper
  write_service

  nginx -t -c "$NGINX_CONF" -p "$BASE_DIR/"
  systemctl daemon-reload
  systemctl enable --now "$APP"
  systemctl is-active --quiet "$APP" || die "服务启动失败，请运行 systemctl status ${APP} 检查状态。"

  printf '\n'
  ok "安装/配置完成。"
  printf '  公网节点端口：%s（没有改变）\n' "$NODE_PORT"
  printf '  内部转发端口：%s（自动管理，无需填到面板）\n' "$summary_proxy"
  printf '  客户端 SNI：%s\n' "$FAKE_SNI"
  printf '\n客户端或面板订阅需要修改：\n'
  printf '  1. SNI 改为 %s\n' "$FAKE_SNI"
  printf '  2. 开启“跳过证书验证 / insecure”\n'
  printf '  3. 节点地址、端口和密码保持原样\n'
  printf '\n'
  warn "若客户端支持证书公钥固定，建议固定公钥，不要只依赖 insecure。"
  warn "节点后端如有“拒绝未知 SNI”选项，请将其关闭。"
}

show_status() {
  load_state
  printf '\n========== 当前状态 ==========\n'
  if [[ -z $NODE_PORT ]]; then
    printf '状态：尚未安装\n'
    return
  fi

  printf 'TLS 节点端口：%s\n' "$NODE_PORT"
  printf '内部转发端口：%s\n' "$PROXY_PORT"
  printf '大厂 SNI：%s\n' "$FAKE_SNI"

  if systemctl is-active --quiet "$APP" 2>/dev/null; then
    printf '分流服务：运行中\n'
  elif systemctl is-active --quiet "$LEGACY_APP" 2>/dev/null; then
    printf '分流服务：旧版正在运行，请选择“安装 / 重新配置”完成迁移\n'
  else
    printf '分流服务：未运行\n'
  fi

  if port_is_listening "$NODE_PORT"; then
    printf 'TLS 后端监听：正常\n'
  else
    printf 'TLS 后端监听：异常，端口未监听\n'
  fi

  if port_is_listening "$PROXY_PORT"; then
    printf 'Nginx 内部监听：正常\n'
  else
    printf 'Nginx 内部监听：异常，端口未监听\n'
  fi

  if iptables -t nat -S PREROUTING 2>/dev/null | grep -q "${APP}-redirect"; then
    printf 'IPv4 透明转发：已启用\n'
  else
    printf 'IPv4 透明转发：未启用\n'
  fi
}

start_service() {
  [[ -f $SERVICE_FILE ]] || die "尚未安装，请先选择“安装 / 重新配置”。"
  systemctl start "$APP"
  ok "服务已启动。"
}

stop_service() {
  [[ -f $SERVICE_FILE ]] || die "尚未安装。"
  systemctl stop "$APP"
  ok "服务已停止，公网端口已恢复为直接连接 TLS 后端。"
}

restart_service() {
  [[ -f $SERVICE_FILE ]] || die "尚未安装，请先选择“安装 / 重新配置”。"
  systemctl restart "$APP"
  ok "服务已重启。"
}

remove_app() {
  if [[ ! -f $SERVICE_FILE && ! -d $BASE_DIR ]] && ! legacy_install_exists; then
    info "当前没有安装。"
    return
  fi

  confirm "确认卸载 SNI 分流吗？卸载后 TLS 节点将恢复直接连接。" || {
    info "操作已取消。"
    return
  }

  cleanup_legacy_install
  if [[ -x $FW_HELPER ]]; then
    "$FW_HELPER" stop || true
  fi
  systemctl disable --now "$APP" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$FW_HELPER"
  rm -f "/var/log/${APP}.log" "/run/${APP}.pid"
  rm -rf "$BASE_DIR"
  systemctl daemon-reload
  ok "已卸载，Nginx 软件包予以保留，原 TLS 节点端口已恢复直连。"
}

show_menu() {
  while true; do
    printf '\n'
    printf '========================================\n'
    printf '       TLS 节点大厂 SNI 分流管理\n'
    printf '========================================\n'
    printf '  1. 安装 / 重新配置\n'
    printf '  2. 查看运行状态\n'
    printf '  3. 启动服务\n'
    printf '  4. 停止服务\n'
    printf '  5. 重启服务\n'
    printf '  6. 卸载分流\n'
    printf '  0. 退出\n'
    printf '========================================\n'
    read -r -p "请选择 [0-6]: " choice

    case "$choice" in
      1) install_or_reconfigure; pause_menu ;;
      2) show_status; pause_menu ;;
      3) start_service; pause_menu ;;
      4) stop_service; pause_menu ;;
      5) restart_service; pause_menu ;;
      6) remove_app; pause_menu ;;
      0) exit 0 ;;
      *) warn "请输入 0 到 6。" ;;
    esac
  done
}

require_root
case "${1:-menu}" in
  menu) show_menu ;;
  install|configure) install_or_reconfigure ;;
  status) show_status ;;
  start) start_service ;;
  stop) stop_service ;;
  restart) restart_service ;;
  remove|uninstall) remove_app ;;
  *) die "未知参数。直接运行脚本可进入中文菜单。" ;;
esac
