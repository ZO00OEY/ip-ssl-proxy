# Caddy + SSL 多服务反向代理

给云服务器一键部署 HTTPS 反向代理，用子路径或子域名将流量分发到多个本地服务。

无需 ICP 备案即可用 IP 证书加密通信；有域名时可切换 Caddy 自动签发证书模式。

---

## 快速开始

```bash
cd ~
git clone https://github.com/ZO00OEY/ip-ssl-proxy.git
cd ip-ssl-proxy && bash setup.sh
```

首次运行弹出菜单：

```
========================================
  Caddy + SSL 多服务反向代理
========================================

  请选择需要的功能:

  1  拉取IP证书  [二选一]
  2  拉取域名证书  [二选一]
  3  添加服务（自动匹配当前配置）
  0  退出

----------------------------------------
  请输入 [1/2/3/0]:
```

选择后自动完成：安装依赖 → 申请证书 → 配置 Caddy → 生成导航页。

运行完后**自动回到菜单**，可以继续选 3 添加自定义服务，或选 0 退出。

---

## 工作模式

### 模式 1：IP 证书（无需域名）

为公网 IP 申请 Let's Encrypt 证书，所有服务通过 `https://IP/路径/` 访问。

适用 Obsidian Livesync、Mihomo 面板等支持子路径配置的应用。

```
https://IP/couchdb/   →  CouchDB (5984)
https://IP/st/        →  SillyTavern (8000)
https://IP/mihomo/    →  Mihomo 面板 (9097)
https://IP/reader/    →  阅读 (4396)
https://IP/hermes/    →  Hermes Agent (9119)
```

### 模式 2：域名证书（需要域名）

Caddy 自动为域名签发和续期 SSL 证书，服务通过 `https://域名/路径/` 访问。

适合有域名的服务器，浏览器显示安全锁。

### 模式 3：添加/删除服务（自动匹配当前配置）

自动检测当前 Caddyfile 是 IP 模式还是域名模式，对应添加子路径或子域名。

- **IP 模式** → 添加子路径：输入名称和端口，生成 `https://IP/名称/`
- **域名模式** → 添加子域名：输入前缀和端口，生成 `https://前缀.域名/`

输入 `!名称` 可删除已有服务。

---

## 证书方案

| 模式 | 拉取方式 | 证书位置 | 续期 |
|------|---------|---------|------|
| IP 证书 | acme.sh webroot | `/root/.acme.sh/<IP>_ecc/fullchain.cer`<br>`/root/.acme.sh/<IP>_ecc/<IP>.key` | crontab 每日 3:00<br>日志: `/var/log/caddy/acme-renew.log` |
| 域名证书 | Caddy 自动签发 | `/root/.local/share/caddy/certificates/`<br>`acme-v02.api.letsencrypt.org-directory/<域名>/` | Caddy 自动续期 |

---

## 自定义服务

通过 `SERVICES` 环境变量覆盖默认服务列表：

```bash
SERVICES="/app1/|3000,/app2/|192.168.1.10|4000" bash setup.sh
```

格式：`"路径|后端IP(可选)|端口|子域名前缀(可选)"`，逗号分隔。

后期可通过模式 3 交互式增删。

---

## 文件位置

| 项目 | 路径 |
|------|------|
| Caddy 主配置 | `/etc/caddy/Caddyfile` |
| IP 模式自定义子路径 | `/etc/caddy/routes-custom.d/*.conf` |
| 域名模式自定义子域名 | `/etc/caddy/subdomains.d/*.conf` |
| 已保存服务列表 | `/etc/caddy/.services.conf` |
| 访问日志 | `/var/log/caddy/access.log` |
| ACME 续期日志 | `/var/log/caddy/acme-renew.log` |
| 导航页面 | `/var/www/html/index.html` |

---

## 日常管理

| 操作 | 命令 |
|------|------|
| 查看 Caddy 状态 | `systemctl status caddy` |
| 重载配置 | `systemctl reload caddy` |
| 查看日志 | `journalctl -u caddy -n 50 --no-pager` |
| 手动续期 IP 证书 | `/root/.acme.sh/acme.sh --cron` |
| 重新运行脚本 | `cd ~/ip-ssl-proxy && git pull && bash setup.sh` |

---

## 注意事项

1. **IP 证书安全警告** — 浏览器会提示"不安全"，这是 Let's Encrypt IP 证书的特性，通信本身加密
2. **SillyTavern 子路径** — `https://IP/st/` 下 CSS 可能错乱，需在 `config.yaml` 中设置 `enableProxy: true`，或改用子域名
3. **端口放行** — 云服务商安全组需放行 80 和 443 端口
4. **HTTP → HTTPS** — 80 端口仅用于 ACME 验证和静态文件服务，不自动跳转
5. **原始端口直达** — `http://IP:原端口` 不受 Caddy 影响
6. **架构支持** — 自动检测 x86_64 / arm64 / armv7
