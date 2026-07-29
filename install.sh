#!/usr/bin/env bash
# TLS 节点大厂 SNI 分流管理脚本
set -Eeuo pipefail

APP="tls-sni"
LEGACY_APP="anytls-sni"
BASE_DIR="/etc/${APP}"
STATE_FILE="${BASE_DIR}/state.env"
SALAMANDER_KEY_FILE="${BASE_DIR}/salamander.key"
NGINX_CONF="${BASE_DIR}/nginx.conf"
FW_HELPER="/usr/local/sbin/${APP}-fw"
SERVICE_FILE="/etc/systemd/system/${APP}.service"
QUIC_APP="${APP}-quic"
QUIC_FILTER_BIN="/usr/local/bin/${QUIC_APP}"
QUIC_FILTER_SERVICE_FILE="/etc/systemd/system/${QUIC_APP}.service"
QUIC_FILTER_SOURCE_DIR="/usr/local/src/${QUIC_APP}"
GO_TOOLCHAIN_ROOT="/opt/${APP}-go/1.23.4"
CACHE_DIR="/var/cache/${APP}"
LOG_DIR="/var/log/${APP}"
LOGROTATE_FILE="/etc/logrotate.d/${APP}"
GO_BIN=""
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

tcp_port_is_listening() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

udp_port_is_listening() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -lnu "sport = :$1" 2>/dev/null | grep -q .
}

port_is_listening() {
  tcp_port_is_listening "$1"
}

port_is_in_use() {
  tcp_port_is_listening "$1" || udp_port_is_listening "$1"
}

