# nft-dns-forward

基于 nftables 的动态域名端口转发管理工具，支持流量统计与时间段限速。

## 功能特点

- **动态域名转发**：支持以域名作为转发目标，由 systemd timer 每 60s 自动重新解析 DNS，自动更新 nftables 规则
- **流量统计**：对每条规则的入站（RX）和出站（TX）方向分别统计包数和字节数，支持实时查看和历史日志
- **灵活限速**：基于 nft meter 实现 per-source-IP token bucket 限速，支持按时间段自动切换（如仅夜间限速），也支持手动启用/停用
- **交互式菜单**：提供完整的交互式管理界面，无需手动编辑 nftables 规则
- **向后兼容**：新字段（限速、时间段）为可选字段，旧格式配置无需修改即可直接使用

## 文件结构

```
├── nft-dns-forward-menu.sh       # 交互式管理菜单（主入口）
├── nft-dns-forward-sync.sh       # 核心引擎：DNS 解析、规则渲染、同步、统计
├── nft-dns-forward-stats.sh      # 独立流量统计工具
├── nft-dns-forward.conf.example  # 配置文件示例
├── nftables.sh                   # 静态 IP 端口转发管理（独立工具）
├── install.sh                    # 一键安装脚本
└── uninstall.sh                  # 一键卸载脚本
```

## 快速安装

> 使用 HTTPS 下载 zip 包，无需 git，不留 clone 记录。

```bash
curl -Lo /tmp/nft_menus.zip https://github.com/utada1stlove/nft_menus/archive/refs/heads/main.zip \
  && unzip -q /tmp/nft_menus.zip -d /tmp \
  && cd /tmp/nft_menus-main \
  && bash install.sh \
  && cd / \
  && rm -rf /tmp/nft_menus.zip /tmp/nft_menus-main
```

安装完成后：

```bash
# 启动管理菜单
sudo nft-dns-forward

# 查看实时流量统计
sudo nft-dns-stats live
```

## 卸载

```bash
curl -Lo /tmp/uninstall.sh https://raw.githubusercontent.com/utada1stlove/nft_menus/main/uninstall.sh \
  && bash /tmp/uninstall.sh \
  && rm -f /tmp/uninstall.sh
```

或者如果安装目录还在：

```bash
sudo bash /opt/nft-dns-forward/uninstall.sh
```

卸载内容包括：
- 停止并删除 systemd timer / service
- 清除所有 nftables 转发规则和限速表
- 删除安装目录 `/opt/nft-dns-forward`
- 删除命令软链接（`nft-dns-forward` / `nft-dns-stats` / `nft-dns-sync`）
- 删除 sysctl 配置文件（IP 转发设置）
- 可选删除流量日志 `/var/log/nft-dns-forward-stats.log`

## 手动安装

```bash
# 1. 下载解压
curl -Lo /tmp/nft_menus.zip https://github.com/utada1stlove/nft_menus/archive/refs/heads/main.zip
unzip -q /tmp/nft_menus.zip -d /tmp
cd /tmp/nft_menus-main

# 2. 安装依赖
apt install -y nftables bc python3   # Debian/Ubuntu
# 或
dnf install -y nftables bc python3   # CentOS/Rocky

# 3. 复制配置文件并编辑
cp nft-dns-forward.conf.example nft-dns-forward.conf
vim nft-dns-forward.conf

# 4. 运行菜单（需 root）
sudo bash nft-dns-forward-menu.sh

# 5. 清理临时文件（可选）
rm -rf /tmp/nft_menus.zip /tmp/nft_menus-main
```

## 配置文件格式

```
name|listen_port|target_host|target_port|source_ip|family|rate_limit|schedule
```

后两个字段（`rate_limit` 和 `schedule`）为**可选字段**，省略或留空均可。

### 字段说明

| 字段 | 必填 | 说明 |
|------|------|------|
| `name` | ✅ | 规则名称，只允许字母、数字、`.` `_` `-` |
| `listen_port` | ✅ | 本机公网监听端口（1-65535） |
| `target_host` | ✅ | 转发目标，支持域名或 IP |
| `target_port` | ✅ | 目标端口（1-65535） |
| `source_ip` | ✅ | SNAT 出口 IP，必须是本机已有的 IP |
| `family` | ✅ | `4`（IPv4）/ `6`（IPv6）/ `auto`（自动判断） |
| `rate_limit` | ⬜ | 限速值，留空=不限速。格式：数字+单位，支持 `mbps` `kbps` `mbit` `kbit` |
| `schedule` | ⬜ | 限速时间段，留空=全天。格式：`HH:MM-HH:MM`，多段用逗号分隔，支持跨午夜 |

### 配置示例

