#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Caddy + IP SSL 一键部署脚本
# 为公网 IP 配置 Caddy 反向代理与 HTTPS
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ZO00OEY/ip-ssl-proxy/main/setup.sh)
#   或:
#   BACKEND_PORT=3000 bash setup.sh
# ============================================

# ---- 配置（可通过环境变量覆盖） ----
BACKEND_PORT="${BACKEND_PORT:-5984}"
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
PUBLIC_IP="${PUBLIC_IP:-}"
SKIP_CADDY_INSTALL="${SKIP_CADDY_INSTALL:-}"

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ============================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限，请使用 sudo 或以 root 身份运行"
        exit 1
    fi
}

detect_ip() {
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
    info "检测操作系统 ..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_LIKE="${ID_LIKE:-}"
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
    # 确保 acme.sh 可用
    export LE_WORKING_DIR="${HOME}/.acme.sh"
    if [[ -f "${HOME}/.acme.sh/acme.sh.env" ]]; then
        set +euo pipefail
        . "${HOME}/.acme.sh/acme.sh.env"
        set -euo pipefail
    fi
    info "acme.sh 安装完成"
}

issue_cert() {
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    local cert_dir="${HOME}/.acme.sh/${PUBLIC_IP}_ecc"
    local cert_file="${cert_dir}/fullchain.cer"
    local key_file="${cert_dir}/${PUBLIC_IP}.key"

    CERT_FILE="$cert_file"
    KEY_FILE="$key_file"

    # 检查端口 80 可用性
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ':80 '; then
            warn "端口 80 被占用，将尝试停止占用程序"
            local pid
            pid=$(ss -tlnp 2>/dev/null | grep ':80 ' | grep -oP 'pid=\K[0-9]+' || true)
            if [[ -n "$pid" ]]; then
                warn "占用端口 80 的进程 PID: ${pid}，将临时停止"
                kill "$pid" 2>/dev/null || true
                sleep 1
            fi
        fi
    fi

    if [[ -f "$cert_file" ]] && [[ -f "$key_file" ]]; then
        info "证书已存在，检查续期 ..."
        ${acme_sh} --cron -d "${PUBLIC_IP}" 2>/dev/null || true
    else
        info "申请 Let's Encrypt IP 证书 ..."
        info "这需要端口 80 对外可访问（acme.sh 会启动临时 HTTP 服务器进行验证）"
        ${acme_sh} --issue \
            --server letsencrypt \
            -d "${PUBLIC_IP}" \
            --certificate-profile shortlived \
            --standalone \
            --force || {
                error "证书申请失败，常见原因："
                error "1. 端口 80 被防火墙阻挡（云服务商安全组/iptables）"
                error "2. 公网 IP ${PUBLIC_IP} 并非本机公网 IP"
                error "3. 有程序占用了端口 80"
                error ""
                error "请检查后重试，或手动运行："
                error "  ~/.acme.sh/acme.sh --issue --server letsencrypt -d ${PUBLIC_IP} --certificate-profile shortlived --standalone"
                exit 1
            }
        info "证书申请成功！"
    fi

    # 设置续期后重载 Caddy
    ${acme_sh} --install-cert -d "${PUBLIC_IP}" \
        --reloadcmd "systemctl reload caddy 2>/dev/null || caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true"
}

install_caddy() {
    if command -v caddy &>/dev/null; then
        info "Caddy 已安装: $(caddy version)"
        return
    fi

    info "安装 Caddy ..."

    # 优先用包管理器安装
    local installed=0
    case "${OS_ID}" in
        ubuntu|debian)
            info "通过 apt 安装 Caddy ..."
            apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https 2>/dev/null || true
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

    # 包管理器安装失败时，回退到二进制安装
    if [[ "$installed" -ne 1 ]]; then
        info "通过二进制包安装 Caddy ..."
        local caddy_url="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_amd64.tar.gz"
        curl -fsSL "$caddy_url" -o /tmp/caddy.tar.gz
        tar xzf /tmp/caddy.tar.gz -C /tmp caddy 2>/dev/null || {
            # 如果 tar 在 Windows 上不行，尝试手动
            cd /tmp && gzip -dc caddy.tar.gz | tar xf - caddy
        }
        mv /tmp/caddy /usr/bin/caddy
        chmod +x /usr/bin/caddy

        # 创建 caddy 用户和数据目录
        if ! id -u caddy &>/dev/null; then
            useradd -r -d /var/lib/caddy -s /sbin/nologin caddy 2>/dev/null || true
        fi
        mkdir -p /var/lib/caddy /etc/caddy /var/log/caddy
        chown -R caddy:caddy /var/lib/caddy /var/log/caddy 2>/dev/null || true

        # 安装 systemd 单元
        if command -v systemctl &>/dev/null; then
            curl -fsSL https://raw.githubusercontent.com/caddyserver/dist/master/init/caddy.service \
                -o /etc/systemd/system/caddy.service 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    info "Caddy 安装完成: $(caddy version)"
}

