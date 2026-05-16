#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Caddy + SSL 多服务反向代理一键部署脚本
#
# 三种模式:
#   1. IP 证书模式 — 纯 IP 证书，配置文件不含域名
#   2. 域名证书模式 — 纯域名证书，配置文件不含 IP
#   3. 子域名管理 — 添加/查看子域名证书
# ============================================================

# ============================================================
# 服务配置
# ============================================================
# 格式: "路径|后端主机|端口|子域名"
# 路径建议用 /name/ 格式（末尾保留斜杠）
# 主机默认为 127.0.0.1，可省略
# 可通过 SERVICES 环境变量覆盖，用逗号分隔
# ============================================================

DEFAULT_SERVICES=(
    "/couchdb/|127.0.0.1|5984|"
    "/st/|127.0.0.1|8000|st"
    "/mihomo/|127.0.0.1|9097|"
    "/reader/|127.0.0.1|4396|"
    "/hermes/|127.0.0.1|9119|"
)

DOMAIN="${DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"

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
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r p h port sub <<< "$svc"
        [[ -z "$h" ]] && h="127.0.0.1"
        echo "    ${p}  →  ${h}:${port}"
    done
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
        echo -e "${YELLOW}-----------------------------------------${NC}"
        echo -e "${YELLOW}  输入你的域名 (例如: example.com)${NC}"
        echo -e "${YELLOW}-----------------------------------------${NC}"
        echo -n "  域名: "
        read -r DOMAIN </dev/tty 2>/dev/null || true
        DOMAIN="$(printf '%s' "$DOMAIN" | LC_ALL=C tr -cd 'a-zA-Z0-9.-')"
        echo ""
    fi
    if [[ -z "$DOMAIN" ]]; then
        error "域名不能为空"
        exit 1
    fi
    info "域名: ${DOMAIN}"
}

detect_ip() {
    PUBLIC_IP="${PUBLIC_IP:-}"
    if [[ -z "$PUBLIC_IP" ]]; then
        info "检测公网 IP ..."
        PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org || curl -s --max-time 10 https://icanhazip.com)
        if [[ -z "$PUBLIC_IP" ]]; then
            error "无法检测公网 IP，请手动设置 PUBLIC_IP 环境变量"
            exit 1
        fi
    fi
    info "公网 IP: ${PUBLIC_IP}"
}

