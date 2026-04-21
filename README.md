# nft-dns-forward（旧版 v1.0 / older 分支）

> ⚠️ 这是旧版分支（`older`），功能为基础端口转发和域名转发，**无流量统计、无限速功能**。
>
> 如需使用带流量统计和时段限速的新版，请切换到 [`main` 分支](https://github.com/utada1stlove/nft_menus)。

---

## 版本对比

| 功能 | 旧版（older） | 新版（main） |
|------|:---:|:---:|
| 静态 IP 端口转发（TCP/UDP） | ✅ | ✅ |
| 动态域名转发（DNS 自动解析） | ✅ | ✅ |
| 流量统计（RX/TX counter） | ❌ | ✅ |
| 限速（nft meter） | ❌ | ✅ |
| 时间段限速（schedule） | ❌ | ✅ |
| 一键安装脚本 | ❌ | ✅ |
| 一键卸载脚本 | ❌ | ✅ |

---

## 文件结构

```
├── nftables.sh                   # 静态 IP 端口转发管理（菜单交互式）
├── nft-dns-forward-menu.sh       # 动态域名转发管理菜单
├── nft-dns-forward-sync.sh       # 域名解析 + nftables 同步引擎
└── nft-dns-forward.conf.example  # 配置文件示例
```

---

## 快速下载使用（无需 git）

```bash
curl -Lo /tmp/nft_older.zip https://github.com/utada1stlove/nft_menus/archive/refs/heads/older.zip \
  && unzip -q /tmp/nft_older.zip -d /tmp \
  && cd /tmp/nft_menus-older \
  && cp nft-dns-forward.conf.example nft-dns-forward.conf \
  && chmod +x nftables.sh nft-dns-forward-menu.sh nft-dns-forward-sync.sh
```

---

## 使用方法

### 静态 IP 端口转发（`nftables.sh`）

适用于目标是固定 IP 的场景，支持 TCP/UDP/双协议，支持端口段。

```bash
sudo bash /tmp/nft_menus-older/nftables.sh
```

菜单选项：
```
 0. 安装 nftables / 启用 IP 转发（含 BBR、IPv4/IPv6 转发、RST/ACK 过滤）
 1. 添加转发规则
 2. 删除转发规则
 3. 查看转发规则
 4. 查看原始 nftables 规则
 5. 清空本脚本管理的规则
```

### 动态域名转发（`nft-dns-forward-menu.sh`）

适用于目标是域名（IP 可能变化）的场景，由 systemd timer 每 60s 自动重解析。

**第一步：编辑配置文件**

```bash
vim /tmp/nft_menus-older/nft-dns-forward.conf
```

配置格式：
```
name|listen_port|target_host|target_port|source_ip|family
```

示例：
```
cloud-a|44288|example.com|51312|10.0.0.10|4
cloud-b|9999|example.com|9999|10.0.0.10|4
```

**第二步：运行菜单**

```bash
sudo bash /tmp/nft_menus-older/nft-dns-forward-menu.sh
```

菜单选项：
```
 0. 开启 IPv4 转发
 1. 添加规则
 2. 删除规则
 3. 查看当前配置
 4. 查看解析结果（含 DNS 解析 IP）
 5. 同步 nftables 规则
 6. 查看当前 nftables 表
 7. 安装自动同步 timer（每 60s 自动重解析域名）
 8. 清空当前生效规则
 9. 退出
```

---

## 卸载

旧版没有自动卸载脚本，执行以下命令手动卸载：

```bash
# 1. 停止并删除 systemd timer
systemctl stop nft-dns-forward-sync.timer 2>/dev/null || true
systemctl disable nft-dns-forward-sync.timer 2>/dev/null || true
rm -f /etc/systemd/system/nft-dns-forward-sync.timer
rm -f /etc/systemd/system/nft-dns-forward-sync.service
systemctl daemon-reload

# 2. 清除 nftables 转发规则（域名转发表）
nft delete table ip  richang_dns_forward_v4 2>/dev/null || true
nft delete table ip6 richang_dns_forward_v6 2>/dev/null || true

# 3. 清除 nftables 静态转发规则（静态转发表）
nft delete table ip   richang_port_forward_v4     2>/dev/null || true
nft delete table ip6  richang_port_forward_v6     2>/dev/null || true
nft delete table inet richang_port_forward_filter 2>/dev/null || true

# 4. 删除 nftables 持久化文件
rm -f /etc/nftables/richang-port-forward.nft
rm -f /etc/sysctl.d/99-richang-ip-forward.conf
rm -f /etc/sysctl.d/99-ip-forward.conf

# 5. 删除脚本文件（按实际路径修改）
rm -rf /tmp/nft_menus-older
rm -f /tmp/nft_older.zip
```

---

## 升级到新版

如果你想升级到带流量统计和时段限速的新版，直接运行：

```bash
curl -Lo /tmp/nft_menus.zip https://github.com/utada1stlove/nft_menus/archive/refs/heads/main.zip \
  && unzip -q /tmp/nft_menus.zip -d /tmp \
  && cd /tmp/nft_menus-main \
  && bash install.sh \
  && cd / \
  && rm -rf /tmp/nft_menus.zip /tmp/nft_menus-main
```

> 新版配置文件格式向后兼容，旧的 6 字段 `.conf` 文件无需修改即可直接使用。