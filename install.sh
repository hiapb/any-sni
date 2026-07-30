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
QUIC_APP="${APP}-quic"
QUIC_FILTER_BIN="/usr/local/bin/${QUIC_APP}"
QUIC_FILTER_SERVICE_FILE="/etc/systemd/system/${QUIC_APP}.service"
QUIC_FILTER_SOURCE_DIR="/usr/local/src/${QUIC_APP}"
GO_VERSION="1.26.5"
GO_TOOLCHAIN_ROOT="/opt/${APP}-go/${GO_VERSION}"
CACHE_DIR="/var/cache/${APP}"
LOG_DIR="/var/log/${APP}"
LOGROTATE_FILE="/etc/logrotate.d/${APP}"
GO_BIN=""
XBOARD_SERVICE="xboard-node.service"
XBOARD_COMMIT="0a29338e1f102a462363ce3527417029f89bab28"
XBOARD_ARCHIVE_SHA256="fe7ca4d44e0a30d01b74d01ce9e0025d5656bb0fd63dbe1634d5710404c59f90"
SINGBOX_COMMIT="2e665cb7e295949ba7c5536f9b7754f94ab78cee"
SINGBOX_ARCHIVE_SHA256="dbd9776319bba3bab9543c384b1558ecac43d590650d6ef179a85bd0d45282d5"
XBOARD_SOURCE_DIR="/usr/local/src/${APP}-xboard-node"
SINGBOX_SOURCE_DIR="/usr/local/src/${APP}-sing-box"
XBOARD_BACKUP_BIN="${BASE_DIR}/xboard-node.original"
XBOARD_PATCH_STATE="${BASE_DIR}/xboard-patch.env"
XBOARD_DROPIN_DIR="/etc/systemd/system/${XBOARD_SERVICE}.d"
XBOARD_DROPIN_FILE="${XBOARD_DROPIN_DIR}/${APP}.conf"
XBOARD_HY2_MARKER_PREFIX="/run/${APP}-xboard-hy2"
SINGBOX_SERVICE="sing-box.service"
SINGBOX_CONFIG_FILE="/etc/sing-box/config.json"
STANDALONE_SINGBOX_VERSION="1.13.15"
STANDALONE_SINGBOX_ARCHIVE_SHA256="b43456c0cb2d4d7b81664010b2149a35ed6e3f6c245d78bcc7caf27c46eca816"
STANDALONE_SINGBOX_SOURCE_DIR="/usr/local/src/${APP}-standalone-sing-box"
STANDALONE_SINGBOX_BACKUP_BIN="${BASE_DIR}/sing-box.original"
STANDALONE_SINGBOX_PATCH_STATE="${BASE_DIR}/sing-box-patch.env"
STANDALONE_SINGBOX_DROPIN_DIR="/etc/systemd/system/${SINGBOX_SERVICE}.d"
STANDALONE_SINGBOX_DROPIN_FILE="${STANDALONE_SINGBOX_DROPIN_DIR}/${APP}.conf"
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

service_owns_udp_port() {
  local service=$1 port=$2 pid
  pid=$(systemctl show --property MainPID --value "$service" 2>/dev/null || true)
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  ss -H -lunp "sport = :${port}" 2>/dev/null | grep -Eq "pid=${pid},"
}

xboard_hy2_marker_file() {
  printf '%s-%s.ready\n' "$XBOARD_HY2_MARKER_PREFIX" "$1"
}

xboard_hysteria2_is_confirmed() {
  local port=$1 expected_sni=${2:-} marker marker_port marker_sni
  marker=$(xboard_hy2_marker_file "$port")
  service_owns_udp_port "$XBOARD_SERVICE" "$port" || return 1
  [[ -r $marker ]] || return 1
  read -r marker_port marker_sni <"$marker" || return 1
  [[ $marker_port == "$port" ]] || return 1
  valid_hostname "$marker_sni" || return 1
  [[ -z $expected_sni || $marker_sni == "$expected_sni" ]]
}

singbox_has_hysteria2_port() {
  local port=$1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -r $SINGBOX_CONFIG_FILE ]] || return 1
  jq -e --argjson port "$port" \
    'any(.inbounds[]?; .type == "hysteria2" and .listen_port == $port)' \
    "$SINGBOX_CONFIG_FILE" >/dev/null 2>&1
}

standalone_singbox_version_supported() {
  local bin first_line version
  bin=$(find_standalone_singbox_binary 2>/dev/null) || return 1
  first_line=$("$bin" version 2>/dev/null) || return 1
  first_line=${first_line%%$'\n'*}
  version=${first_line#sing-box version }
  [[ $version == "$STANDALONE_SINGBOX_VERSION" ||
    $version == "tls-sni-${STANDALONE_SINGBOX_VERSION}" ]]
}

standalone_singbox_hysteria2_is_confirmed() {
  local port=$1
  service_owns_udp_port "$SINGBOX_SERVICE" "$port" &&
    singbox_has_hysteria2_port "$port" &&
    standalone_singbox_version_supported
}

standalone_singbox_sni_guard_is_configured() {
  local port=$1 expected_sni=$2
  [[ -r $STANDALONE_SINGBOX_DROPIN_FILE ]] || return 1
  grep -Fxq "Environment=SING_BOX_HYSTERIA2_SNI_GUARD=${expected_sni}" \
    "$STANDALONE_SINGBOX_DROPIN_FILE" &&
    grep -Fxq "Environment=SING_BOX_HYSTERIA2_SNI_GUARD_PORT=${port}" \
      "$STANDALONE_SINGBOX_DROPIN_FILE"
}

detect_udp_backend() {
  local port=$1
  if service_owns_udp_port "$XBOARD_SERVICE" "$port"; then
    printf 'xboard\n'
    return 0
  fi
  if standalone_singbox_hysteria2_is_confirmed "$port"; then
    printf 'singbox\n'
    return 0
  fi
  return 1
}

udp_backend_service() {
  case "${UDP_BACKEND:-none}" in
    xboard) printf '%s\n' "$XBOARD_SERVICE" ;;
    singbox) printf '%s\n' "$SINGBOX_SERVICE" ;;
    *) return 1 ;;
  esac
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
  UDP_BACKEND="none"
  XBOARD_BIN_PATH=""
  SINGBOX_BIN_PATH=""
  if [[ -r $STATE_FILE ]]; then
    # 状态文件只允许 root 写入，并且值在写入前已经校验。
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  elif [[ -r $LEGACY_STATE_FILE ]]; then
    # 读取旧版配置作为重新安装时的默认值。
    # shellcheck disable=SC1090
    source "$LEGACY_STATE_FILE"
  fi
  case "${UDP_MODE:-none}" in
    plain|salamander) UDP_MODE="kernel" ;;
  esac
  case "${UDP_BACKEND:-none}" in
    xboard|singbox) ;;
    *) UDP_BACKEND="none" ;;
  esac
  if [[ $UDP_MODE == kernel && $UDP_BACKEND == none ]]; then
    if [[ -r $XBOARD_PATCH_STATE || -f $XBOARD_DROPIN_FILE ]]; then
      UDP_BACKEND=xboard
    elif [[ -r $STANDALONE_SINGBOX_PATCH_STATE || -f $STANDALONE_SINGBOX_DROPIN_FILE ]]; then
      UDP_BACKEND=singbox
    fi
  fi
}

