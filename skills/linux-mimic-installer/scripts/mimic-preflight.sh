#!/usr/bin/env bash
set -u

section() {
  printf '\n== %s ==\n' "$1"
}

kv() {
  printf '%-22s %s\n' "$1:" "$2"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

kernel_ge_6_1() {
  local rel major minor
  rel="$(uname -r)"
  major="${rel%%.*}"
  minor="${rel#*.}"
  minor="${minor%%.*}"
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$minor" in
    ''|*[!0-9]*) minor=0 ;;
  esac
  [ "$major" -gt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -ge 1 ]; }
}

section "主机信息"
kv "主机名" "$(hostname 2>/dev/null || printf unknown)"
kv "当前用户" "$(id -un 2>/dev/null || printf unknown)"
kv "UID" "$(id -u 2>/dev/null || printf unknown)"
kv "内核" "$(uname -r)"
kv "架构" "$(uname -m)"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  ID=""
  VERSION_ID=""
  VERSION_CODENAME=""
  PRETTY_NAME=""
fi

kv "系统" "${PRETTY_NAME:-unknown}"
kv "发行版 ID" "${ID:-unknown}"
kv "版本" "${VERSION_ID:-unknown}"
kv "代号" "${VERSION_CODENAME:-unknown}"

if kernel_ge_6_1; then
  kv "内核 6.1+" "通过"
else
  kv "内核 6.1+" "警告：Mimic 要求 Linux 6.1+"
fi

case "$(uname -m)" in
  x86_64|amd64)
    kv "预编译架构" "通常可使用上游 deb artifact"
    ;;
  *)
    kv "预编译架构" "警告：上游可能没有该架构的预编译 deb"
    ;;
esac

section "包管理器"
for cmd in apt dpkg pacman makepkg dnf yum zypper apk; do
  if have "$cmd"; then
    kv "$cmd" "$(command -v "$cmd")"
  fi
done

section "Mimic 状态"
if have mimic; then
  kv "mimic" "$(command -v mimic)"
  mimic --version 2>/dev/null || true
else
  kv "mimic" "未安装"
fi

if have systemctl; then
  kv "systemctl" "$(command -v systemctl)"
  systemctl list-unit-files 'mimic@*.service' --no-pager 2>/dev/null || true
  systemctl list-units 'mimic@*.service' --no-pager 2>/dev/null || true
else
  kv "systemctl" "未找到"
fi

if lsmod 2>/dev/null | awk '$1 == "mimic" { found=1 } END { exit !found }'; then
  kv "内核模块" "已加载"
else
  kv "内核模块" "未加载或 lsmod 不可用"
fi
modinfo mimic 2>/dev/null | sed -n '1,20p' || true

section "内核构建路径"
if [ -e "/lib/modules/$(uname -r)/build" ]; then
  kv "headers/build" "/lib/modules/$(uname -r)/build 存在"
else
  kv "headers/build" "警告：/lib/modules/$(uname -r)/build 不存在"
fi

section "网络信息"
if have ip; then
  ip -brief link show 2>/dev/null || true
  printf '\n'
  ip route show default 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true
else
  kv "ip" "未找到"
fi

section "WireGuard"
if have wg; then
  wg show interfaces 2>/dev/null || true
  wg show all endpoints 2>/dev/null || true
else
  kv "wg" "未找到"
fi
if [ -d /etc/wireguard ]; then
  find /etc/wireguard -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null || true
fi

section "Mimic 配置"
if [ -d /etc/mimic ]; then
  find /etc/mimic -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null || true
else
  kv "/etc/mimic" "不存在"
fi

section "防火墙工具"
for cmd in nft iptables ip6tables ufw firewall-cmd; do
  if have "$cmd"; then
    kv "$cmd" "$(command -v "$cmd")"
  fi
done

section "BPF/XDP 工具"
for cmd in bpftool clang pahole dkms; do
  if have "$cmd"; then
    kv "$cmd" "$(command -v "$cmd")"
  else
    kv "$cmd" "未找到"
  fi
done

section "安装路径建议"
case "${ID:-}:${VERSION_CODENAME:-}:$(uname -m)" in
  debian:trixie:x86_64|debian:trixie:amd64)
    printf '%s\n' "可使用 Debian 仓库，或使用上游 trixie deb。"
    ;;
  debian:bookworm:x86_64|debian:bookworm:amd64)
    printf '%s\n' "使用上游 bookworm deb，同时安装 mimic 和 mimic-dkms。"
    ;;
  ubuntu:noble:x86_64|ubuntu:noble:amd64)
    printf '%s\n' "使用上游 noble deb，同时安装 mimic 和 mimic-dkms。"
    ;;
  arch::*)
    printf '%s\n' "使用 AUR 包 mimic-bpf 或 mimic-bpf-git。"
    ;;
  *)
    printf '%s\n' "可能需要源码构建或属于未明确支持路径；安装前先核对上游。"
    ;;
esac

section "完成"
printf '%s\n' "本预检脚本未修改系统。"
