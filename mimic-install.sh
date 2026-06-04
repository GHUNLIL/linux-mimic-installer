#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026-06-04"
REPO="hack3ric/mimic"

ACTION="${1:-menu}"
if [ "$#" -gt 0 ]; then
  shift
fi

METHOD="auto"
INTERFACE=""
LOG_VERBOSITY="info"
XDP_MODE=""
LINK_TYPE=""
KEEPALIVE=""
PADDING=""
WG_INTERFACE=""
WG_MTU="1408"
SET_WG_MTU=0
PURGE_CONFIG=0
DRY_RUN=0
ASSUME_YES=0
FORCE=0
ENABLE_SERVICE=1
FILTERS=()
MENU_USE_DEV_TTY=0

msg() { printf '%s\n' "$*"; }
info() { printf '[信息] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Mimic Linux 安装脚本

用法:
  sudo bash mimic-install.sh              # 进入上下键交互菜单
  sudo bash mimic-install.sh menu         # 进入上下键交互菜单
  sudo bash mimic-install.sh preflight
  sudo bash mimic-install.sh install [--method auto|apt|github|aur|source]
  sudo bash mimic-install.sh configure --interface eth0 --filter local=203.0.113.10:51820
  sudo bash mimic-install.sh start --interface eth0
  sudo bash mimic-install.sh all --interface eth0 --filter local=203.0.113.10:51820
  sudo bash mimic-install.sh status --interface eth0
  sudo bash mimic-install.sh wg-mtu --wg-interface wg0 [--wg-mtu 1408]
  sudo bash mimic-install.sh rollback --interface eth0
  sudo bash mimic-install.sh uninstall [--purge-config]

常用场景:
  服务端 WireGuard 监听本机公网端口:
    sudo bash mimic-install.sh all --interface eth0 --filter local=203.0.113.10:51820

  客户端连接远端 WireGuard endpoint:
    sudo bash mimic-install.sh all --interface eth0 --filter remote=203.0.113.10:51820

  IPv6 endpoint:
    sudo bash mimic-install.sh all --interface eth0 --filter 'remote=[2001:db8::10]:51820'

  native XDP 不稳定时:
    sudo bash mimic-install.sh configure --interface eth0 --filter remote=203.0.113.10:51820 --xdp-mode skb

参数:
  --method auto|apt|github|aur|source   安装方式，默认 auto
  --interface IFACE                     承载 UDP endpoint 的底层网卡，例如 eth0、ens3
  --filter FILTER                       Mimic filter，可重复传入；格式 local=IP:PORT 或 remote=IP:PORT
  --log-verbosity LEVEL                 error|warn|info|debug|trace，默认 info
  --xdp-mode MODE                       native 或 skb
  --link-type TYPE                      eth 或 none
  --keepalive VALUE                     写入 keepalive，例如 180:10:3:600
  --padding VALUE                       写入 padding，例如 random 或数字
  --set-wg-mtu --wg-interface wg0       修改 /etc/wireguard/wg0.conf 的 MTU，默认 1408
  --wg-mtu N                            配合 --set-wg-mtu 使用
  --no-enable                           start/all 时只 start，不 enable 开机启动
  -y, --yes                             非交互确认
  --dry-run                             只打印将执行的命令
  --force                               跳过部分保护性检查
  --purge-config                        uninstall 时同时删除 /etc/mimic
  -h, --help                            显示帮助

交互界面:
  - 支持上下键选择操作、底层网卡、TUN/WireGuard 接口和安装方式。
  - 选择 TUN/WireGuard 接口主要用于自动设置 WireGuard MTU。
  - Mimic 通常应配置在承载公网 UDP endpoint 的底层网卡，不是 wg0/tun0。

说明:
  - 本脚本会在安装 GitHub deb 时实时查询 https://api.github.com/repos/hack3ric/mimic/releases/latest。
  - Debian/Ubuntu 支持 bookworm/trixie/noble 的上游预编译包；其他系统会给出保守提示。
  - 配合 WireGuard 时，Mimic 通常配置在公网底层网卡，不是 wg0。
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

need_root() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "该操作需要 root，请使用 sudo 运行。"
  fi
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ] || [ "$FORCE" -eq 1 ]; then
    return 0
  fi
  printf '%s [y/N] ' "$prompt"
  read -r answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) die "用户取消。" ;;
  esac
}

ensure_tty_menu() {
  if [ -r /dev/tty ] && [ -w /dev/tty ] && { printf '' > /dev/tty; } 2>/dev/null; then
    MENU_USE_DEV_TTY=1
    return 0
  fi
  if [ -t 0 ] && [ -t 1 ]; then
    MENU_USE_DEV_TTY=0
    return 0
  fi
  die "交互菜单需要可读写的 TTY。"
}