go_version_ok() {
  local go_cmd=${1:-go} version minor
  command -v "$go_cmd" >/dev/null 2>&1 || [[ -x $go_cmd ]] || return 1
  version=$("$go_cmd" version 2>/dev/null) || return 1
  [[ $version =~ go1\.([0-9]+) ]] || return 1
  minor=${BASH_REMATCH[1]}
  (( minor >= 26 ))
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
    x86_64|amd64) arch=amd64; checksum=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053 ;;
    aarch64|arm64) arch=arm64; checksum=fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49 ;;
    *) die "HY2 内核 SNI 模式仅支持 amd64 和 arm64。" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载 Go 工具链。"
  command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum，无法校验 Go 工具链。"
  command -v tar >/dev/null 2>&1 || die "缺少 tar，无法解压 Go 工具链。"
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT
  archive="$tmp_dir/go${GO_VERSION}.linux-${arch}.tar.gz"
  url="https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"
  info "正在安装 Go ${GO_VERSION}（仅用于构建补丁版 xboard-node）..."
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
  if [[ $UDP_MODE != none ]]; then
    command -v curl >/dev/null 2>&1 || packages_needed=1
    command -v sha256sum >/dev/null 2>&1 || packages_needed=1
    command -v tar >/dev/null 2>&1 || packages_needed=1
    command -v patch >/dev/null 2>&1 || packages_needed=1
  fi

  if (( packages_needed == 0 )); then
    info "所需组件已经安装。"
    [[ $UDP_MODE == none ]] || ensure_go
    return 0
  fi

  systemctl is-active --quiet nginx 2>/dev/null && nginx_was_active=1
  info "正在安装 Nginx Stream、构建工具和网络组件..."

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nginx libnginx-mod-stream iptables iproute2 logrotate curl ca-certificates tar coreutils patch
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx nginx-mod-stream iptables iproute logrotate curl ca-certificates tar coreutils patch
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx nginx-mod-stream iptables iproute logrotate curl ca-certificates tar coreutils patch
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
  if [[ $UDP_MODE != none ]]; then
    command -v patch >/dev/null 2>&1 || die "patch 安装失败。"
    ensure_go
  fi
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
UDP_BACKEND=${UDP_BACKEND:-none}
XBOARD_BIN_PATH=${XBOARD_BIN_PATH:-}
SINGBOX_BIN_PATH=${SINGBOX_BIN_PATH:-}
EOF
  chmod 0600 "$STATE_FILE"
}

