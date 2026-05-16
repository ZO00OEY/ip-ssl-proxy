#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Caddy + IP SSL 多服务反向代理一键部署脚本
#
# 功能: 为公网 IP 申请 SSL 证书，部署 Caddy 反向代理，
#       通过路径路由将 HTTPS 流量转发到多个本地服务。
#       同时监听 80 端口做 HTTP → HTTPS 自动跳转。
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/ZO00OEY/ip-ssl-proxy/main/setup.sh | bash
#
# 带域名（启用子域名访问，Caddy 自动签发 SSL 证书）:
#   DOMAIN=yourdomain.com curl -fsSL ... | bash
#
# 自定义服务列表:
#   SERVICES="/app1/|3000,/app2/|4000" curl -fsSL ... | bash
#   SERVICES="/app1/|3000|sub" DOMAIN=yourdomain.com curl -fsSL ... | bash
# ============================================================

# ============================================================
# 服务配置
# ============================================================
# 格式: "路径|后端主机|端口|子域名"
# 路径建议用 /name/ 格式（末尾保留斜杠）
# 主机默认为 127.0.0.1，可省略
# 子域名可选，设置后同时通过 https://子域名.你的域名 访问
# 设置 DOMAIN 环境变量启用子域名访问
#
# 可通过 SERVICES 环境变量覆盖，格式同上，用逗号分隔
# ============================================================

DEFAULT_SERVICES=(
    "/couchdb/|127.0.0.1|5984|"
    "/sillytavern/|127.0.0.1|8000|st"
    "/mihomo/|127.0.0.1|9097|"
    "/reader/|127.0.0.1|4396|"
    "/hermes/|127.0.0.1|9119|"
)

DOMAIN="${DOMAIN:-}"

# ============================================================

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---- 解析服务配置 ----
parse_services() {
    if [[ -n "${SERVICES:-}" ]]; then
        info "使用环境变量 SERVICES 中的自定义服务配置"
        IFS=',' read -ra SVC_TMP <<< "$SERVICES"
        SERVICES_LIST=()
        for svc in "${SVC_TMP[@]}"; do
            svc="${svc## }"
            svc="${svc%% }"
            SERVICES_LIST+=("$svc")
        done
    else
        SERVICES_LIST=("${DEFAULT_SERVICES[@]}")
    fi

    info "服务列表:"
    local has_subdomain=false
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r p h port sub <<< "$svc"
        [[ -z "$h" ]] && h="127.0.0.1"
        local line="    ${p}  →  ${h}:${port}"
        if [[ -n "$sub" && -n "$DOMAIN" ]]; then
            line+="  (https://${sub}.${DOMAIN}/)"
            has_subdomain=true
        fi
        echo "$line"
    done
    if [[ "$has_subdomain" == "true" ]]; then
        echo ""
        info "子域名访问已启用（DOMAIN=${DOMAIN}），Caddy 将自动签发 SSL 证书"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限，请使用 sudo 或以 root 身份运行"
        exit 1
    fi
}

prompt_domain() {
    if [[ -z "${DOMAIN:-}" ]]; then
        echo ""
        echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  可选：输入你的域名以启用子域名 HTTPS 访问          │${NC}"
        echo -e "${YELLOW}│  格式如: example.com                               │${NC}"
        echo -e "${YELLOW}│  留空直接回车则跳过，仅使用 IP 方式访问            │${NC}"
        echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
        echo -n "  域名: "
        read -r DOMAIN </dev/tty 2>/dev/null || true
        # 严格清理：只保留字母、数字、点、横线
        DOMAIN="$(printf '%s' "$DOMAIN" | LC_ALL=C tr -cd 'a-zA-Z0-9.-')"
        echo ""
    fi
    if [[ -n "$DOMAIN" ]]; then
        info "域名: ${DOMAIN}"
    fi
}