menu_print() {
  if [ "$MENU_USE_DEV_TTY" -eq 1 ]; then
    printf "$@" > /dev/tty
  else
    printf "$@"
  fi
}

menu_read_char() {
  if [ "$MENU_USE_DEV_TTY" -eq 1 ]; then
    IFS= read -rsn1 "$1" < /dev/tty
  else
    IFS= read -rsn1 "$1"
  fi
}

menu_read_rest() {
  if [ "$MENU_USE_DEV_TTY" -eq 1 ]; then
    IFS= read -rsn2 -t 1 "$1" < /dev/tty
  else
    IFS= read -rsn2 -t 1 "$1"
  fi
}

menu_clear() {
  menu_print '\033[H\033[J'
}

menu_read_key() {
  local key rest
  MENU_KEY=""
  menu_read_char key || return 1
  if [ "$key" = $'\033' ]; then
    menu_read_rest rest || rest=""
    case "$rest" in
      "[A") MENU_KEY="up" ;;
      "[B") MENU_KEY="down" ;;
      *) MENU_KEY="esc" ;;
    esac
  elif [ -z "$key" ]; then
    MENU_KEY="enter"
  else
    case "$key" in
      q|Q) MENU_KEY="quit" ;;
      k|K) MENU_KEY="up" ;;
      j|J) MENU_KEY="down" ;;
      "") MENU_KEY="enter" ;;
      *) MENU_KEY="other" ;;
    esac
  fi
}

menu_select() {
  local title="$1"
  shift
  local items=("$@")
  local idx=0
  local count="${#items[@]}"
  local i
  [ "$count" -gt 0 ] || die "菜单没有可选项：$title"
  ensure_tty_menu

  while true; do
    menu_clear
    menu_print 'Mimic Linux 安装脚本\n'
    menu_print '版本: %s\n\n' "$VERSION"
    menu_print '%s\n\n' "$title"
    for ((i = 0; i < count; i++)); do
      if [ "$i" -eq "$idx" ]; then
        menu_print '  \033[7m> %s\033[0m\n' "${items[$i]}"
      else
        menu_print '    %s\n' "${items[$i]}"
      fi
    done
    menu_print '\n↑/↓ 选择，Enter 确认，q 退出。也可用 j/k。\n'
    menu_read_key || die "读取按键失败。"
    case "$MENU_KEY" in
      up)
        idx=$((idx - 1))
        [ "$idx" -lt 0 ] && idx=$((count - 1))
        ;;
      down)
        idx=$((idx + 1))
        [ "$idx" -ge "$count" ] && idx=0
        ;;
      enter)
        MENU_SELECTED="${items[$idx]}"
        menu_clear
        return 0
        ;;
      quit|esc)
        menu_clear
        exit 0
        ;;
    esac
  done
}

prompt_input() {
  local label="$1"
  local default="${2:-}"
  local value
  ensure_tty_menu
  if [ -n "$default" ]; then
    menu_print '%s [%s]: ' "$label" "$default"
  else
    menu_print '%s: ' "$label"
  fi
  if [ "$MENU_USE_DEV_TTY" -eq 1 ]; then
    IFS= read -r value < /dev/tty
  else
    IFS= read -r value
  fi
  if [ -z "$value" ]; then
    value="$default"
  fi
  PROMPT_VALUE="$value"
}

menu_yes_no() {
  local title="$1"
  menu_select "$title" "是" "否"
  [ "$MENU_SELECTED" = "是" ]
}

list_interfaces() {
  if command -v ip >/dev/null 2>&1; then
    ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | sort -u
  elif [ -d /sys/class/net ]; then
    find /sys/class/net -maxdepth 1 -mindepth 1 -exec basename {} \; | sort -u
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig -l | tr ' ' '\n' | sort -u
  fi
}

list_underlay_interfaces() {
  list_interfaces | awk '
    $0 == "lo" { next }
    $0 ~ /^(wg|tun|tap|utun|zt|tailscale|nebula|warp|ppp)/ { tunnel[++tunnel_count] = $0; next }
    { print }
    END {
      for (i = 1; i <= tunnel_count; i++) print tunnel[i]
    }
  '
}

list_tun_interfaces() {
  {
    list_interfaces | awk '/^(wg|tun|tap|utun|zt|tailscale|nebula|warp|ppp)/ { print }'
    if command -v wg >/dev/null 2>&1; then
      wg show interfaces 2>/dev/null | tr ' ' '\n'
    fi
    if [ -d /etc/wireguard ]; then
      find /etc/wireguard -maxdepth 1 -type f -name '*.conf' -exec basename {} .conf \; 2>/dev/null
    fi
  } | awk 'NF && !seen[$0]++' | sort -u
}