```bash
# 纯转发，不限速（最简格式）
cloud-a|44288|example.com|51312|10.0.0.10|4

# 纯转发，不限速（8字段完整格式）
cloud-b|8888|example.com|8888|10.0.0.10|4||

# 全天限速 50mbps
cloud-c|9001|example.com|9001|10.0.0.10|4|50mbps|

# 仅在 22:00-08:00（夜间）限速 10mbps，白天全速
cloud-d|9002|example.com|9002|10.0.0.10|4|10mbps|22:00-08:00

# 多时间段：上午 8-12 点 + 下午 14-18 点 限速 20mbps
cloud-e|9003|example.com|9003|10.0.0.10|4|20mbps|08:00-12:00,14:00-18:00

# IPv6 转发
cloud-f|9004|example.com|9004|2001:db8::1|6||
```

## 菜单说明

运行 `sudo nft-dns-forward` 进入交互式菜单：

```
 ── 基础配置 ──
  0. 开启 IP 转发（IPv4/IPv6 + BBR）
  1. 添加转发规则
  2. 删除转发规则
  3. 查看当前配置
  4. 查看解析结果（含 DNS 解析 IP）

 ── nftables 操作 ──
  5. 同步 nftables 规则
  6. 查看当前 nftables 表
  7. 安装自动同步 timer（每 60s）
  8. 清空所有生效规则

 ── 限速管理 ──
  r. 手动启用限速规则
  s. 手动停用限速规则（清空 limit 表，下次 sync 恢复）

 ── 流量统计 ──
  a. 查看实时流量统计
  b. 查看历史流量日志
  c. 重置流量计数器
```

## 流量统计

### 实时查看

```bash
sudo nft-dns-stats live
```

输出示例：

```
实时流量统计  2025-04-21 18:30:00
──────────────────────────────────────────────────────────────────────────────────────────
规则名称                RX 包数     RX 流量       TX 包数     TX 流量       主导方向
──────────────────────────────────────────────────────────────────────────────────────────
cloud-a                 12345       1.23 GB       12100       1.21 GB       ↑ RX
cloud-b                 890         45.60 MB      880         44.90 MB      ↑ RX
──────────────────────────────────────────────────────────────────────────────────────────
【合计】                -           1.27 GB       -           1.25 GB
```

- **RX**：prerouting 方向，进入本机转发的流量
- **TX**：postrouting 方向，从本机出去的流量
- **主导方向**：字节数较大的一侧

### 历史日志

日志由 systemd timer 每 60s 自动追加，也可手动触发：

```bash
# 查看历史日志（最近 100 行）
sudo nft-dns-stats log

# 查看最近 200 行
sudo nft-dns-stats log 200

# 清理 30 天前的日志（默认保留 30 天）
sudo nft-dns-stats rotate

# 清理 7 天前的日志
sudo nft-dns-stats rotate 7
```

日志路径：`/var/log/nft-dns-forward-stats.log`

## 限速说明

### 自动时间段限速

在 `.conf` 中配置 `rate_limit` 和 `schedule` 后，systemd timer 每 60s 检查一次当前时间：

- **时间段内** → 写入限速规则，立即生效
- **时间段外** → 不写限速规则，全速运行

### 手动控制

在菜单中使用 `r`（启用）和 `s`（停用）可随时手动覆盖：

```
r → 立即应用当前配置中所有限速规则（忽略时间段判断）
s → 立即清空 limit 表，所有规则恢复全速
    （下次 timer sync 时将重新按 schedule 判断）
```

### 限速实现原理

使用 `nft meter` 实现 per-source-IP token bucket：

```
tcp dport 9002 meter cloud-d-lmt { ip saddr limit rate 10 mbytes/second } drop
```

- 对**每个客户端来源 IP** 单独限速，而非所有客户端共享带宽池
- 超出速率的包直接 drop

## nftables 表说明

| 表 | Family | 说明 |
|----|--------|------|
| `richang_dns_forward_v4` | `ip` | IPv4 DNAT/SNAT 转发表（含 counter） |
| `richang_dns_forward_v6` | `ip6` | IPv6 DNAT/SNAT 转发表（含 counter） |
| `richang_dns_forward_limit` | `inet` | 限速表（meter，仅限速时段内存在） |

## 依赖

| 依赖 | 用途 |
|------|------|
| `nftables` | 防火墙规则管理 |
| `getent` | DNS 解析（由 `libc-bin` 提供） |
| `python3` | 解析 `nft -j` JSON 输出（流量统计） |
| `bc` | 字节数格式化计算 |
| `systemd` | 定时任务（可选） |

## 系统要求

- Linux 内核 >= 4.18（nftables NAT 支持）
- 已测试系统：Debian 11/12、Ubuntu 20.04/22.04、CentOS 8/9、Rocky Linux 8/9

## License

MIT