detect_ip() {
    PUBLIC_IP="${PUBLIC_IP:-}"
    if [[ -z "$PUBLIC_IP" ]]; then
        info "检测公网 IP ..."
        PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org || curl -s --max-time 10 https://icanhazip.com)
        if [[ -z "$PUBLIC_IP" ]]; then
            error "无法检测公网 IP，请手动设置 PUBLIC_IP 环境变量"
            error "示例: PUBLIC_IP=1.2.3.4 bash setup.sh"
            exit 1
        fi
    fi
    info "公网 IP: ${PUBLIC_IP}"
}

prompt_ip() {
    echo ""
    echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  检测到公网 IP: ${PUBLIC_IP}${NC}"
    echo -e "${YELLOW}│  如服务器使用 VPN，检测的可能不是服务器真实 IP    ${NC}"
    echo -e "${YELLOW}│  回车确认使用，或输入正确的公网 IP                ${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
    echo -n "  IP [${PUBLIC_IP}]: "
    read -r INPUT_IP </dev/tty 2>/dev/null || true
    if [[ -n "$INPUT_IP" ]]; then
        PUBLIC_IP="$INPUT_IP"
        info "已手动设置公网 IP: ${PUBLIC_IP}"
    else
        info "使用检测到的公网 IP: ${PUBLIC_IP}"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
    else
        OS_ID="unknown"
    fi
    info "系统: ${OS_ID} ${VERSION_ID:-}"
}

install_deps() {
    info "安装必要依赖 ..."
    local pkgs="curl socat openssl"
    case "${OS_ID}" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq $pkgs
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y $pkgs
            else
                yum install -y $pkgs
            fi
            ;;
        alpine)
            apk add $pkgs
            ;;
        *)
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq $pkgs
            elif command -v yum &>/dev/null; then
                yum install -y $pkgs
            else
                warn "未知系统，请手动安装: curl, socat, openssl"
            fi
            ;;
    esac
}

install_acme() {
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    if [[ -f "$acme_sh" ]]; then
        info "acme.sh 已安装"
        return
    fi
    info "安装 acme.sh ..."
    curl -fsSL https://get.acme.sh | bash
    if [[ -f "${HOME}/.acme.sh/acme.sh.env" ]]; then
        set +euo pipefail
        . "${HOME}/.acme.sh/acme.sh.env"
        set -euo pipefail
    fi
    info "acme.sh 安装完成"
}

install_caddy() {
    if command -v caddy &>/dev/null; then
        info "Caddy 已安装: $(caddy version)"
        return
    fi

    info "安装 Caddy ..."

    local installed=0
    case "${OS_ID}" in
        ubuntu|debian)
            info "通过 apt 安装 Caddy ..."
            apt-get install -y -qq debian-archive-keyring apt-transport-https 2>/dev/null || true
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' 2>/dev/null | \
                gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' 2>/dev/null | \
                tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null || true
            apt-get update -qq && apt-get install -y -qq caddy && installed=1 || true
            ;;
        centos|rhel|rocky|almalinux|fedora)
            info "通过 dnf/yum 安装 Caddy ..."
            if command -v dnf &>/dev/null; then
                dnf install -y 'dnf-command(copr)' && dnf copr enable -y @caddy/caddy && dnf install -y caddy && installed=1 || true
            fi
            ;;
    esac

    if [[ "$installed" -ne 1 ]]; then
        info "通过二进制包安装 Caddy ..."
        local caddy_url="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_amd64.tar.gz"
        curl -fsSL "$caddy_url" -o /tmp/caddy.tar.gz
        tar xzf /tmp/caddy.tar.gz -C /tmp caddy 2>/dev/null || (cd /tmp && gzip -dc caddy.tar.gz | tar xf - caddy)
        mv /tmp/caddy /usr/bin/caddy
        chmod +x /usr/bin/caddy

        if ! id -u caddy &>/dev/null; then
            useradd -r -d /var/lib/caddy -s /sbin/nologin caddy 2>/dev/null || true
        fi
        mkdir -p /var/lib/caddy /etc/caddy /var/log/caddy /var/www/html
        chown -R caddy:caddy /var/lib/caddy /var/log/caddy 2>/dev/null || true

        if command -v systemctl &>/dev/null; then
            curl -fsSL https://raw.githubusercontent.com/caddyserver/dist/master/init/caddy.service \
                -o /etc/systemd/system/caddy.service 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    info "Caddy 安装完成: $(caddy version)"
}