choose_interface() {
  local items=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && items+=("$line")
  done < <(list_underlay_interfaces)
  items+=("手动输入")
  menu_select "选择 Mimic 绑定的底层网卡（通常是公网网卡，不是 wg0/tun0）" "${items[@]}"
  if [ "$MENU_SELECTED" = "手动输入" ]; then
    prompt_input "请输入底层网卡名" "${INTERFACE:-eth0}"
    INTERFACE="$PROMPT_VALUE"
  else
    INTERFACE="$MENU_SELECTED"
  fi
}

choose_tun_interface() {
  local items=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && items+=("$line")
  done < <(list_tun_interfaces)
  items+=("手动输入" "跳过")
  menu_select "选择 TUN/WireGuard 接口（用于设置 MTU）" "${items[@]}"
  case "$MENU_SELECTED" in
    "手动输入")
      prompt_input "请输入 TUN/WireGuard 接口名" "${WG_INTERFACE:-wg0}"
      WG_INTERFACE="$PROMPT_VALUE"
      ;;
    "跳过")
      WG_INTERFACE=""
      SET_WG_MTU=0
      ;;
    *)
      WG_INTERFACE="$MENU_SELECTED"
      ;;
  esac
}

primary_ip_for_interface() {
  local iface="$1"
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'
    return 0
  fi
  return 0
}

normalize_endpoint_host() {
  local host="$1"
  case "$host" in
    \[*\]) printf '%s\n' "$host" ;;
    *:*) printf '[%s]\n' "$host" ;;
    *) printf '%s\n' "$host" ;;
  esac
}

choose_filter() {
  local origin host port filter default_host
  menu_select "选择 Mimic filter 方向" \
    "服务端：local=本机监听IP:端口" \
    "客户端：remote=远端服务器IP:端口" \
    "手动输入完整 filter"
  case "$MENU_SELECTED" in
    服务端：*)
      origin="local"
      default_host="$(primary_ip_for_interface "$INTERFACE")"
      prompt_input "本机 WireGuard 监听 IP（IPv6 可直接输入，不用手动加方括号）" "$default_host"
      [ -n "$PROMPT_VALUE" ] || die "本机监听 IP 不能为空。请填写对端访问这台机器使用的公网/专线 IP。"
      host="$(normalize_endpoint_host "$PROMPT_VALUE")"
      prompt_input "本机 WireGuard 监听端口" "51820"
      port="$PROMPT_VALUE"
      filter="${origin}=${host}:${port}"
      ;;
    客户端：*)
      origin="remote"
      prompt_input "远端 WireGuard 服务器 IP（IPv6 可直接输入，不用手动加方括号）" ""
      [ -n "$PROMPT_VALUE" ] || die "远端服务器 IP 不能为空。"
      host="$(normalize_endpoint_host "$PROMPT_VALUE")"
      prompt_input "远端 WireGuard 服务器端口" "51820"
      port="$PROMPT_VALUE"
      filter="${origin}=${host}:${port}"
      ;;
    *)
      prompt_input "请输入完整 filter，例如 remote=203.0.113.10:51820" ""
      filter="$PROMPT_VALUE"
      ;;
  esac
  [ -n "$filter" ] || die "filter 不能为空。"
  case "$filter" in
    local=:*|remote=:*) die "filter 不能省略 IP：$filter" ;;
  esac
  FILTERS+=("$filter")

  while menu_yes_no "是否继续添加另一个 filter？"; do
    prompt_input "请输入完整 filter" ""
    [ -n "$PROMPT_VALUE" ] || die "filter 不能为空。"
    case "$PROMPT_VALUE" in
      local=:*|remote=:*) die "filter 不能省略 IP：$PROMPT_VALUE" ;;
    esac
    FILTERS+=("$PROMPT_VALUE")
  done
}

choose_method_menu() {
  menu_select "选择安装方式" \
    "auto 自动判断" \
    "github GitHub release deb" \
    "apt Debian 仓库" \
    "aur Arch AUR" \
    "source 源码构建提示"
  case "$MENU_SELECTED" in
    auto*) METHOD="auto" ;;
    github*) METHOD="github" ;;
    apt*) METHOD="apt" ;;
    aur*) METHOD="aur" ;;
    source*) METHOD="source" ;;
  esac
}

