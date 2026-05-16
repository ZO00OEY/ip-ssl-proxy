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
# 自定义服务列表:
#   SERVICES="/app1/|3000,/app2/|4000" curl -fsSL ... | bash
#   SERVICES="/app1/|192.168.1.2|3000,/app2/|4000" bash setup.sh
# ============================================================

# ============================================================
# 服务配置
# ============================================================
# 格式: "路径|后端主机|端口"
# 路径建议用 /name/ 格式（末尾保留斜杠）
# 主机默认为 127.0.0.1，可省略
#
# 可通过 SERVICES 环境变量覆盖，格式同上，用逗号分隔
# ============================================================

DEFAULT_SERVICES=(
    "/couchdb/|127.0.0.1|5984"    # Obsidian Livesync (CouchDB)
    "/tavern/|127.0.0.1|8000"     # SillyTavern 酒馆
    "/mihomo/|127.0.0.1|9097"     # Mihomo 控制面板
    "/reader/|127.0.0.1|4396"     # 阅读
    "/hermes/|127.0.0.1|9119"     # Hermes Agent
)

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
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r p h port <<< "$svc"
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
                gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
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
    # 如果证书已存在，不需要启动临时 Caddy
    local cert_dir="${HOME}/.acme.sh/${PUBLIC_IP}_ecc"
    if [[ -f "${cert_dir}/fullchain.cer" ]] && [[ -f "${cert_dir}/${PUBLIC_IP}.key" ]]; then
        return
    fi

    # 检查端口 80 是否被占用
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ':80 '; then
            # 可能已有 Caddy 在运行（重跑脚本），直接返回
            if pgrep -x caddy &>/dev/null; then
                info "Caddy 已在运行，跳过临时启动"
                return
            fi
            error "端口 80 被占用，请释放后重试"
            error "执行: lsof -ti:80 | xargs kill -9"
            exit 1
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

    mkdir -p /var/www/html

    if [[ -f "$CERT_FILE" ]] && [[ -f "$KEY_FILE" ]]; then
        info "证书已存在，检查续期 ..."
        ${acme_sh} --cron 2>/dev/null || true
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

# ---- 生成根页面 HTML ----
gen_root_html() {
    local html="/var/www/html/index.html"
    mkdir -p /var/www/html

    local list_items=""
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r p h port <<< "$svc"
        local name="${p//\//}"
        [[ -z "$name" ]] && continue
        list_items+="        <li><a href=\"${p}\">${name}</a> <span style=\"color:#666;\">(${h}:${port})</span></li>\\n"
    done

    cat > "$html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Caddy + IP SSL</title>
<style>
body { font-family: -apple-system, sans-serif; max-width: 640px; margin: 60px auto; padding: 0 20px; line-height: 1.6; }
h1 { color: #333; border-bottom: 2px solid #4CAF50; padding-bottom: 10px; }
ul { list-style: none; padding: 0; }
li { padding: 8px 12px; margin: 4px 0; background: #f5f5f5; border-radius: 6px; }
li:hover { background: #e8f5e9; }
a { color: #2e7d32; text-decoration: none; font-weight: 500; }
.ip { color: #888; font-size: 0.9em; }
.footer { margin-top: 40px; font-size: 0.85em; color: #999; }
</style>
</head>
<body>
<h1>Caddy 反向代理运行中</h1>
<p class="ip">${PUBLIC_IP} — IP SSL</p>
<ul>
${list_items}
</ul>
<div class="footer">
  HTTP 自动跳转 HTTPS &middot; 证书自动续期 &middot; 路径路由反向代理
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
    # 其余请求跳转 HTTPS
    handle {
        redir https://${PUBLIC_IP}{uri} permanent
    }
}

# -------- 端口 443: HTTPS + 反向代理 --------
:443 {
    tls ${CERT_FILE} ${KEY_FILE}

CADDYEOF

    # 写入每个服务的路由
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path host port <<< "$svc"
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
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://${PUBLIC_IP}" --insecure --max-time 5 2>/dev/null || echo "000")

    if [[ "$http_code" != "000" ]]; then
        info "Caddy 启动成功，HTTPS 根页面响应码: ${http_code}"
    else
        warn "Caddy 已启动但 HTTPS 暂时无响应，请稍后检查: curl -k https://${PUBLIC_IP}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Caddy + IP SSL 多服务部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  入口地址:  ${GREEN}https://${PUBLIC_IP}${NC}"
    echo -e "  HTTP 跳转:  http://${PUBLIC_IP}  →  https://${PUBLIC_IP}"
    echo ""
    echo -e "  ${YELLOW}可用服务:${NC}"
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path h port <<< "$svc"
        [[ -z "$h" ]] && h="127.0.0.1"
        echo -e "    https://${PUBLIC_IP}${path}  →  ${h}:${port}"
    done
    echo ""
    echo "  Caddy 配置:   /etc/caddy/Caddyfile"
    echo "  SSL 证书:     ${CERT_FILE}"
    echo "  SSL 私钥:     ${KEY_FILE}"
    echo "  访问日志:     /var/log/caddy/access.log"
    echo ""
    echo -e "${YELLOW}  重要提示：${NC}"
    echo "  1. 云服务商安全组需放行端口 443 (HTTPS) 和 80 (HTTP)"
    echo "  2. 访问 http://IP 会自动跳转到 https://IP"
    echo "  3. 原始 http://IP:端口 仍然可以直接访问（旁路）"
    echo "  4. 某些 Web 应用（如 SillyTavern）需在应用内开启反代模式:"
    echo "     SillyTavern: config.yaml 中设置 enableProxy: true"
    echo "  5. 修改服务列表后，编辑 /etc/caddy/Caddyfile 然后执行:"
    echo "     systemctl reload caddy"
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
    install_acme
    install_caddy

    # 首次运行：启动临时 Caddy（端口 80）用于证书申请
    # 后续运行：证书已存在，直接检查续期
    start_temp_caddy
    issue_cert
    stop_temp_caddy

    gen_root_html
    configure_caddy
    setup_cron_renew
    start_caddy
    print_summary
}

main "$@"