# ---- 启动临时 Caddy（仅端口 80，用于首次证书申请） ----
start_temp_caddy() {
    local cert_dir="${HOME}/.acme.sh/${PUBLIC_IP}_ecc"
    if [[ -f "${cert_dir}/fullchain.cer" ]] && [[ -f "${cert_dir}/${PUBLIC_IP}.key" ]]; then
        return
    fi

    # 停止可能已运行的 Caddy（apt 安装后会自动启动），
    # 换成我们自己的临时配置来响应 ACME 验证
    if pgrep -x caddy &>/dev/null; then
        info "停止已运行的 Caddy，启动临时配置用于证书验证..."
        systemctl stop caddy 2>/dev/null || true
        caddy stop 2>/dev/null || true
        sleep 1
    fi

    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ':80 '; then
            warn "端口 80 被占用，尝试强制释放..."
            systemctl stop caddy 2>/dev/null || true
            caddy stop 2>/dev/null || true
            sleep 2
            if ss -tlnp 2>/dev/null | grep -q ':80 '; then
                error "端口 80 仍被占用，无法启动临时 Caddy"
                error "请手动执行: systemctl stop caddy && fuser -k 80/tcp"
                exit 1
            fi
        fi
    fi

    info "启动临时 Caddy（端口 80，用于 Let's Encrypt 验证）..."
    mkdir -p /var/www/html

    cat > /etc/caddy/Caddyfile.temp <<'EOF'
:80 {
    root * /var/www/html
    file_server
}
EOF

    caddy start --config /etc/caddy/Caddyfile.temp --adapter caddyfile 2>/dev/null || {
        caddy run --config /etc/caddy/Caddyfile.temp --adapter caddyfile > /dev/null 2>&1 &
        TEMP_CADDY_PID=$!
    }
    sleep 2
    info "临时 Caddy 已启动"
}

stop_temp_caddy() {
    if [[ -n "${TEMP_CADDY_PID:-}" ]]; then
        kill "$TEMP_CADDY_PID" 2>/dev/null || true
        wait "$TEMP_CADDY_PID" 2>/dev/null || true
    fi
    # 也尝试用 caddy stop（处理 caddy start 启动的情况）
    caddy stop --config /etc/caddy/Caddyfile.temp 2>/dev/null || true
    rm -f /etc/caddy/Caddyfile.temp
}

