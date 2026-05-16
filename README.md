# Caddy + IP SSL 多服务反向代理

给**没有域名**的云服务器一键部署 HTTPS 反向代理，通过路径路由将流量分发到多个本地服务。

支持**可选的域名子域名模式**，解决 SillyTavern 等不支持子路径路由的应用。

---

## 快速开始

```bash
cd ~
git clone https://github.com/ZO00OEY/ip-ssl-proxy.git
cd ip-ssl-proxy && bash setup.sh
```

脚本会全自动完成：

```
安装依赖 → 申请 IP 证书 → 安装 Caddy → 配置反代 → 生成导航页 → 开机自启 + 证书续期
```

整个过程 1-3 分钟。

---

## 更新脚本

```bash
cd ~/ip-ssl-proxy && git pull && bash setup.sh
```

脚本已安装过的情况下，重新运行会：检查续期证书 → 重新生成配置 → 重启 Caddy。

> 如果上次运行被 Ctrl+C 中断导致 apt 锁残留，先执行：
> ```bash
> rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
> dpkg --configure -a
> ```

---

## 交互流程

脚本运行过程会依次：

1. **确认公网 IP** — 自动检测，如果服务器在用 VPN 可能检测错误，可手动修正
2. **可选输入域名** — 有域名就填，直接回车跳过，仅用 IP 方式访问

两个都是可选步骤，全程回车即使用默认值。

---

## 工作原理

```
用户 → http://IP          ─┐
用户 → http://IP/xxx      ─┤──→ Caddy :80 ─→ 301 跳转 HTTPS
                            │
用户 → https://IP/couchdb/ ─┤
用户 → https://IP/tavern/  ─┤
用户 → https://IP/mihomo/  ─┼──→ Caddy :443 (IP SSL 证书) ─→ 各本地服务
用户 → https://IP/reader/  ─┤
用户 → https://IP/hermes/  ─┘
```

- Caddy 同时监听 80（HTTP→HTTPS 跳转）和 443（HTTPS 反代）
- 你的服务不需要任何修改，原端口依然可直接访问

---

## 子域名访问（有域名时可选）

对于 SillyTavern 这类使用绝对路径导致子路径下 CSS 错乱的应用，可以用子域名方式访问。

### DNS 配置

在域名管理后台添加 A 记录：

| 类型 | 主机记录 | 指向 |
|------|----------|------|
| A | `st` | 你的服务器 IP |
| A | `*` | 你的服务器 IP（可选泛解析） |

### 运行脚本

```bash
cd ~/ip-ssl-proxy && git pull && bash setup.sh
```

在域名提示处输入 `moyugod.com`，脚本自动：
- 保留 IP 路径访问不变
- 为带子域名的服务添加 `https://子域名.你的域名/` 入口
- Caddy 自动签发 SSL 证书并续期

默认子域名 `st` 对应 SillyTavern：`https://st.你的域名/`

---

## 默认服务列表

| 路径 | 目标地址 | 说明 |
|------|----------|------|
| `/couchdb/` | `127.0.0.1:5984` | Obsidian Livesync |
| `/tavern/` | `127.0.0.1:8000` | SillyTavern |
| `/mihomo/` | `127.0.0.1:9097` | Mihomo 面板 |
| `/reader/` | `127.0.0.1:4396` | 阅读 |
| `/hermes/` | `127.0.0.1:9119` | Hermes Agent |

---

## 自定义服务

通过环境变量覆盖：

```bash
SERVICES="/app1/|3000,/app2/|192.168.1.10|4000" bash setup.sh
```

格式：`"路径|后端IP(可选)|端口"`，逗号分隔。  
加子域名：`"/app/|端口|sub"`，需配合 `DOMAIN` 环境变量。

---

## 日常管理

| 操作 | 命令 |
|------|------|
| 查看状态 | `systemctl status caddy` |
| 重载配置 | `systemctl reload caddy` |
| 查看日志 | `tail -f /var/log/caddy/access.log` |
| 手动续期 | `~/.acme.sh/acme.sh --cron` |
| 修改导航页 | `vi /var/www/html/index.html` |

证书每天凌晨 3 点自动检查续期。

---

## 文件位置

| 项目 | 路径 |
|------|------|
| Caddy 配置 | `/etc/caddy/Caddyfile` |
| SSL 证书 | `~/.acme.sh/你的IP_ecc/fullchain.cer` |
| SSL 私钥 | `~/.acme.sh/你的IP_ecc/你的IP.key` |
| 访问日志 | `/var/log/caddy/access.log` |
| 导航页面 | `/var/www/html/index.html` |

---

## 注意事项

1. **IP 证书安全警告** — 浏览器会提示"不安全"，这是正常的，通信本身加密
2. **SillyTavern** — 子路径访问需在 `config.yaml` 中设置 `enableProxy: true`
3. **端口放行** — 云服务商安全组需放行 80 和 443 端口
4. **HTTP 自动跳转** — `http://IP` 自动 301 到 `https://IP`
5. **原始端口直达** — `http://IP:原端口` 不受 Caddy 影响
