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

# ---- 清理函数（Ctrl+C 时停止临时 Caddy）----
cleanup() {
    stop_temp_caddy 2>/dev/null || true
}
trap cleanup EXIT INT TERM

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
    local pkgs="curl openssl"
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
                warn "未知系统，请手动安装: curl, openssl"
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
        local arch caddy_url
        arch=$(uname -m)
        case "$arch" in
            x86_64)  caddy_url="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_amd64.tar.gz" ;;
            aarch64) caddy_url="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_arm64.tar.gz" ;;
            armv7l)  caddy_url="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_armv7.tar.gz" ;;
            *)       error "不支持的架构: $arch，请手动安装 Caddy" ; exit 1 ;;
        esac
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
                error "1. Let's Encrypt 频率限制（同一 IP 7 天内最多 5 次）"
                error "2. 端口 80 被防火墙阻挡（安全组/iptables 需放行）"
                error "3. 公网 IP ${PUBLIC_IP} 并非本机公网 IP"
                error "4. /var/www/html 目录不可写"
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
    mkdir -p /var/www/html
    write_nav_html "/var/www/html/index.html" "$base_url" "${SERVICES_LIST[@]}"
}

# ---- 生成 Caddy 配置（mode: ip|domain）----
configure_caddy() {
    local mode="${1}"
    local caddyfile="/etc/caddy/Caddyfile"
    info "生成 Caddy 配置（${mode} 模式）: ${caddyfile}"
    mkdir -p /etc/caddy

    local site_addr tls_line section_title mode_label
    if [[ "$mode" == "ip" ]]; then
        site_addr="${PUBLIC_IP}:443"
        tls_line="    tls ${CERT_FILE} ${KEY_FILE}"
        section_title="IP 证书反代"
        mode_label="IP"
    else
        site_addr="${DOMAIN}"
        tls_line=""
        section_title="域名反代（Caddy 自动签发证书）"
        mode_label="域名"
    fi

    cat > "$caddyfile" <<CADDYEOF
# Caddy + SSL ${mode_label}模式 - 由 setup.sh 自动生成
CADDYEOF
    if [[ "$mode" == "ip" ]]; then
        echo "# 公网 IP: ${PUBLIC_IP}" >> "$caddyfile"
    else
        echo "# 域名: ${DOMAIN}" >> "$caddyfile"
    fi

    cat >> "$caddyfile" <<CADDYEOF

# -------- 端口 80: ACME 验证 --------
:80 {
    @acme path /.well-known/acme-challenge/*
    handle @acme {
        root * /var/www/html
        file_server
    }
    handle {
        root * /var/www/html
        file_server
    }
}

# -------- ${section_title} --------
${site_addr} {
CADDYEOF

    if [[ "$mode" == "ip" ]]; then
        echo "${tls_line}" >> "$caddyfile"
    fi

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

    # 只在有自定义路由文件时才加 import（空 glob 会导致 Caddy 报错）
    mkdir -p /etc/caddy/routes-custom.d
    if ls /etc/caddy/routes-custom.d/*.conf &>/dev/null 2>&1; then
        echo "    import /etc/caddy/routes-custom.d/*.conf" >> "$caddyfile"
    fi
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
        (crontab -l 2>/dev/null || true; echo "0 3 * * * ${acme_sh} --cron -d ${PUBLIC_IP} >> /var/log/caddy/acme-renew.log 2>&1") | crontab -
        info "已添加续期 crontab（每日 3:00 检查 IP 证书）"
    else
        info "续期 crontab 已存在"
    fi
}

# ---- 启动 Caddy ----
start_caddy() {
    local verify_url="${1:-}"
    info "启动 Caddy 服务 ..."

    # 确保日志目录权限正确（Caddy systemd 以 caddy 用户运行）
    mkdir -p /var/log/caddy
    if id -u caddy &>/dev/null; then
        chown caddy:caddy /var/log/caddy 2>/dev/null || true
    fi

    if command -v systemctl &>/dev/null && systemctl cat caddy.service &>/dev/null; then
        # 先杀手动运行的 Caddy（如果有），避免端口冲突
        pkill -x caddy 2>/dev/null || true
        sleep 1
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
print_summary() {
    local mode="${1}"
    local entry_url ssl_line extra_tip test_url
    if [[ "$mode" == "ip" ]]; then
        entry_url="https://${PUBLIC_IP}"
        ssl_line="  SSL 证书:     ${CERT_FILE}"
        extra_tip=""
        test_url="curl -k https://${PUBLIC_IP}/couchdb/"
    else
        entry_url="https://${DOMAIN}"
        ssl_line="  SSL 证书:     Caddy 自动管理（Let's Encrypt）"
        extra_tip="  2. 确保域名 ${DOMAIN} 的 DNS A 记录指向本机 IP"
        test_url="curl -k https://${DOMAIN}/couchdb/"
    fi

    local mode_label
    if [[ "$mode" == "ip" ]]; then
        mode_label="IP"
    else
        mode_label="域名"
    fi
    echo ""
    echo "========================================"
    echo "  ${mode_label}证书模式部署完成！"
    echo "========================================"
    echo ""
    echo "  入口地址:  ${entry_url}"
    echo ""
    echo "  可用服务:"
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path h port _ <<< "$svc"
        [[ -z "$h" ]] && h="127.0.0.1"
        echo "    ${entry_url}${path}  →  ${h}:${port}"
    done
    echo ""
    echo "  Caddy 配置:   /etc/caddy/Caddyfile"
    echo "${ssl_line}"
    echo "  访问日志:     /var/log/caddy/access.log"
    echo "  导航页面:     /var/www/html/index.html"
    echo ""
    echo "  重要提示："
    echo "  1. 云服务商安全组需放行端口 443 (HTTPS) 和 80 (HTTP)"
    [[ -n "$extra_tip" ]] && echo "${extra_tip}"
    echo ""
    echo "  一键测试: ${test_url}"
    echo ""
}

# ============================================================
# 模式 3: 添加服务（自动匹配当前配置模式）
# ============================================================
mode_paired() {
    check_root

    local caddyfile="/etc/caddy/Caddyfile"
    if [[ ! -f "$caddyfile" ]]; then
        error "未找到 Caddyfile，请先运行模式 1 或模式 2"
        exit 1
    fi

    # 检测当前配置模式（兼容新旧格式）
    local mode_type=""
    if grep -qiE "ip\s*模式" "$caddyfile" 2>/dev/null; then
        mode_type="ip"
        PUBLIC_IP=$(grep -oP '公网 IP:\s*\K[\d.]+' "$caddyfile" 2>/dev/null || true)
        if [[ -z "${PUBLIC_IP:-}" ]]; then
            error "无法从 Caddyfile 提取公网 IP，请重新运行模式 1"
            exit 1
        fi
    elif grep -q "域名模式" "$caddyfile" 2>/dev/null; then
        mode_type="domain"
    else
        error "无法识别 Caddyfile 模式，请重新运行模式 1 或模式 2"
        exit 1
    fi

    if [[ "$mode_type" == "ip" ]]; then
        add_custom_routes
    else
        add_custom_subdomains
    fi
}

# ---- IP 模式：添加子路径 ----
add_custom_routes() {
    local custom_dir="/etc/caddy/routes-custom.d"
    mkdir -p "$custom_dir"

    # 确保 Caddyfile 有 import 行，没有则自动添加
    if ! grep -q "routes-custom.d" /etc/caddy/Caddyfile 2>/dev/null; then
        info "Caddyfile 缺少自定义路由引用，自动添加..."
        sed -i '/^    handle \/ {/i\    import /etc/caddy/routes-custom.d/*.conf' /etc/caddy/Caddyfile
    fi

    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  当前模式: IP — 添加/删除子路径${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    local changed=false
    while true; do
        echo ""
        echo "  可用服务:"

        # 构建编号列表
        local -a list_items=()
        local -a delete_names=()
        local -a base_services=()
        if [[ -f /etc/caddy/.services.conf ]]; then
            mapfile -t base_services < /etc/caddy/.services.conf
        else
            base_services=("${DEFAULT_SERVICES[@]}")
        fi

        # 预配置服务（不可删除）
        for svc in "${base_services[@]}"; do
            IFS='|' read -r p h port _ <<< "$svc"
            [[ -z "$h" ]] && h="127.0.0.1"
            local _name="${p//\//}"
            [[ -z "$_name" ]] && continue
            list_items+=("${p} → ${h}:${port}")
            delete_names+=("")
        done

        # 自定义服务（可删除）
        for f in "$custom_dir"/*.conf; do
            [[ -f "$f" ]] || continue
            local n; n=$(basename "$f" .conf)
            local p; p=$(grep -oP ':\K\d+' "$f" 2>/dev/null | head -1 || echo "?")
            [[ -n "$p" ]] || continue
            list_items+=("/${n}/ → 127.0.0.1:${p} [自定义]")
            delete_names+=("$n")
        done

        # 打印编号列表
        for i in "${!list_items[@]}"; do
            printf "  %2d. %s\n" $((i+1)) "${list_items[$i]}"
        done

        echo ""
        echo -n "  输入序号删除服务，回车添加新服务，0 返回菜单: "
        read -r input </dev/tty 2>/dev/null || true

        # 回车 → 添加流程
        if [[ -z "$input" ]]; then
            echo -n "  服务名称（如: myapp）: "
            read -r SVC_NAME </dev/tty 2>/dev/null || true
            [[ -z "$SVC_NAME" ]] && continue
            SVC_NAME="$(printf '%s' "$SVC_NAME" | LC_ALL=C tr -cd 'a-zA-Z0-9_-')"
            [[ -z "$SVC_NAME" ]] && { error "服务名称不能为空"; continue; }

            echo -n "  后端端口（如: 3000）: "
            read -r SVC_PORT </dev/tty 2>/dev/null || true
            SVC_PORT="$(printf '%s' "$SVC_PORT" | LC_ALL=C tr -cd '0-9')"
            [[ -z "$SVC_PORT" ]] && { error "端口不能为空"; continue; }

            # 查重
            if [[ -f "${custom_dir}/${SVC_NAME}.conf" ]]; then
                warn "服务 /${SVC_NAME}/ 已存在，跳过"
                continue
            fi

            cat > "${custom_dir}/${SVC_NAME}.conf" <<ROUTE
    redir /${SVC_NAME} /${SVC_NAME}/ 308
    handle_path /${SVC_NAME}/* {
        reverse_proxy 127.0.0.1:${SVC_PORT} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-For {remote_host}
        }
    }
ROUTE
            info "已添加: https://${PUBLIC_IP}/${SVC_NAME}/ → :${SVC_PORT}"
            rebuild_nav_ip
            reload_caddy
            continue
        fi

        # 0 → 返回
        [[ "$input" == "0" ]] && break

        # 数字 → 删除
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            local idx=$((10#$input - 1))
            if [[ $idx -lt 0 || $idx -ge ${#delete_names[@]} ]]; then
                error "无效序号"
                continue
            fi
            if [[ -z "${delete_names[$idx]}" ]]; then
                error "默认服务不能删除"
                continue
            fi
            local del_name="${delete_names[$idx]}"
            rm "${custom_dir}/${del_name}.conf"
            info "已删除: /${del_name}/"
            rebuild_nav_ip
            reload_caddy
            continue
        fi

        error "输入无效，请输入序号、回车或 0"
    done

    [[ "$changed" == "true" ]] && { rebuild_nav_ip; reload_caddy; }
}

rebuild_nav_ip() {
    local custom_dir="/etc/caddy/routes-custom.d"
    local base_url="https://${PUBLIC_IP}"
    local html="/var/www/html/index.html"
    mkdir -p /var/www/html

    local -a all_services=()
    if [[ -f /etc/caddy/.services.conf ]]; then
        mapfile -t all_services < /etc/caddy/.services.conf
    else
        all_services=("${DEFAULT_SERVICES[@]}")
    fi
    local name port
    for f in "$custom_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .conf)
        port=$(grep -oP ':\K\d+' "$f" 2>/dev/null | head -1 || true)
        [[ -n "$port" ]] && all_services+=("/${name}/|127.0.0.1|${port}|")
    done

    write_nav_html "$html" "$base_url" "${all_services[@]}"
    info "导航页已更新"
}

# ---- 域名模式：添加子域名 ----
add_custom_subdomains() {
    local sub_dir="/etc/caddy/subdomains.d"
    local caddyfile="/etc/caddy/Caddyfile"
    mkdir -p "$sub_dir"

    # 从 Caddyfile 提取域名
    local domain=""
    domain=$(grep -oP '^[a-zA-Z0-9.-]+\s*\{' "$caddyfile" 2>/dev/null | head -1 | awk '{print $1}' | tr -d '{')
    if [[ -z "$domain" ]]; then
        # 尝试从注释提取
        domain=$(grep "域名:" "$caddyfile" 2>/dev/null | head -1 | grep -oP '[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')
    fi
    if [[ -z "$domain" ]]; then
        error "无法从 Caddyfile 提取域名"
        exit 1
    fi
    DOMAIN="$domain"

    # 确保 Caddyfile 有 import 子域名目录（插入到 handle / 之前）
    if ! grep -q "subdomains.d" "$caddyfile" 2>/dev/null; then
        info "Caddyfile 缺少子域名引用，自动添加..."
        sed -i '/^    handle \/ {/i\    import /etc/caddy/subdomains.d/*.conf' "$caddyfile"
    fi

    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  当前模式: 域名 — 添加/删除子域名${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    local changed=false
    while true; do
        echo ""
        echo "  可用服务:"

        # 构建编号列表
        local -a list_items=()
        local -a delete_names=()
        local -a base_services=()
        if [[ -f /etc/caddy/.services.conf ]]; then
            mapfile -t base_services < /etc/caddy/.services.conf
        else
            for svc in "${DEFAULT_SERVICES[@]}"; do
                base_services+=("$svc")
            done
        fi

        # 预配置服务（不可删除）
        for svc in "${base_services[@]}"; do
            IFS='|' read -r p h port _ <<< "$svc"
            [[ -z "$h" ]] && h="127.0.0.1"
            local _name="${p//\//}"
            [[ -z "$_name" ]] && continue
            list_items+=("https://${DOMAIN}${p} → ${h}:${port}")
            delete_names+=("")
        done

        # 自定义子域名（可删除）
        for f in "$sub_dir"/*.conf; do
            [[ -f "$f" ]] || continue
            local n; n=$(basename "$f" .conf)
            local p; p=$(grep -oP ':\K\d+' "$f" 2>/dev/null | head -1 || echo "?")
            [[ -n "$p" ]] || continue
            list_items+=("${n}.${DOMAIN} → :${p} [自定义]")
            delete_names+=("$n")
        done

        # 打印编号列表
        for i in "${!list_items[@]}"; do
            printf "  %2d. %s\n" $((i+1)) "${list_items[$i]}"
        done

        echo ""
        echo -n "  输入序号删除服务，回车添加新服务，0 返回菜单: "
        read -r input </dev/tty 2>/dev/null || true

        # 回车 → 添加流程
        if [[ -z "$input" ]]; then
            echo -n "  子域名前缀（如: st）: "
            read -r SUB_PREFIX </dev/tty 2>/dev/null || true
            [[ -z "$SUB_PREFIX" ]] && continue
            SUB_PREFIX="$(printf '%s' "$SUB_PREFIX" | LC_ALL=C tr -cd 'a-zA-Z0-9-')"
            [[ -z "$SUB_PREFIX" ]] && { error "子域名前缀不能为空"; continue; }

            echo -n "  后端端口（如: 8000）: "
            read -r SUB_PORT </dev/tty 2>/dev/null || true
            SUB_PORT="$(printf '%s' "$SUB_PORT" | LC_ALL=C tr -cd '0-9')"
            [[ -z "$SUB_PORT" ]] && { error "端口不能为空"; continue; }

            local sub_domain="${SUB_PREFIX}.${DOMAIN}"

            # 查重
            if [[ -f "${sub_dir}/${SUB_PREFIX}.conf" ]]; then
                warn "子域名 ${sub_domain} 已存在，跳过"
                continue
            fi

            cat > "${sub_dir}/${SUB_PREFIX}.conf" <<ROUTE
${sub_domain} {
    reverse_proxy 127.0.0.1:${SUB_PORT} {
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
            info "已添加: https://${sub_domain}/ → :${SUB_PORT}"
            rebuild_nav_domain "$domain"
            reload_caddy
            continue
        fi

        # 0 → 返回
        [[ "$input" == "0" ]] && break

        # 数字 → 删除
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            local idx=$((10#$input - 1))
            if [[ $idx -lt 0 || $idx -ge ${#delete_names[@]} ]]; then
                error "无效序号"
                continue
            fi
            if [[ -z "${delete_names[$idx]}" ]]; then
                error "默认服务不能删除"
                continue
            fi
            local del_name="${delete_names[$idx]}"
            rm "${sub_dir}/${del_name}.conf"
            info "已删除: ${del_name}.${DOMAIN}"
            rebuild_nav_domain "$domain"
            reload_caddy
            continue
        fi

        error "输入无效，请输入序号、回车或 0"
    done

    [[ "$changed" == "true" ]] && { rebuild_nav_domain "$domain"; reload_caddy; }

}

rebuild_nav_domain() {
    local domain="${1}"
    local sub_dir="/etc/caddy/subdomains.d"
    local base_url="https://${domain}"
    local html="/var/www/html/index.html"
    mkdir -p /var/www/html

    # 已配置服务（域名路径）+ 子域名
    local -a all_services=()
    local name port

    if [[ -f /etc/caddy/.services.conf ]]; then
        mapfile -t all_services < /etc/caddy/.services.conf
    else
        for svc in "${DEFAULT_SERVICES[@]}"; do
            all_services+=("$svc")
        done
    fi

    for f in "$sub_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .conf)
        port=$(grep -oP ':\K\d+' "$f" 2>/dev/null | head -1 || true)
        [[ -n "$port" ]] && all_services+=("/${name}/|127.0.0.1|${port}|subdomain")
    done

    local cards=""
    for svc in "${all_services[@]}"; do
        IFS='|' read -r p h port stype <<< "$svc"
        name="${p//\//}"
        [[ -z "$name" ]] && continue

        local note=""
        local url=""
        if [[ "$stype" == "subdomain" ]]; then
            # 子域名入口
            url="https://${name}.${domain}/"
            note=" <span style=\"color:#22d3ee;font-size:0.7rem;\">[子域名]</span>"
        else
            url="${base_url}${p}"
            if [[ "$port" == "8000" ]]; then
                name="SillyTavern"
                note=" <span style=\"color:#f87171;font-size:0.75rem;\">（通过本方式使用酒馆会CSS错乱）</span>"
            fi
        fi

        cards+="        <div class=\"card\">
          <div class=\"card-title\">${name}${note}</div>
          <div class=\"card-links\"><a href=\"${url}\" class=\"link\">${url}</a></div>
        </div>
"
    done

    write_nav_html "$html" "$base_url" "$cards" --raw
    info "导航页已更新"
}

write_nav_html() {
    local file="$1"
    local base="$2"
    shift 2
    local cards_content=""
    local raw_mode=false
    # 检测 --raw: 最后一个参数是 --raw 表示 $@ 是预制 HTML
    if [[ $# -gt 0 && "${!#}" == "--raw" ]]; then
        raw_mode=true
        set -- "${@:1:$(($#-1))}"
    fi

    if [[ "$raw_mode" == "true" ]]; then
        cards_content="$*"
    else
        local all_services=("$@")
        for svc in "${all_services[@]}"; do
            IFS='|' read -r p h port _ <<< "$svc"
            local name="${p//\//}"
            [[ -z "$name" ]] && continue
            local note=""
            if [[ "$port" == "8000" ]]; then
                name="SillyTavern"
                note=" <span style=\"color:#f87171;font-size:0.75rem;\">（通过本方式使用酒馆会CSS错乱）</span>"
            fi
            cards_content+="        <div class=\"card\">
          <div class=\"card-title\">${name}${note}</div>
          <div class=\"card-links\"><a href=\"${base}${p}\" class=\"link\">${base}${p}</a></div>
        </div>
"
        done
    fi

    cat > "$file" <<HTML
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
  <div class="cards">${cards_content}</div>
  <div class="footer">SSL 加密 &middot; 证书自动续期</div>
</div>
</body>
</html>
HTML
}

reload_caddy() {
    info "重载 Caddy..."
    local ok=true
    # 确保日志目录权限正确
    mkdir -p /var/log/caddy
    if id -u caddy &>/dev/null; then
        chown caddy:caddy /var/log/caddy 2>/dev/null || true
    fi

    if command -v systemctl &>/dev/null && systemctl is-active caddy &>/dev/null; then
        systemctl reload caddy 2>&1 || systemctl restart caddy 2>&1 || ok=false
    else
        if caddy reload --config /etc/caddy/Caddyfile 2>&1; then
            :
        else
            warn "caddy reload 失败，强制重启 Caddy..."
            pkill -x caddy 2>/dev/null || true
            sleep 1
            if command -v systemctl &>/dev/null && systemctl cat caddy.service &>/dev/null 2>&1; then
                systemctl start caddy 2>&1 || ok=false
            else
                nohup caddy run --config /etc/caddy/Caddyfile --adapter caddyfile > /var/log/caddy/caddy.log 2>&1 &
                sleep 2
            fi
        fi
    fi
    $ok && info "完成！" || error "Caddy 启动失败，请手动检查"
}

# ============================================================
# 模式 1: IP 证书
# ============================================================
mode_ip() {
    check_root
    parse_services
    printf '%s\n' "${SERVICES_LIST[@]}" > /etc/caddy/.services.conf
    detect_os
    install_deps
    detect_ip
    prompt_ip
    install_acme
    install_caddy

    # 检查已有证书是否有效（短命证书通常 7 天，用 2 天阈值）
    local acme_dir="${HOME}/.acme.sh/${PUBLIC_IP}_ecc"
    local cert_f="${acme_dir}/fullchain.cer"
    local key_f="${acme_dir}/${PUBLIC_IP}.key"
    if [[ -f "$cert_f" ]] && [[ -f "$key_f" ]] && openssl x509 -checkend $((2*86400)) -noout -in "$cert_f" 2>/dev/null; then
        info "有效证书已存在，跳过证书申请"
        CERT_FILE="$cert_f"
        KEY_FILE="$key_f"
    else
        if [[ -f "$cert_f" ]]; then
            warn "证书即将过期或已过期，重新申请..."
        fi
        start_temp_caddy
        issue_ip_cert
        stop_temp_caddy
    fi

    gen_root_html "https://${PUBLIC_IP}"
    configure_caddy "ip"
    setup_cron_renew_ip
    start_caddy "https://${PUBLIC_IP}"
    print_summary "ip"
}

# ============================================================
# 模式 2: 域名证书
# ============================================================
mode_domain() {
    check_root
    parse_services
    printf '%s\n' "${SERVICES_LIST[@]}" > /etc/caddy/.services.conf
    detect_os
    install_deps
    prompt_domain
    install_caddy

    gen_root_html "https://${DOMAIN}"
    configure_caddy "domain"
    start_caddy "https://${DOMAIN}"
    print_summary "domain"
}

# ============================================================
# 菜单
# ============================================================
show_menu() {
    echo ""
    echo "========================================"
    echo -e "${YELLOW}  Caddy + SSL 多服务反向代理${NC}"
    echo "========================================"
    echo ""
    echo "  请选择需要的功能:"
    echo ""
    echo "  1  拉取IP证书  [二选一]"
    echo "  2  拉取域名证书  [二选一]"
    echo "  3  添加服务（自动匹配当前配置）"
    echo "  0  退出"
    echo ""
    echo "----------------------------------------"
    echo -n "  请输入 [1/2/3/0]: "
}

# ============================================================
# Main
# ============================================================
main() {
    while true; do
        show_menu
        read -r CHOICE </dev/tty 2>/dev/null || true
        echo ""

        case "$CHOICE" in
            1) mode_ip ;;
            2) mode_domain ;;
            3) mode_paired ;;
            q|Q|0) info "已退出" ; exit 0 ;;
            *) error "无效选项，请输入 1、2、3 或 0" ;;
        esac
    done
}

main "$@"
