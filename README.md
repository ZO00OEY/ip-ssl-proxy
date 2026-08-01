# Caddy + SSL 多服务反向代理

给云服务器一键部署 HTTPS 反向代理，用子路径将流量分发到多个本地服务。

无需 ICP 备案即可用 IP 证书加密通信；有域名时可切换 Caddy 自动签发证书模式。

## 更新说明（2026-08-01）

- 修复 IP 短期证书过期后只尝试静默续期、未真正重新签发的问题。
- 证书过期或剩余有效期不足两天时，强制重新签发并验证新证书有效性。
- 明确使用 ECC 证书，并在安装证书后自动重新加载 Caddy。
- 合并 acme.sh 安装程序和历史脚本生成的重复 cron，统一为每天 03:00 执行的唯一全局续期任务。
- 续期输出统一写入 `/var/log/caddy/acme-renew.log`，方便排查失败原因。
- 重复运行安装脚本不会再次追加证书续期任务。

---

## 快速开始

```bash
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

选 1 自动完成所有步骤：安装依赖 → 申请证书 → 配置 Caddy → 生成导航页。

运行完后自动回到菜单，可以继续选 3 添加自定义服务，或选 0 退出。

**更新脚本：**
```bash
cd ~/ip-ssl-proxy && git pull && bash setup.sh
```

---

## 工作模式

### 模式 1：IP 证书（无需域名）

为公网 IP 申请 Let's Encrypt 证书，所有服务通过 `https://IP/路径/` 访问。

已内置的默认服务：

```
https://IP/couchdb/   →  CouchDB (5984)
https://IP/st/        →  SillyTavern (8000)
https://IP/mihomo/    →  Mihomo 面板 (9097)
https://IP/reader/    →  阅读 (4396)
https://IP/hermes/    →  Hermes Agent (9119)
```

适用场景：没有域名或不想备案，但仍需 HTTPS 加密通信的服务。

### 模式 2：域名证书（需要域名）

Caddy 自动为域名签发和续期 SSL 证书，服务通过 `https://域名/路径/` 访问。

适合有域名的服务器，浏览器不提示安全警告。

### 模式 3：添加/删除服务

自动检测当前 Caddyfile 是 IP 模式还是域名模式，对应添加子路径或子域名。

进入后看到编号列表，操作方式：

- **回车** → 逐步输入服务名称和端口，添加新服务
- **输入序号** → 删除对应的自定义服务
- **输入 0** → 返回菜单

操作后自动更新导航页和 Caddy 配置，即时生效。

---

## 证书方案

| 模式 | 拉取方式 | 证书位置 | 续期 |
|------|---------|---------|------|
| IP 证书 | acme.sh webroot | `/root/.acme.sh/<IP>_ecc/fullchain.cer`<br>`/root/.acme.sh/<IP>_ecc/<IP>.key` | crontab 每日 3:00<br>日志: `/var/log/caddy/acme-renew.log` |
| 域名证书 | Caddy 自动签发 | `/root/.local/share/caddy/certificates/`<br>`acme-v02.api.letsencrypt.org-directory/<域名>/` | Caddy 自动续期 |

IP 证书是有效期较短的 `shortlived` 证书。重新运行脚本时会检查有效期；证书已过期或不足两天时会强制重新签发。脚本会清理 acme.sh 安装程序及本项目遗留的重复续期任务，再写入唯一一条每日 3:00 执行、带日志的全局 acme.sh 续期任务。该任务会覆盖 acme.sh 管理的全部证书。

---

## 自定义服务

通过 `SERVICES` 环境变量覆盖默认服务列表：

```bash
SERVICES="/app1/|3000,/app2/|192.168.1.10|4000" bash setup.sh
```

格式：`"路径|后端IP(可选)|端口|子域名前缀(可选)"`，逗号分隔。

之后也可以通过模式 3 交互式增删。

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

1. **IP 证书安全警告** — 浏览器会提示"不安全"，这是 Let's Encrypt IP 证书的机制，通信本身是加密的
2. **SillyTavern 子路径** — `https://IP/st/` 下 CSS 会错乱，需改用子域名
3. **端口放行** — 云服务商安全组需放行 80 和 443 端口
4. **HTTP → HTTPS 跳转** — 访问 `http://IP/xxx` 会自动跳转到 `https://IP/xxx`
5. **原始端口直达** — `http://IP:原端口` 不受 Caddy 影响，可旁路访问
6. **架构支持** — 自动检测 x86_64 / arm64 
