# Mimic Linux 参考

使用这些笔记生成适配目标主机的安装、配置、验证和回滚命令。release URL 要在执行时动态推导或先核对上游；除非用户要求固定版本，不要写死过期 release。

## 支持状态速查

- 上游项目：`hack3ric/mimic`，eBPF UDP 转 TCP 混淆工具。
- 内核要求：Linux kernel 6.1 或更新，并启用基础 BPF 支持。
- Debian 仓库：Debian 13 或更新版本可直接安装 `mimic`，但不一定是最新版。
- 上游预编译 deb：Debian 12 `bookworm`、Debian 13 `trixie`、Ubuntu 24.04 `noble`，x86_64/amd64。
- Arch：AUR 包 `mimic-bpf` 和 `mimic-bpf-git`。
- Debian 12 以前、Ubuntu 23.04 以前通常不适合，因为 kernel/libbpf 太旧。

## 预检命令

```bash
set -eu
. /etc/os-release
printf 'os=%s version=%s codename=%s\n' "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}"
uname -a
uname -m
command -v systemctl || true
command -v mimic || true
ip -brief link show
ip route show default || true
ip -6 route show default || true
wg show 2>/dev/null || true
ls -la /etc/mimic 2>/dev/null || true
modinfo mimic 2>/dev/null || true
```

如果可用，运行技能内置的只读预检脚本：

```bash
bash scripts/mimic-preflight.sh
```

## Debian/Ubuntu 从 GitHub Releases 安装

适用于支持的 codename 和 amd64/x86_64 主机，尤其是发行版仓库没有 Mimic 或版本太旧时。下载时必须选择匹配 codename 的 artifact：

- `<codename>_mimic_<version>_<arch>.deb`
- `<codename>_mimic-dkms_<version>_<arch>.deb`
- 如果提供，对应下载 `*.sha256`

命令形态：

```bash
set -eu
. /etc/os-release
codename="${VERSION_CODENAME:?missing VERSION_CODENAME}"
arch="$(dpkg --print-architecture)"
tmp="$(mktemp -d)"
cd "$tmp"

# 先核对上游最新 release，再把这里替换成当前 release 的真实 artifact URL。
curl -fLO "https://github.com/hack3ric/mimic/releases/download/<tag>/${codename}_mimic_<version>_${arch}.deb"
curl -fLO "https://github.com/hack3ric/mimic/releases/download/<tag>/${codename}_mimic-dkms_<version>_${arch}.deb"
curl -fLO "https://github.com/hack3ric/mimic/releases/download/<tag>/${codename}_mimic_<version>_${arch}.deb.sha256" || true
curl -fLO "https://github.com/hack3ric/mimic/releases/download/<tag>/${codename}_mimic-dkms_<version>_${arch}.deb.sha256" || true

if ls ./*.sha256 >/dev/null 2>&1; then
  sha256sum -c ./*.sha256
fi
sudo apt update
sudo apt install ./*_mimic_*.deb ./*_mimic-dkms_*.deb
```

安装前确认内核头文件可用：

```bash
sudo apt update
sudo apt install dkms "linux-headers-$(uname -r)"
```

如果云厂商内核找不到 `linux-headers-$(uname -r)`，先识别对应 provider kernel package，不要硬装不匹配的 headers。

## Debian 13 仓库安装

```bash
sudo apt update
sudo apt install mimic
mimic --version
```

用户更重视发行版托管和稳定升级时，用这个路径。

## Arch Linux

```bash
git clone https://aur.archlinux.org/mimic-bpf.git
cd mimic-bpf
makepkg -si
```

只有用户明确要开发版/最新提交时，才使用 `mimic-bpf-git`。

## 源码构建

只在不支持的发行版上考虑源码构建，并先确认 kernel 6.1+、headers、编译器和 libbpf 条件。

Debian/Ubuntu 依赖形态：

```bash
sudo apt update
sudo apt install build-essential clang gcc make pahole bpftool libbpf-dev libffi-dev dkms linux-headers-"$(uname -r)" devscripts equivs
git clone https://github.com/hack3ric/mimic.git
cd mimic
make
```

