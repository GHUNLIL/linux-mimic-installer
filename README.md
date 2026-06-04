# Linux Mimic Installer

中文 Linux Mimic 一键安装脚本和 Codex skill。

Mimic 上游项目：<https://github.com/hack3ric/mimic>

## 一键拉取运行

推荐使用下面这一行，下载到 `/tmp` 后再运行，交互菜单的上下键选择会更稳定：

```bash
curl -fsSL -o /tmp/mimic-install.sh https://raw.githubusercontent.com/GHUNLIL/linux-mimic-installer/main/mimic-install.sh && chmod +x /tmp/mimic-install.sh && sudo bash /tmp/mimic-install.sh
```

只做预检，不改系统：

```bash
curl -fsSL -o /tmp/mimic-install.sh https://raw.githubusercontent.com/GHUNLIL/linux-mimic-installer/main/mimic-install.sh && bash /tmp/mimic-install.sh preflight
```

直接命令行一键安装并配置服务端示例：

```bash
curl -fsSL -o /tmp/mimic-install.sh https://raw.githubusercontent.com/GHUNLIL/linux-mimic-installer/main/mimic-install.sh && sudo bash /tmp/mimic-install.sh all --interface eth0 --filter local=203.0.113.10:51820
```

不建议用 `curl ... | bash` 跑交互菜单，因为管道会占用标准输入，方向键菜单可能无法读取按键。

## 功能

- 中文交互菜单，默认直接运行脚本进入菜单。
- 支持上下键选择操作、安装方式、底层网卡、TUN/WireGuard 接口。
- 支持 Debian/Ubuntu GitHub release deb、Debian apt、Arch AUR 和源码构建提示。
- 支持生成 `/etc/mimic/<interface>.conf`。
- 支持启动、状态查看、回滚和卸载。
- 支持单独设置 WireGuard/TUN MTU。
- 内置 Codex skill：`skills/linux-mimic-installer`。

## 快速使用

从仓库克隆后本地运行：

```bash
chmod +x mimic-install.sh
sudo bash mimic-install.sh
```

服务端 WireGuard 监听本机公网端口：

```bash
sudo bash mimic-install.sh all --interface eth0 --filter local=203.0.113.10:51820
```

客户端连接远端 WireGuard endpoint：

```bash
sudo bash mimic-install.sh all --interface eth0 --filter remote=203.0.113.10:51820
```

native XDP 不稳定时：

```bash
sudo bash mimic-install.sh all --interface eth0 --filter remote=203.0.113.10:51820 --xdp-mode skb
```

单独设置 WireGuard MTU：

```bash
sudo bash mimic-install.sh wg-mtu --wg-interface wg0 --wg-mtu 1408
```

## 常用命令

```bash
sudo bash mimic-install.sh preflight
sudo bash mimic-install.sh install --method auto
sudo bash mimic-install.sh configure --interface eth0 --filter local=203.0.113.10:51820
sudo bash mimic-install.sh start --interface eth0
sudo bash mimic-install.sh status --interface eth0
sudo bash mimic-install.sh rollback --interface eth0
sudo bash mimic-install.sh uninstall
```

## 安全提示

- Mimic 通常配置在承载公网 UDP endpoint 的底层网卡，不是 `wg0`/`tun0`。
- 选择 TUN/WireGuard 接口主要用于设置 MTU。
- 在线服务器操作前，请保留当前 SSH 会话和云控制台/救援模式。
- 脚本会在改配置前备份现有文件。

## 安装 Codex Skill

把 skill 目录复制到本地 Codex skills 目录：

```bash
mkdir -p ~/.codex/skills
cp -a skills/linux-mimic-installer ~/.codex/skills/
```

之后可以在 Codex 中使用：

```text
使用 $linux-mimic-installer 帮我在 Linux 服务器上安装并配置 Mimic。
```