prompt_ip() {
    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  检测到公网 IP: ${PUBLIC_IP}${NC}"
    echo -e "${YELLOW}  如服务器使用 VPN，检测的可能不是服务器真实 IP${NC}"
    echo -e "${YELLOW}  回车确认使用，或输入正确的公网 IP${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"
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

    curl -fsSL https://get.acme.sh | bash 2>/dev/null || true

    if [[ ! -f "$acme_sh" ]]; then
        warn "默认源安装失败，尝试中国镜像（gitlink）..."
        CFG_MIRROR=gitlink curl -fsSL https://get.acme.sh | bash 2>/dev/null || true
    fi

    if [[ ! -f "$acme_sh" ]]; then
        error "acme.sh 安装失败，请手动安装后重试"
        error "中国大陆用户参考: https://github.com/acmesh-official/acme.sh/wiki/Install-in-China"
        exit 1
    fi

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

# ---- 临时 Caddy（端口 80，用于证书申请） ----
start_temp_caddy() {
    if pgrep -x caddy &>/dev/null; then
        info "停止已运行的 Caddy..."
        systemctl stop caddy 2>/dev/null || true
        caddy stop 2>/dev/null || true
        sleep 1
    fi

    # 确保端口 80 可用
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ':80 '; then
            warn "端口 80 被占用，强制释放..."
            systemctl stop caddy 2>/dev/null || true
            caddy stop 2>/dev/null || true
            sleep 2
            if ss -tlnp 2>/dev/null | grep -q ':80 '; then
                warn "使用 fuser 强制释放..."
                fuser -k 80/tcp 2>/dev/null || true
                sleep 1
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
    caddy stop --config /etc/caddy/Caddyfile.temp 2>/dev/null || true
    rm -f /etc/caddy/Caddyfile.temp
}

# ---- 申请 IP 证书 ----
issue_ip_cert() {
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    local cert_dir="${HOME}/.acme.sh/${PUBLIC_IP}_ecc"
    CERT_FILE="${cert_dir}/fullchain.cer"
    KEY_FILE="${cert_dir}/${PUBLIC_IP}.key"

    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  IP 证书（acme.sh）${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    mkdir -p /var/www/html

    if [[ -f "$CERT_FILE" ]] && [[ -f "$KEY_FILE" ]]; then
        info "证书已存在，检查续期 ..."
        ${acme_sh} --cron -d "${PUBLIC_IP}" 2>/dev/null || true
    else
        info "申请 Let's Encrypt IP 证书（webroot 模式）..."
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
                exit 1
            }
        info "证书申请成功！"
    fi

    ${acme_sh} --install-cert -d "${PUBLIC_IP}" \
        --reloadcmd "systemctl reload caddy 2>/dev/null || caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true"
}

# ---- 生成根页面 HTML ----
gen_root_html() {
    local base_url="${1:-}"
    if [[ -z "$base_url" ]]; then
        if [[ -n "$DOMAIN" ]]; then
            base_url="https://${DOMAIN}"
        else
            base_url="https://${PUBLIC_IP}"
        fi
    fi

    local html="/var/www/html/index.html"
    mkdir -p /var/www/html

    local cards=""
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r p h port _ <<< "$svc"
        local name="${p//\//}"
        [[ -z "$name" ]] && continue

        # 为 SillyTavern 显示全称，并提示子路径下 CSS 错乱
        local note=""
        if [[ "$port" == "8000" ]]; then
            name="SillyTavern"
            note=" <span style=\"color:#f87171;font-size:0.75rem;\">（通过本方式使用酒馆会CSS错乱）</span>"
        fi

        cards+="        <div class=\"card\">
          <div class=\"card-title\">${name}${note}</div>
          <div class=\"card-links\"><a href=\"${base_url}${p}\" class=\"link\">${base_url}${p}</a></div>
        </div>
"
    done

    cat > "$html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Caddy + SSL</title>
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
.container { width: 100%; max-width: 560px; }
.header { text-align: center; margin-bottom: 2.5rem; }
.header h1 { font-size: 1.5rem; font-weight: 600; color: #f1f5f9; letter-spacing: -0.02em; }
.cards { display: flex; flex-direction: column; gap: 0.75rem; }
.card {
  background: rgba(30, 41, 59, 0.6);
  backdrop-filter: blur(8px);
  border: 1px solid rgba(148, 163, 184, 0.1);
  border-radius: 12px;
  padding: 1rem 1.25rem;
}
.card-title {
  font-size: 0.8rem; font-weight: 500; color: #94a3b8;
  text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.5rem;
}
.link {
  font-size: 0.9rem; color: #38bdf8; text-decoration: none; word-break: break-all;
}
.link:hover { color: #7dd3fc; }
.footer {
  text-align: center; margin-top: 2.5rem; font-size: 0.75rem; color: #475569;
}
</style>
</head>
<body>
<div class="container">
  <div class="header"><h1>本站导航</h1></div>
  <div class="cards">${cards}</div>
  <div class="footer">SSL 加密 &middot; 证书自动续期</div>
</div>
</body>
</html>
HTML
}

# ---- 生成 Caddy 配置（IP 模式）----
configure_caddy_ip() {
    local caddyfile="/etc/caddy/Caddyfile"
    info "生成 Caddy 配置（IP 模式）: ${caddyfile}"
    mkdir -p /etc/caddy

    cat > "$caddyfile" <<CADDYEOF
# Caddy + SSL IP 模式 - 由 setup.sh 自动生成
# 公网 IP: ${PUBLIC_IP}

{
    admin off
}

# -------- 端口 80: ACME 验证 --------
:80 {
    @acme {
        path /.well-known/acme-challenge/*
    }
    handle @acme {
        root * /var/www/html
        file_server
    }
    handle {
        root * /var/www/html
        file_server
    }
}

# -------- 端口 443: IP 证书反代 --------
${PUBLIC_IP}:443 {
    tls ${CERT_FILE} ${KEY_FILE}
CADDYEOF

    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path host port _ <<< "$svc"
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

    cat >> "$caddyfile" <<ROUTE
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

# ---- 生成 Caddy 配置（域名模式）----
configure_caddy_domain() {
    local caddyfile="/etc/caddy/Caddyfile"
    info "生成 Caddy 配置（域名模式）: ${caddyfile}"
    mkdir -p /etc/caddy

    cat > "$caddyfile" <<CADDYEOF
# Caddy + SSL 域名模式 - 由 setup.sh 自动生成
# 域名: ${DOMAIN}

{
    admin off
}

# -------- 端口 80: ACME 验证 --------
:80 {
    @acme {
        path /.well-known/acme-challenge/*
    }
    handle @acme {
        root * /var/www/html
        file_server
    }
    handle {
        root * /var/www/html
        file_server
    }
}

# -------- 域名反代（Caddy 自动签发证书）-------
${DOMAIN} {
CADDYEOF

    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path host port _ <<< "$svc"
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

    cat >> "$caddyfile" <<ROUTE
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

# ---- 证书续期 cron（仅 IP）----
setup_cron_renew_ip() {
    info "配置 IP 证书自动续期 ..."
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    if ! (crontab -l 2>/dev/null | grep -q "acme.sh.*--cron.*${PUBLIC_IP}"); then
        (crontab -l 2>/dev/null || true; echo "0 3 * * * ${acme_sh} --cron -d ${PUBLIC_IP} > /dev/null 2>&1") | crontab -
        info "已添加续期 crontab（每日 3:00 检查 IP 证书）"
    else
        info "续期 crontab 已存在"
    fi
}

# ---- 启动 Caddy ----
start_caddy() {
    local verify_url="${1:-}"
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

    if [[ -z "$verify_url" ]]; then
        if [[ -n "$DOMAIN" ]]; then
            verify_url="https://${DOMAIN}"
        else
            verify_url="https://${PUBLIC_IP}"
        fi
    fi

    sleep 2
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$verify_url" --insecure --max-time 5 2>/dev/null)
    http_code="${http_code%%[[:space:]]*}"

    if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [[ "$http_code" != "000" ]]; then
        info "Caddy 启动成功，HTTPS 响应码: ${http_code}"
    else
        warn "Caddy 已启动但 HTTPS 暂时无响应: curl -k ${verify_url}"
    fi
}

# ---- 输出摘要 ----
print_summary_ip() {
    echo ""
    echo "========================================"
    echo "  IP 证书模式部署完成！"
    echo "========================================"
    echo ""
    echo "  入口地址:  https://${PUBLIC_IP}"
    echo ""
    echo "  可用服务:"
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path h port _ <<< "$svc"
        [[ -z "$h" ]] && h="127.0.0.1"
        echo "    https://${PUBLIC_IP}${path}  →  ${h}:${port}"
    done
    echo ""
    echo "  Caddy 配置:   /etc/caddy/Caddyfile"
    echo "  SSL 证书:     ${CERT_FILE}"
    echo "  访问日志:     /var/log/caddy/access.log"
    echo "  导航页面:     /var/www/html/index.html"
    echo ""
    echo "  重要提示："
    echo "  1. 云服务商安全组需放行端口 443 (HTTPS) 和 80 (HTTP)"
    echo ""
    echo "  一键测试: curl -k https://${PUBLIC_IP}/couchdb/"
    echo ""
}

print_summary_domain() {
    echo ""
    echo "========================================"
    echo "  域名证书模式部署完成！"
    echo "========================================"
    echo ""
    echo "  入口地址:  https://${DOMAIN}"
    echo ""
    echo "  可用服务:"
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path h port _ <<< "$svc"
        [[ -z "$h" ]] && h="127.0.0.1"
        echo "    https://${DOMAIN}${path}  →  ${h}:${port}"
    done
    echo ""
    echo "  Caddy 配置:   /etc/caddy/Caddyfile"
    echo "  SSL 证书:     Caddy 自动管理（Let's Encrypt）"
    echo "  访问日志:     /var/log/caddy/access.log"
    echo "  导航页面:     /var/www/html/index.html"
    echo ""
    echo "  重要提示："
    echo "  1. 云服务商安全组需放行端口 443 (HTTPS) 和 80 (HTTP)"
    echo "  2. 确保域名 ${DOMAIN} 的 DNS A 记录指向本机 IP"
    echo ""
    echo "  一键测试: curl -k https://${DOMAIN}/couchdb/"
    echo ""
}

# ============================================================
# 模式 3: 配对模式（IP + 域名双入口）
# ============================================================
mode_paired() {
    check_root
    detect_os
    install_deps
    detect_ip
    prompt_ip
    prompt_domain
    install_acme
    install_caddy

    # 确保 IP 证书
    start_temp_caddy
    issue_ip_cert
    stop_temp_caddy

    # 生成并启动配对配置
    configure_caddy_paired
    gen_root_html "https://${DOMAIN}"
    start_caddy "https://${DOMAIN}"

    # 交互式添加服务
    paired_add_services
}

configure_caddy_paired() {
    local caddyfile="/etc/caddy/Caddyfile"
    local routes_ip_dir="/etc/caddy/routes-ip.d"
    local routes_domain_dir="/etc/caddy/routes-domain.d"
    local sub_dir="/etc/caddy/subdomains.d"

    info "生成 Caddy 配置（配对模式）: ${caddyfile}"
    mkdir -p /etc/caddy "$routes_ip_dir" "$routes_domain_dir" "$sub_dir"

    cat > "$caddyfile" <<CADDYEOF
# Caddy + SSL 配对模式 - 由 setup.sh 自动生成
# IP: ${PUBLIC_IP}  域名: ${DOMAIN}

{
    admin off
}

# -------- 端口 80: ACME 验证 --------
:80 {
    @acme {
        path /.well-known/acme-challenge/*
    }
    handle @acme {
        root * /var/www/html
        file_server
    }
    handle {
        root * /var/www/html
        file_server
    }
}

# -------- IP 证书入口 --------
${PUBLIC_IP}:443 {
    tls ${CERT_FILE} ${KEY_FILE}

    import ${routes_ip_dir}/*.conf

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

# -------- 域名入口（Caddy 自动签发证书）-------
${DOMAIN} {
    import ${routes_domain_dir}/*.conf

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

import ${sub_dir}/*.conf
CADDYEOF
    info "配对 Caddyfile 已生成"
}

paired_add_services() {
    local routes_ip_dir="/etc/caddy/routes-ip.d"
    local routes_domain_dir="/etc/caddy/routes-domain.d"
    local sub_dir="/etc/caddy/subdomains.d"

    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  添加服务（可多次添加，留空名称结束）${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    while true; do
        echo ""
        echo -n "  服务名称（如: sillytavern，留空结束）: "
        read -r SVC_NAME </dev/tty 2>/dev/null || true
        SVC_NAME="$(printf '%s' "$SVC_NAME" | LC_ALL=C tr -cd 'a-zA-Z0-9_-')"
        [[ -z "$SVC_NAME" ]] && break

        echo -n "  后端端口（如: 8000）: "
        read -r SVC_PORT </dev/tty 2>/dev/null || true
        SVC_PORT="$(printf '%s' "$SVC_PORT" | LC_ALL=C tr -cd '0-9')"

        if [[ -z "$SVC_PORT" ]]; then
            error "端口不能为空"
            continue
        fi

        info "添加: /${SVC_NAME}/ → :${SVC_PORT}"
        echo "  入口:"
        echo "    https://${PUBLIC_IP}/${SVC_NAME}/"
        echo "    https://${DOMAIN}/${SVC_NAME}/"
        echo "    https://${SVC_NAME}.${DOMAIN}/"

        # IP 路径路由
        cat > "${routes_ip_dir}/${SVC_NAME}.conf" <<ROUTE
    handle_path /${SVC_NAME}/* {
        reverse_proxy 127.0.0.1:${SVC_PORT} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-For {remote_host}
        }
    }
ROUTE

        # 域名路径路由
        cp "${routes_ip_dir}/${SVC_NAME}.conf" "${routes_domain_dir}/${SVC_NAME}.conf"

        # 子域名
        cat > "${sub_dir}/${SVC_NAME}.conf" <<ROUTE
${SVC_NAME}.${DOMAIN} {
    reverse_proxy 127.0.0.1:${SVC_PORT} {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-For {remote_host}
    }
    log {
        output file /var/log/caddy/access.log {
            roll_size 50mb
            roll_keep 3
        }
    }
}
ROUTE

        info "${SVC_NAME} 已添加"
    done

    # 重载 Caddy
    if ls "${routes_ip_dir}"/*.conf &>/dev/null 2>&1 || ls "${sub_dir}"/*.conf &>/dev/null 2>&1; then
        info "重载 Caddy..."
        if command -v systemctl &>/dev/null && systemctl is-active caddy &>/dev/null 2>&1; then
            systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
        else
            caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
        fi
        info "配对模式部署完成！"
    else
        warn "未添加任何服务，请重新运行模式 3"
    fi
}

# ============================================================
# 模式 4: 子域名管理（原模式 3）
# ============================================================

# ---- 列出已有子域名 ----
list_subdomains() {
    local sub_dir="/etc/caddy/subdomains.d"
    local found=()

    if [[ -d "$sub_dir" ]]; then
        for f in "$sub_dir"/*.conf; do
            [[ -f "$f" ]] || continue
            local sub
            sub=$(basename "$f" .conf)
            local port
            port=$(grep -oP ':\K\d+' "$f" 2>/dev/null | head -1 || echo "?")
            found+=("${sub}.${DOMAIN} (端口 ${port})")
        done
    fi

    if [[ ${#found[@]} -eq 0 ]]; then
        echo "  （暂无子域名）"
    else
        for entry in "${found[@]}"; do
            echo "  ${entry}"
        done
    fi
}


# ---- 添加子域名到 Caddyfile ----
add_subdomain_to_caddy() {
    local sub_domain="${1}"
    local port="${2}"
    local sub_prefix="${sub_domain%%.${DOMAIN}}"
    local sub_dir="/etc/caddy/subdomains.d"
    local caddyfile="/etc/caddy/Caddyfile"

    mkdir -p "$sub_dir"

    # 检查是否已存在
    if [[ -f "${sub_dir}/${sub_prefix}.conf" ]]; then
        warn "子域名 ${sub_domain} 已存在，跳过添加"
        return 0
    fi

    info "添加子域名: ${sub_domain} → :${port}（Caddy 将自动签发证书）"
    cat > "${sub_dir}/${sub_prefix}.conf" <<ROUTE
${sub_domain} {
    reverse_proxy 127.0.0.1:${port} {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-For {remote_host}
    }
    log {
        output file /var/log/caddy/access.log {
            roll_size 50mb
            roll_keep 3
        }
    }
}
ROUTE

    # 确保主 Caddyfile 有 import 子域名目录
    if ! grep -q "import.*subdomains.d" "$caddyfile" 2>/dev/null; then
        echo "" >> "$caddyfile"
        echo "import /etc/caddy/subdomains.d/*.conf" >> "$caddyfile"
        info "已在 Caddyfile 添加子域名引用"
    fi

    info "已添加 ${sub_domain} → :${port}"
}

# ============================================================
# 模式 1: IP 证书
# ============================================================
mode_ip() {
    check_root
    parse_services
    detect_os
    install_deps
    detect_ip
    prompt_ip
    install_acme
    install_caddy

    start_temp_caddy
    issue_ip_cert
    stop_temp_caddy

    gen_root_html "https://${PUBLIC_IP}"
    configure_caddy_ip
    setup_cron_renew_ip
    start_caddy "https://${PUBLIC_IP}"
    print_summary_ip
}

# ============================================================
# 模式 2: 域名证书
# ============================================================
mode_domain() {
    check_root
    parse_services
    detect_os
    install_deps
    prompt_domain
    install_caddy

    gen_root_html "https://${DOMAIN}"
    configure_caddy_domain
    start_caddy "https://${DOMAIN}"
    print_summary_domain
}

# ============================================================
# 模式 4: 子域名管理
# ============================================================
mode_subdomain() {
    check_root

    # 需要先有域名
    if [[ -z "$DOMAIN" ]]; then
        prompt_domain
    fi

    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  现有子域名${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"
    list_subdomains

    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  添加新子域名${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -n "  子域名前缀（如: st → ${DOMAIN} 的 st.${DOMAIN}）: "
    read -r SUB_PREFIX </dev/tty 2>/dev/null || true
    SUB_PREFIX="$(printf '%s' "$SUB_PREFIX" | LC_ALL=C tr -cd 'a-zA-Z0-9-')"

    if [[ -z "$SUB_PREFIX" ]]; then
        error "子域名前缀不能为空"
        return 1
    fi

    echo -n "  后端端口（如: 8000）: "
    read -r SUB_PORT </dev/tty 2>/dev/null || true
    SUB_PORT="$(printf '%s' "$SUB_PORT" | LC_ALL=C tr -cd '0-9')"

    if [[ -z "$SUB_PORT" ]]; then
        error "端口不能为空"
        return 1
    fi

    local sub_domain="${SUB_PREFIX}.${DOMAIN}"
    echo ""
    info "即将添加: ${sub_domain} → :${SUB_PORT}（Caddy 将自动签发证书）"

    if [[ -f /etc/caddy/Caddyfile ]]; then
        add_subdomain_to_caddy "$sub_domain" "$SUB_PORT"

        # 重载 Caddy
        info "重载 Caddy..."
        if command -v systemctl &>/dev/null && systemctl is-active caddy &>/dev/null 2>&1; then
            systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
        else
            caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
        fi
        info "子域名添加完成！https://${sub_domain}/"
    else
        warn "未找到 Caddyfile，请先运行模式 2 设置域名"
    fi
}

# ============================================================
# 菜单
# ============================================================
show_menu() {
    echo ""
    echo "========================================"
    echo "  Caddy + SSL 多服务反向代理"
    echo "========================================"
    echo ""
    echo "  请选择需要的功能:"
    echo ""
    echo "  1  拉取IP证书  [二选一]"
    echo "  2  拉取域名证书  [二选一]"
    echo "  3  配对模式（IP + 域名双入口）"
    echo "  4  添加子域名"
    echo "  0  退出"
    echo ""
    echo "----------------------------------------"
    echo -n "  请输入 [1/2/3/4/0]: "
}

# ============================================================
# Main
# ============================================================
main() {
    show_menu
    read -r CHOICE </dev/tty 2>/dev/null || true
    echo ""

    case "$CHOICE" in
        1) mode_ip ;;
        2) mode_domain ;;
        3) mode_paired ;;
        4) mode_subdomain ;;
        q|Q|0) info "已退出" ; exit 0 ;;
        *) error "无效选项，请输入 1、2、3、4 或 0" ; exit 1 ;;
    esac
}

main "$@"