执行 `make` 后，CLI 和内核模块会生成在 `out/` 下。优先构建发行版包，不要手工散落安装这些文件。若从源码树构建 Debian 包：

```bash
sudo apt build-dep .
debuild -b -us -uc
sudo apt install ../mimic_*.deb ../mimic-dkms_*.deb
```

目标主机有 systemd 和 DKMS 时，优先使用包安装方式，而不是直接放置构建产物。

## 配置示例

创建 `/etc/mimic/<underlay-interface>.conf`。

服务端，WireGuard 监听本机公网 endpoint：

```ini
log.verbosity = info
filter = local=203.0.113.10:51820
keepalive = 180:10:3:600
```

客户端，流量发往固定远端 WireGuard endpoint：

```ini
log.verbosity = info
filter = remote=203.0.113.10:51820
keepalive = 180:10:3:600
```

IPv6 endpoint：

```ini
filter = remote=[2001:db8::10]:51820
```

native XDP 不稳定时强制 skb 模式：

```ini
xdp_mode = skb
filter = remote=203.0.113.10:51820
```

## Systemd

```bash
sudo install -d -m 0755 /etc/mimic
sudoedit /etc/mimic/eth0.conf
sudo systemctl enable --now mimic@eth0
systemctl status mimic@eth0 --no-pager
journalctl -u mimic@eth0 -n 100 --no-pager
```

把 `eth0` 替换成实际承载 UDP 包的底层网卡。

## WireGuard MTU

Mimic 每个 UDP 包增加 12 字节。WireGuard 走 IPv6/Ethernet 时，通常把 MTU 从 1420 调成 1408：

```ini
[Interface]
MTU = 1408
```

IPv4 underlay 下默认 1420 通常可用。没有丢包或分片证据时，不要继续盲目降低 MTU。

## 防火墙注意事项

防火墙同时控制出入方向时，把 endpoint 同时按 UDP 和 TCP 放行：

```bash
sudo ufw allow 51820/udp
sudo ufw allow 51820/tcp
```

nftables/iptables 系统添加等价 TCP 和 UDP accept 规则。不要清空现有规则。

## 验证

```bash
mimic --version
sudo modprobe mimic
lsmod | grep '^mimic' || true
sudo systemctl restart mimic@eth0
systemctl is-active mimic@eth0
sudo mimic show --connections eth0
sudo mimic show --process eth0
sudo wg show
```

流量检查：

```bash
sudo tcpdump -ni eth0 'tcp port 51820 or udp port 51820'
ping -M do -s 1360 <remote-tunnel-ip>
iperf3 -c <remote-tunnel-ip> -t 10
```

使用真实端口和网卡名。没有用户确认时，不要在生产链路上跑高负载测速。

## 回滚

```bash
sudo systemctl disable --now mimic@eth0 || true
sudo mv /etc/mimic/eth0.conf /etc/mimic/eth0.conf.disabled.$(date +%Y%m%d%H%M%S)
sudo systemctl daemon-reload
```

Debian/Ubuntu 上需要移除软件包时：

```bash
sudo apt purge mimic mimic-dkms
sudo rm -f /etc/modules-load.d/mimic.conf
sudo depmod -a
```

如果改过 WireGuard MTU 或防火墙规则，同时恢复对应备份。

## 排障

- 服务无法启动：检查内核版本、headers、BPF 支持、网卡名、filter 语法、systemd 日志和模块加载。
- DKMS 失败：安装匹配的内核头文件，检查 `/var/lib/dkms/mimic`，阅读 `/var/lib/dkms/*/*/build/make.log`。
- 服务启动但没有流量：确认服务绑定的是底层网卡，不是 tunnel 网卡；确认 `local`/`remote` 方向。
- 握手成功后卡住：检查 MTU 和防火墙 TCP 放行。
- native XDP 下突然断流：强制 `xdp_mode = skb`。
- IPv6 filter 不生效：确认 IPv6 地址包在方括号里。
- 多个 WireGuard peer 共用服务端端口：服务端通常仍是一条 `local=<server-ip>:<listen-port>` filter；客户端使用同一个服务端 endpoint 作为 `remote=...`。
