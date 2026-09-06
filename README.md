# Caddy + SSL 多服务反向代理

给云服务器一键部署 HTTPS 反向代理，用子路径将流量分发到多个本地服务。

无需 ICP 备案即可用 IP 证书加密通信；有域名时可切换 Caddy 自动签发证书模式。

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

  1  初始化环境
  2  域名 / SSL 证书 / 导航页
  3  CPA 反代安装与管理
  0  退出

----------------------------------------
  请输入 [1/2/3/0]:
```

选 1 初始化依赖、acme.sh、Caddy 和基础配置；选 2 进入证书、服务路由和导航页管理；选 3 进入 CPA 管理。

也可以直接执行 `bash setup.sh cpa <操作>`，适合服务器上的自动化调用。

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

### CPA（CLIProxyAPI）

CPA 默认安装到 `/opt/cliproxyapi`，配置在 `/etc/cliproxyapi/config.yaml`，认证目录在 `/var/lib/cliproxyapi/auth-dir`，由 root 用户级 systemd 管理。默认会 GET GitHub Releases API，自动选择当前 Linux 架构的最新版本，并从 `checksums.txt` 取得 SHA256：

```bash
bash setup.sh cpa install
```

如需可审计的固定版本，可同时设置 `CPA_DOWNLOAD_URL` 和 `CPA_SHA256`，脚本将跳过 Releases API；只设置其中一个会直接报错。

首次安装只生成配置模板，不会伪造或上传上游凭证。编辑配置时必须把 `api-keys` 中的占位值替换成你手动收集的客户端 Key，并设置独立的 `remote-management.secret-key`；完成 OAuth 登录后，再接入现有 Caddy：

```bash
bash setup.sh cpa status
bash setup.sh cpa route
bash setup.sh cpa backup
```

公网只暴露 `/cpa/v1` API，并在 Caddy 层拒绝 `/cpa/v1/management*`；管理页面默认保持本机访问，需管理时使用 SSH 隧道到 `127.0.0.1:8317`。升级、日志、启停和保留数据卸载分别为 `cpa upgrade`、`cpa logs`、`cpa restart`、`cpa uninstall`。

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