choose_xdp_menu() {
  menu_select "选择 XDP 模式" \
    "自动/默认" \
    "skb 兼容模式" \
    "native 高性能模式"
  case "$MENU_SELECTED" in
    skb*) XDP_MODE="skb" ;;
    native*) XDP_MODE="native" ;;
    *) XDP_MODE="" ;;
  esac
}

choose_wg_mtu_menu() {
  if menu_yes_no "是否选择 TUN/WireGuard 接口并设置 MTU？"; then
    SET_WG_MTU=1
    choose_tun_interface
    if [ "$SET_WG_MTU" -eq 1 ]; then
      prompt_input "MTU 值" "$WG_MTU"
      WG_MTU="$PROMPT_VALUE"
    fi
  fi
}

show_interactive_summary() {
  msg "== 即将执行 =="
  msg "动作: $ACTION"
  msg "安装方式: $METHOD"
  [ -n "$INTERFACE" ] && msg "Mimic 网卡: $INTERFACE"
  [ "${#FILTERS[@]}" -gt 0 ] && printf 'filter: %s\n' "${FILTERS[@]}"
  [ -n "$XDP_MODE" ] && msg "XDP 模式: $XDP_MODE"
  if [ "$SET_WG_MTU" -eq 1 ]; then
    msg "TUN/WireGuard 接口: $WG_INTERFACE"
    msg "WireGuard MTU: $WG_MTU"
  fi
  msg
}

interactive_menu() {
  ensure_tty_menu
  menu_select "选择操作" \
    "预检环境" \
    "一键安装并配置 Mimic" \
    "仅安装 Mimic" \
    "仅生成/更新 Mimic 配置" \
    "启动 Mimic 服务" \
    "查看状态" \
    "设置 TUN/WireGuard MTU" \
    "回滚当前网卡配置" \
    "卸载 Mimic" \
    "退出"

  case "$MENU_SELECTED" in
    "预检环境") ACTION="preflight" ;;
    "一键安装并配置 Mimic") ACTION="all" ;;
    "仅安装 Mimic") ACTION="install" ;;
    "仅生成/更新 Mimic 配置") ACTION="configure" ;;
    "启动 Mimic 服务") ACTION="start" ;;
    "查看状态") ACTION="status" ;;
    "设置 TUN/WireGuard MTU") ACTION="wg-mtu" ;;
    "回滚当前网卡配置") ACTION="rollback" ;;
    "卸载 Mimic") ACTION="uninstall" ;;
    *) exit 0 ;;
  esac

  case "$ACTION" in
    install|all)
      choose_method_menu
      ;;
  esac

  case "$ACTION" in
    configure|all|start|status|rollback)
      choose_interface
      ;;
  esac

  case "$ACTION" in
    configure|all)
      choose_filter
      choose_xdp_menu
      choose_wg_mtu_menu
      ;;
    wg-mtu)
      SET_WG_MTU=1
      choose_tun_interface
      if [ "$SET_WG_MTU" -eq 1 ]; then
        prompt_input "MTU 值" "$WG_MTU"
        WG_MTU="$PROMPT_VALUE"
      fi
      ;;
  esac

  if [ "$ACTION" = "uninstall" ] && menu_yes_no "是否同时删除 /etc/mimic 配置目录？"; then
    PURGE_CONFIG=1
  fi

  show_interactive_summary
  confirm "确认执行？"
  ASSUME_YES=1

  case "$ACTION" in
    preflight)
      preflight
      ;;
    install)
      validate_common
      install_mimic
      ;;
    configure)
      validate_common
      write_config
      set_wireguard_mtu
      ;;
    all)
      validate_common
      install_mimic
      write_config
      set_wireguard_mtu
      start_service
      ;;
    start)
      validate_common
      start_service
      ;;
    status)
      validate_common
      show_status
      ;;
    wg-mtu)
      set_wireguard_mtu
      ;;
    rollback)
      validate_common
      rollback
      ;;
    uninstall)
      validate_common
      uninstall_mimic
      ;;
  esac
}

read_os() {
  OS_ID=""
  OS_VERSION_ID=""
  OS_CODENAME=""
  OS_PRETTY=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-}"
  fi
}

kernel_ge_6_1() {
  local rel major minor
  rel="$(uname -r)"
  major="${rel%%.*}"
  minor="${rel#*.}"
  minor="${minor%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  [ "$major" -gt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -ge 1 ]; }
}