# ---- 申请证书（webroot 模式） ----
issue_cert() {
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    local cert_dir="${HOME}/.acme.sh/${PUBLIC_IP}_ecc"
    CERT_FILE="${cert_dir}/fullchain.cer"
    KEY_FILE="${cert_dir}/${PUBLIC_IP}.key"

    echo ""
    echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  IP 证书（acme.sh）                                │${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"

    mkdir -p /var/www/html

    if [[ -f "$CERT_FILE" ]] && [[ -f "$KEY_FILE" ]]; then
        info "证书已存在，检查续期 ..."
        ${acme_sh} --cron -d "${PUBLIC_IP}" 2>/dev/null || true
    else
        info "申请 Let's Encrypt IP 证书（webroot 模式）..."
        info "Caddy 已在端口 80 响应验证请求"
        ${acme_sh} --issue \
            --server letsencrypt \
            -d "${PUBLIC_IP}" \
            --certificate-profile shortlived \
            --webroot /var/www/html \
            --force || {
                stop_temp_caddy
                error "证书申请失败，常见原因："
                error "1. 端口 80 被防火墙阻挡（安全组/iptables 需放行）"
                error "2. 公网 IP ${PUBLIC_IP} 并非本机公网 IP"
                error "3. /var/www/html 目录不可写"
                error ""
                error "请检查后重试，或手动运行："
                error "  ~/.acme.sh/acme.sh --issue --server letsencrypt -d ${PUBLIC_IP} --certificate-profile shortlived --webroot /var/www/html"
                exit 1
            }
        info "证书申请成功！"
    fi

    # 设置续期后重载 Caddy（webroot 模式）
    ${acme_sh} --install-cert -d "${PUBLIC_IP}" \
        --reloadcmd "systemctl reload caddy 2>/dev/null || caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true"
}

# ---- 申请域名证书（acme.sh webroot 模式）----
issue_domain_certs() {
    [[ -z "$DOMAIN" ]] && return
    local acme_sh="${HOME}/.acme.sh/acme.sh"

    echo ""
    echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  域名证书（acme.sh webroot 模式）                    │${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"

    local cert_dir="${HOME}/.acme.sh/${DOMAIN}_ecc"
    local cert_file="${cert_dir}/fullchain.cer"
    local key_file="${cert_dir}/${DOMAIN}.key"

    if [[ -f "$cert_file" ]] && [[ -f "$key_file" ]]; then
        info "域名证书已存在: ${DOMAIN}"
    else
        info "申请域名证书: ${DOMAIN}"
        ${acme_sh} --issue --server letsencrypt -d "${DOMAIN}" \
            --webroot /var/www/html --force 2>/dev/null && {
            info "${DOMAIN} 证书申请成功"
        } || {
            warn "${DOMAIN} 证书申请失败，常见原因："
            warn "1. 域名 ${DOMAIN} 的 DNS 未指向本机 IP ${PUBLIC_IP}"
            warn "2. 端口 80 被防火墙/安全组阻挡"
        }
    fi
    echo ""
}

# ---- 生成根页面 HTML ----
gen_root_html() {
    local html="/var/www/html/index.html"
    mkdir -p /var/www/html

    local cards=""
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r p h port sub <<< "$svc"
        local name="${p//\//}"
        [[ -z "$name" ]] && continue
        local ip_link="https://${PUBLIC_IP}${p}"
        local links="<a href=\"${ip_link}\" class=\"link\">${ip_link}</a>"
        if [[ -n "$sub" && -n "$DOMAIN" ]]; then
            local domain_link="https://${sub}.${DOMAIN}/"
            links+="<a href=\"${domain_link}\" class=\"link sub\">${domain_link}</a>"
        fi
        cards+="        <div class=\"card\">
          <div class=\"card-title\">${name}</div>
          <div class=\"card-links\">${links}</div>
        </div>
"
    done

    local domain_section=""
    if [[ -n "$DOMAIN" ]]; then
        domain_section="<p class=\"domain\">🌐 <a href=\"https://${DOMAIN}\">${DOMAIN}</a></p>"
    fi

    cat > "$html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Caddy + IP SSL</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%);
  color: #e2e8f0;
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 2rem;
}
.container {
  width: 100%;
  max-width: 560px;
}
.header {
  text-align: center;
  margin-bottom: 2.5rem;
}
.header h1 {
  font-size: 1.5rem;
  font-weight: 600;
  color: #f1f5f9;
  letter-spacing: -0.02em;
}
.footer-path {
  text-align: center;
  margin-top: 0.75rem;
  font-size: 0.7rem;
  color: #334155;
}
.domain {
  text-align: center;
  margin-top: 0.3rem;
}
.domain a {
  color: #38bdf8;
  font-size: 0.9rem;
  text-decoration: none;
}
.domain a:hover {
  text-decoration: underline;
}
.cards {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
.card {
  background: rgba(30, 41, 59, 0.6);
  backdrop-filter: blur(8px);
  border: 1px solid rgba(148, 163, 184, 0.1);
  border-radius: 12px;
  padding: 1rem 1.25rem;
  transition: border-color 0.2s;
}
.card:hover {
  border-color: rgba(148, 163, 184, 0.25);
}
.card-title {
  font-size: 0.8rem;
  font-weight: 500;
  color: #94a3b8;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 0.5rem;
}
.card-links {
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
}
.link {
  font-size: 0.9rem;
  color: #38bdf8;
  text-decoration: none;
  word-break: break-all;
  transition: color 0.15s;
}
.link:hover {
  color: #7dd3fc;
}
.link.sub {
  color: #a78bfa;
  font-size: 0.85rem;
}
.link.sub:hover {
  color: #c4b5fd;
}
.footer {
  text-align: center;
  margin-top: 2.5rem;
  font-size: 0.75rem;
  color: #475569;
}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>本站导航</h1>
    ${domain_section}
  </div>
  <div class="cards">
${cards}
  </div>
  <div class="footer">
    IP SSL &middot; HTTP → HTTPS 自动跳转 &middot; 证书自动续期
  </div>
  <div class="footer-path">/var/www/html/index.html</div>
</div>
</body>
</html>
HTML
}

# ---- 生成 Caddy 配置 ----
configure_caddy() {
    local caddyfile="/etc/caddy/Caddyfile"
    info "生成 Caddy 配置: ${caddyfile}"

    mkdir -p /etc/caddy

    cat > "$caddyfile" <<CADDYEOF
# Caddy + IP SSL 多服务配置 - 由 setup.sh 自动生成
# 公网 IP: ${PUBLIC_IP}

{
    admin off
}

# -------- 端口 80: ACME 验证 + HTTP → HTTPS 跳转 --------
:80 {
    # 先处理 Let's Encrypt 验证请求
    @acme {
        path /.well-known/acme-challenge/*
    }
    handle @acme {
        root * /var/www/html
        file_server
    }
    }
}

CADDYEOF

    # ---- 主域名区块 ----
    local acme_home="${HOME}/.acme.sh"
    if [[ -n "$DOMAIN" ]]; then
        cat >> "$caddyfile" <<ROUTE

# ${DOMAIN} → 导航页
${DOMAIN} {
    tls ${acme_home}/${DOMAIN}_ecc/fullchain.cer ${acme_home}/${DOMAIN}_ecc/${DOMAIN}.key
    root * /var/www/html
    file_server
}
ROUTE
        info "已添加主域名 ${DOMAIN} → 导航页"
    fi

    # -------- 端口 443: 证书反向代理（catch-all，使用 IP 证书兜底）--------
    cat >> "$caddyfile" <<ROUTE

:443 {
    tls ${CERT_FILE} ${KEY_FILE}

ROUTE

    # 写入每个服务的路由
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path host port sub <<< "$svc"
        [[ -z "$host" ]] && host="127.0.0.1"
        local strip_path="${path%/}"

        cat >> "$caddyfile" <<ROUTE
    # ${strip_path} → ${host}:${port}
    redir ${strip_path} ${path} 308
    handle_path ${path}* {
        reverse_proxy ${host}:${port} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-For {remote_host}
        }
    }
ROUTE
    done

    # 根路径和日志
    cat >> "$caddyfile" <<ROUTE

    # 根路径 - 服务列表页
    handle / {
        root * /var/www/html
        file_server
    }

    log {
        output file /var/log/caddy/access.log {
            roll_size 50mb
            roll_keep 3
        }
    }
}

ROUTE

    info "Caddy 配置已生成，共 ${#SERVICES_LIST[@]} 个服务路由"
}

setup_cron_renew() {
    info "配置证书自动续期 ..."
    local acme_sh="${HOME}/.acme.sh/acme.sh"

    # 每天凌晨 3 点检查续期（acme.sh 自动使用 webroot 模式）
    if ! (crontab -l 2>/dev/null | grep -q 'acme.sh.*--cron'); then
        (crontab -l 2>/dev/null || true; echo "0 3 * * * ${acme_sh} --cron > /dev/null 2>&1") | crontab -
        info "已添加续期 crontab（每日 3:00 检查）"
    else
        info "续期 crontab 已存在"
    fi
}

start_caddy() {
    info "启动 Caddy 服务 ..."

    if command -v systemctl &>/dev/null && [[ -f /etc/systemd/system/caddy.service ]]; then
        systemctl enable caddy 2>/dev/null || true
        systemctl restart caddy 2>/dev/null || systemctl start caddy 2>/dev/null || {
            error "systemctl 启动 Caddy 失败，请检查: journalctl -u caddy -n 50"
            return 1
        }
    else
        caddy stop 2>/dev/null || true
        sleep 1
        nohup caddy run --config /etc/caddy/Caddyfile --adapter caddyfile > /var/log/caddy/caddy.log 2>&1 &
        info "Caddy 已后台启动 (PID: $!)"
    fi

    # 验证
    sleep 2
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://${PUBLIC_IP}" --insecure --max-time 5 2>/dev/null)
    http_code="${http_code%%[[:space:]]*}"

    if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [[ "$http_code" != "000" ]]; then
        info "Caddy 启动成功，HTTPS 根页面响应码: ${http_code}"
    else
        warn "Caddy 已启动但 HTTPS 暂时无响应，请稍后检查: curl -k https://${PUBLIC_IP}"
    fi
}

# ---- 检查域名 SSL 证书（验证 acme.sh 签发文件） ----
check_domain_certs() {
    [[ -z "$DOMAIN" ]] && return

    echo ""
    echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  验证域名 SSL 证书...                               │${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"

    local cert_file="${HOME}/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    local key_file="${HOME}/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"
    echo -n "  ${DOMAIN}  ...  "

    if [[ -f "$cert_file" ]] && [[ -f "$key_file" ]]; then
        local expiry
        expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
        local now_epoch
        now_epoch=$(date +%s)
        local expiry_epoch
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        if [[ -n "$expiry" ]] && [[ "$expiry_epoch" -gt "$now_epoch" ]]; then
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            echo -e "${GREEN}有效${NC}（${days_left} 天后到期）"
            echo ""
            info "域名 SSL 证书有效"
        else
            echo -e "${RED}已过期${NC}"
            echo ""
            warn "域名证书已过期，请重新申请"
        fi
    else
        echo -e "${RED}证书文件缺失${NC}"
        echo ""
        warn "域名证书未找到，请检查 acme.sh 日志"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Caddy + IP SSL 多服务部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  入口地址:  ${GREEN}https://${PUBLIC_IP}${NC}"
    if [[ -n "$DOMAIN" ]]; then
        echo -e "  主站:       ${GREEN}https://${DOMAIN}${NC}"
    fi
    echo ""
    echo -e "  ${YELLOW}可用服务:${NC}"
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path h port _ <<< "$svc"
        [[ -z "$h" ]] && h="127.0.0.1"
        echo -e "    https://${PUBLIC_IP}${path}  →  ${h}:${port}"
    done
    echo ""
    if [[ -n "$DOMAIN" ]]; then
        echo -e "  ${GREEN}域名证书已配置！${NC}"
        echo "  证书续期: acme.sh 每日 3:00 自动检查"
        echo ""
    fi
    echo "  Caddy 配置:   /etc/caddy/Caddyfile"
    echo "  SSL 证书:     ${CERT_FILE}"
    echo "  SSL 私钥:     ${KEY_FILE}"
    echo "  访问日志:     /var/log/caddy/access.log"
    echo "  导航页面:     /var/www/html/index.html"
    echo ""
    echo -e "${YELLOW}  重要提示：${NC}"
    echo "  1. 云服务商安全组需放行端口 443 (HTTPS) 和 80 (HTTP)"
    echo "  2. 原始 http://IP:端口 仍然可以直接访问（旁路）"
    echo ""
    echo -e "${GREEN}  一键测试: curl -k https://${PUBLIC_IP}/couchdb/${NC}"
    echo ""
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Caddy + IP SSL 多服务反向代理${NC}"
    echo -e "${GREEN}  一键部署脚本${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    check_root
    parse_services
    detect_os
    install_deps
    detect_ip
    prompt_ip
    prompt_domain
    install_acme
    install_caddy

    # 首次运行：启动临时 Caddy（端口 80）用于证书申请
    # 后续运行：证书已存在，直接检查续期
    start_temp_caddy
    issue_cert

    # 如果设置了域名，在临时 Caddy 还在运行时申请域名证书
    if [[ -n "$DOMAIN" ]]; then
        issue_domain_certs
    fi

    stop_temp_caddy

    gen_root_html
    configure_caddy
    setup_cron_renew
    start_caddy
    check_domain_certs
    print_summary
}

main "$@"