configure_caddy() {
    local caddyfile="/etc/caddy/Caddyfile"
    info "生成 Caddy 配置: ${caddyfile}"

    mkdir -p /etc/caddy

    cat > "$caddyfile" <<CADDYEOF
# Caddy + IP SSL 配置 - 由 setup.sh 自动生成
# 后端服务: ${BACKEND_HOST}:${BACKEND_PORT}
# 公网 IP: ${PUBLIC_IP}

{
    # 关闭 admin API
    admin off
}

# HTTPS - 使用 IP 证书
:443 {
    tls ${CERT_FILE} ${KEY_FILE}

    reverse_proxy ${BACKEND_HOST}:${BACKEND_PORT} {
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
CADDYEOF

    info "Caddy 配置已生成"
}

setup_cron_renew() {
    info "配置证书自动续期 ..."

    local acme_sh="${HOME}/.acme.sh/acme.sh"

    # acme.sh 已有自己的 crontab，确保它存在
    if ! (crontab -l 2>/dev/null | grep -q 'acme.sh'); then
        info "添加 acme.sh 续期 crontab ..."
        (crontab -l 2>/dev/null || true; echo "0 3 * * * ${acme_sh} --cron > /dev/null 2>&1") | crontab -
    fi

    info "自动续期已配置（每日检查，仅在证书即将过期时续期）"
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
        # 直接启动
        caddy stop --config /etc/caddy/Caddyfile 2>/dev/null || true
        sleep 1
        nohup caddy run --config /etc/caddy/Caddyfile --adapter caddyfile > /var/log/caddy/caddy.log 2>&1 &
        info "Caddy 已后台启动 (PID: $!)"
    fi

    # 验证
    sleep 2
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://${PUBLIC_IP}" --insecure --max-time 5 2>/dev/null || echo "000")

    if [[ "$http_code" != "000" ]]; then
        info "Caddy 启动成功，HTTPS 响应码: ${http_code}"
    else
        warn "Caddy 已启动但 HTTPS 暂时无响应，请稍后检查: curl -k https://${PUBLIC_IP}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Caddy + IP SSL 部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "  访问地址:  https://${PUBLIC_IP}"
    echo "  后端服务:  ${BACKEND_HOST}:${BACKEND_PORT}"
    echo ""
    echo "  Caddy 配置:   /etc/caddy/Caddyfile"
    echo "  SSL 证书:     ${CERT_FILE}"
    echo "  SSL 私钥:     ${KEY_FILE}"
    echo "  访问日志:     /var/log/caddy/access.log"
    echo ""
    echo "  证书续期: 每日自动检查（short-lived, ~6.5 天有效）"
    echo ""
    echo -e "${YELLOW}  重要提示：${NC}"
    echo "  1. 请确保云服务商安全组已放行端口 443"
    echo "  2. 端口 80 需放行（acme.sh 续期验证用）"
    echo "  3. 如果后端服务地址变了，编辑 /etc/caddy/Caddyfile 后执行:"
    echo "     systemctl reload caddy"
    echo ""
    echo -e "${GREEN}  一键测试: curl -k https://${PUBLIC_IP}${NC}"
    echo ""
}

# ============================================
# Main
# ============================================

main() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Caddy + IP SSL 一键部署脚本${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    check_root
    install_deps
    detect_ip
    install_acme
    issue_cert
    install_caddy
    configure_caddy
    setup_cron_renew
    start_caddy
    print_summary
}

main "$@"