deb_arch() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture
  else
    case "$(uname -m)" in
      x86_64) printf 'amd64\n' ;;
      aarch64) printf 'arm64\n' ;;
      *) uname -m ;;
    esac
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --method) METHOD="${2:?--method 需要参数}"; shift 2 ;;
      --interface|-i) INTERFACE="${2:?--interface 需要参数}"; shift 2 ;;
      --filter|-f) FILTERS+=("${2:?--filter 需要参数}"); shift 2 ;;
      --log-verbosity) LOG_VERBOSITY="${2:?--log-verbosity 需要参数}"; shift 2 ;;
      --xdp-mode) XDP_MODE="${2:?--xdp-mode 需要参数}"; shift 2 ;;
      --link-type) LINK_TYPE="${2:?--link-type 需要参数}"; shift 2 ;;
      --keepalive) KEEPALIVE="${2:?--keepalive 需要参数}"; shift 2 ;;
      --padding) PADDING="${2:?--padding 需要参数}"; shift 2 ;;
      --set-wg-mtu) SET_WG_MTU=1; shift ;;
      --wg-interface) WG_INTERFACE="${2:?--wg-interface 需要参数}"; shift 2 ;;
      --wg-mtu) WG_MTU="${2:?--wg-mtu 需要参数}"; shift 2 ;;
      --purge-config) PURGE_CONFIG=1; shift ;;
      --no-enable) ENABLE_SERVICE=0; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --force) FORCE=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

validate_common() {
  case "$METHOD" in auto|apt|github|aur|source) : ;; *) die "未知安装方式：$METHOD" ;; esac
  case "$LOG_VERBOSITY" in error|warn|info|debug|trace|0|1|2|3|4) : ;; *) die "未知 log verbosity：$LOG_VERBOSITY" ;; esac
  if [ -n "$XDP_MODE" ]; then
    case "$XDP_MODE" in native|skb) : ;; *) die "--xdp-mode 只支持 native 或 skb" ;; esac
  fi
  if [ -n "$LINK_TYPE" ]; then
    case "$LINK_TYPE" in eth|none) : ;; *) die "--link-type 只支持 eth 或 none" ;; esac
  fi
}

validate_interface() {
  [ -n "$INTERFACE" ] || die "需要 --interface，例如 --interface eth0"
  if command -v ip >/dev/null 2>&1 && [ "$FORCE" -ne 1 ]; then
    ip link show dev "$INTERFACE" >/dev/null 2>&1 || die "网卡不存在：${INTERFACE}。确认后可用 --force 跳过。"
  fi
}

validate_filters() {
  [ "${#FILTERS[@]}" -gt 0 ] || die "需要至少一个 --filter，例如 --filter local=203.0.113.10:51820"
  local f
  for f in "${FILTERS[@]}"; do
    case "$f" in
      local=:*|remote=:*) die "filter 不能省略 IP：${f}。请写成 local=IP:PORT 或 remote=IP:PORT" ;;
      local=*:*|remote=*:*|local=\[*\]:*|remote=\[*\]:*) : ;;
      *) die "filter 格式看起来不对：${f}。应类似 local=IP:PORT 或 remote=IP:PORT" ;;
    esac
  done
}

preflight() {
  read_os
  msg "== 主机信息 =="
  msg "系统: ${OS_PRETTY:-unknown}"
  msg "发行版: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown} ${OS_CODENAME:-unknown}"
  msg "内核: $(uname -r)"
  msg "架构: $(uname -m)"
  if kernel_ge_6_1; then
    msg "内核要求: 通过，Mimic 要求 Linux 6.1+"
  else
    warn "内核低于 6.1，Mimic 可能无法使用。"
  fi

  msg
  msg "== 命令检查 =="
  for cmd in curl apt-get dpkg systemctl ip wg mimic dkms bpftool clang pahole sha256sum; do
    if command -v "$cmd" >/dev/null 2>&1; then
      msg "$cmd: $(command -v "$cmd")"
    else
      msg "$cmd: 未找到"
    fi
  done

  msg
  msg "== 网络接口 =="
  if command -v ip >/dev/null 2>&1; then
    ip -brief link show || true
    ip route show default || true
    ip -6 route show default || true
  else
    warn "未找到 ip 命令。"
  fi

  msg
  msg "== WireGuard =="
  if command -v wg >/dev/null 2>&1; then
    wg show interfaces || true
    wg show all endpoints || true
  else
    msg "wg: 未找到"
  fi

  msg
  msg "== Mimic =="
  if command -v mimic >/dev/null 2>&1; then
    mimic --version || true
  else
    msg "mimic: 未安装"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-units 'mimic@*.service' --all --no-pager || true
  fi
  if [ -d /etc/mimic ]; then
    find /etc/mimic -maxdepth 1 -type f -name '*.conf' -print || true
  fi

  msg
  msg "== 安装建议 =="
  install_hint
}