find_free_udp_port() {
  local candidate=$1
  if (( candidate > 65535 )); then
    candidate=39001
  fi
  while (( candidate <= 65535 )); do
    if ! port_is_in_use "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

load_state() {
  NODE_PORT=""
  PROXY_PORT=""
  FAKE_SNI=""
  UDP_MODE="none"
  QUIC_FILTER_PORT=""
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

go_version_ok() {
  local go_cmd=${1:-go} version minor
  command -v "$go_cmd" >/dev/null 2>&1 || [[ -x $go_cmd ]] || return 1
  version=$("$go_cmd" version 2>/dev/null) || return 1
  [[ $version =~ go1\.([0-9]+) ]] || return 1
  minor=${BASH_REMATCH[1]}
  (( minor >= 22 ))
}

ensure_go() {
  [[ $UDP_MODE != none ]] || return 0
  if go_version_ok go; then
    GO_BIN=$(command -v go)
    return 0
  fi
  if [[ -x ${GO_TOOLCHAIN_ROOT}/bin/go ]] && go_version_ok "${GO_TOOLCHAIN_ROOT}/bin/go"; then
    GO_BIN="${GO_TOOLCHAIN_ROOT}/bin/go"
    return 0
  fi

  local arch archive checksum url tmp_dir
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64; checksum=6924efde5de86fe277676e929dc9917d466efa02fb934197bc2eba35d5680971 ;;
    aarch64|arm64) arch=arm64; checksum=16e5017863a7f6071363782b1b8042eb12c6ca4f4cd71528b2123f0a1275b13e ;;
    *) die "UDP/HY2 模式需要 Go 1.22+，当前架构无法自动安装 Go 工具链。" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载 Go 工具链。"
  command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum，无法校验 Go 工具链。"
  command -v tar >/dev/null 2>&1 || die "缺少 tar，无法解压 Go 工具链。"
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT
  archive="$tmp_dir/go1.23.4.linux-${arch}.tar.gz"
  url="https://dl.google.com/go/go1.23.4.linux-${arch}.tar.gz"
  info "正在安装 Go 1.23.4（仅用于构建 UDP 过滤器）..."
  curl -fL --retry 3 -o "$archive" "$url"
  printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c - >/dev/null
  rm -rf "$GO_TOOLCHAIN_ROOT"
  mkdir -p "$(dirname "$GO_TOOLCHAIN_ROOT")"
  tar -C "$(dirname "$GO_TOOLCHAIN_ROOT")" -xzf "$archive"
  mv "$(dirname "$GO_TOOLCHAIN_ROOT")/go" "$GO_TOOLCHAIN_ROOT"
  rm -rf "$tmp_dir"
  trap - EXIT
  GO_BIN="${GO_TOOLCHAIN_ROOT}/bin/go"
  go_version_ok "$GO_BIN" || die "Go 工具链安装后版本检查失败。"
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

cleanup_quic_filter() {
  systemctl disable --now "$QUIC_APP" >/dev/null 2>&1 || true
  rm -f "$QUIC_FILTER_SERVICE_FILE" "$QUIC_FILTER_BIN"
  rm -rf "$QUIC_FILTER_SOURCE_DIR"
  systemctl daemon-reload
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
  local nginx_was_active=0 packages_needed=0

  command -v nginx >/dev/null 2>&1 || packages_needed=1
  command -v iptables >/dev/null 2>&1 || packages_needed=1
  command -v ss >/dev/null 2>&1 || packages_needed=1
  command -v logrotate >/dev/null 2>&1 || packages_needed=1
  find_stream_module >/dev/null 2>&1 || packages_needed=1
  if [[ $UDP_MODE != none ]] &&
    ! go_version_ok go && ! go_version_ok "${GO_TOOLCHAIN_ROOT}/bin/go"; then
    command -v curl >/dev/null 2>&1 || packages_needed=1
    command -v sha256sum >/dev/null 2>&1 || packages_needed=1
    command -v tar >/dev/null 2>&1 || packages_needed=1
  fi

  if (( packages_needed == 0 )); then
    info "所需组件已经安装。"
    [[ $UDP_MODE == none ]] || ensure_go
    return 0
  fi

  systemctl is-active --quiet nginx 2>/dev/null && nginx_was_active=1
  info "正在安装 Nginx Stream、iptables 和网络工具..."

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nginx libnginx-mod-stream iptables iproute2 logrotate curl ca-certificates tar coreutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx nginx-mod-stream iptables iproute logrotate curl ca-certificates tar coreutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx nginx-mod-stream iptables iproute logrotate curl ca-certificates tar coreutils
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
  command -v logrotate >/dev/null 2>&1 || die "logrotate 安装失败。"
  [[ $UDP_MODE == none ]] || ensure_go
  find_stream_module >/dev/null 2>&1 || die "没有找到 Nginx Stream 模块。"
}

write_state() {
  umask 077
  mkdir -p "$BASE_DIR"
  cat >"$STATE_FILE" <<EOF
NODE_PORT=$NODE_PORT
PROXY_PORT=$PROXY_PORT
FAKE_SNI=$FAKE_SNI
UDP_MODE=$UDP_MODE
QUIC_FILTER_PORT=$QUIC_FILTER_PORT
EOF
  chmod 0600 "$STATE_FILE"
  if [[ $UDP_MODE == salamander ]]; then
    [[ -s $SALAMANDER_KEY_FILE ]] || die "Salamander 密码文件不存在。"
    chmod 0600 "$SALAMANDER_KEY_FILE"
  else
    rm -f "$SALAMANDER_KEY_FILE"
  fi
}

write_salamander_key() {
  local first second
  while true; do
    read -r -p "请输入节点的 Salamander 密码: " first
    [[ ${#first} -ge 4 ]] || { warn "Salamander 密码至少 4 个字符。"; continue; }
    read -r -p "请再次输入 Salamander 密码: " second
    [[ $first == "$second" ]] || { warn "两次密码不一致，请重试。"; continue; }
    SALAMANDER_NEW_PASSWORD=$first
    return
  done
}

save_salamander_key() {
  [[ $UDP_MODE == salamander && -n ${SALAMANDER_NEW_PASSWORD:-} ]] || return 0
  umask 077
  mkdir -p "$BASE_DIR"
  printf '%s' "$SALAMANDER_NEW_PASSWORD" >"$SALAMANDER_KEY_FILE"
  chmod 0600 "$SALAMANDER_KEY_FILE"
  SALAMANDER_NEW_PASSWORD=""
}

write_quic_filter_source() {
  mkdir -p "$QUIC_FILTER_SOURCE_DIR"
  cat >"$QUIC_FILTER_SOURCE_DIR/go.mod" <<'EOF'
module tls-sni-quic

go 1.22

require (
  github.com/cuonglm/quicsni v0.0.0-20241227084737-7044966074df
  golang.org/x/crypto v0.31.0
)
EOF
  cat >"$QUIC_FILTER_SOURCE_DIR/main.go" <<'EOF'
package main

import (
  "flag"
  "fmt"
  "log"
  "net"
  "os"
  "strings"
  "sync"
  "time"

  "github.com/cuonglm/quicsni"
  "golang.org/x/crypto/blake2b"
)

type session struct {
  client *net.UDPAddr
  backend *net.UDPConn
  last time.Time
}

func salamanderDecode(packet, psk []byte) []byte {
  if len(packet) <= 8 { return nil }
  h := blake2b.Sum256(append(append([]byte{}, psk...), packet[:8]...))
  out := make([]byte, len(packet)-8)
  for i, b := range packet[8:] { out[i] = b ^ h[i%len(h)] }
  return out
}

func packetSNI(packet []byte, psk []byte, salamander bool) (string, bool) {
  if salamander { packet = salamanderDecode(packet, psk) }
  if len(packet) == 0 { return "", false }
  hello, err := quicsni.ReadClientHello(packet)
  if err != nil || hello == nil { return "", false }
  return strings.TrimSpace(hello.ServerName), true
}

func main() {
  listen := flag.String("listen", "127.0.0.1:39001", "UDP listener")
  backendAddr := flag.String("backend", "127.0.0.1:8445", "HY2 backend")
  expected := flag.String("sni", "", "expected SNI")
  mode := flag.String("mode", "plain", "plain or salamander")
  keyFile := flag.String("key", "", "Salamander key file")
  logFile := flag.String("log", "", "log file")
  flag.Parse()
  if *expected == "" { log.Fatal("missing expected SNI") }
  if *logFile != "" {
    f, err := os.OpenFile(*logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
    if err != nil { log.Fatal(err) }
    defer f.Close()
    log.SetOutput(f)
  }
  var psk []byte
  salamander := *mode == "salamander"
  if salamander {
    var err error
    psk, err = os.ReadFile(*keyFile)
    if err != nil || len(psk) < 4 { log.Fatal("invalid Salamander key") }
    if len(psk) > 0 && psk[len(psk)-1] == '\n' { psk = psk[:len(psk)-1] }
    if len(psk) < 4 { log.Fatal("invalid Salamander key") }
  }
  listener, err := net.ListenUDP("udp", mustResolve(*listen))
  if err != nil { log.Fatal(err) }
  defer listener.Close()
  log.Printf("listening=%s backend=%s sni=%s mode=%s", *listen, *backendAddr, *expected, *mode)
  var mu sync.Mutex
  sessions := make(map[string]*session)
  go func() {
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()
    for range ticker.C {
      now := time.Now(); mu.Lock()
      for k, s := range sessions { if now.Sub(s.last) > 90*time.Second { s.backend.Close(); delete(sessions, k) } }
      mu.Unlock()
    }
  }()
  buf := make([]byte, 64*1024)
  for {
    n, addr, err := listener.ReadFromUDP(buf)
    if err != nil { if ne, ok := err.(net.Error); ok && ne.Temporary() { continue }; log.Fatal(err) }
    key := addr.String()
    mu.Lock(); s := sessions[key]; mu.Unlock()
    if s == nil {
      // quicsni 会改写输入缓冲区；使用副本解析，原始包仍原样交给 HY2。
      packet := append([]byte(nil), buf[:n]...)
      seenSNI, isInitial := packetSNI(packet, psk, salamander)
      if !isInitial || !strings.EqualFold(seenSNI, *expected) { continue }
      remote, err := net.ResolveUDPAddr("udp", *backendAddr); if err != nil { log.Printf("resolve backend: %v", err); continue }
      conn, err := net.DialUDP("udp", nil, remote); if err != nil { log.Printf("dial backend: %v", err); continue }
      s = &session{client: addr, backend: conn, last: time.Now()}
      mu.Lock(); sessions[key] = s; mu.Unlock()
      log.Printf("allow client=%s sni=%q mode=%s", addr, *expected, *mode)
      go func(k string, ss *session) {
        defer ss.backend.Close()
        rb := make([]byte, 64*1024)
        for {
          ss.backend.SetReadDeadline(time.Now().Add(2 * time.Minute))
          rn, err := ss.backend.Read(rb); if err != nil { mu.Lock(); if sessions[k] == ss { delete(sessions, k) }; mu.Unlock(); return }
          if _, err = listener.WriteToUDP(rb[:rn], ss.client); err != nil { mu.Lock(); if sessions[k] == ss { delete(sessions, k) }; mu.Unlock(); return }
        }
      }(key, s)
    }
    mu.Lock(); s.last = time.Now(); mu.Unlock()
    if _, err := s.backend.Write(buf[:n]); err != nil { mu.Lock(); if sessions[key] == s { delete(sessions, key) }; mu.Unlock(); s.backend.Close() }
  }
}

func mustResolve(addr string) *net.UDPAddr {
  a, err := net.ResolveUDPAddr("udp", addr); if err != nil { panic(fmt.Sprintf("invalid listen address: %v", err)) }; return a
}

EOF
}

build_quic_filter() {
  [[ $UDP_MODE != none ]] || return 0
  ensure_go
  write_quic_filter_source
  mkdir -p "$CACHE_DIR/mod" "$CACHE_DIR/build"
  (cd "$QUIC_FILTER_SOURCE_DIR" && \
    GOMODCACHE="$CACHE_DIR/mod" GOCACHE="$CACHE_DIR/build" "$GO_BIN" mod tidy && \
    CGO_ENABLED=0 GOMODCACHE="$CACHE_DIR/mod" GOCACHE="$CACHE_DIR/build" \
      "$GO_BIN" build -trimpath -ldflags='-s -w' -o "$QUIC_FILTER_BIN" .)
  chmod 0755 "$QUIC_FILTER_BIN"
}

write_quic_filter_service() {
  [[ $UDP_MODE != none ]] || return 0
  local mode_args="--mode plain"
  [[ $UDP_MODE == salamander ]] && mode_args="--mode salamander --key ${SALAMANDER_KEY_FILE}"
  cat >"$QUIC_FILTER_SERVICE_FILE" <<EOF
[Unit]
Description=TLS QUIC SNI UDP 过滤服务
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${QUIC_FILTER_BIN} --listen 127.0.0.1:${QUIC_FILTER_PORT} --backend 127.0.0.1:${NODE_PORT} --sni ${FAKE_SNI} --log ${LOG_DIR}/quic.log ${mode_args}
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_config() {
  local module_path=$1
  local load_module=""
  local ipv6_listen=""
  local udp_config=""

  if [[ -n $module_path ]]; then
    load_module="load_module ${module_path};"
  fi
  if [[ -s /proc/net/if_inet6 ]]; then
    ipv6_listen="        listen [::]:${PROXY_PORT} ipv6only=on reuseport;"
  fi
  if [[ $UDP_MODE != none ]]; then
    udp_config="
    server {
        listen 0.0.0.0:${PROXY_PORT} udp reuseport;
        access_log ${LOG_DIR}/quic-access.log quic_route;
        proxy_pass 127.0.0.1:${QUIC_FILTER_PORT};
        proxy_timeout 2m;
    }
"
    if [[ -s /proc/net/if_inet6 ]]; then
      udp_config+="    server {
        listen [::]:${PROXY_PORT} udp ipv6only=on reuseport;
        access_log ${LOG_DIR}/quic-access.log quic_route;
        proxy_pass 127.0.0.1:${QUIC_FILTER_PORT};
        proxy_timeout 2m;
    }
"
    fi
  fi

  mkdir -p "$BASE_DIR"
  cat >"$NGINX_CONF" <<EOF
${load_module}
worker_processes auto;
pid /run/${APP}.pid;
error_log ${LOG_DIR}/error.log warn;

events {
    worker_connections 8192;
}

stream {
    map \$ssl_preread_server_name \$selected_backend {
        "${FAKE_SNI}" tls_backend;
        default       cover_backend;
    }

    log_format sni_route '\$time_iso8601 client=\$remote_addr:\$remote_port sni="\$ssl_preread_server_name" route=\$selected_backend status=\$status sent=\$bytes_sent received=\$bytes_received time=\$session_time';
    log_format quic_route '\$time_iso8601 client=\$remote_addr:\$remote_port protocol=UDP route=quic_filter status=\$status sent=\$bytes_sent received=\$bytes_received time=\$session_time';

    upstream tls_backend {
        server 127.0.0.1:${NODE_PORT};
    }

    upstream cover_backend {
        server ${FAKE_SNI}:443;
    }

    server {
        listen 0.0.0.0:${PROXY_PORT} reuseport;
${ipv6_listen}

        access_log ${LOG_DIR}/access.log sni_route;
        ssl_preread on;
        proxy_pass \$selected_backend;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        tcp_nodelay on;
    }
${udp_config}
}
EOF
}

write_logrotate_config() {
  mkdir -p "$LOG_DIR"
  chmod 0755 "$LOG_DIR"
  cat >"$LOGROTATE_FILE" <<EOF
${LOG_DIR}/*.log {
    daily
    rotate 0
    missingok
    notifempty
    copytruncate
    su root root
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
  if ! command -v "$ipt" >/dev/null 2>&1; then
    [[ $action == stop ]] && return 0
    echo "缺少 $ipt，无法保护后端端口。" >&2
    return 1
  fi
  if ! "$ipt" -L INPUT -n >/dev/null 2>&1 ||
    ! "$ipt" -t raw -L PREROUTING -n >/dev/null 2>&1; then
    [[ $action == stop ]] && return 0
    echo "$ipt 无法管理 INPUT 或 raw/PREROUTING 规则。" >&2
    return 1
  fi

  local -a front_accept_rule=(
    -p tcp --dport "$PROXY_PORT"
    -m comment --comment "${APP}-front-accept"
    -j ACCEPT
  )
  local -a backend_drop_rule=(
    ! -i lo
    -p tcp --dport "$NODE_PORT"
    -m comment --comment "${APP}-backend-drop"
    -j DROP
  )
  local -a front_udp_accept_rule=(
    -p udp --dport "$PROXY_PORT"
    -m comment --comment "${APP}-front-udp-accept"
    -j ACCEPT
  )
  local -a backend_udp_drop_rule=(
    ! -i lo
    -p udp --dport "$NODE_PORT"
    -m comment --comment "${APP}-backend-udp-drop"
    -j DROP
  )

  if [[ $action == start ]]; then
    "$ipt" -t raw -C PREROUTING "${backend_drop_rule[@]}" >/dev/null 2>&1 ||
      "$ipt" -t raw -I PREROUTING 1 "${backend_drop_rule[@]}"
    "$ipt" -C INPUT "${front_accept_rule[@]}" >/dev/null 2>&1 ||
      "$ipt" -I INPUT 1 "${front_accept_rule[@]}"
    if [[ ${UDP_MODE:-none} != none ]]; then
      "$ipt" -t raw -C PREROUTING "${backend_udp_drop_rule[@]}" >/dev/null 2>&1 ||
        "$ipt" -t raw -I PREROUTING 1 "${backend_udp_drop_rule[@]}"
      "$ipt" -C INPUT "${front_udp_accept_rule[@]}" >/dev/null 2>&1 ||
        "$ipt" -I INPUT 1 "${front_udp_accept_rule[@]}"
    fi
  else
    while "$ipt" -C INPUT "${front_accept_rule[@]}" >/dev/null 2>&1; do
      "$ipt" -D INPUT "${front_accept_rule[@]}"
    done
    while "$ipt" -t raw -C PREROUTING "${backend_drop_rule[@]}" >/dev/null 2>&1; do
      "$ipt" -t raw -D PREROUTING "${backend_drop_rule[@]}"
    done
    while "$ipt" -C INPUT "${front_udp_accept_rule[@]}" >/dev/null 2>&1; do
      "$ipt" -D INPUT "${front_udp_accept_rule[@]}"
    done
    while "$ipt" -t raw -C PREROUTING "${backend_udp_drop_rule[@]}" >/dev/null 2>&1; do
      "$ipt" -t raw -D PREROUTING "${backend_udp_drop_rule[@]}"
    done
  fi
}

case "${1:-}" in
  start)
    manage_family start iptables
    if [[ -s /proc/net/if_inet6 ]]; then
      manage_family start ip6tables
    fi
    ;;
  stop)
    manage_family stop iptables
    manage_family stop ip6tables || true
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
  local quic_dependency=""
  if [[ $UDP_MODE != none ]]; then
    quic_dependency="Requires=${QUIC_APP}.service"
    quic_dependency+=$'\nAfter='"${QUIC_APP}.service"
  fi

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TLS 节点 SNI 分流服务
After=network-online.target firewalld.service nftables.service
Wants=network-online.target
${quic_dependency}

[Service]
Type=simple
ExecStartPre=${nginx_bin} -t -c ${NGINX_CONF} -p ${BASE_DIR}/
ExecStartPre=${FW_HELPER} start
ExecStart=${nginx_bin} -c ${NGINX_CONF} -p ${BASE_DIR}/ -g "daemon off;"
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

read_udp_mode() {
  local old_mode=${1:-none}
  local choice
  while true; do
    printf '\n请选择 UDP/HY2 模式：\n'
    printf '  1) 不启用 UDP\n'
    printf '  2) HY2（无混淆）\n'
    printf '  3) HY2（Salamander）\n'
    if [[ $old_mode == none ]]; then
      printf '  直接回车：1\n'
    else
      printf '  直接回车：保持当前模式\n'
    fi
    read -r -p "请选择 [1-3]: " choice
    if [[ -z $choice && $old_mode != none ]]; then
      UDP_MODE=$old_mode
      return
    fi
    case "${choice:-1}" in
      1) UDP_MODE=none; return ;;
      2) UDP_MODE=plain; return ;;
      3) UDP_MODE=salamander; return ;;
      *) warn "请输入 1 到 3。" ;;
    esac
  done
}

read_install_values() {
  local old_node_port old_proxy_port old_sni old_udp_mode input suggested_proxy_port

  SALAMANDER_NEW_PASSWORD=""
  load_state
  old_node_port=$NODE_PORT
  old_proxy_port=$PROXY_PORT
  old_sni=$FAKE_SNI
  old_udp_mode=${UDP_MODE:-none}

  printf '\n请填写后端端口、选择大厂 SNI 并设置 Nginx 公网端口。\n\n'

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

  if valid_port "$old_proxy_port" && [[ $old_proxy_port -ne $NODE_PORT ]]; then
    suggested_proxy_port=$old_proxy_port
  else
    suggested_proxy_port=$((NODE_PORT + 1))
    if (( suggested_proxy_port > 65535 )); then
      suggested_proxy_port=39001
    fi
  fi

  while true; do
    read -r -p "请输入 Nginx 公网端口 [$suggested_proxy_port]: " input
    PROXY_PORT=${input:-$suggested_proxy_port}
    if ! valid_port "$PROXY_PORT"; then
      warn "端口必须是 1 到 65535 之间的数字。"
      continue
    fi
    if [[ $PROXY_PORT -eq $NODE_PORT ]]; then
      warn "Nginx 公网端口不能与节点后端端口相同。"
      continue
    fi
    if port_is_in_use "$PROXY_PORT" && [[ $PROXY_PORT != "$old_proxy_port" ]]; then
      warn "端口 $PROXY_PORT 已被其他服务占用。"
      continue
    fi
    break
  done

  read_udp_mode "$old_udp_mode"
  if [[ $UDP_MODE == salamander ]]; then
    if [[ -s $SALAMANDER_KEY_FILE ]]; then
      read -r -p "请输入节点的 Salamander 密码（直接回车保留）: " input
      if [[ -n $input ]]; then
        local first=$input second
        read -r -p "请再次输入 Salamander 密码: " second
        [[ $first == "$second" ]] || die "两次 Salamander 密码不一致。"
        [[ ${#first} -ge 4 ]] || die "Salamander 密码至少 4 个字符。"
        SALAMANDER_NEW_PASSWORD=$first
      fi
    else
      write_salamander_key
    fi
  fi
}

install_or_reconfigure() {
  local module_path

  load_state
  read_install_values

  printf '\n准备应用以下配置：\n'
  printf '  节点后端端口：%s（仅供本机 Nginx 回连）\n' "$NODE_PORT"
  printf '  Nginx 公网端口：%s（用户连接此端口）\n' "$PROXY_PORT"
  printf '  大厂 SNI：%s\n' "$FAKE_SNI"
  case "$UDP_MODE" in
    plain) printf '  UDP/HY2：已启用（无混淆）\n' ;;
    salamander) printf '  UDP/HY2：已启用（Salamander）\n' ;;
    *) printf '  UDP/HY2：未启用\n' ;;
  esac
  printf '  节点后端配置及密码：保持不变\n'
  printf '  HTTP 申请证书及 80 端口：不修改\n\n'
  confirm "确认安装或重新配置吗？" || {
    info "操作已取消。"
    return
  }

  install_dependencies

  if [[ $UDP_MODE == none ]] && ! tcp_port_is_listening "$NODE_PORT"; then
    die "TCP 端口 $NODE_PORT 没有服务监听。请先确认 TCP 节点已正常运行。"
  fi
  if [[ $UDP_MODE != none ]] &&
    ! tcp_port_is_listening "$NODE_PORT" && ! udp_port_is_listening "$NODE_PORT"; then
    die "TCP/UDP 端口 $NODE_PORT 都没有服务监听。请先确认节点已正常运行。"
  fi
  if [[ $UDP_MODE != none ]] && ! udp_port_is_listening "$NODE_PORT"; then
    die "UDP 端口 $NODE_PORT 没有服务监听。请先确认 HY2 节点已正常运行。"
  fi

  # 先撤销旧转发，保证重新配置时不会残留规则或占用内部端口。
  cleanup_legacy_install
  if systemctl is-active --quiet "$APP" 2>/dev/null; then
    systemctl stop "$APP"
  fi
  if [[ -x $FW_HELPER ]]; then
    "$FW_HELPER" stop >/dev/null 2>&1 || true
  fi
  cleanup_quic_filter
  rm -f "/var/log/${APP}.log" "/run/${APP}.pid"

  if port_is_in_use "$PROXY_PORT"; then
    die "Nginx 公网端口 $PROXY_PORT 仍被其他服务占用，请重新运行并选择其他端口。"
  fi
  if [[ $UDP_MODE != none ]]; then
    local filter_start=$((PROXY_PORT + 1))
    (( filter_start <= 65535 )) || filter_start=39001
    QUIC_FILTER_PORT=$(find_free_udp_port "$filter_start") || die "没有可用的本机 UDP 过滤端口。"
  else
    QUIC_FILTER_PORT=""
  fi

  module_path=$(find_stream_module) || die "没有找到 Nginx Stream 模块。"
  save_salamander_key
  write_state
  write_logrotate_config
  write_nginx_config "$module_path"
  write_firewall_helper
  build_quic_filter
  write_quic_filter_service
  write_service

  nginx -t -c "$NGINX_CONF" -p "$BASE_DIR/"
  systemctl daemon-reload
  if [[ $UDP_MODE != none ]]; then
    systemctl enable --now "$QUIC_APP"
    systemctl is-active --quiet "$QUIC_APP" || die "QUIC SNI 过滤服务启动失败。"
  fi
  systemctl enable --now "$APP"
  systemctl is-active --quiet "$APP" || die "服务启动失败，请运行 systemctl status ${APP} 检查状态。"

  printf '\n'
  ok "安装/配置完成。"
  printf '  节点后端端口：%s（公网已封锁）\n' "$NODE_PORT"
  printf '  用户连接端口：%s\n' "$PROXY_PORT"
  printf '  客户端 SNI：%s\n' "$FAKE_SNI"
  if [[ $UDP_MODE == salamander ]]; then
    printf '  UDP/HY2：Salamander 已启用\n'
  elif [[ $UDP_MODE == plain ]]; then
    printf '  UDP/HY2：无混淆\n'
  fi
  printf '\n客户端或面板订阅需要修改：\n'
  printf '  1. SNI 改为 %s\n' "$FAKE_SNI"
  printf '  2. 端口改为 %s\n' "$PROXY_PORT"
  printf '  3. 开启“跳过证书验证 / insecure”\n'
  printf '  4. 节点地址和密码保持原样\n'
  printf '\n'
  warn "若客户端支持证书公钥固定，建议固定公钥，不要只依赖 insecure。"
  warn "节点后端如有“拒绝未知 SNI”选项，请将其关闭。"
  if [[ $UDP_MODE == none ]]; then
    warn "请确认云厂商安全组已经放行 TCP ${PROXY_PORT}，主机防火墙无法代替云安全组。"
  else
    warn "请确认云厂商安全组已经放行 TCP 和 UDP ${PROXY_PORT}。"
  fi
}

show_status() {
  load_state
  printf '\n========== 当前状态 ==========\n'
  if [[ -z $NODE_PORT ]]; then
    printf '状态：尚未安装\n'
    return
  fi

  printf 'TLS 后端端口：%s（禁止公网直连）\n' "$NODE_PORT"
  printf 'Nginx 公网端口：%s（用户连接端口）\n' "$PROXY_PORT"
  printf '大厂 SNI：%s\n' "$FAKE_SNI"
  case "${UDP_MODE:-none}" in
    plain) printf 'UDP/HY2：已启用（无混淆）\n' ;;
    salamander) printf 'UDP/HY2：已启用（Salamander）\n' ;;
    *) printf 'UDP/HY2：未启用\n' ;;
  esac

  if systemctl is-active --quiet "$APP" 2>/dev/null; then
    printf '分流服务：运行中\n'
  elif systemctl is-active --quiet "$LEGACY_APP" 2>/dev/null; then
    printf '分流服务：旧版正在运行，请选择“安装 / 重新配置”完成迁移\n'
  else
    printf '分流服务：未运行\n'
  fi

  if tcp_port_is_listening "$NODE_PORT"; then
    printf 'TCP 后端监听：正常\n'
  elif [[ ${UDP_MODE:-none} != none ]]; then
    printf 'TCP 后端监听：未启用（仅使用 HY2 时正常）\n'
  else
    printf 'TCP 后端监听：异常，端口未监听\n'
  fi

  if [[ ${UDP_MODE:-none} != none ]]; then
    if udp_port_is_listening "$NODE_PORT"; then
      printf 'HY2 后端 UDP 监听：正常\n'
    else
      printf 'HY2 后端 UDP 监听：异常，端口未监听\n'
    fi
    if udp_port_is_listening "$PROXY_PORT"; then
      printf 'Nginx 公网 UDP 监听：正常\n'
    else
      printf 'Nginx 公网 UDP 监听：异常，端口未监听\n'
    fi
    if systemctl is-active --quiet "$QUIC_APP" 2>/dev/null; then
      printf 'QUIC SNI 过滤：运行中\n'
    else
      printf 'QUIC SNI 过滤：未运行\n'
    fi
  fi

  if port_is_listening "$PROXY_PORT"; then
    printf 'Nginx 公网监听：正常\n'
  else
    printf 'Nginx 公网监听：异常，端口未监听\n'
  fi

  if iptables -S INPUT 2>/dev/null | grep -q "${APP}-front-accept"; then
    printf 'IPv4 Nginx端口：已开放\n'
  else
    printf 'IPv4 Nginx端口：未开放\n'
  fi
  if iptables -t raw -S PREROUTING 2>/dev/null | grep -q "${APP}-backend-drop"; then
    printf 'IPv4 后端端口：已封锁公网访问\n'
  else
    printf 'IPv4 后端端口：未封锁\n'
  fi
  if [[ ${UDP_MODE:-none} != none ]]; then
    if iptables -S INPUT 2>/dev/null | grep -q "${APP}-front-udp-accept"; then
      printf 'IPv4 Nginx UDP端口：已开放\n'
    else
      printf 'IPv4 Nginx UDP端口：未开放\n'
    fi
    if iptables -t raw -S PREROUTING 2>/dev/null | grep -q "${APP}-backend-udp-drop"; then
      printf 'IPv4 后端 UDP端口：已封锁公网访问\n'
    else
      printf 'IPv4 后端 UDP端口：未封锁\n'
    fi
  fi
  if [[ -s /proc/net/if_inet6 ]]; then
    if ip6tables -S INPUT 2>/dev/null | grep -q "${APP}-front-accept" &&
      ip6tables -t raw -S PREROUTING 2>/dev/null | grep -q "${APP}-backend-drop"; then
      if [[ ${UDP_MODE:-none} == none ]] ||
        (ip6tables -S INPUT 2>/dev/null | grep -q "${APP}-front-udp-accept" &&
          ip6tables -t raw -S PREROUTING 2>/dev/null | grep -q "${APP}-backend-udp-drop"); then
        printf 'IPv6 入口及后端保护：已启用\n'
      else
        printf 'IPv6 入口及后端保护：未完整启用\n'
      fi
    else
      printf 'IPv6 入口及后端保护：未完整启用\n'
    fi
  fi
}

start_service() {
  load_state
  [[ -f $SERVICE_FILE ]] || die "尚未安装，请先选择“安装 / 重新配置”。"
  if [[ ${UDP_MODE:-none} != none ]]; then
    systemctl start "$QUIC_APP"
  fi
  systemctl start "$APP"
  ok "服务已启动。"
}

stop_service() {
  load_state
  [[ -f $SERVICE_FILE ]] || die "尚未安装。"
  systemctl stop "$APP"
  if [[ ${UDP_MODE:-none} != none ]]; then
    systemctl stop "$QUIC_APP" || true
  fi
  ok "服务已停止；原后端端口继续保持封锁，卸载后才恢复直连。"
}

restart_service() {
  load_state
  [[ -f $SERVICE_FILE ]] || die "尚未安装，请先选择“安装 / 重新配置”。"
  if [[ ${UDP_MODE:-none} != none ]]; then
    systemctl restart "$QUIC_APP"
  fi
  systemctl restart "$APP"
  ok "服务已重启。"
}

show_logs() {
  load_state
  printf '\n========== 服务状态 ==========\n'
  systemctl --no-pager --full status "$APP" 2>/dev/null || true
  if [[ ${UDP_MODE:-none} != none ]]; then
    printf '\n========== QUIC 过滤服务 ==========\n'
    systemctl --no-pager --full status "$QUIC_APP" 2>/dev/null || true
  fi

  printf '\n========== 最近 SNI 路由 ==========\n'
  if [[ -f ${LOG_DIR}/access.log ]]; then
    tail -n 100 "${LOG_DIR}/access.log"
  else
    printf '暂无访问日志。\n'
  fi

  if [[ ${UDP_MODE:-none} != none ]]; then
    printf '\n========== 最近 QUIC SNI 放行 ==========\n'
    if [[ -f ${LOG_DIR}/quic.log ]]; then
      tail -n 100 "${LOG_DIR}/quic.log"
    else
      printf '暂无 QUIC 访问日志。\n'
    fi
  fi
  printf '\n========== 最近错误 ==========\n'
  if [[ -f ${LOG_DIR}/error.log ]]; then
    tail -n 100 "${LOG_DIR}/error.log"
  else
    printf '暂无错误日志。\n'
  fi
}

remove_app() {
  load_state
  if [[ ! -f $SERVICE_FILE && ! -d $BASE_DIR ]] && ! legacy_install_exists; then
    info "当前没有安装。"
    return
  fi

  confirm "确认卸载 SNI 分流吗？卸载后 TLS 节点将恢复直接连接。" || {
    info "操作已取消。"
    return
  }

  cleanup_legacy_install
  cleanup_quic_filter
  if [[ -x $FW_HELPER ]]; then
    "$FW_HELPER" stop || true
  fi
  systemctl disable --now "$APP" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$FW_HELPER"
  rm -f "/var/log/${APP}.log" "/run/${APP}.pid"
  rm -f "$LOGROTATE_FILE"
  rm -rf "$LOG_DIR"
  [[ ! -d $CACHE_DIR ]] || chmod -R u+w "$CACHE_DIR" 2>/dev/null || true
  rm -rf "$CACHE_DIR"
  rm -rf "$BASE_DIR"
  rm -rf "$GO_TOOLCHAIN_ROOT"
  rmdir "$(dirname "$GO_TOOLCHAIN_ROOT")" >/dev/null 2>&1 || true
  systemctl daemon-reload
  ok "已卸载，Nginx 和系统已有依赖予以保留，原节点端口已恢复直连。"
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
    printf '  6. 查看日志\n'
    printf '  7. 卸载分流\n'
    printf '  0. 退出\n'
    printf '========================================\n'
    read -r -p "请选择 [0-7]: " choice

    case "$choice" in
      1) install_or_reconfigure; pause_menu ;;
      2) show_status; pause_menu ;;
      3) start_service; pause_menu ;;
      4) stop_service; pause_menu ;;
      5) restart_service; pause_menu ;;
      6) show_logs; pause_menu ;;
      7) remove_app; pause_menu ;;
      0) exit 0 ;;
      *) warn "请输入 0 到 7。" ;;
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
  logs) show_logs ;;
  remove|uninstall) remove_app ;;
  *) die "未知参数。直接运行脚本可进入中文菜单。" ;;
esac
