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

## 快速开始

### 前提条件

- Linux 云服务器（Debian/Ubuntu/CentOS 等）
- 有**固定公网 IP**
- 云服务商安全组已**放行 80 和 443 端口**
- 你的各个后端服务已经在对应端口运行

### 一键安装

在云服务器终端执行：

```bash
curl -fsSL https://raw.githubusercontent.com/ZO00OEY/ip-ssl-proxy/main/setup.sh | bash
```

或者分两步下载再运行：

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/ZO00OEY/ip-ssl-proxy/main/setup.sh && bash setup.sh
```

然后**什么都不用做**，脚本全自动跑完。整个过程通常 1-3 分钟。

### 验证

部署完成后，浏览器访问 `https://你的公网IP` 能看到服务列表页。

或者用 curl 测试：

```bash
curl -k https://你的公网IP/couchdb/
curl -k https://你的公网IP/tavern/
```

> `-k` 是因为 IP 证书是自签名链，第一次访问会提示不安全，这是正常的。

## 默认服务路由

安装后自动配置以下路径转发：

| 路径 | 目标地址 | 说明 |
|---|---|---|
| `/couchdb/` | `127.0.0.1:5984` | Obsidian Livesync (CouchDB) |
| `/tavern/` | `127.0.0.1:8000` | SillyTavern 酒馆 |
| `/mihomo/` | `127.0.0.1:9097` | Mihomo 控制面板 |
| `/reader/` | `127.0.0.1:4396` | 阅读 |
| `/hermes/` | `127.0.0.1:9119` | Hermes Agent |

## 自定义服务

如果你的服务列表不一样，通过环境变量覆盖：

```bash
curl -fsSL https://raw.githubusercontent.com/ZO00OEY/ip-ssl-proxy/main/setup.sh | SERVICES="/app1/|3000,/app2/|4000" bash
```

格式：`"路径|后端IP(可选)|端口"`，多个用逗号分隔，主机 IP 省略则默认为 `127.0.0.1`。

更多例子：

```bash
# 省略主机 IP（默认 127.0.0.1）
SERVICES="/ui/|8080,/api/|9000" bash setup.sh

# 指定不同主机
SERVICES="/svc1/|192.168.1.10|3000,/svc2/|4000" bash setup.sh
```

## 日常管理

### 查看 Caddy 状态

```bash
systemctl status caddy
```

### 重新加载配置

修改 `/etc/caddy/Caddyfile` 后：

```bash
systemctl reload caddy
```

### 查看访问日志

```bash
tail -f /var/log/caddy/access.log
```

### 证书续期

证书每天凌晨 3 点自动检查续期，无需手动干预。如需手动触发：

```bash
~/.acme.sh/acme.sh --cron
```

## 注意事项

1. **SSL 证书警告**：浏览器访问 IP 证书时可能会显示"不安全"，因为 IP 证书不属于公开信任的证书体系（但**通信本身是加密的**）。如果需要消除这个提示，建议使用域名。
2. **SillyTavern**：如果页面资源加载异常，需要在 SillyTavern 的 `config.yaml` 中设置 `enableProxy: true`。
3. **无法访问？** 检查云服务商安全组是否放行了 80 和 443 端口入站规则。
4. **HTTP 跳转**：访问 `http://IP` 会自动 301 跳转到 `https://IP`，这是 Caddy 的标准行为。
5. **原始端口仍可直达**：`http://IP:5984`、`http://IP:8000` 等依然可以直接访问，Caddy 不干扰现有服务。

## 文件位置

| 项目 | 路径 |
|---|---|
| Caddy 配置 | `/etc/caddy/Caddyfile` |
| SSL 证书 | `~/.acme.sh/你的IP_ecc/fullchain.cer` |
| SSL 私钥 | `~/.acme.sh/你的IP_ecc/你的IP.key` |
| 访问日志 | `/var/log/caddy/access.log` |
| 服务列表页 | `/var/www/html/index.html` |