install_hint() {
  read_os
  local arch
  arch="$(deb_arch 2>/dev/null || uname -m)"
  case "${OS_ID:-}:${OS_CODENAME:-}:$arch" in
    debian:bookworm:amd64)
      msg "建议：使用 GitHub release 的 bookworm deb，同时安装 mimic 和 mimic-dkms。"
      ;;
    debian:trixie:amd64)
      msg "建议：可用 Debian 仓库 apt install mimic，或使用 GitHub release 的 trixie deb。"
      ;;
    ubuntu:noble:amd64)
      msg "建议：使用 GitHub release 的 noble deb，同时安装 mimic 和 mimic-dkms。"
      ;;
    arch::*)
      msg "建议：使用 AUR 包 mimic-bpf 或 mimic-bpf-git。"
      ;;
    *)
      msg "建议：该系统不在上游预编译包的明确支持范围内，先核对上游再考虑源码构建。"
      ;;
  esac
}

select_method() {
  if [ "$METHOD" != "auto" ]; then
    printf '%s\n' "$METHOD"
    return
  fi
  read_os
  case "${OS_ID:-}:${OS_CODENAME:-}:$(deb_arch 2>/dev/null || uname -m)" in
    debian:trixie:amd64)
      printf 'apt\n'
      ;;
    debian:bookworm:amd64|ubuntu:noble:amd64)
      printf 'github\n'
      ;;
    arch::*)
      printf 'aur\n'
      ;;
    *)
      printf 'source\n'
      ;;
  esac
}

install_mimic() {
  local chosen
  chosen="$(select_method)"
  info "安装方式：$chosen"
  case "$chosen" in
    apt) install_apt ;;
    github) install_github_deb ;;
    aur) install_arch ;;
    source) source_hint ;;
  esac
}

install_apt() {
  need_root
  need_cmd apt-get
  if ! kernel_ge_6_1; then
    die "内核低于 6.1，停止安装。"
  fi
  run apt-get update
  run apt-get install -y mimic
}

json_value() {
  local key="$1"
  sed -nE "s/^[[:space:]]*\"$key\": \"([^\"]*)\".*/\\1/p" | head -n 1
}

json_asset_url() {
  local regex="$1"
  sed -nE "s/^[[:space:]]*\"browser_download_url\": \"([^\"]*$regex[^\"]*)\".*/\\1/p" | head -n 1
}

download_file() {
  local url="$1"
  local out="$2"
  info "下载：$url"
  run curl -fL -o "$out" "$url"
}

verify_sha256_file() {
  local file="$1"
  local sha_file="$2"
  local expected actual
  expected="$(awk '{print $1; exit}' "$sha_file")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ -n "$expected" ] || die "SHA256 文件为空：$sha_file"
  [ "$expected" = "$actual" ] || die "SHA256 校验失败：$file"
  info "SHA256 校验通过：$(basename "$file")"
}

install_github_deb() {
  need_root
  need_cmd apt-get
  need_cmd curl
  need_cmd sha256sum
  read_os

  if ! kernel_ge_6_1; then
    die "内核低于 6.1，停止安装。"
  fi

  local codename arch
  codename="${OS_CODENAME:-}"
  arch="$(deb_arch)"
  case "$codename:$arch" in
    bookworm:amd64|trixie:amd64|noble:amd64) : ;;
    *) die "上游预编译 deb 当前只明确支持 bookworm/trixie/noble 的 amd64，本机是 ${codename:-unknown}/${arch}。" ;;
  esac

  run apt-get update
  run apt-get install -y ca-certificates curl dkms
  run apt-get install -y "linux-headers-$(uname -r)"

  local api tag cli_url dkms_url cli_sha_url dkms_sha_url tmp cli_file dkms_file cli_sha_file dkms_sha_file
  info "查询 GitHub 最新 release：$REPO"
  api="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")"
  tag="$(printf '%s\n' "$api" | json_value tag_name)"
  cli_url="$(printf '%s\n' "$api" | json_asset_url "${codename}_mimic_[0-9][^/\"]*_${arch}\\.deb")"
  dkms_url="$(printf '%s\n' "$api" | json_asset_url "${codename}_mimic-dkms_[0-9][^/\"]*_${arch}\\.deb")"
  cli_sha_url="$(printf '%s\n' "$api" | json_asset_url "${codename}_mimic_[0-9][^/\"]*_${arch}\\.deb\\.sha256")"
  dkms_sha_url="$(printf '%s\n' "$api" | json_asset_url "${codename}_mimic-dkms_[0-9][^/\"]*_${arch}\\.deb\\.sha256")"

  [ -n "$cli_url" ] || die "未在最新 release ${tag:-unknown} 找到 mimic deb：$codename/$arch"
  [ -n "$dkms_url" ] || die "未在最新 release ${tag:-unknown} 找到 mimic-dkms deb：$codename/$arch"

  tmp="$(mktemp -d)"
  info "临时目录：$tmp"
  cli_file="$tmp/${cli_url##*/}"
  dkms_file="$tmp/${dkms_url##*/}"
  download_file "$cli_url" "$cli_file"
  download_file "$dkms_url" "$dkms_file"

  if [ -n "$cli_sha_url" ]; then
    cli_sha_file="$tmp/${cli_sha_url##*/}"
    download_file "$cli_sha_url" "$cli_sha_file"
    if [ "$DRY_RUN" -eq 0 ]; then
      verify_sha256_file "$cli_file" "$cli_sha_file"
    fi
  else
    warn "未找到 mimic deb 的 sha256 artifact。"
  fi

  if [ -n "$dkms_sha_url" ]; then
    dkms_sha_file="$tmp/${dkms_sha_url##*/}"
    download_file "$dkms_sha_url" "$dkms_sha_file"
    if [ "$DRY_RUN" -eq 0 ]; then
      verify_sha256_file "$dkms_file" "$dkms_sha_file"
    fi
  else
    warn "未找到 mimic-dkms deb 的 sha256 artifact。"
  fi

  run apt-get install -y "$cli_file" "$dkms_file"
}

