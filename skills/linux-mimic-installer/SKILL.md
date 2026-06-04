---
name: linux-mimic-installer
description: 在 Linux 服务器上安装、配置、验证、排障、升级或卸载 hack3ric/mimic。用于部署 Mimic、为 Debian、Ubuntu、Arch 或其他 Linux 选择安装方式、配置每网卡 /etc/mimic 配置文件和 systemd mimic@interface 服务、配合 WireGuard UDP 端点使用、调整 MTU、防火墙和 XDP 设置，或诊断 kernel、DKMS、eBPF、BPF、XDP、模块、软件包、流量不通等问题。
---

# Linux Mimic 安装器

## 概览

使用本技能在 Linux 系统上安装和运维 Mimic，也就是 hack3ric 的 eBPF UDP 转 TCP 混淆工具。优先采用上游推荐的软件包或 release 安装路径，保护现有网络连接，在改动生产网络前先完成主机预检。

上游项目：https://github.com/hack3ric/mimic。用户询问最新版、下载链接或当前支持状态时，执行前先核对上游文档和 releases。

## 工作流

1. 确认目标机器和访问方式。
   - 如果通过 SSH 修改远程 VPS，先记录 SSH 主机、用户、端口，以及是否有 VNC、云控制台、救援模式等带外恢复方式。
   - 在有回滚方案前，不要修改在线机器的防火墙规则、默认路由、WireGuard 配置、内核模块或 systemd 服务。

2. 安装前先做安全探测。
   - 有 shell 权限时，优先运行 `scripts/mimic-preflight.sh`。
   - 不能运行脚本时，手动收集等价信息：`/etc/os-release`、`uname -r`、`uname -m`、包管理器、`systemctl`、`ip -brief link`、默认路由、`wg show`、现有 `/etc/mimic`、当前 `mimic`/`mimic-dkms` 状态。

3. 选择安装路径。
   - Debian 13 或更新版本：可优先用发行版仓库 `apt install mimic`，但提醒用户版本可能不是最新。
   - Debian 12/13 或 Ubuntu 24.04，且架构为 x86_64/amd64：优先使用 GitHub release 中匹配 codename 的 `.deb` 预编译包，同时安装 `mimic` 和 `mimic-dkms`。
   - Arch Linux：使用 AUR 的 `mimic-bpf` 或 `mimic-bpf-git`。
   - 其他发行版或不支持的 codename：确认内核、libbpf、clang、内核头文件和 DKMS 条件后，再考虑源码构建。

4. 为承载 UDP 端点流量的底层网卡配置 Mimic。
   - 每个网卡配置文件放在 `/etc/mimic/<interface>.conf`。
   - 配合 WireGuard 时，通常要把 Mimic 配在承载公网 UDP 包的物理/上联网卡上，而不是 `wg0`。
   - `local=<ip>:<port>` 用于匹配本机端点，常见于服务端 WireGuard 监听 IP/端口。
   - `remote=<ip>:<port>` 用于匹配远端端点，常见于客户端访问服务端 WireGuard endpoint。
   - IPv6 filter 里的地址要用方括号，例如 `remote=[2001:db8::1]:51820`。

5. 启动并验证。
   - 优先使用包内 systemd 服务：`systemctl enable --now mimic@<interface>`。
   - 检查 `systemctl status mimic@<interface>`、`journalctl -u mimic@<interface>`、`mimic show` 和业务层连通性。
   - 上线前先人工检查 `/etc/mimic/<interface>.conf` 的 filter、xdp_mode、link_type 等配置，再用 systemd 启动并观察 journal；不要假设 Mimic 存在 dry-run/check 子命令。

6. 有证据再调优。
   - Mimic 每个 UDP 包会增加 12 字节。WireGuard 走 IPv6/Ethernet 时，通常把 MTU 从 1420 降到 1408。IPv4 下默认 1420 通常可用；上游文档里的最大值是 1428。
   - 防火墙里通常要把 Mimic endpoint 同时按 UDP 和 TCP 放行，因为 netfilter 在不同 hook 上看到的协议不同。
   - Intel e1000/igb/igc 或 Mellanox mlx4/mlx5 等驱动上如果 native XDP 不稳定或突然断流，设置 `xdp_mode = skb`，或运行时传 `--xdp-mode skb`。

## 参考资料

需要具体命令片段时，读取 `references/mimic-linux-reference.md`，它覆盖：

- Debian/Ubuntu 从最新 GitHub release 下载安装软件包。
- Arch AUR 和源码构建路径。
- 服务端/客户端 WireGuard endpoint filter 配置示例。
- 验证、排障、回滚、升级和卸载命令。

## 内置脚本

- `scripts/mimic-install.sh`：完整中文安装脚本，默认进入上下键交互菜单；支持 `menu`、`preflight`、`install`、`configure`、`start`、`all`、`status`、`wg-mtu`、`rollback`、`uninstall`。菜单可用上下键选择操作、底层网卡、TUN/WireGuard 接口和安装方式。
- `scripts/mimic-preflight.sh`：只读预检脚本，不改系统，适合先在目标 Linux 上收集环境信息。

用户要求“一键脚本”“自动安装”“生成配置”“卸载/回滚”时，优先使用 `scripts/mimic-install.sh`，并根据目标机器参数传入 `--interface` 和 `--filter`。

## 安全规则

- 优先使用包管理器，不手动散落复制二进制和模块文件。
- 下载 release artifact 后校验 GitHub 提供的 SHA256。
- 改动前备份 `/etc/mimic`、`/etc/wireguard` 和防火墙规则。
- 测试网络改动时保持当前 SSH 会话不断开。
- 未经用户明确同意，不要重启机器、卸载正在使用的内核模块、重启 SSH、清空防火墙规则或替换 WireGuard 配置。
- 任何可能导致断连的命令，执行前先给出命令和回滚命令。
