# Caddy + IP SSL 多服务反向代理一键部署

为没有域名的云服务器一键部署 HTTPS 反向代理，通过路径路由将流量分发到多个本地服务。

## 适用场景

你有一台云服务器，上面跑了多个 Web 服务（比如 CouchDB、SillyTavern、Mihomo 面板等），各自监听在不同端口。你想**不买域名**，直接通过 `https://公网IP/路径` 来 HTTPS 访问这些服务。

## 工作原理

```
用户 → http://IP          ─┐
用户 → http://IP/xxx      ─┤──→ Caddy (端口 80) ─→ 301 跳转到 HTTPS
                            │
用户 → https://IP/couchdb/ ─┤
用户 → https://IP/tavern/  ─┤
用户 → https://IP/mihomo/  ─┼──→ Caddy (端口 443, IP SSL 证书) ─→ 分流到各本地服务
用户 → https://IP/reader/  ─┤
用户 → https://IP/hermes/  ─┘
```

- Caddy **同时监听 80 和 443 端口**
- **80 端口**：处理 Let's Encrypt 证书验证 + HTTP → HTTPS 自动跳转
- **443 端口**：HTTPS 加密流量，根据 URL 路径将请求转发到对应的本地端口
- 你现有的服务**不需要做任何修改**，继续在原端口运行
- `http://IP:原端口` 依然可以直接访问，不受影响

## 前提条件

- Linux 云服务器（Debian/Ubuntu/CentOS 等）
- 有**固定公网 IP**
- 云服务商安全组已**放行 80 和 443 端口**
- 你的各个后端服务已经在对应端口运行

---

## 第一部分：首次安装

**git clone 下载脚本 → 运行**

```bash
cd ~
git clone https://github.com/ZO00OEY/ip-ssl-proxy.git
cd ip-ssl-proxy && bash setup.sh
```

脚本会全自动完成：安装依赖 → 申请 IP 证书 → 安装 Caddy → 配置反向代理 → 设置开机自启和证书续期。

整个过程通常 1-3 分钟。

---

## 第二部分：安装中断后的恢复

如果上次运行被 `Ctrl+C` 中断，或者脚本中途报错退出，apt 的锁可能没释放，再次运行会卡住。

**清理残留锁文件 → 更新脚本 → 重新运行**

```bash
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
dpkg --configure -a
cd ~/ip-ssl-proxy && git pull && bash setup.sh
```

- 前三行：删掉上次中断残留的 apt 锁，释放 dpkg，让包管理器恢复正常
- `git pull`：拉取脚本最新版本
- `bash setup.sh`：重新运行

---

## 验证部署

浏览器访问 `https://你的公网IP` 能看到服务列表页。

或用 curl 测试：

```bash
curl -k https://你的公网IP/couchdb/
curl -k https://你的公网IP/tavern/
```

> `-k` 是因为 IP 证书不是域名证书，第一次访问浏览器会提示不安全，但通信本身是加密的。

## 默认服务路由

| 路径 | 目标地址 | 说明 |
|---|---|---|
| `/couchdb/` | `127.0.0.1:5984` | Obsidian Livesync (CouchDB) |
| `/tavern/` | `127.0.0.1:8000` | SillyTavern 酒馆 |
| `/mihomo/` | `127.0.0.1:9097` | Mihomo 控制面板 |
| `/reader/` | `127.0.0.1:4396` | 阅读 |
| `/hermes/` | `127.0.0.1:9119` | Hermes Agent |

## 自定义服务

通过环境变量 `SERVICES` 覆盖默认列表，格式：`"路径|后端IP(可选)|端口"`，多个用逗号分隔。

```bash
cd ~/ip-ssl-proxy
SERVICES="/app1/|3000,/app2/|192.168.1.10|4000" bash setup.sh
```

## 日常管理

| 操作 | 命令 |
|---|---|
| 查看 Caddy 状态 | `systemctl status caddy` |
| 修改配置后重载 | `systemctl reload caddy` |
| 查看访问日志 | `tail -f /var/log/caddy/access.log` |
| 手动续期证书 | `~/.acme.sh/acme.sh --cron` |

证书每天凌晨 3 点自动检查续期，无需手动干预。

## 注意事项

1. **SSL 证书警告**：浏览器访问 IP 证书时显示"不安全"是正常的，因为 IP 证书不属于公开信任体系。通信本身是加密的。
2. **SillyTavern**：如果页面资源加载异常，需要在 `config.yaml` 中设置 `enableProxy: true`。
3. **无法访问？** 检查云服务商安全组是否放行了 80 和 443 端口。
4. **HTTP 跳转**：访问 `http://IP` 会自动 301 跳转到 `https://IP`。
5. **原始端口仍可直达**：`http://IP:5984`、`http://IP:8000` 等不受 Caddy 影响。

## 文件位置

| 项目 | 路径 |
|---|---|
| Caddy 配置 | `/etc/caddy/Caddyfile` |
| SSL 证书 | `~/.acme.sh/你的IP_ecc/fullchain.cer` |
| SSL 私钥 | `~/.acme.sh/你的IP_ecc/你的IP.key` |
| 访问日志 | `/var/log/caddy/access.log` |
| 服务列表页 | `/var/www/html/index.html` |