install_arch() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    die "AUR 不应以 root 构建。请用普通用户运行 install，配置/start 再 sudo。"
  fi
  if command -v yay >/dev/null 2>&1; then
    run yay -S --needed mimic-bpf
  elif command -v paru >/dev/null 2>&1; then
    run paru -S --needed mimic-bpf
  else
    need_cmd git
    need_cmd makepkg
    local tmp
    tmp="$(mktemp -d)"
    run git clone https://aur.archlinux.org/mimic-bpf.git "$tmp/mimic-bpf"
    run bash -lc "cd '$tmp/mimic-bpf' && makepkg -si"
  fi
}

source_hint() {
  cat >&2 <<'EOF'
当前系统不在脚本的自动安装白名单里。

保守源码构建路径：
  1. 确认 Linux kernel 6.1+、匹配内核 headers、clang、bpftool、pahole、libbpf-dev、dkms 可用。
  2. git clone https://github.com/hack3ric/mimic.git
  3. cd mimic && make
  4. 优先按发行版方式打包后安装，不建议手工散落复制 out/ 产物。

EOF
  exit 2
}

backup_file() {
  local file="$1"
  if [ -e "$file" ]; then
    local bak="${file}.bak.$(date +%Y%m%d%H%M%S)"
    info "备份：$file -> $bak"
    run cp -a "$file" "$bak"
  fi
}

write_config() {
  need_root
  validate_interface
  validate_filters
  local config tmp f
  config="/etc/mimic/${INTERFACE}.conf"
  tmp="$(mktemp)"

  {
    printf '# 由 mimic-install.sh 生成：%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'log.verbosity = %s\n' "$LOG_VERBOSITY"
    [ -z "$LINK_TYPE" ] || printf 'link_type = %s\n' "$LINK_TYPE"
    [ -z "$XDP_MODE" ] || printf 'xdp_mode = %s\n' "$XDP_MODE"
    [ -z "$KEEPALIVE" ] || printf 'keepalive = %s\n' "$KEEPALIVE"
    [ -z "$PADDING" ] || printf 'padding = %s\n' "$PADDING"
    for f in "${FILTERS[@]}"; do
      printf 'filter = %s\n' "$f"
    done
  } > "$tmp"

  info "将写入配置：$config"
  sed 's/^/  /' "$tmp"
  confirm "确认写入 ${config}？"
  run install -d -m 0755 /etc/mimic
  backup_file "$config"
  run install -m 0644 "$tmp" "$config"
  rm -f "$tmp"
}