find_xboard_binary() {
  local candidate pid
  if [[ -n ${XBOARD_BIN_PATH:-} && -x $XBOARD_BIN_PATH ]]; then
    printf '%s\n' "$XBOARD_BIN_PATH"
    return 0
  fi
  pid=$(systemctl show --property MainPID --value "$XBOARD_SERVICE" 2>/dev/null || true)
  if [[ $pid =~ ^[1-9][0-9]*$ ]]; then
    candidate=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
    if [[ -n $candidate && -x $candidate ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  for candidate in \
    /usr/local/bin/xboard-node \
    /usr/bin/xboard-node \
    /usr/local/xboard-node/xboard-node \
    /opt/xboard-node/xboard-node; do
    if [[ -x $candidate ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate=$(command -v xboard-node 2>/dev/null || true)
  if [[ -n $candidate && -x $candidate ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

download_source_archive() {
  local name=$1 url=$2 checksum=$3 destination=$4 archive=$5
  info "正在下载固定版本的 ${name} 源码..."
  curl -fL --retry 3 --connect-timeout 15 -o "$archive" "$url"
  printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c - >/dev/null ||
    die "${name} 源码校验失败。"
  rm -rf "$destination"
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination" --strip-components=1
}

write_xboard_source_patches() {
  local patch_dir=$1
  cat >"${patch_dir}/sing-box-sni-guard.patch" <<'PATCH'
--- a/option/tls.go
+++ b/option/tls.go
@@ -12,6 +12,7 @@
 type InboundTLSOptions struct {
 	Enabled                          bool                                `json:"enabled,omitempty"`
 	ServerName                       string                              `json:"server_name,omitempty"`
+	StrictServerName                 bool                                `json:"strict_server_name,omitempty"`
 	Insecure                         bool                                `json:"insecure,omitempty"`
 	ALPN                             badoption.Listable[string]          `json:"alpn,omitempty"`
 	MinVersion                       string                              `json:"min_version,omitempty"`
--- a/common/tls/std_server.go
+++ b/common/tls/std_server.go
@@ -369,6 +369,16 @@
 		echKeyPath:            echKeyPath,
 	}
 	serverConfig.config.GetConfigForClient = func(info *tls.ClientHelloInfo) (*tls.Config, error) {
+		if options.StrictServerName {
+			expectedServerName := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(options.ServerName)), ".")
+			clientServerName := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(info.ServerName)), ".")
+			if expectedServerName == "" {
+				return nil, E.New("tls: strict_server_name requires server_name")
+			}
+			if clientServerName != expectedServerName {
+				return nil, E.New("tls: rejected client SNI")
+			}
+		}
 		serverConfig.access.Lock()
 		defer serverConfig.access.Unlock()
 		return serverConfig.config, nil
--- /dev/null
+++ b/common/tls/strict_server_name_test.go
@@ -0,0 +1,36 @@
+package tls
+
+import (
+	"context"
+	stdTLS "crypto/tls"
+	"testing"
+
+	boxLog "github.com/sagernet/sing-box/log"
+	"github.com/sagernet/sing-box/option"
+)
+
+func TestStrictServerName(t *testing.T) {
+	serverConfig, err := NewSTDServer(context.Background(), boxLog.NewNOPFactory().Logger(), option.InboundTLSOptions{
+		Enabled:          true,
+		ServerName:       "www.itunes.com",
+		StrictServerName: true,
+		Insecure:         true,
+	})
+	if err != nil {
+		t.Fatal(err)
+	}
+	stdConfig, err := serverConfig.STDConfig()
+	if err != nil {
+		t.Fatal(err)
+	}
+	for _, serverName := range []string{"www.itunes.com", "WWW.ITUNES.COM."} {
+		if _, err = stdConfig.GetConfigForClient(&stdTLS.ClientHelloInfo{ServerName: serverName}); err != nil {
+			t.Fatalf("expected %q to pass: %v", serverName, err)
+		}
+	}
+	for _, serverName := range []string{"", "mtth.mm1998.com"} {
+		if _, err = stdConfig.GetConfigForClient(&stdTLS.ClientHelloInfo{ServerName: serverName}); err == nil {
+			t.Fatalf("expected %q to be rejected", serverName)
+		}
+	}
+}
PATCH

  cat >"${patch_dir}/xboard-node-sni-guard.patch" <<'PATCH'
--- a/internal/kernel/singbox/config.go
+++ b/internal/kernel/singbox/config.go
@@ -4,6 +4,7 @@
 	"encoding/base64"
 	"fmt"
 	"net"
+	"os"
 	"path/filepath"
 	"strconv"
 	"strings"
@@ -430,6 +431,7 @@
 }
 
 func buildInbound(nc *model.NodeSpec, users []model.UserSpec, tc kernel.TLSCert) M {
+	clearHysteria2SNIGuardMarker(nc)
 	base := M{
 		"tag":         nc.Protocol + "-in",
 		"listen":      "::",
@@ -678,6 +680,16 @@
 	if tls == nil {
 		nlog.Core().Warn("hysteria requires TLS certificate files on disk; configure cert_mode (self, file, http, dns, or content). Sing-box will not start this inbound without tls.")
 		return base
+	}
+	if guardedServerName, markerPath, guarded := hysteria2SNIGuard(nc); guarded {
+		tls["server_name"] = guardedServerName
+		tls["strict_server_name"] = true
+		if markerPath != "" {
+			content := fmt.Sprintf("%d %s\n", nc.ServerPort, guardedServerName)
+			if err := os.WriteFile(markerPath, []byte(content), 0o600); err != nil {
+				nlog.Core().Warn("cannot write hysteria2 SNI guard marker", "error", err)
+			}
+		}
 	}
 	// Hysteria/Hysteria2 uses QUIC and requires ALPN; default to h3 if not set.
 	if _, ok := tls["alpn"]; !ok {
@@ -685,8 +697,36 @@
 	}
 	base["tls"] = tls
 	return base
+}
+
+func hysteria2SNIGuard(nc *model.NodeSpec) (string, string, bool) {
+	if nc == nil || nc.Protocol != "hysteria" || nc.Version != 2 {
+		return "", "", false
+	}
+	serverName := strings.TrimSpace(os.Getenv("XBOARD_HYSTERIA2_SNI_GUARD"))
+	portText := strings.TrimSpace(os.Getenv("XBOARD_HYSTERIA2_SNI_GUARD_PORT"))
+	port, err := strconv.Atoi(portText)
+	if serverName == "" || err != nil || port != nc.ServerPort {
+		return "", "", false
+	}
+	markerPath := strings.TrimSpace(os.Getenv("XBOARD_HYSTERIA2_SNI_GUARD_MARKER"))
+	return serverName, markerPath, true
 }
 
+func clearHysteria2SNIGuardMarker(nc *model.NodeSpec) {
+	if nc == nil {
+		return
+	}
+	port, err := strconv.Atoi(strings.TrimSpace(os.Getenv("XBOARD_HYSTERIA2_SNI_GUARD_PORT")))
+	if err != nil || port != nc.ServerPort {
+		return
+	}
+	markerPath := strings.TrimSpace(os.Getenv("XBOARD_HYSTERIA2_SNI_GUARD_MARKER"))
+	if markerPath != "" {
+		_ = os.Remove(markerPath)
+	}
+}
+
 func buildTUIC(base M, nc *model.NodeSpec, users []model.UserSpec, tc kernel.TLSCert) M {
 	base["type"] = "tuic"
 
--- a/internal/kernel/singbox/config_test.go
+++ b/internal/kernel/singbox/config_test.go
@@ -2,6 +2,8 @@
 
 import (
 	"encoding/json"
+	"os"
+	"path/filepath"
 	"reflect"
 	"testing"
 
@@ -336,6 +338,44 @@
 	assertMapValue(t, tls, "enabled", true)
 }
 
+func TestBuildInbound_Hysteria2_WithSNIGuard(t *testing.T) {
+	markerPath := filepath.Join(t.TempDir(), "hysteria2.ready")
+	t.Setenv("XBOARD_HYSTERIA2_SNI_GUARD", "www.itunes.com")
+	t.Setenv("XBOARD_HYSTERIA2_SNI_GUARD_PORT", "444")
+	t.Setenv("XBOARD_HYSTERIA2_SNI_GUARD_MARKER", markerPath)
+	nc := &panel.NodeConfig{
+		Protocol:   "hysteria",
+		ServerPort: 444,
+		Version:    2,
+	}
+	inbound := buildInbound(testNodeSpec(nc), testUsers, kernel.TLSCert{CertPEM: []byte("CERT"), KeyPEM: []byte("KEY")})
+	tls := inbound["tls"].(M)
+	assertMapValue(t, tls, "server_name", "www.itunes.com")
+	assertMapValue(t, tls, "strict_server_name", true)
+	marker, err := os.ReadFile(markerPath)
+	if err != nil {
+		t.Fatal(err)
+	}
+	if string(marker) != "444 www.itunes.com\n" {
+		t.Fatalf("unexpected SNI guard marker: %q", marker)
+	}
+
+	// A different protocol on the same UDP port must clear the marker.
+	tuic := &panel.NodeConfig{Protocol: "tuic", ServerPort: 444}
+	buildInbound(testNodeSpec(tuic), testUsers, kernel.TLSCert{CertPEM: []byte("CERT"), KeyPEM: []byte("KEY")})
+	if _, err = os.Stat(markerPath); !os.IsNotExist(err) {
+		t.Fatalf("SNI guard marker was not cleared for TUIC: %v", err)
+	}
+
+	// Hysteria v1 on the selected port must not receive the strict SNI guard.
+	hy1 := &panel.NodeConfig{Protocol: "hysteria", ServerPort: 444, Version: 1}
+	inbound = buildInbound(testNodeSpec(hy1), testUsers, kernel.TLSCert{CertPEM: []byte("CERT"), KeyPEM: []byte("KEY")})
+	tls = inbound["tls"].(M)
+	if _, exists := tls["strict_server_name"]; exists {
+		t.Fatal("SNI guard leaked to Hysteria v1")
+	}
+}
+
 func TestBuildInbound_Hysteria2_WithObfs(t *testing.T) {
 	nc := &panel.NodeConfig{
 		Protocol:     "hysteria",
PATCH
  chmod 0600 "${patch_dir}"/*.patch
}

build_patched_xboard() {
  local tmp_dir xboard_archive singbox_archive output
  local GOPROXY=${GOPROXY:-}
  if [[ -z $GOPROXY ]]; then
    GOPROXY='https://proxy.golang.org|https://goproxy.cn|direct'
  fi
  export GOPROXY
  ensure_go
  command -v patch >/dev/null 2>&1 || die "缺少 patch，无法应用 xboard-node 内核补丁。"
  systemctl cat "$XBOARD_SERVICE" >/dev/null 2>&1 ||
    die "没有找到 ${XBOARD_SERVICE}，请先安装并对接 xboard-node。"

  tmp_dir=$(mktemp -d)
  xboard_archive="${tmp_dir}/xboard-node.tar.gz"
  singbox_archive="${tmp_dir}/sing-box.tar.gz"
  write_xboard_source_patches "$tmp_dir"

  download_source_archive \
    "xboard-node" \
    "https://github.com/cedar2025/Xboard-Node/archive/${XBOARD_COMMIT}.tar.gz" \
    "$XBOARD_ARCHIVE_SHA256" \
    "$XBOARD_SOURCE_DIR" \
    "$xboard_archive"
  download_source_archive \
    "sing-box" \
    "https://github.com/cedar2025/sing-box/archive/${SINGBOX_COMMIT}.tar.gz" \
    "$SINGBOX_ARCHIVE_SHA256" \
    "$SINGBOX_SOURCE_DIR" \
    "$singbox_archive"

  patch --batch --forward -d "$SINGBOX_SOURCE_DIR" -p1 <"${tmp_dir}/sing-box-sni-guard.patch"
  patch --batch --forward -d "$XBOARD_SOURCE_DIR" -p1 <"${tmp_dir}/xboard-node-sni-guard.patch"

  mkdir -p "$CACHE_DIR/mod" "$CACHE_DIR/build"
  (
    cd "$SINGBOX_SOURCE_DIR"
    CGO_ENABLED=0 GOTOOLCHAIN=local \
      GOMODCACHE="$CACHE_DIR/mod" GOCACHE="$CACHE_DIR/build" \
      "$GO_BIN" test ./common/tls
  )
  (
    cd "$XBOARD_SOURCE_DIR"
    GOTOOLCHAIN=local "$GO_BIN" mod edit \
      -replace="github.com/sagernet/sing-box=${SINGBOX_SOURCE_DIR}"
    CGO_ENABLED=0 GOTOOLCHAIN=local \
      GOMODCACHE="$CACHE_DIR/mod" GOCACHE="$CACHE_DIR/build" \
      "$GO_BIN" test ./internal/kernel/singbox
    CGO_ENABLED=0 GOTOOLCHAIN=local \
      GOMODCACHE="$CACHE_DIR/mod" GOCACHE="$CACHE_DIR/build" \
      "$GO_BIN" build \
        -trimpath \
        -tags "with_quic with_utls with_wireguard with_acme with_clash_api" \
        -ldflags "-s -w -X main.version=tls-sni-${XBOARD_COMMIT:0:12}" \
        -o xboard-node.tls-sni ./cmd/xboard-node
  )
  output="${XBOARD_SOURCE_DIR}/xboard-node.tls-sni"
  [[ -x $output ]] || die "补丁版 xboard-node 构建失败。"
  "$GO_BIN" version -m "$output" >/dev/null 2>&1 || die "补丁版 xboard-node 校验失败。"
  rm -rf "$tmp_dir"
}

write_xboard_dropin() {
  local marker
  marker=$(xboard_hy2_marker_file "$NODE_PORT")
  mkdir -p "$XBOARD_DROPIN_DIR"
  cat >"$XBOARD_DROPIN_FILE" <<EOF
[Service]
Environment=XBOARD_HYSTERIA2_SNI_GUARD=${FAKE_SNI}
Environment=XBOARD_HYSTERIA2_SNI_GUARD_PORT=${NODE_PORT}
Environment=XBOARD_HYSTERIA2_SNI_GUARD_MARKER=${marker}
EOF
  chmod 0644 "$XBOARD_DROPIN_FILE"
}

wait_for_xboard_udp() {
  local attempt marker marker_value
  marker=$(xboard_hy2_marker_file "$NODE_PORT")
  for attempt in $(seq 1 30); do
    if systemctl is-active --quiet "$XBOARD_SERVICE" && service_owns_udp_port "$XBOARD_SERVICE" "$NODE_PORT"; then
      if [[ -r $marker ]]; then
        marker_value=$(<"$marker")
        [[ $marker_value == "$NODE_PORT $FAKE_SNI" ]] && return 0
      fi
      # The patched core writes the marker before binding the matching HY2
      # inbound. Owning the UDP port without it proves this is not that HY2.
      return 2
    fi
    systemctl is-failed --quiet "$XBOARD_SERVICE" && return 1
    sleep 1
  done
  return 1
}

install_patched_xboard() {
  local built_bin current_bin current_sha previous_patched_sha=""
  local rollback_bin rollback_dropin patched_sha marker start_status=0 had_dropin=0
  current_bin=$(find_xboard_binary) ||
    die "没有找到 xboard-node 可执行文件。"
  [[ $current_bin != *[[:space:]]* ]] || die "xboard-node 路径包含空白字符，无法安全处理。"
  XBOARD_BIN_PATH=$current_bin

  build_patched_xboard
  built_bin="${XBOARD_SOURCE_DIR}/xboard-node.tls-sni"
  mkdir -p "$BASE_DIR"
  current_sha=$(sha256_file "$current_bin")
  if [[ -r $XBOARD_PATCH_STATE ]]; then
    previous_patched_sha=$(awk -F= '$1 == "PATCHED_SHA256" { print $2; exit }' "$XBOARD_PATCH_STATE")
  fi
  if [[ ! -s $XBOARD_BACKUP_BIN ]]; then
    install -m 0755 "$current_bin" "$XBOARD_BACKUP_BIN"
  elif [[ -n $previous_patched_sha && $current_sha != "$previous_patched_sha" ]]; then
    # 节点管理程序可能已在补丁安装后升级二进制，更新恢复基线。
    install -m 0755 "$current_bin" "$XBOARD_BACKUP_BIN"
  fi

  rollback_bin=$(mktemp)
  install -m 0755 "$current_bin" "$rollback_bin"
  rollback_dropin="${rollback_bin}.dropin"
  if [[ -f $XBOARD_DROPIN_FILE ]]; then
    cp -a "$XBOARD_DROPIN_FILE" "$rollback_dropin"
    had_dropin=1
  fi

  write_xboard_dropin
  systemctl stop "$XBOARD_SERVICE"
  marker=$(xboard_hy2_marker_file "$NODE_PORT")
  rm -f "$marker"
  install -m 0755 "$built_bin" "$current_bin"
  systemctl daemon-reload

  if ! systemctl start "$XBOARD_SERVICE"; then
    start_status=1
  else
    wait_for_xboard_udp || start_status=$?
  fi
  if (( start_status != 0 )); then
    if (( start_status == 2 )); then
      warn "xboard-node 的 UDP ${NODE_PORT} 不是面板下发的 Hysteria2，正在恢复原版。"
    else
      warn "补丁版 xboard-node 启动失败，正在自动回滚。"
    fi
    systemctl stop "$XBOARD_SERVICE" >/dev/null 2>&1 || true
    install -m 0755 "$rollback_bin" "$current_bin"
    if (( had_dropin == 1 )); then
      install -m 0644 "$rollback_dropin" "$XBOARD_DROPIN_FILE"
    else
      rm -f "$XBOARD_DROPIN_FILE"
    fi
    systemctl daemon-reload
    systemctl start "$XBOARD_SERVICE" >/dev/null 2>&1 || true
    rm -f "$rollback_bin" "$rollback_dropin" "$marker"
    if (( start_status == 2 )); then
      return 2
    fi
    die "补丁版 xboard-node 未能监听 UDP ${NODE_PORT}，原二进制已经恢复。"
  fi

  rm -f "$rollback_bin" "$rollback_dropin"
  patched_sha=$(sha256_file "$current_bin")
  umask 077
  cat >"$XBOARD_PATCH_STATE" <<EOF
XBOARD_BIN_PATH=$current_bin
PATCHED_SHA256=$patched_sha
XBOARD_COMMIT=$XBOARD_COMMIT
SINGBOX_COMMIT=$SINGBOX_COMMIT
EOF
  chmod 0600 "$XBOARD_PATCH_STATE"
  ok "xboard-node 已替换为内核 SNI 校验版本。"
}

restore_xboard_node() {
  local current_sha="" marker_sha="" restore_bin=""
  if [[ -r $XBOARD_PATCH_STATE ]]; then
    # shellcheck disable=SC1090
    source "$XBOARD_PATCH_STATE"
    marker_sha=${PATCHED_SHA256:-}
    restore_bin=${XBOARD_BIN_PATH:-}
  fi
  if [[ -z $restore_bin ]]; then
    restore_bin=$(find_xboard_binary 2>/dev/null || true)
  fi

  rm -f "$XBOARD_DROPIN_FILE"
  rmdir "$XBOARD_DROPIN_DIR" >/dev/null 2>&1 || true
  systemctl daemon-reload

  if [[ -n $restore_bin && -x $restore_bin && -s $XBOARD_BACKUP_BIN ]]; then
    current_sha=$(sha256_file "$restore_bin")
    if [[ -z $marker_sha || $current_sha == "$marker_sha" ]]; then
      systemctl stop "$XBOARD_SERVICE" >/dev/null 2>&1 || true
      install -m 0755 "$XBOARD_BACKUP_BIN" "$restore_bin"
      systemctl start "$XBOARD_SERVICE" >/dev/null 2>&1 || true
      info "已恢复原版 xboard-node。"
    else
      warn "xboard-node 在安装补丁后又被修改，未覆盖当前二进制；仅移除了 SNI 环境配置。"
      systemctl restart "$XBOARD_SERVICE" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$XBOARD_PATCH_STATE" "$XBOARD_BACKUP_BIN"
  rm -f "${XBOARD_HY2_MARKER_PREFIX}-"*.ready
  rm -rf "$XBOARD_SOURCE_DIR" "$SINGBOX_SOURCE_DIR"
}

find_standalone_singbox_binary() {
  local candidate pid
  if [[ -n ${SINGBOX_BIN_PATH:-} && -x $SINGBOX_BIN_PATH ]]; then
    printf '%s\n' "$SINGBOX_BIN_PATH"
    return 0
  fi
  pid=$(systemctl show --property MainPID --value "$SINGBOX_SERVICE" 2>/dev/null || true)
  if [[ $pid =~ ^[1-9][0-9]*$ ]]; then
    candidate=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
    if [[ -n $candidate && -x $candidate ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  for candidate in /usr/local/bin/sing-box /usr/bin/sing-box; do
    if [[ -x $candidate ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate=$(command -v sing-box 2>/dev/null || true)
  if [[ -n $candidate && -x $candidate ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

write_standalone_singbox_patch() {
  local patch_file=$1
  cat >"$patch_file" <<'PATCH'
--- a/option/tls.go
+++ b/option/tls.go
@@ -12,6 +12,7 @@
 type InboundTLSOptions struct {
 	Enabled                          bool                                `json:"enabled,omitempty"`
 	ServerName                       string                              `json:"server_name,omitempty"`
+	StrictServerName                 bool                                `json:"strict_server_name,omitempty"`
 	Insecure                         bool                                `json:"insecure,omitempty"`
 	ALPN                             badoption.Listable[string]          `json:"alpn,omitempty"`
 	MinVersion                       string                              `json:"min_version,omitempty"`
--- a/common/tls/std_server.go
+++ b/common/tls/std_server.go
@@ -371,6 +371,16 @@
 		echKeyPath:            echKeyPath,
 	}
 	serverConfig.config.GetConfigForClient = func(info *tls.ClientHelloInfo) (*tls.Config, error) {
+		if options.StrictServerName {
+			expectedServerName := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(options.ServerName)), ".")
+			clientServerName := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(info.ServerName)), ".")
+			if expectedServerName == "" {
+				return nil, E.New("tls: strict_server_name requires server_name")
+			}
+			if clientServerName != expectedServerName {
+				return nil, E.New("tls: rejected client SNI")
+			}
+		}
 		serverConfig.access.Lock()
 		defer serverConfig.access.Unlock()
 		return serverConfig.config, nil
--- /dev/null
+++ b/common/tls/strict_server_name_test.go
@@ -0,0 +1,36 @@
+package tls
+
+import (
+	"context"
+	stdTLS "crypto/tls"
+	"testing"
+
+	boxLog "github.com/sagernet/sing-box/log"
+	"github.com/sagernet/sing-box/option"
+)
+
+func TestStrictServerName(t *testing.T) {
+	serverConfig, err := NewSTDServer(context.Background(), boxLog.NewNOPFactory().Logger(), option.InboundTLSOptions{
+		Enabled:          true,
+		ServerName:       "www.itunes.com",
+		StrictServerName: true,
+		Insecure:         true,
+	})
+	if err != nil {
+		t.Fatal(err)
+	}
+	stdConfig, err := serverConfig.STDConfig()
+	if err != nil {
+		t.Fatal(err)
+	}
+	for _, serverName := range []string{"www.itunes.com", "WWW.ITUNES.COM."} {
+		if _, err = stdConfig.GetConfigForClient(&stdTLS.ClientHelloInfo{ServerName: serverName}); err != nil {
+			t.Fatalf("expected %q to pass: %v", serverName, err)
+		}
+	}
+	for _, serverName := range []string{"", "mtth.mm1998.com"} {
+		if _, err = stdConfig.GetConfigForClient(&stdTLS.ClientHelloInfo{ServerName: serverName}); err == nil {
+			t.Fatalf("expected %q to be rejected", serverName)
+		}
+	}
+}
--- a/protocol/hysteria2/inbound.go
+++ b/protocol/hysteria2/inbound.go
@@ -6,6 +6,9 @@
 	"net/http"
 	"net/http/httputil"
 	"net/url"
+	"os"
+	"strconv"
+	"strings"
 	"time"
 
 	"github.com/sagernet/sing-box/adapter"
@@ -38,11 +41,26 @@
 	userNameList []string
 }
 
+func applySNIGuard(options *option.Hysteria2InboundOptions) {
+	serverName := strings.TrimSpace(os.Getenv("SING_BOX_HYSTERIA2_SNI_GUARD"))
+	portText := strings.TrimSpace(os.Getenv("SING_BOX_HYSTERIA2_SNI_GUARD_PORT"))
+	if serverName == "" || portText == "" || options.TLS == nil || !options.TLS.Enabled {
+		return
+	}
+	port, err := strconv.ParseUint(portText, 10, 16)
+	if err != nil || uint16(port) != options.ListenPort {
+		return
+	}
+	options.TLS.ServerName = serverName
+	options.TLS.StrictServerName = true
+}
+
 func NewInbound(ctx context.Context, router adapter.Router, logger log.ContextLogger, tag string, options option.Hysteria2InboundOptions) (adapter.Inbound, error) {
 	options.UDPFragmentDefault = true
 	if options.TLS == nil || !options.TLS.Enabled {
 		return nil, C.ErrTLSRequired
 	}
+	applySNIGuard(&options)
 	tlsConfig, err := tls.NewServer(ctx, logger, common.PtrValueOrDefault(options.TLS))
 	if err != nil {
 		return nil, err
--- /dev/null
+++ b/protocol/hysteria2/sni_guard_test.go
@@ -0,0 +1,33 @@
+package hysteria2
+
+import (
+	"testing"
+
+	"github.com/sagernet/sing-box/option"
+)
+
+func TestApplySNIGuard(t *testing.T) {
+	t.Setenv("SING_BOX_HYSTERIA2_SNI_GUARD", "www.itunes.com")
+	t.Setenv("SING_BOX_HYSTERIA2_SNI_GUARD_PORT", "8446")
+	matching := option.Hysteria2InboundOptions{
+		ListenOptions: option.ListenOptions{ListenPort: 8446},
+		InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{TLS: &option.InboundTLSOptions{
+			Enabled: true,
+		}},
+	}
+	applySNIGuard(&matching)
+	if matching.TLS.ServerName != "www.itunes.com" || !matching.TLS.StrictServerName {
+		t.Fatal("matching Hysteria2 inbound did not receive the SNI guard")
+	}
+
+	nonMatching := option.Hysteria2InboundOptions{
+		ListenOptions: option.ListenOptions{ListenPort: 9443},
+		InboundTLSOptionsContainer: option.InboundTLSOptionsContainer{TLS: &option.InboundTLSOptions{
+			Enabled: true,
+		}},
+	}
+	applySNIGuard(&nonMatching)
+	if nonMatching.TLS.StrictServerName {
+		t.Fatal("SNI guard leaked to a different Hysteria2 port")
+	}
+}
PATCH
  chmod 0600 "$patch_file"
}

build_patched_standalone_singbox() {
  local current_bin=$1 tmp_dir archive output build_tags
  local GOPROXY=${GOPROXY:-}
  if [[ -z $GOPROXY ]]; then
    GOPROXY='https://proxy.golang.org|https://goproxy.cn|direct'
  fi
  export GOPROXY
  ensure_go
  systemctl cat "$SINGBOX_SERVICE" >/dev/null 2>&1 ||
    die "没有找到 ${SINGBOX_SERVICE}。"

  tmp_dir=$(mktemp -d)
  archive="${tmp_dir}/sing-box.tar.gz"
  write_standalone_singbox_patch "${tmp_dir}/sing-box-sni-guard.patch"
  download_source_archive \
    "sing-box v${STANDALONE_SINGBOX_VERSION}" \
    "https://github.com/SagerNet/sing-box/archive/refs/tags/v${STANDALONE_SINGBOX_VERSION}.tar.gz" \
    "$STANDALONE_SINGBOX_ARCHIVE_SHA256" \
    "$STANDALONE_SINGBOX_SOURCE_DIR" \
    "$archive"
  patch --batch --forward -d "$STANDALONE_SINGBOX_SOURCE_DIR" -p1 \
    <"${tmp_dir}/sing-box-sni-guard.patch"

  build_tags=$("$GO_BIN" version -m "$current_bin" 2>/dev/null |
    sed -n 's/^[[:space:]]*build[[:space:]]*-tags=//p' | head -n 1)
  if [[ -z $build_tags ]]; then
    build_tags=$(<"${STANDALONE_SINGBOX_SOURCE_DIR}/release/DEFAULT_BUILD_TAGS_OTHERS")
  fi

  mkdir -p "$CACHE_DIR/mod" "$CACHE_DIR/build"
  (
    cd "$STANDALONE_SINGBOX_SOURCE_DIR"
    CGO_ENABLED=0 GOTOOLCHAIN=local \
      GOMODCACHE="$CACHE_DIR/mod" GOCACHE="$CACHE_DIR/build" \
      "$GO_BIN" test ./common/tls ./protocol/hysteria2
    CGO_ENABLED=0 GOTOOLCHAIN=local \
      GOMODCACHE="$CACHE_DIR/mod" GOCACHE="$CACHE_DIR/build" \
      "$GO_BIN" build \
        -trimpath \
        -tags "$build_tags" \
        -ldflags "-X github.com/sagernet/sing-box/constant.Version=tls-sni-${STANDALONE_SINGBOX_VERSION} -X internal/godebug.defaultGODEBUG=multipathtcp=0 -checklinkname=0 -s -w -buildid=" \
        -o sing-box.tls-sni ./cmd/sing-box
  )
  output="${STANDALONE_SINGBOX_SOURCE_DIR}/sing-box.tls-sni"
  [[ -x $output ]] || die "补丁版 sing-box 构建失败。"
  "$GO_BIN" version -m "$output" >/dev/null 2>&1 || die "补丁版 sing-box 校验失败。"
  rm -rf "$tmp_dir"
}

write_standalone_singbox_dropin() {
  mkdir -p "$STANDALONE_SINGBOX_DROPIN_DIR"
  cat >"$STANDALONE_SINGBOX_DROPIN_FILE" <<EOF
[Service]
Environment=SING_BOX_HYSTERIA2_SNI_GUARD=${FAKE_SNI}
Environment=SING_BOX_HYSTERIA2_SNI_GUARD_PORT=${NODE_PORT}
EOF
  chmod 0644 "$STANDALONE_SINGBOX_DROPIN_FILE"
}

wait_for_udp_service() {
  local service=$1 attempt
  for attempt in $(seq 1 30); do
    if systemctl is-active --quiet "$service" && service_owns_udp_port "$service" "$NODE_PORT"; then
      return 0
    fi
    systemctl is-failed --quiet "$service" && return 1
    sleep 1
  done
  return 1
}

wait_for_configured_udp_backend() {
  case "${UDP_BACKEND:-none}" in
    xboard)
      wait_for_xboard_udp
      ;;
    singbox)
      singbox_has_hysteria2_port "$NODE_PORT" || return 2
      standalone_singbox_version_supported || return 2
      standalone_singbox_sni_guard_is_configured "$NODE_PORT" "$FAKE_SNI" || return 2
      wait_for_udp_service "$SINGBOX_SERVICE" || return 1
      standalone_singbox_hysteria2_is_confirmed "$NODE_PORT" || return 2
      ;;
    *)
      return 2
      ;;
  esac
}

install_patched_standalone_singbox() {
  local built_bin current_bin current_sha previous_patched_sha=""
  local rollback_bin rollback_dropin patched_sha had_dropin=0
  current_bin=$(find_standalone_singbox_binary) || die "没有找到 sing-box 可执行文件。"
  [[ $current_bin != *[[:space:]]* ]] || die "sing-box 路径包含空白字符，无法安全处理。"
  SINGBOX_BIN_PATH=$current_bin

  build_patched_standalone_singbox "$current_bin"
  built_bin="${STANDALONE_SINGBOX_SOURCE_DIR}/sing-box.tls-sni"
  mkdir -p "$BASE_DIR"
  current_sha=$(sha256_file "$current_bin")
  if [[ -r $STANDALONE_SINGBOX_PATCH_STATE ]]; then
    previous_patched_sha=$(awk -F= '$1 == "PATCHED_SHA256" { print $2; exit }' "$STANDALONE_SINGBOX_PATCH_STATE")
  fi
  if [[ ! -s $STANDALONE_SINGBOX_BACKUP_BIN ]]; then
    install -m 0755 "$current_bin" "$STANDALONE_SINGBOX_BACKUP_BIN"
  elif [[ -n $previous_patched_sha && $current_sha != "$previous_patched_sha" ]]; then
    install -m 0755 "$current_bin" "$STANDALONE_SINGBOX_BACKUP_BIN"
  fi

  rollback_bin=$(mktemp)
  install -m 0755 "$current_bin" "$rollback_bin"
  rollback_dropin="${rollback_bin}.dropin"
  if [[ -f $STANDALONE_SINGBOX_DROPIN_FILE ]]; then
    cp -a "$STANDALONE_SINGBOX_DROPIN_FILE" "$rollback_dropin"
    had_dropin=1
  fi

  write_standalone_singbox_dropin
  systemctl stop "$SINGBOX_SERVICE"
  install -m 0755 "$built_bin" "$current_bin"
  systemctl daemon-reload
  if ! systemctl start "$SINGBOX_SERVICE" || ! wait_for_configured_udp_backend; then
    warn "补丁版 sing-box 启动失败，正在自动回滚。"
    systemctl stop "$SINGBOX_SERVICE" >/dev/null 2>&1 || true
    install -m 0755 "$rollback_bin" "$current_bin"
    if (( had_dropin == 1 )); then
      install -m 0644 "$rollback_dropin" "$STANDALONE_SINGBOX_DROPIN_FILE"
    else
      rm -f "$STANDALONE_SINGBOX_DROPIN_FILE"
    fi
    systemctl daemon-reload
    systemctl start "$SINGBOX_SERVICE" >/dev/null 2>&1 || true
    rm -f "$rollback_bin" "$rollback_dropin"
    die "补丁版 sing-box 未能监听 UDP ${NODE_PORT}，原二进制已经恢复。"
  fi

  rm -f "$rollback_bin" "$rollback_dropin"
  patched_sha=$(sha256_file "$current_bin")
  umask 077
  cat >"$STANDALONE_SINGBOX_PATCH_STATE" <<EOF
SINGBOX_BIN_PATH=$current_bin
PATCHED_SHA256=$patched_sha
SINGBOX_VERSION=$STANDALONE_SINGBOX_VERSION
EOF
  chmod 0600 "$STANDALONE_SINGBOX_PATCH_STATE"
  ok "sing-box 已替换为 HY2 内核 SNI 校验版本。"
}

restore_standalone_singbox() {
  local current_sha="" marker_sha="" restore_bin=""
  if [[ -r $STANDALONE_SINGBOX_PATCH_STATE ]]; then
    # shellcheck disable=SC1090
    source "$STANDALONE_SINGBOX_PATCH_STATE"
    marker_sha=${PATCHED_SHA256:-}
    restore_bin=${SINGBOX_BIN_PATH:-}
  fi
  if [[ -z $restore_bin ]]; then
    restore_bin=$(find_standalone_singbox_binary 2>/dev/null || true)
  fi

  rm -f "$STANDALONE_SINGBOX_DROPIN_FILE"
  rmdir "$STANDALONE_SINGBOX_DROPIN_DIR" >/dev/null 2>&1 || true
  systemctl daemon-reload

  if [[ -n $restore_bin && -x $restore_bin && -s $STANDALONE_SINGBOX_BACKUP_BIN ]]; then
    current_sha=$(sha256_file "$restore_bin")
    if [[ -z $marker_sha || $current_sha == "$marker_sha" ]]; then
      systemctl stop "$SINGBOX_SERVICE" >/dev/null 2>&1 || true
      install -m 0755 "$STANDALONE_SINGBOX_BACKUP_BIN" "$restore_bin"
      systemctl start "$SINGBOX_SERVICE" >/dev/null 2>&1 || true
      info "已恢复原版 sing-box。"
    else
      warn "sing-box 在安装补丁后又被修改，未覆盖当前二进制；仅移除了 SNI 环境配置。"
      systemctl restart "$SINGBOX_SERVICE" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$STANDALONE_SINGBOX_PATCH_STATE" "$STANDALONE_SINGBOX_BACKUP_BIN"
  rm -rf "$STANDALONE_SINGBOX_SOURCE_DIR"
}

write_nginx_config() {
  local module_path=$1
  local output_file=${2:-$NGINX_CONF}
  local load_module=""
  local ipv6_listen=""
  local ipv6_udp_listen=""
  local udp_server=""

  if [[ -n $module_path ]]; then
    load_module="load_module ${module_path};"
  fi
  if [[ -s /proc/net/if_inet6 ]]; then
    ipv6_listen="        listen [::]:${PROXY_PORT} ipv6only=on reuseport;"
    ipv6_udp_listen="        listen [::]:${PROXY_PORT} udp ipv6only=on reuseport;"
  fi
  if [[ $UDP_MODE != none ]]; then
    udp_server=$(cat <<EOF
    server {
        listen 0.0.0.0:${PROXY_PORT} udp reuseport;
${ipv6_udp_listen}

        access_log ${LOG_DIR}/udp-access.log udp_route;
        proxy_pass hy2_backend;
        proxy_timeout 1h;
    }
EOF
)
  fi

  mkdir -p "$(dirname "$output_file")"
  cat >"$output_file" <<EOF
${load_module}
worker_processes auto;
worker_rlimit_nofile 1048576;
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
    log_format udp_route '\$time_iso8601 client=\$remote_addr:\$remote_port protocol=udp route=hy2_backend status=\$status sent=\$bytes_sent received=\$bytes_received time=\$session_time';

    upstream tls_backend {
        server 127.0.0.1:${NODE_PORT};
    }

    upstream cover_backend {
        server ${FAKE_SNI}:443;
    }

    upstream hy2_backend {
        server 127.0.0.1:${NODE_PORT};
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

${udp_server}
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
  local nginx_bin udp_service=""
  nginx_bin=$(command -v nginx)
  local node_dependency=""
  if [[ $UDP_MODE != none ]]; then
    udp_service=$(udp_backend_service) || die "UDP 后端服务状态无效。"
    node_dependency="After=${udp_service}"
    node_dependency+=$'\nWants='"${udp_service}"
  fi

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TLS 节点 SNI 分流服务
After=network-online.target firewalld.service nftables.service
Wants=network-online.target
${node_dependency}

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

detect_install_udp_mode() {
  UDP_BACKEND=$(detect_udp_backend "$NODE_PORT" 2>/dev/null || true)
  case "$UDP_BACKEND" in
    xboard)
      UDP_MODE=kernel
      if xboard_hysteria2_is_confirmed "$NODE_PORT"; then
        info "已确认 xboard-node Hysteria2 UDP 后端：${NODE_PORT}。"
      else
        info "检测到 xboard-node 正在监听 UDP ${NODE_PORT}；安装时将根据实际节点配置确认是否为 Hysteria2。"
      fi
      ;;
    singbox)
      UDP_MODE=kernel
      info "检测到官方 sing-box Hysteria2 UDP 后端：${NODE_PORT}。"
      ;;
    *)
      UDP_MODE=none
      UDP_BACKEND=none
      if service_owns_udp_port "$SINGBOX_SERVICE" "$NODE_PORT" &&
        singbox_has_hysteria2_port "$NODE_PORT" &&
        ! standalone_singbox_version_supported; then
        warn "检测到 sing-box HY2，但其版本不是受支持的 ${STANDALONE_SINGBOX_VERSION}，不会替换二进制，已自动回退为仅 TCP。"
      elif udp_port_is_listening "$NODE_PORT"; then
        warn "UDP ${NODE_PORT} 不是受支持的 xboard-node/sing-box HY2，已自动回退为仅 TCP。"
      else
        info "未检测到受支持的 HY2 UDP 后端，将按纯 TCP 模式配置。"
      fi
      ;;
  esac
}

read_install_values() {
  local old_node_port old_proxy_port old_sni input suggested_proxy_port

  load_state
  old_node_port=$NODE_PORT
  old_proxy_port=$PROXY_PORT
  old_sni=$FAKE_SNI

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

  detect_install_udp_mode

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
}

install_or_reconfigure() {
  local module_path preflight_conf xboard_status=0

  load_state
  read_install_values

  printf '\n准备应用以下配置：\n'
  printf '  节点后端端口：%s（仅供本机 Nginx 回连）\n' "$NODE_PORT"
  printf '  Nginx 公网端口：%s（用户连接此端口）\n' "$PROXY_PORT"
  printf '  大厂 SNI：%s\n' "$FAKE_SNI"
  case "${UDP_BACKEND:-none}" in
    xboard)
      if xboard_hysteria2_is_confirmed "$NODE_PORT" "$FAKE_SNI"; then
        printf '  UDP/HY2：已确认 xboard-node Hysteria2（兼容 Salamander）\n'
      else
        printf '  UDP/HY2：xboard-node UDP 候选，安装时确认协议；非 HY2 自动回退 TCP\n'
      fi
      ;;
    singbox) printf '  UDP/HY2：已确认官方 sing-box Hysteria2（兼容 Salamander）\n' ;;
    *) printf '  UDP/HY2：未识别，自动使用纯 TCP\n' ;;
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

  module_path=$(find_stream_module) || die "没有找到 Nginx Stream 模块。"
  mkdir -p "$BASE_DIR"
  mkdir -p "$LOG_DIR"
  chmod 0755 "$LOG_DIR"
  preflight_conf=$(mktemp)
  write_nginx_config "$module_path" "$preflight_conf"
  if ! nginx -t -c "$preflight_conf" -p "$BASE_DIR/"; then
    rm -f "$preflight_conf"
    die "Nginx 配置校验失败，现有分流和节点后端均未修改。"
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
  rm -f "$BASE_DIR/salamander.key"
  rm -f "/var/log/${APP}.log" "/run/${APP}.pid"

  if port_is_in_use "$PROXY_PORT"; then
    rm -f "$preflight_conf"
    die "Nginx 公网端口 $PROXY_PORT 仍被其他服务占用，请重新运行并选择其他端口。"
  fi

  case "${UDP_BACKEND:-none}" in
    xboard)
      restore_standalone_singbox
      SINGBOX_BIN_PATH=""
      install_patched_xboard || xboard_status=$?
      if (( xboard_status == 2 )); then
        UDP_MODE=none
        UDP_BACKEND=none
        XBOARD_BIN_PATH=""
        warn "已确认 xboard-node 的 UDP ${NODE_PORT} 不是 Hysteria2，已恢复原版并回退为纯 TCP。"
        if ! tcp_port_is_listening "$NODE_PORT"; then
          rm -f "$preflight_conf"
          die "该端口也没有 TCP 服务，无法继续配置；节点后端未被修改。"
        fi
        rm -f "$preflight_conf"
        preflight_conf=$(mktemp)
        write_nginx_config "$module_path" "$preflight_conf"
        if ! nginx -t -c "$preflight_conf" -p "$BASE_DIR/"; then
          rm -f "$preflight_conf"
          die "回退 TCP 后的 Nginx 配置校验失败。"
        fi
      elif (( xboard_status != 0 )); then
        rm -f "$preflight_conf"
        die "xboard-node HY2 协议确认失败。"
      fi
      ;;
    singbox)
      restore_xboard_node
      XBOARD_BIN_PATH=""
      install_patched_standalone_singbox
      ;;
    *)
      restore_xboard_node
      restore_standalone_singbox
      XBOARD_BIN_PATH=""
      SINGBOX_BIN_PATH=""
      ;;
  esac

  mkdir -p "$BASE_DIR"
  install -m 0644 "$preflight_conf" "$NGINX_CONF"
  rm -f "$preflight_conf"
  write_logrotate_config
  write_firewall_helper
  write_service
  write_state
  systemctl daemon-reload
  systemctl enable --now "$APP"
  systemctl is-active --quiet "$APP" || die "服务启动失败，请运行 systemctl status ${APP} 检查状态。"

  printf '\n'
  ok "安装/配置完成。"
  printf '  节点后端端口：%s（公网已封锁）\n' "$NODE_PORT"
  printf '  用户连接端口：%s\n' "$PROXY_PORT"
  printf '  客户端 SNI：%s\n' "$FAKE_SNI"
  case "${UDP_BACKEND:-none}" in
    xboard) printf '  UDP/HY2：xboard-node 内核 SNI 校验已启用\n' ;;
    singbox) printf '  UDP/HY2：官方 sing-box 内核 SNI 校验已启用\n' ;;
  esac
  printf '\n客户端或面板订阅需要修改：\n'
  printf '  1. SNI 改为 %s\n' "$FAKE_SNI"
  printf '  2. 端口改为 %s\n' "$PROXY_PORT"
  printf '  3. 开启“跳过证书验证 / insecure”\n'
  printf '  4. 节点地址和密码保持原样\n'
  printf '\n'
  warn "若客户端支持证书公钥固定，建议固定公钥，不要只依赖 insecure。"
  [[ $UDP_MODE == none ]] || warn "Salamander 配置继续由 HY2 后端管理，本脚本不会读取或修改。"
  if [[ $UDP_MODE == none ]]; then
    warn "请确认云厂商安全组已经放行 TCP ${PROXY_PORT}，主机防火墙无法代替云安全组。"
  else
    warn "请确认云厂商安全组已经放行 TCP 和 UDP ${PROXY_PORT}。"
  fi
}

show_status() {
  local udp_service="" udp_label=""
  load_state
  printf '\n========== 当前状态 ==========\n'
  if [[ -z $NODE_PORT ]]; then
    printf '状态：尚未安装\n'
    return
  fi

  printf 'TLS 后端端口：%s（禁止公网直连）\n' "$NODE_PORT"
  printf 'Nginx 公网端口：%s（用户连接端口）\n' "$PROXY_PORT"
  printf '大厂 SNI：%s\n' "$FAKE_SNI"
  case "${UDP_BACKEND:-none}" in
    xboard)
      if xboard_hysteria2_is_confirmed "$NODE_PORT" "$FAKE_SNI"; then
        printf 'UDP/HY2：已确认 xboard-node Hysteria2 内核 SNI 校验\n'
      else
        printf 'UDP/HY2：异常，xboard-node 当前未确认是 Hysteria2\n'
      fi
      ;;
    singbox)
      if standalone_singbox_hysteria2_is_confirmed "$NODE_PORT"; then
        printf 'UDP/HY2：已确认官方 sing-box Hysteria2 内核 SNI 校验\n'
      else
        printf 'UDP/HY2：异常，sing-box 当前未确认是 Hysteria2\n'
      fi
      ;;
    *) printf 'UDP/HY2：未启用（纯 TCP）\n' ;;
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
      printf 'QUIC 公网 UDP 监听：正常\n'
    else
      printf 'QUIC 公网 UDP 监听：异常，端口未监听\n'
    fi
    udp_service=$(udp_backend_service 2>/dev/null || true)
    case "${UDP_BACKEND:-none}" in
      xboard) udp_label="xboard-node" ;;
      singbox) udp_label="sing-box" ;;
      *) udp_label="HY2 后端" ;;
    esac
    if [[ -n $udp_service ]] && systemctl is-active --quiet "$udp_service" 2>/dev/null; then
      printf '%s：运行中\n' "$udp_label"
    else
      printf '%s：未运行\n' "$udp_label"
    fi
    case "${UDP_BACKEND:-none}" in
      xboard)
        if [[ -f $XBOARD_DROPIN_FILE && -r $XBOARD_PATCH_STATE ]] &&
          xboard_hysteria2_is_confirmed "$NODE_PORT" "$FAKE_SNI"; then
          printf 'HY2 内核 SNI 补丁：已安装\n'
        else
          printf 'HY2 内核 SNI 补丁：未完整安装或协议未确认\n'
        fi
        ;;
      singbox)
        if [[ -f $STANDALONE_SINGBOX_DROPIN_FILE && -r $STANDALONE_SINGBOX_PATCH_STATE ]] &&
          standalone_singbox_hysteria2_is_confirmed "$NODE_PORT" &&
          standalone_singbox_sni_guard_is_configured "$NODE_PORT" "$FAKE_SNI"; then
          printf 'HY2 内核 SNI 补丁：已安装\n'
        else
          printf 'HY2 内核 SNI 补丁：未完整安装或协议未确认\n'
        fi
        ;;
    esac
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
  local udp_service="" udp_status=0
  load_state
  [[ -f $SERVICE_FILE ]] || die "尚未安装，请先选择“安装 / 重新配置”。"
  if [[ ${UDP_MODE:-none} != none ]]; then
    udp_service=$(udp_backend_service) || die "没有记录有效的 HY2 后端服务。"
    if [[ ${UDP_BACKEND:-none} == xboard ]] && ! systemctl is-active --quiet "$udp_service"; then
      rm -f "$(xboard_hy2_marker_file "$NODE_PORT")"
    fi
    systemctl start "$udp_service" || die "HY2 后端启动失败。"
    wait_for_configured_udp_backend || udp_status=$?
    if (( udp_status != 0 )); then
      systemctl stop "$APP" >/dev/null 2>&1 || true
      if (( udp_status == 2 )); then
        die "目标 UDP ${NODE_PORT} 当前未确认是 Hysteria2，分流服务未启动。"
      fi
      die "HY2 后端启动后未正常监听 UDP ${NODE_PORT}，分流服务未启动。"
    fi
  fi
  systemctl start "$APP"
  ok "服务已启动。"
}

stop_service() {
  load_state
  [[ -f $SERVICE_FILE ]] || die "尚未安装。"
  systemctl stop "$APP"
  ok "服务已停止；原后端端口继续保持封锁，卸载后才恢复直连。"
}

restart_service() {
  local udp_service="" udp_status=0
  load_state
  [[ -f $SERVICE_FILE ]] || die "尚未安装，请先选择“安装 / 重新配置”。"
  if [[ ${UDP_MODE:-none} != none ]]; then
    udp_service=$(udp_backend_service) || die "没有记录有效的 HY2 后端服务。"
    systemctl stop "$APP" >/dev/null 2>&1 || true
    if [[ ${UDP_BACKEND:-none} == xboard ]]; then
      rm -f "$(xboard_hy2_marker_file "$NODE_PORT")"
    fi
    systemctl restart "$udp_service" || die "HY2 后端重启失败；分流服务保持停止。"
    wait_for_configured_udp_backend || udp_status=$?
    if (( udp_status != 0 )); then
      if (( udp_status == 2 )); then
        die "目标 UDP ${NODE_PORT} 重启后未确认是 Hysteria2；分流服务保持停止。"
      fi
      die "HY2 后端重启后未正常监听 UDP ${NODE_PORT}；分流服务保持停止。"
    fi
  fi
  systemctl restart "$APP"
  ok "服务已重启。"
}

show_logs() {
  local udp_service="" udp_label=""
  load_state
  printf '\n========== 服务状态 ==========\n'
  systemctl --no-pager --full status "$APP" 2>/dev/null || true
  if [[ ${UDP_MODE:-none} != none ]]; then
    udp_service=$(udp_backend_service 2>/dev/null || true)
    case "${UDP_BACKEND:-none}" in
      xboard) udp_label="xboard-node" ;;
      singbox) udp_label="sing-box" ;;
      *) udp_label="HY2 后端" ;;
    esac
    printf '\n========== %s 内核 SNI 服务 ==========\n' "$udp_label"
    [[ -z $udp_service ]] || systemctl --no-pager --full status "$udp_service" 2>/dev/null || true
  fi

  printf '\n========== 最近 SNI 路由 ==========\n'
  if [[ -f ${LOG_DIR}/access.log ]]; then
    tail -n 100 "${LOG_DIR}/access.log"
  else
    printf '暂无访问日志。\n'
  fi

  if [[ ${UDP_MODE:-none} != none ]]; then
    printf '\n========== 最近 HY2 UDP 转发 ==========\n'
    if [[ -f ${LOG_DIR}/udp-access.log ]]; then
      tail -n 100 "${LOG_DIR}/udp-access.log"
    else
      printf '暂无 QUIC 访问日志。\n'
    fi
    printf '\n========== 最近 %s 日志 ==========\n' "$udp_label"
    [[ -z $udp_service ]] || journalctl -u "$udp_service" -n 100 --no-pager -l 2>/dev/null || true
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
  restore_xboard_node
  restore_standalone_singbox
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