set_wireguard_mtu() {
  [ "$SET_WG_MTU" -eq 1 ] || return 0
  need_root
  [ -n "$WG_INTERFACE" ] || die "--set-wg-mtu 需要同时传 --wg-interface wg0"
  local conf tmp
  conf="/etc/wireguard/${WG_INTERFACE}.conf"
  if [ ! -f "$conf" ]; then
    warn "WireGuard 配置不存在：${conf}，跳过自动 MTU 修改。"
    warn "如果你使用的是 tun/tap 或其他隧道，请在对应软件里手动把 MTU 降 12 字节。"
    return 0
  fi
  backup_file "$conf"
  tmp="$(mktemp)"
  awk -v mtu="$WG_MTU" '
    BEGIN { in_iface=0; done=0 }
    /^\[Interface\][[:space:]]*$/ { in_iface=1; print; next }
    /^\[/ && $0 !~ /^\[Interface\][[:space:]]*$/ {
      if (in_iface && !done) { print "MTU = " mtu; done=1 }
      in_iface=0
    }
    in_iface && /^[[:space:]]*MTU[[:space:]]*=/ {
      if (!done) { print "MTU = " mtu; done=1 }
      next
    }
    { print }
    END {
      if (in_iface && !done) print "MTU = " mtu
    }
  ' "$conf" > "$tmp"
  info "设置 WireGuard MTU：$conf -> $WG_MTU"
  run install -m 0600 "$tmp" "$conf"
  rm -f "$tmp"
  warn "已修改 WireGuard 配置；是否重启 wg-quick@${WG_INTERFACE} 由你决定，避免当前 SSH 断连。"
}

start_service() {
  need_root
  validate_interface
  need_cmd systemctl
  local unit="mimic@${INTERFACE}"
  if [ ! -f "/etc/mimic/${INTERFACE}.conf" ] && [ "$FORCE" -ne 1 ]; then
    die "配置不存在：/etc/mimic/${INTERFACE}.conf。先运行 configure 或使用 --force。"
  fi
  if [ "$ENABLE_SERVICE" -eq 1 ]; then
    run systemctl enable --now "$unit"
  else
    run systemctl start "$unit"
  fi
  run systemctl status "$unit" --no-pager
}

show_status() {
  validate_interface
  if command -v mimic >/dev/null 2>&1; then
    mimic --version || true
    mimic show --connections "$INTERFACE" 2>/dev/null || true
    mimic show --process "$INTERFACE" 2>/dev/null || true
  else
    warn "mimic 未安装。"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status "mimic@${INTERFACE}" --no-pager || true
    journalctl -u "mimic@${INTERFACE}" -n 80 --no-pager || true
  fi
}

rollback() {
  need_root
  validate_interface
  local unit="mimic@${INTERFACE}"
  confirm "确认停止并禁用 ${unit}，并停用 /etc/mimic/${INTERFACE}.conf？"
  if command -v systemctl >/dev/null 2>&1; then
    run systemctl disable --now "$unit" || true
  fi
  if [ -e "/etc/mimic/${INTERFACE}.conf" ]; then
    run mv "/etc/mimic/${INTERFACE}.conf" "/etc/mimic/${INTERFACE}.conf.disabled.$(date +%Y%m%d%H%M%S)"
  fi
}

uninstall_mimic() {
  need_root
  confirm "确认卸载 Mimic 软件包？"
  if command -v systemctl >/dev/null 2>&1; then
    while read -r unit; do
      [ -n "$unit" ] || continue
      run systemctl disable --now "$unit" || true
    done < <(systemctl list-unit-files 'mimic@*.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}')
  fi

  read_os
  case "${OS_ID:-}" in
    debian|ubuntu)
      run apt-get purge -y mimic mimic-dkms || true
      ;;
    arch)
      run pacman -Rns --noconfirm mimic-bpf mimic-bpf-git mimic 2>/dev/null || true
      ;;
    *)
      warn "未知发行版，请手动移除 Mimic。"
      ;;
  esac

  if [ "$PURGE_CONFIG" -eq 1 ]; then
    confirm "确认删除 /etc/mimic？"
    run rm -rf /etc/mimic
  else
    warn "保留 /etc/mimic。需要删除时重新运行 uninstall --purge-config。"
  fi
}

main() {
  case "$ACTION" in
    menu)
      parse_args "$@"
      validate_common
      interactive_menu
      ;;
    help|-h|--help)
      usage
      ;;
    preflight)
      parse_args "$@"
      validate_common
      preflight
      ;;
    install)
      parse_args "$@"
      validate_common
      install_mimic
      ;;
    configure)
      parse_args "$@"
      validate_common
      write_config
      set_wireguard_mtu
      ;;
    start)
      parse_args "$@"
      validate_common
      start_service
      ;;
    all)
      parse_args "$@"
      validate_common
      install_mimic
      write_config
      set_wireguard_mtu
      start_service
      ;;
    status)
      parse_args "$@"
      validate_common
      show_status
      ;;
    wg-mtu|mtu)
      parse_args "$@"
      validate_common
      SET_WG_MTU=1
      set_wireguard_mtu
      ;;
    rollback)
      parse_args "$@"
      validate_common
      rollback
      ;;
    uninstall)
      parse_args "$@"
      validate_common
      uninstall_mimic
      ;;
    *)
      usage
      die "未知动作：$ACTION"
      ;;
  esac
}

main "$@"
