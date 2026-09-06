#!/usr/bin/env bash
set -euo pipefail 2>/dev/null || set -eu

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
TEMP_CADDY_OWNED=0
TEMP_CADDY_PID=""
TEMP_CADDY_ADMIN_ADDR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORTED_OS=false
OS_ID="unknown"
OS_VERSION=""
OS_CODENAME=""
APT_MANAGED_LIST="/etc/apt/sources.list.d/ip-ssl-proxy.sources.list"
IP_CERT_STATE_FILE="/etc/caddy/.ip-cert"
DOMAIN_CERT_STATE_FILE="/etc/caddy/.domain-certs"
CLOUDFLARE_DOMAIN_STATE_FILE="/etc/caddy/.cloudflare-domains"
ROUTES_STATE_FILE="/etc/caddy/.routes.conf"
ROUTE_DISABLED_STATE_FILE="/etc/caddy/.route-disabled.conf"
ROUTES_MIGRATION_STATE_FILE="/etc/caddy/.routes-migrated"

BASIC_DEP_COMMANDS=(
    "curl:curl"
    "openssl:openssl"
    "gpg:gnupg"
    "ss:iproute2"
    "fuser:psmisc"
    "tar:tar"
    "unzip:unzip"
    "jq:jq"
    "git:git"
    "crontab:cron"
)

BASIC_DEP_PACKAGES=(
    curl
    openssl
    ca-certificates
    gnupg
    iproute2
    psmisc
    tar
    unzip
    jq
    git
    cron
)

APT_OPTS=(
    -o Acquire::http::Timeout=10
    -o Acquire::https::Timeout=10
    -o Acquire::Retries=1
)

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
TITLE_YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# CPA 模块只定义函数，不在加载时安装、启动或修改系统。
if [[ -f "${SCRIPT_DIR}/modules/cpa.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/modules/cpa.sh"
fi

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

on_error() {
    local exit_code=$?
    local line_no="${1:-未知}"
    local command="${2:-未知命令}"
    error "脚本异常退出：第 ${line_no} 行，退出码 ${exit_code}"
    error "失败命令：${command}"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

print_root_title() {
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo -e "${GREEN}    云 服 务 器 傻 瓜 助 手${NC}"
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}============================================================${NC}"
}

print_section_title() {
    local title="$1"
    echo ""
    echo -e "${TITLE_YELLOW}========================================${NC}"
    echo -e "${TITLE_YELLOW}  ${title}${NC}"
    echo -e "${TITLE_YELLOW}========================================${NC}"
}

print_subsection_title() {
    local title="$1"
    echo ""
    echo -e "${CYAN}  ── ${title} ──${NC}"
}

print_child_page_title() {
    local title="$1"
    echo ""
    echo -e "${CYAN}  --------------------------------------${NC}"
    echo -e "${CYAN}  ${title}${NC}"
    echo -e "${CYAN}  --------------------------------------${NC}"
}

print_route_help() {
    echo ""
    echo "  说明:"
    echo "  1. 独立域名：使用一个完整域名访问指定端口的服务。"
    echo "     例：st.example.com 访问 127.0.0.1:8000。"
    echo ""
    echo "  2. 子路径：多个服务共用一个域名，通过 /服务名称/ 区分。"
    echo "     添加时只需填写端口和服务名称，访问路径会自动使用服务名称。"
    echo "     例：example.com/reader/ 访问阅读。"
    echo "     例：example.com/mihomo/ 访问 Mihomo 管理面板。"
    echo ""
    echo "  3. 生成 Caddy 配置 / 网站首页："
    echo "     落实独立域名、子路径等访问地址，并更新网站首页内容，便于快速访问不同服务。"
    echo "     网站首页可通过服务器 IP 或未被独立域名占用的域名根目录访问，例如 https://example.com/。"
    echo "     修改域名、端口或路由关系后，请务必执行下方功能 6 完成收尾。"
}

# ---- 清理函数（Ctrl+C 时停止临时 Caddy）----
cleanup() {
    if [[ "${TEMP_CADDY_OWNED:-0}" == "1" ]]; then
        stop_temp_caddy 2>/dev/null || true
    fi
    restore_caddy_after_challenge 2>/dev/null || true
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

load_saved_or_default_services() {
    if [[ -f /etc/caddy/.services.conf ]]; then
        mapfile -t SERVICES_LIST < /etc/caddy/.services.conf
    else
        SERVICES_LIST=("${DEFAULT_SERVICES[@]}")
        mkdir -p /etc/caddy
        printf '%s\n' "${SERVICES_LIST[@]}" > /etc/caddy/.services.conf
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限，请使用 sudo 或以 root 身份运行"
        exit 1
    fi
}

prompt_domain() {
    local input_domain
    echo ""
    if [[ -n "${DOMAIN:-}" ]]; then
        echo -n "  域名 [${DOMAIN}]: "
    else
        echo -n "  域名: "
    fi
    read -r input_domain </dev/tty 2>/dev/null || true
    input_domain="$(printf '%s' "$input_domain" | LC_ALL=C tr -cd 'a-zA-Z0-9.-')"
    if [[ -n "$input_domain" ]]; then
        DOMAIN="$input_domain"
    fi
    echo ""

    if [[ -z "$DOMAIN" ]]; then
        error "域名不能为空"
        exit 1
    fi
    info "域名: ${DOMAIN}"
}

detect_ip() {
    local quiet="${1:-}"
    PUBLIC_IP="${PUBLIC_IP:-}"
    if [[ -z "$PUBLIC_IP" ]]; then
        [[ "$quiet" == "--quiet" ]] || info "检测公网 IP ..."
        PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org || curl -s --max-time 10 https://icanhazip.com)
        if [[ -z "$PUBLIC_IP" ]]; then
            error "无法检测公网 IP，请手动设置 PUBLIC_IP 环境变量"
            exit 1
        fi
    fi
    [[ "$quiet" == "--quiet" ]] || info "公网 IP: ${PUBLIC_IP}"
}

prompt_ip() {
    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  如果启用了网络代理功能，检测结果可能为代理出口 IP，以实际为准${NC}"
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
    local quiet="${1:-}"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID:-}"
        OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    else
        OS_ID="unknown"
        OS_VERSION=""
        OS_CODENAME=""
    fi
    if [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" ]]; then
        SUPPORTED_OS=true
    else
        SUPPORTED_OS=false
    fi
    if [[ "$quiet" != "--quiet" ]]; then
        info "系统: ${OS_ID} ${OS_VERSION}${OS_CODENAME:+ (${OS_CODENAME})}"
    fi
}

require_supported_os() {
    local quiet="${1:-}"
    detect_os "$quiet"
    if [[ "$SUPPORTED_OS" != "true" ]]; then
        error "当前系统暂未适配: ${OS_ID} ${OS_VERSION}"
        error "当前脚本第一版仅支持 Debian / Ubuntu"
        exit 1
    fi
}

collect_missing_basic_deps() {
    MISSING_BASIC_DEPS=()
    local item cmd pkg
    for item in "${BASIC_DEP_COMMANDS[@]}"; do
        IFS=':' read -r cmd pkg <<< "$item"
        command -v "$cmd" &>/dev/null || MISSING_BASIC_DEPS+=("$pkg")
    done
}

current_apt_source_url() {
    local url=""
    url="$(grep -RhoE 'https?://[^[:space:]]+' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | head -1 || true)"
    printf '%s' "$url"
}

apt_mirror_candidates() {
    local current
    current="$(current_apt_source_url)"
    [[ -n "$current" ]] && printf 'current|%s\n' "$current"

    if [[ "$OS_ID" == "debian" ]]; then
        printf '%s\n' \
            "official|https://deb.debian.org/debian" \
            "tencent|https://mirrors.tencent.com/debian" \
            "aliyun|https://mirrors.aliyun.com/debian" \
            "huawei|https://repo.huaweicloud.com/debian"
    else
        printf '%s\n' \
            "official|https://archive.ubuntu.com/ubuntu" \
            "tencent|https://mirrors.tencent.com/ubuntu" \
            "aliyun|https://mirrors.aliyun.com/ubuntu" \
            "huawei|https://repo.huaweicloud.com/ubuntu"
    fi
}

mirror_release_url() {
    local base="$1"
    printf '%s/dists/%s/Release' "${base%/}" "$OS_CODENAME"
}

measure_mirror() {
    local name="$1" base="$2" url elapsed
    url="$(mirror_release_url "$base")"
    elapsed="$(curl -L -o /dev/null -s -w '%{http_code} %{time_total}' --max-time 5 "$url" 2>/dev/null || true)"
    local code="${elapsed%% *}"
    local seconds="${elapsed#* }"
    if [[ "$code" == "200" ]]; then
        printf '%s|%s|%s\n' "$seconds" "$name" "$base"
        printf '  %-8s %ss\n' "$name" "$seconds" >&2
    else
        printf '  %-8s 访问失败\n' "$name" >&2
    fi
}

backup_apt_sources() {
    local backup_dir="/etc/apt/ip-ssl-proxy-backup"
    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"
    cp -a /etc/apt/sources.list "$backup_dir/" 2>/dev/null || true
    if [[ -d /etc/apt/sources.list.d ]]; then
        mkdir -p "$backup_dir/sources.list.d"
        cp -a /etc/apt/sources.list.d/. "$backup_dir/sources.list.d/" 2>/dev/null || true
    fi
    info "已备份 apt 源到: ${backup_dir}"
}

write_apt_mirror() {
    local name="$1" base="$2"
    backup_apt_sources
    mkdir -p /etc/apt/sources.list.d

    if [[ -f /etc/apt/sources.list ]]; then
        mv /etc/apt/sources.list /etc/apt/sources.list.ip-ssl-proxy.disabled 2>/dev/null || true
    fi
    local f
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$APT_MANAGED_LIST" ]] && continue
        [[ "$f" == *.ip-ssl-proxy.disabled ]] && continue
        mv "$f" "${f}.ip-ssl-proxy.disabled" 2>/dev/null || true
    done

    if [[ "$OS_ID" == "debian" ]]; then
        cat > "$APT_MANAGED_LIST" <<EOF
deb ${base} ${OS_CODENAME} main contrib non-free non-free-firmware
deb ${base} ${OS_CODENAME}-updates main contrib non-free non-free-firmware
deb ${base}-security ${OS_CODENAME}-security main contrib non-free non-free-firmware
EOF
    else
        cat > "$APT_MANAGED_LIST" <<EOF
deb ${base} ${OS_CODENAME} main restricted universe multiverse
deb ${base} ${OS_CODENAME}-updates main restricted universe multiverse
deb ${base} ${OS_CODENAME}-security main restricted universe multiverse
EOF
    fi

    info "已写入 apt 源: ${name} (${base})"
    warn "旧 apt 源已备份并禁用，如需恢复请查看 /etc/apt/ip-ssl-proxy-backup"
}

select_fastest_apt_mirror() {
    require_supported_os --quiet
    if [[ -z "$OS_CODENAME" ]]; then
        error "无法识别系统版本代号，不能自动匹配 apt 源"
        return 1
    fi

    info "开始测速 apt 下载源 ..."
    local results="" item name base result
    while IFS='|' read -r name base; do
        [[ -z "$name" || -z "$base" ]] && continue
        result="$(measure_mirror "$name" "$base")"
        [[ -n "$result" ]] && results+="${result}"$'\n'
    done < <(apt_mirror_candidates)

    if [[ -z "$results" ]]; then
        error "没有可用 apt 源"
        return 1
    fi

    printf '%s' "$results" | sort -t'|' -k1,1n | head -1
}

select_and_apply_fastest_apt_mirror() {
    local fastest seconds name base
    fastest="$(select_fastest_apt_mirror)" || return 1
    IFS='|' read -r seconds name base <<< "$fastest"
    info "最快 apt 源: ${name} (${seconds}s)"
    write_apt_mirror "$name" "$base"
    apt-get "${APT_OPTS[@]}" update -qq
}

run_apt_with_mirror_fallback() {
    local desc="$1"
    shift
    if "$@"; then
        return 0
    fi

    warn "${desc} 失败，开始自动测速并切换 apt 源"
    select_and_apply_fastest_apt_mirror || {
        error "自动换源失败，请检查网络、DNS 或系统时间"
        return 1
    }

    info "已切换 apt 源，重新执行: ${desc}"
    "$@"
}

safe_apt_update() {
    run_apt_with_mirror_fallback "apt 更新索引" apt-get "${APT_OPTS[@]}" update -qq
}

safe_apt_install() {
    run_apt_with_mirror_fallback "apt 安装依赖" apt-get "${APT_OPTS[@]}" install -y -qq "$@"
}

safe_apt_upgrade() {
    run_apt_with_mirror_fallback "apt 更新全部依赖" apt-get "${APT_OPTS[@]}" upgrade -y
}

check_github_network_light() {
    local result code seconds
    result="$(curl -L -I -o /dev/null -s -w '%{http_code} %{time_total}' --max-time 3 https://github.com 2>/dev/null || true)"
    code="${result%% *}"
    seconds="${result#* }"

    if [[ "$code" =~ ^(200|301|302)$ ]]; then
        info "GitHub 访问正常: ${seconds}s"
    elif [[ "$code" != "000" && "$code" =~ ^[0-9]{3}$ ]]; then
        warn "GitHub 可访问但返回异常状态: HTTP ${code}, ${seconds}s"
    else
        warn "当前网络访问 GitHub 可能有明显问题"
        warn "建议配置 mihomo 代理后再进行 GitHub 下载/更新"
    fi
}

runtime_preflight() {
    echo ""
    echo "----------------------------------------"
    echo "  启动检测"
    echo "----------------------------------------"

    detect_os
    if [[ "$SUPPORTED_OS" != "true" ]]; then
        error "当前系统暂未适配: ${OS_ID} ${OS_VERSION}"
        error "建议使用 Debian / Ubuntu 后再运行本脚本"
        return
    fi

    check_github_network_light

    collect_missing_basic_deps
    if [[ ${#MISSING_BASIC_DEPS[@]} -eq 0 ]]; then
        info "基础依赖完整"
    else
        warn "检测到缺少基础依赖: ${MISSING_BASIC_DEPS[*]}"
        warn "建议输入 1 进入初始化环境进行补装"
    fi
}

install_deps() {
    require_supported_os --quiet
    collect_missing_basic_deps
    if [[ ${#MISSING_BASIC_DEPS[@]} -eq 0 ]]; then
        info "必要依赖已完整"
        return
    fi

    info "安装缺失必要依赖: ${MISSING_BASIC_DEPS[*]}"
    safe_apt_update
    safe_apt_install ca-certificates "${MISSING_BASIC_DEPS[@]}"
}

detect_download_source() {
    check_root
    require_supported_os --quiet
    select_and_apply_fastest_apt_mirror
}

upgrade_all_deps() {
    check_root
    require_supported_os --quiet
    info "更新全部依赖 ..."
    safe_apt_update
    safe_apt_upgrade
    info "全部依赖更新完成"
}

repair_apt_downloads() {
    check_root
    require_supported_os --quiet
    info "开始修复 apt 下载/安装状态 ..."
    apt-get clean
    safe_apt_update
    dpkg --configure -a
    apt-get "${APT_OPTS[@]}" install -f -y
    info "apt 下载/安装状态修复完成"
}

command_exists() {
    command -v "$1" &>/dev/null
}

is_caddy_service_active() {
    command_exists systemctl && systemctl is-active --quiet caddy 2>/dev/null
}

check_github_connection() {
    echo ""
    echo "----------------------------------------"
    echo "  GitHub 连接检测"
    echo "----------------------------------------"

    if ! command_exists git; then
        warn "git 未安装，无法检测 GitHub 仓库连接"
        return 0
    fi

    if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        warn "当前脚本目录不是 Git 仓库: ${SCRIPT_DIR}"
        return 0
    fi

    local remote
    remote="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ -z "$remote" ]]; then
        warn "当前仓库未配置 origin 远端"
        return 0
    fi

    info "origin: ${remote}"
    if [[ "$remote" != *github.com* ]]; then
        warn "origin 不是 GitHub 地址，仅检测 Git 远端可访问性"
    fi

    if GIT_TERMINAL_PROMPT=0 git -C "$SCRIPT_DIR" \
        -c http.lowSpeedLimit=1 \
        -c http.lowSpeedTime=8 \
        ls-remote --heads origin >/dev/null 2>&1; then
        info "GitHub/远端仓库连接正常"
    else
        warn "GitHub/远端仓库连接失败"
        warn "可能原因：网络不可达、GitHub 被阻断、认证失效或远端地址错误"
    fi
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
        set +euo pipefail 2>/dev/null || set +eu
        . "${HOME}/.acme.sh/acme.sh.env"
        set -euo pipefail 2>/dev/null || set -eu
    fi
    info "acme.sh 安装完成"
}

install_caddy() {
    if command -v caddy &>/dev/null; then
        info "Caddy 已安装: $(caddy version)"
        ensure_caddy_root
        return
    fi

    info "安装 Caddy ..."

    local installed=0
    case "${OS_ID}" in
        ubuntu|debian)
            info "通过 apt 安装 Caddy ..."
            safe_apt_install debian-archive-keyring apt-transport-https || true
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' 2>/dev/null | \
                gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' 2>/dev/null | \
                tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null || true
            safe_apt_update || true
            safe_apt_install caddy && installed=1 || true
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
    ensure_caddy_root
}

ensure_base_caddyfile() {
    mkdir -p /etc/caddy /var/www/html
    if [[ -f /etc/caddy/Caddyfile ]]; then
        return
    fi
    cat > /etc/caddy/Caddyfile <<'CADDYEOF'
:80 {
    root * /var/www/html
    file_server
}
CADDYEOF
}

# ---- 强制 Caddy 以 root 运行（避免日志/权限问题）----
ensure_caddy_root() {
    if ! command -v systemctl &>/dev/null; then
        return
    fi
    local drop_in="/etc/systemd/system/caddy.service.d/root-user.conf"
    if [[ -f "$drop_in" ]]; then
        return
    fi
    info "配置 Caddy systemd 以 root 运行..."
    mkdir -p /etc/systemd/system/caddy.service.d
    cat > "$drop_in" <<'EOF'
[Service]
User=root
Group=root
EOF
    systemctl daemon-reload
    info "Caddy 已配置为 root 运行"
}

# ---- 临时 Caddy（端口 80，用于证书申请） ----
port80_processes() {
    if command_exists ss; then
        ss -H -ltnp 2>/dev/null | awk '$4 ~ /:80$/ {print}'
    fi
}

port80_is_busy() {
    [[ -n "$(port80_processes)" ]]
}

prepare_caddy_for_challenge() {
    FORMAL_CADDY_WAS_ACTIVE=0
    CHALLENGE_ACTIVE=0

    # 正式 Caddy 已负责 ACME webroot 时直接复用，不停止其服务。
    if is_caddy_service_active; then
        FORMAL_CADDY_WAS_ACTIVE=1
        info "正式 Caddy 已运行，复用端口 80 提供 ACME 验证"
        return 0
    fi

    # 其他手动 Caddy 或服务占用端口时拒绝继续，避免误杀进程。
    if pgrep -x caddy &>/dev/null; then
        warn "检测到非 systemd 管理的 Caddy；不会强制停止，请先处理端口 80 冲突"
        return 1
    fi
    if port80_is_busy; then
        error "端口 80 已被占用；不会停止或强制杀死占用者，请先处理端口冲突"
        port80_processes >&2 || true
        return 1
    fi

    CHALLENGE_ACTIVE=1
}

restore_caddy_after_challenge() {
    if [[ "${CHALLENGE_ACTIVE:-0}" != "1" ]]; then
        return
    fi
    CHALLENGE_ACTIVE=0
    if [[ "${FORMAL_CADDY_WAS_ACTIVE:-0}" == "1" ]] && command_exists systemctl && systemctl cat caddy.service &>/dev/null; then
        systemctl start caddy 2>/dev/null || true
    fi
}

start_temp_caddy() {
    prepare_caddy_for_challenge || return $?
    if [[ "${CHALLENGE_ACTIVE:-0}" != "1" ]]; then
        return 0
    fi

    info "启动临时 Caddy（端口 80，用于 Let's Encrypt 验证）..."
    mkdir -p /var/www/html

    local admin_port
    admin_port=$((20000 + RANDOM % 10000))
    TEMP_CADDY_ADMIN_ADDR="127.0.0.1:${admin_port}"
    cat > /etc/caddy/Caddyfile.temp <<EOF
{
    admin ${TEMP_CADDY_ADMIN_ADDR}
}
:80 {
    root * /var/www/html
    file_server
}
EOF

    TEMP_CADDY_OWNED=0
    if caddy start --config /etc/caddy/Caddyfile.temp --adapter caddyfile 2>/dev/null; then
        TEMP_CADDY_OWNED=1
    else
        caddy run --config /etc/caddy/Caddyfile.temp --adapter caddyfile > /dev/null 2>&1 &
        TEMP_CADDY_PID=$!
        sleep 2
        if kill -0 "$TEMP_CADDY_PID" 2>/dev/null; then
            TEMP_CADDY_OWNED=1
        else
            rm -f /etc/caddy/Caddyfile.temp
            TEMP_CADDY_ADMIN_ADDR=""
            CHALLENGE_ACTIVE=0
            error "临时 Caddy 启动失败"
            return 1
        fi
    fi
    sleep 2
    info "临时 Caddy 已启动"
}

stop_temp_caddy() {
    [[ "${TEMP_CADDY_OWNED:-0}" == "1" ]] || return 0
    if [[ -n "${TEMP_CADDY_PID:-}" ]]; then
        kill "$TEMP_CADDY_PID" 2>/dev/null || true
        wait "$TEMP_CADDY_PID" 2>/dev/null || true
        TEMP_CADDY_PID=""
    fi
    if [[ -n "${TEMP_CADDY_ADMIN_ADDR:-}" ]]; then
        caddy stop --address "$TEMP_CADDY_ADMIN_ADDR" 2>/dev/null || true
    fi
    rm -f /etc/caddy/Caddyfile.temp
    TEMP_CADDY_OWNED=0
    TEMP_CADDY_ADMIN_ADDR=""
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

    info "申请 Let's Encrypt IP 证书（webroot 模式）..."
    ${acme_sh} --issue \
        --server letsencrypt \
        -d "${PUBLIC_IP}" \
        --certificate-profile shortlived \
        --webroot /var/www/html \
        --ecc \
        --force || {
            stop_temp_caddy
            error "证书申请失败，常见原因："
            error "1. Let's Encrypt 频率限制（同一 IP 7 天内最多 5 次）"
            error "2. 端口 80 被防火墙阻挡（安全组/iptables 需放行）"
            error "3. 公网 IP ${PUBLIC_IP} 并非本机公网 IP"
            error "4. /var/www/html 目录不可写"
            exit 1
        }

    if ! openssl x509 -checkend 0 -noout -in "$CERT_FILE" 2>/dev/null; then
        stop_temp_caddy
        error "证书申请命令已结束，但未生成有效证书: ${CERT_FILE}"
        exit 1
    fi
    info "证书申请成功！"

    ${acme_sh} --install-cert -d "${PUBLIC_IP}" \
        --ecc \
        --reloadcmd "systemctl reload caddy 2>/dev/null || caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true"
}

issue_domain_cert() {
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    local cert_dir="${HOME}/.acme.sh/${DOMAIN}_ecc"
    CERT_FILE="${cert_dir}/fullchain.cer"
    KEY_FILE="${cert_dir}/${DOMAIN}.key"

    echo ""
    echo -e "${YELLOW}-----------------------------------------${NC}"
    echo -e "${YELLOW}  域名证书（acme.sh）${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    mkdir -p /var/www/html

    info "申请 Let's Encrypt 域名证书（webroot 模式）..."
    ${acme_sh} --issue \
        --server letsencrypt \
        -d "${DOMAIN}" \
        --webroot /var/www/html \
        --ecc \
        --force || {
            stop_temp_caddy
            error "证书申请失败，常见原因："
            error "1. 域名 DNS A 记录没有指向本机公网 IP"
            error "2. 端口 80 被防火墙阻挡（安全组/iptables 需放行）"
            error "3. Let's Encrypt 频率限制"
            error "4. /var/www/html 目录不可写"
            exit 1
        }

    if ! openssl x509 -checkend 0 -noout -in "$CERT_FILE" 2>/dev/null; then
        stop_temp_caddy
        error "证书申请命令已结束，但未生成有效证书: ${CERT_FILE}"
        exit 1
    fi
    info "证书申请成功！"

    ${acme_sh} --install-cert -d "${DOMAIN}" \
        --ecc \
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
    collect_all_services
    write_nav_html "/var/www/html/index.html" "$base_url" "${ALL_SERVICES[@]}"
}

# ---- 生成 Caddy 配置（mode: ip|domain）----
configure_caddy() {
    local mode="${1}"
    local target_caddyfile="/etc/caddy/Caddyfile"
    local caddyfile="/tmp/ip-ssl-proxy.Caddyfile.$$"
    info "生成 Caddy 配置（${mode} 模式）: ${target_caddyfile}"
    mkdir -p /etc/caddy
    mkdir -p /var/log/caddy

    local site_addr tls_line section_title mode_label
    if [[ "$mode" == "ip" ]]; then
        site_addr=":443"
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
        redir https://{host}{uri} permanent
    }
}

# -------- ${section_title} --------
${site_addr} {
CADDYEOF

    if [[ "$mode" == "ip" ]]; then
        echo "${tls_line}" >> "$caddyfile"
    fi

    load_removed_services
    for svc in "${SERVICES_LIST[@]}"; do
        IFS='|' read -r path host port _ <<< "$svc"
        is_service_removed "$path" && continue
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
    mkdir -p /etc/caddy/routes-custom.d /etc/caddy/subdomains.d
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
    # 子域名（完整 site block，必须放在主 site block 之外）
    if ls /etc/caddy/subdomains.d/*.conf &>/dev/null 2>&1; then
        echo "# 子域名（自动引入）" >> "$caddyfile"
        echo "import /etc/caddy/subdomains.d/*.conf" >> "$caddyfile"
    fi
    info "Caddy 配置已生成，共 ${#SERVICES_LIST[@]} 个服务路由"
    caddy fmt --overwrite "$caddyfile" 2>/dev/null || true
    caddy validate --config "$caddyfile" --adapter caddyfile >/dev/null 2>&1 || {
        rm -f "$caddyfile"
        error "Caddy 配置校验失败: ${target_caddyfile}"
        error "旧配置未被覆盖，请检查自定义路由或证书路径"
        exit 1
    }
    if [[ -f "$target_caddyfile" ]]; then
        cp "$target_caddyfile" "${target_caddyfile}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    mv "$caddyfile" "$target_caddyfile"
}

# ---- acme.sh 证书续期 cron ----
setup_cron_renew_acme() {
    info "配置 acme.sh 证书自动续期 ..."
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    local renew_script="/usr/local/sbin/ip-ssl-proxy-acme-renew"
    local cron_line="0 3 * * * ${renew_script} >> /var/log/caddy/acme-renew.log 2>&1"
    local current_cron
    mkdir -p "$(dirname "$renew_script")" /var/log/caddy

    cat > "$renew_script" <<RENEWEOF
#!/usr/bin/env bash
set -eu

ACME_SH="${acme_sh}"
TEMP_CADDYFILE="/etc/caddy/Caddyfile.temp"
FORMAL_WAS_ACTIVE=0

command_exists() { command -v "\$1" >/dev/null 2>&1; }
port80_processes() {
    if command_exists ss; then
        ss -H -ltnp 2>/dev/null | awk '\$4 ~ /:80$/ {print}'
    fi
}
port80_is_busy() { [ -n "\$(port80_processes)" ]; }
cleanup() {
    caddy stop --config "\$TEMP_CADDYFILE" >/dev/null 2>&1 || true
    rm -f "\$TEMP_CADDYFILE"
    if [ "\$FORMAL_WAS_ACTIVE" = "1" ] && command_exists systemctl && systemctl cat caddy.service >/dev/null 2>&1; then
        systemctl start caddy >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

if command_exists systemctl && systemctl is-active --quiet caddy 2>/dev/null; then
    FORMAL_WAS_ACTIVE=1
    systemctl stop caddy >/dev/null 2>&1 || true
fi
caddy stop >/dev/null 2>&1 || true
sleep 1

if port80_is_busy; then
    echo "端口 80 被占用，准备强制关闭以下进程:"
    port80_processes || true
fi

if port80_is_busy && command_exists fuser; then
    fuser -k 80/tcp >/dev/null 2>&1 || true
    sleep 1
fi

if port80_is_busy; then
    echo "端口 80 仍被占用，再次强制关闭:"
    port80_processes || true
    fuser -k 80/tcp >/dev/null 2>&1 || true
    sleep 1
fi

if port80_is_busy; then
    echo "端口 80 占用进程未能被关闭:"
    port80_processes || true
    exit 1
elif command_exists fuser; then
    echo "端口 80 占用进程已强制关闭"
fi

mkdir -p /var/www/html
cat > "\$TEMP_CADDYFILE" <<'CADDYEOF'
:80 {
    root * /var/www/html
    file_server
}
CADDYEOF

caddy start --config "\$TEMP_CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || {
    caddy run --config "\$TEMP_CADDYFILE" --adapter caddyfile >/tmp/ip-ssl-proxy-renew-caddy.log 2>&1 &
    sleep 2
}

"\$ACME_SH" --cron --home "${HOME}/.acme.sh"
RENEWEOF
    chmod +x "$renew_script"

    current_cron="$(crontab -l 2>/dev/null || true)"
    {
        printf '%s\n' "$current_cron" | awk \
            '!(index($0, "acme.sh") && index($0, "--cron")) && !(index($0, "ip-ssl-proxy-acme-renew"))'
        printf '%s\n' "$cron_line"
    } | sed '/^[[:space:]]*$/d' | crontab -
    info "已配置唯一续期 crontab（每日 3:00 临时接管 80 端口续期）"
}

remove_ip_cert_renew_task() {
    local renew_script="/usr/local/sbin/ip-ssl-proxy-acme-renew"
    local current_cron
    rm -f "$renew_script"

    current_cron="$(crontab -l 2>/dev/null || true)"
    {
        printf '%s\n' "$current_cron" | awk \
            '!(index($0, "acme.sh") && index($0, "--cron")) && !(index($0, "ip-ssl-proxy-acme-renew"))'
    } | sed '/^[[:space:]]*$/d' | crontab -
    info "已删除 acme.sh 证书自动拉取任务"
}

remove_ip_cert_files() {
    local ip="$1"
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    [[ -z "$ip" ]] && return 0

    if [[ -f "$acme_sh" ]]; then
        "$acme_sh" --remove -d "$ip" --ecc >/dev/null 2>&1 || true
    fi
    rm -rf "${HOME}/.acme.sh/${ip}_ecc" "${HOME}/.acme.sh/${ip}"
    info "已删除 IP 证书文件: ${ip}"
}

remove_domain_cert_files() {
    local domain="$1"
    local acme_sh="${HOME}/.acme.sh/acme.sh"
    [[ -z "$domain" ]] && return 0

    if [[ -f "$acme_sh" ]]; then
        "$acme_sh" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
    fi
    rm -rf "${HOME}/.acme.sh/${domain}_ecc" "${HOME}/.acme.sh/${domain}"
    info "已删除域名证书文件: ${domain}"
}

# ---- 启动 Caddy ----
start_caddy() {
    local verify_url="${1:-}"
    info "启动 Caddy 服务 ..."

    # 确保日志目录权限正确（配置 systemd 以 root 运行规避日志权限问题）
    mkdir -p /var/log/caddy
    if id -u caddy &>/dev/null; then
        chown -R caddy:caddy /var/log/caddy 2>/dev/null || true
    fi

    ensure_caddy_root

    if command -v systemctl &>/dev/null && systemctl cat caddy.service &>/dev/null; then
        if pgrep -x caddy &>/dev/null && ! is_caddy_service_active; then
            error "检测到非 systemd 管理的 Caddy；不会强制停止，请先处理现有实例"
            return 1
        fi
        systemctl enable caddy 2>/dev/null || true
        systemctl restart caddy 2>/dev/null || systemctl start caddy 2>/dev/null || {
            error "systemctl 启动 Caddy 失败，请检查: journalctl -u caddy -n 50"
            return 1
        }
    else
        if pgrep -x caddy &>/dev/null; then
            error "检测到非 systemd 管理的 Caddy；不会强制停止，请先处理现有实例"
            return 1
        fi
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
# 服务访问与导航页管理
# ============================================================
mode_paired() {
    check_root
    while true; do
        print_child_page_title "2.3 服务访问与导航页管理"
        print_route_help
        bootstrap_routes_from_legacy
        show_route_mappings
        echo ""
        echo "  1  为指定端口配置独立域名"
        echo "  2  将指定端口添加为子路径"
        echo "  3  添加新域名（子路径）"
        echo "  4  删除端口"
        echo "  5  删除域名（子路径）"
        echo "  6  生成 Caddy 配置 / 网站首页"
        echo "  0  返回上级菜单"
        echo ""
        echo -n "  请输入 [1/2/3/4/5/6/0]: "

        local ROUTE_CHOICE
        if tty -s; then
            read -r ROUTE_CHOICE </dev/tty || { info "已返回上级菜单" ; return 0; }
        else
            info "未检测到交互终端，已返回上级菜单"
            return 0
        fi
        echo ""

        case "$ROUTE_CHOICE" in
            1) add_site_mapping ;;
            2) add_path_mapping ;;
            3) add_cloudflare_domain ;;
            4) delete_route_mapping ;;
            5) delete_cloudflare_domain ;;
            6) generate_route_config ;;
            0) info "已返回上级菜单" ; return 0 ;;
            *) error "无效选项，请输入 1、2、3、4、5、6 或 0" ;;
        esac
    done
}

manage_route_mappings() {
    while true; do
        bootstrap_routes_from_legacy
        show_route_mappings
        echo ""
        echo "  管理操作:"
        echo "  1  编辑映射"
        echo "  2  删除映射"
        echo "  0  返回上一级"
        echo ""
        echo -n "  请输入 [1/2/0]: "

        local choice
        read -r choice </dev/tty 2>/dev/null || return 0
        echo ""
        case "$choice" in
            1) edit_route_mapping ;;
            2) delete_route_mapping ;;
            0) info "已返回上一级"; return 0 ;;
            *) error "无效选项，请输入 1、2 或 0" ;;
        esac
    done
}

load_routes() {
    ROUTES=()
    if [[ -f "$ROUTES_STATE_FILE" ]]; then
        mapfile -t ROUTES < <(sed '/^[[:space:]]*$/d' "$ROUTES_STATE_FILE")
    fi
}

bootstrap_routes_from_legacy() {
    [[ -f "$ROUTES_MIGRATION_STATE_FILE" ]] && return 0
    load_routes
    local entry ip domain path port name line existing
    local changed=0

    ip="$(configured_ip_from_caddyfile)"
    if [[ -n "$ip" ]]; then
        entry="ip"
    else
        load_domain_certs
        domain="${DOMAIN_CERTS[0]:-}"
        [[ -n "$domain" ]] || return 0
        entry="$domain"
    fi

    if [[ -f /etc/caddy/Caddyfile ]]; then
        while IFS='|' read -r path port; do
            [[ -n "$path" && -n "$port" ]] || continue
            valid_port "$port" || continue
            existing=0
            for line in "${ROUTES[@]}"; do
                [[ "${line%%|*}" == "$port" ]] && existing=1 && break
            done
            [[ "$existing" -eq 1 ]] && continue
            name="${path#/}"
            name="${name%/}"
            [[ -n "$name" ]] || name="端口 ${port}"
            [[ "$path" == /* ]] || path="/${path}"
            [[ "$path" == */ ]] || path="${path}/"
            ROUTES+=("${port}|${name}|127.0.0.1:${port}|path|${entry}|${path}|yes")
            changed=1
        done < <(
            awk '
                /handle_path[[:space:]]+\// {
                    path=$2
                    sub(/\*$/, "", path)
                }
                path != "" && /reverse_proxy[[:space:]]+127\.0\.0\.1:[0-9]+/ {
                    backend=$2
                    sub(/^127\.0\.0\.1:/, "", backend)
                    print path "|" backend
                    path=""
                }
            ' /etc/caddy/Caddyfile
        )
    fi

    local file
    for file in /etc/caddy/routes-custom.d/*.conf; do
        [[ -f "$file" ]] || continue
        port="$(grep -oE '127\.0\.0\.1:[0-9]+' "$file" 2>/dev/null | head -1 | cut -d: -f2 || true)"
        valid_port "$port" || continue
        existing=0
        for line in "${ROUTES[@]}"; do
            [[ "${line%%|*}" == "$port" ]] && existing=1 && break
        done
        [[ "$existing" -eq 1 ]] && continue
        name="$(basename "$file" .conf)"
        path="$(grep -oE 'handle_path[[:space:]]+/[^*[:space:]]+' "$file" 2>/dev/null | head -1 | awk '{print $2}' || true)"
        [[ -n "$path" ]] || path="/${name}/"
        [[ "$path" == */ ]] || path="${path}/"
        valid_route_path "$path" || continue
        ROUTES+=("${port}|${name}|127.0.0.1:${port}|path|${entry}|${path}|yes")
        changed=1
    done

    if [[ "$changed" -eq 1 ]]; then
        save_routes
        info "已将旧配置中缺失的映射补入统一路由表"
    fi
    mkdir -p "$(dirname "$ROUTES_MIGRATION_STATE_FILE")"
    : > "$ROUTES_MIGRATION_STATE_FILE"
    return 0
}

save_routes() {
    mkdir -p /etc/caddy
    if [[ ${#ROUTES[@]} -eq 0 ]]; then
        rm -f "$ROUTES_STATE_FILE"
        return 0
    fi
    printf '%s\n' "${ROUTES[@]}" > "$ROUTES_STATE_FILE"
}

valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

valid_route_entry() {
    local entry="${1:-}"
    [[ -n "$entry" ]] || return 1
    [[ "$entry" != *'|'* && "$entry" != *'/'* && "$entry" != *' '* ]]
    [[ "$entry" =~ ^([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|[0-9A-Fa-f:]+)(:[0-9]+)?$ ]]
}

valid_route_path() {
    local path="${1:-}"
    [[ "$path" =~ ^/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*/$ ]]
}

route_conflicts() {
    local wanted_type="$1" wanted_entry="$2" wanted_path="$3"
    local line port name backend route_type entry path nav
    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r port name backend route_type entry path nav <<< "$line"
        [[ "$entry" == "$wanted_entry" ]] || continue
        if [[ "$wanted_type" == "site" || "$route_type" == "site" ]]; then
            return 0
        fi
        [[ "$path" == "$wanted_path" ]] && return 0
    done
    return 1
}

prune_disabled_routes() {
    load_disabled_routes
    local -a kept=()
    local key entry port line route_port route_entry found
    for key in "${DISABLED_ROUTES[@]}"; do
        IFS='|' read -r entry port <<< "$key"
        found=0
        load_routes
        for line in "${ROUTES[@]}"; do
            IFS='|' read -r route_port _ _ _ route_entry _ _ <<< "$line"
            if [[ "$route_entry" == "$entry" && "$route_port" == "$port" ]]; then
                found=1
                break
            fi
        done
        [[ "$found" -eq 1 ]] && kept+=("$key")
    done
    DISABLED_ROUTES=("${kept[@]}")
    save_disabled_routes
}

load_disabled_routes() {
    DISABLED_ROUTES=()
    if [[ -f "$ROUTE_DISABLED_STATE_FILE" ]]; then
        mapfile -t DISABLED_ROUTES < <(sed '/^[[:space:]]*$/d' "$ROUTE_DISABLED_STATE_FILE")
    fi
}

save_disabled_routes() {
    mkdir -p /etc/caddy
    if [[ ${#DISABLED_ROUTES[@]} -eq 0 ]]; then
        rm -f "$ROUTE_DISABLED_STATE_FILE"
        return 0
    fi
    printf '%s\n' "${DISABLED_ROUTES[@]}" | awk 'NF && !seen[$0]++' > "$ROUTE_DISABLED_STATE_FILE"
}

route_disabled_key() {
    local entry="$1" port="$2"
    printf '%s|%s' "$entry" "$port"
}

is_route_disabled() {
    local entry="$1" port="$2" key item
    key="$(route_disabled_key "$entry" "$port")"
    load_disabled_routes
    for item in "${DISABLED_ROUTES[@]}"; do
        [[ "$item" == "$key" ]] && return 0
    done
    return 1
}

toggle_route_disabled() {
    local entry="$1" port="$2" key item
    key="$(route_disabled_key "$entry" "$port")"
    load_disabled_routes

    local -a kept=()
    local found=0
    for item in "${DISABLED_ROUTES[@]}"; do
        if [[ "$item" == "$key" ]]; then
            found=1
            continue
        fi
        kept+=("$item")
    done

    if [[ "$found" -eq 1 ]]; then
        DISABLED_ROUTES=("${kept[@]}")
        save_disabled_routes
        info "已开启端口 ${port} 的映射"
    else
        kept+=("$key")
        DISABLED_ROUTES=("${kept[@]}")
        save_disabled_routes
        info "已关闭端口 ${port} 的映射"
    fi
}

entry_display_name() {
    local entry="$1"
    if [[ "$entry" == "ip" ]]; then
        configured_ip_from_caddyfile
    else
        printf '%s' "$entry"
    fi
}

load_cloudflare_domains() {
    CLOUDFLARE_DOMAINS=()
    if [[ -f "$CLOUDFLARE_DOMAIN_STATE_FILE" ]]; then
        mapfile -t CLOUDFLARE_DOMAINS < <(sed '/^[[:space:]]*$/d' "$CLOUDFLARE_DOMAIN_STATE_FILE")
    fi
}

save_cloudflare_domains() {
    mkdir -p /etc/caddy
    if [[ ${#CLOUDFLARE_DOMAINS[@]} -eq 0 ]]; then
        rm -f "$CLOUDFLARE_DOMAIN_STATE_FILE"
        return 0
    fi
    printf '%s\n' "${CLOUDFLARE_DOMAINS[@]}" | awk 'NF && !seen[$0]++' > "$CLOUDFLARE_DOMAIN_STATE_FILE"
}

cloudflare_domain_exists() {
    local wanted="$1" domain
    load_cloudflare_domains
    for domain in "${CLOUDFLARE_DOMAINS[@]}"; do
        [[ "$domain" == "$wanted" ]] && return 0
    done
    return 1
}

valid_domain_name() {
    local domain="${1:-}"
    [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]
}

add_cloudflare_domain() {
    local domain
    echo ""
    echo -n "  由 Cloudflare 托管的新域名: "
    read -r domain </dev/tty 2>/dev/null || true
    domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"

    if ! valid_domain_name "$domain"; then
        error "域名格式无效，例如 example.com 或 home.example.com"
        return 0
    fi
    if domain_cert_exists "$domain"; then
        warn "域名 ${domain} 已由本脚本管理证书，无需重复添加"
        return 0
    fi
    if cloudflare_domain_exists "$domain"; then
        warn "Cloudflare 托管域名 ${domain} 已存在"
        return 0
    fi

    load_cloudflare_domains
    CLOUDFLARE_DOMAINS+=("$domain")
    save_cloudflare_domains
    info "已添加新域名（子路径）: ${domain}"
    info "请选择 6「生成 Caddy 配置 / 网站首页」使其生效"
}

delete_cloudflare_domain() {
    load_cloudflare_domains
    if [[ ${#CLOUDFLARE_DOMAINS[@]} -eq 0 ]]; then
        info "暂无通过功能 3 添加的域名"
        return 0
    fi

    echo ""
    echo "  当前子路径域名:"
    local i input idx domain line port route_type entry item
    for i in "${!CLOUDFLARE_DOMAINS[@]}"; do
        printf "  %2d. %s\n" $((i+1)) "${CLOUDFLARE_DOMAINS[$i]}"
    done
    echo ""
    echo -n "  输入要删除的域名编号，0 返回: "
    read -r input </dev/tty 2>/dev/null || true
    [[ "$input" == "0" || -z "$input" ]] && { info "已取消删除域名"; return 0; }
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        error "请输入有效编号"
        return 0
    fi

    idx=$((10#$input - 1))
    if [[ $idx -lt 0 || $idx -ge ${#CLOUDFLARE_DOMAINS[@]} ]]; then
        error "域名编号不存在"
        return 0
    fi
    domain="${CLOUDFLARE_DOMAINS[$idx]}"

    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r port _ _ route_type entry _ _ <<< "$line"
        if [[ "$route_type" == "site" && "$entry" == "$domain" ]]; then
            error "域名 ${domain} 正由端口 ${port} 作为独立域名使用，请先通过功能 4 删除该端口"
            return 0
        fi
    done

    local -a kept_domains=() kept_disabled=()
    for i in "${!CLOUDFLARE_DOMAINS[@]}"; do
        [[ "$i" -eq "$idx" ]] && continue
        kept_domains+=("${CLOUDFLARE_DOMAINS[$i]}")
    done
    CLOUDFLARE_DOMAINS=("${kept_domains[@]}")
    save_cloudflare_domains

    load_disabled_routes
    for item in "${DISABLED_ROUTES[@]}"; do
        [[ "$item" == "${domain}|"* ]] && continue
        kept_disabled+=("$item")
    done
    DISABLED_ROUTES=("${kept_disabled[@]}")
    save_disabled_routes

    info "已删除域名（子路径）: ${domain}"
    info "请选择 6「生成 Caddy 配置 / 网站首页」使其生效"
}

load_route_entries() {
    ROUTE_ENTRIES=()
    local ip domain line _port _name _backend _type entry _path _nav

    ip="$(configured_ip_from_caddyfile)"
    [[ -n "$ip" ]] && ROUTE_ENTRIES+=("ip|公网 IP 证书入口：${ip}")

    load_domain_certs
    for domain in "${DOMAIN_CERTS[@]}"; do
        ROUTE_ENTRIES+=("${domain}|已配置域名：${domain}")
    done

    load_cloudflare_domains
    for domain in "${CLOUDFLARE_DOMAINS[@]}"; do
        local cf_exists=0 cf_item
        for cf_item in "${ROUTE_ENTRIES[@]}"; do
            [[ "${cf_item%%|*}" == "$domain" ]] && cf_exists=1 && break
        done
        [[ "$cf_exists" -eq 0 ]] && ROUTE_ENTRIES+=("${domain}|Cloudflare 托管域名：${domain}")
    done

    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r _port _name _backend _type entry _path _nav <<< "$line"
        [[ "$_type" == "site" ]] || continue
        [[ -z "$entry" || "$entry" == "ip" ]] && continue
        local exists=0 item
        for item in "${ROUTE_ENTRIES[@]}"; do
            [[ "${item%%|*}" == "$entry" ]] && exists=1 && break
        done
        [[ "$exists" -eq 0 ]] && ROUTE_ENTRIES+=("${entry}|自定义入口：${entry}")
    done
    return 0
}

route_port_exists() {
    local target_port="$1" ignored_port="${2:-}" line port
    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r port _ _ _ _ _ _ <<< "$line"
        [[ -n "$ignored_port" && "$port" == "$ignored_port" ]] && continue
        [[ "$port" == "$target_port" ]] && return 0
    done
    return 1
}

route_conflicts_except_port() {
    local wanted_type="$1" wanted_entry="$2" wanted_path="$3" ignored_port="$4"
    local line port name backend route_type entry path nav
    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r port name backend route_type entry path nav <<< "$line"
        [[ "$port" == "$ignored_port" || "$entry" != "$wanted_entry" ]] && continue
        if [[ "$wanted_type" == "site" || "$route_type" == "site" ]]; then
            return 0
        fi
        [[ "$path" == "$wanted_path" ]] && return 0
    done
    return 1
}

route_url() {
    local route_type="$1" entry="$2" path="$3"
    if [[ "$entry" == "ip" ]]; then
        entry="$(configured_ip_from_caddyfile)"
    fi
    [[ "$entry" == http://* || "$entry" == https://* ]] || entry="https://${entry}"
    if [[ "$route_type" == "site" ]]; then
        printf '%s/' "${entry%/}"
    else
        printf '%s%s' "${entry%/}" "$path"
    fi
}

choose_route_entry() {
    local include_ip="${1:-yes}"
    local -a entries=()
    local ip domain input

    if [[ "$include_ip" == "yes" ]]; then
        ip="$(configured_ip_from_caddyfile)"
        [[ -n "$ip" ]] && entries+=("公网 IP 证书入口|ip|${ip}")
    fi

    load_domain_certs
    for domain in "${DOMAIN_CERTS[@]}"; do
        entries+=("已配置域名|${domain}|${domain}")
    done
    load_cloudflare_domains
    for domain in "${CLOUDFLARE_DOMAINS[@]}"; do
        entries+=("Cloudflare 托管域名|${domain}|${domain}")
    done
    entries+=("自定义入口|custom|")

    echo ""
    echo "  选择映射入口:"
    local i label value display
    for i in "${!entries[@]}"; do
        IFS='|' read -r label value display <<< "${entries[$i]}"
        if [[ "$value" == "custom" ]]; then
            printf "  %2d. %s\n" $((i+1)) "$label"
        else
            printf "  %2d. %s：%s\n" $((i+1)) "$label" "$display"
        fi
    done
    echo "   0. 取消"
    echo ""
    echo -n "  请输入序号: "
    read -r input </dev/tty 2>/dev/null || true
    [[ "$input" == "0" || -z "$input" ]] && return 1
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        error "无效序号"
        return 1
    fi

    local idx=$((10#$input - 1))
    if [[ $idx -lt 0 || $idx -ge ${#entries[@]} ]]; then
        error "无效序号"
        return 1
    fi

    IFS='|' read -r label value display <<< "${entries[$idx]}"
    if [[ "$value" == "custom" ]]; then
        echo -n "  自定义入口: "
        read -r ROUTE_ENTRY </dev/tty 2>/dev/null || true
        ROUTE_ENTRY="${ROUTE_ENTRY#http://}"
        ROUTE_ENTRY="${ROUTE_ENTRY#https://}"
        ROUTE_ENTRY="$(printf '%s' "$ROUTE_ENTRY" | tr '[:upper:]' '[:lower:]')"
        if ! valid_route_entry "$ROUTE_ENTRY"; then
            error "入口格式无效，请输入域名、IP 或带端口的入口，不要包含路径"
            return 1
        fi
    else
        ROUTE_ENTRY="$value"
    fi
}

prompt_route_port_name() {
    echo -n "  端口: "
    read -r ROUTE_PORT </dev/tty 2>/dev/null || true
    if ! valid_port "$ROUTE_PORT"; then
        error "端口必须是 1–65535 之间的整数"
        return 1
    fi
    if route_port_exists "$ROUTE_PORT"; then
        info "端口 ${ROUTE_PORT} 已有配置；保存后将以新映射覆盖旧配置"
    fi

    echo -n "  服务名称: "
    read -r ROUTE_NAME </dev/tty 2>/dev/null || true
    ROUTE_NAME="${ROUTE_NAME//|/}"
    [[ -z "$ROUTE_NAME" ]] && { error "服务名称不能为空"; return 1; }
    ROUTE_BACKEND="127.0.0.1:${ROUTE_PORT}"
}

default_path_route_entry() {
    local ip
    ip="$(configured_ip_from_caddyfile)"
    if [[ -n "$ip" ]]; then
        ROUTE_ENTRY="ip"
        return 0
    fi

    load_domain_certs
    if [[ ${#DOMAIN_CERTS[@]} -gt 0 ]]; then
        ROUTE_ENTRY="${DOMAIN_CERTS[0]}"
        return 0
    fi

    load_cloudflare_domains
    if [[ ${#CLOUDFLARE_DOMAINS[@]} -gt 0 ]]; then
        ROUTE_ENTRY="${CLOUDFLARE_DOMAINS[0]}"
        return 0
    fi

    error "没有可用的公网 IP 或域名入口，请先配置证书或通过功能 3 添加新域名"
    return 1
}

save_route_replacing_port() {
    local new_line="$1"
    local line port item
    local -a kept_routes=() kept_disabled=()

    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r port _ _ _ _ _ _ <<< "$line"
        [[ "$port" == "$ROUTE_PORT" ]] && continue
        kept_routes+=("$line")
    done
    kept_routes+=("$new_line")
    ROUTES=("${kept_routes[@]}")
    save_routes

    load_disabled_routes
    for item in "${DISABLED_ROUTES[@]}"; do
        [[ "$item" == *"|${ROUTE_PORT}" ]] && continue
        kept_disabled+=("$item")
    done
    DISABLED_ROUTES=("${kept_disabled[@]}")
    save_disabled_routes
}

add_site_mapping() {
    print_subsection_title "为指定端口配置独立域名"
    prompt_route_port_name || return 0
    choose_route_entry yes || { info "已取消配置独立域名"; return 0; }
    if route_conflicts_except_port site "$ROUTE_ENTRY" / "$ROUTE_PORT"; then
        error "入口 ${ROUTE_ENTRY} 已有配置；独立域名不能与该入口的其他配置共存"
        return 0
    fi

    save_route_replacing_port "${ROUTE_PORT}|${ROUTE_NAME}|${ROUTE_BACKEND}|site|${ROUTE_ENTRY}|/|yes"
    info "已配置独立域名: $(route_url site "$ROUTE_ENTRY" "/") -> ${ROUTE_BACKEND}"
}

add_path_mapping() {
    print_subsection_title "将指定端口添加为子路径"
    prompt_route_port_name || return 0
    default_path_route_entry || return 0
    local route_slug
    route_slug="$(printf '%s' "$ROUTE_NAME" | sed -E 's/[[:space:]]+/-/g')"
    ROUTE_PATH="/${route_slug}/"
    if ! valid_route_path "$ROUTE_PATH"; then
        error "服务名称无法用作访问路径，请仅使用字母、数字、下划线、短横线或空格"
        return 0
    fi
    if route_conflicts_except_port path "$ROUTE_ENTRY" "$ROUTE_PATH" "$ROUTE_PORT"; then
        error "入口 ${ROUTE_ENTRY} 已配置独立域名或相同路径 ${ROUTE_PATH}"
        return 0
    fi

    save_route_replacing_port "${ROUTE_PORT}|${ROUTE_NAME}|${ROUTE_BACKEND}|path|${ROUTE_ENTRY}|${ROUTE_PATH}|yes"
    info "已添加子路径 ${ROUTE_PATH} -> ${ROUTE_BACKEND}（自动应用到可用入口）"
}

delete_route_mapping() {
    load_routes
    if [[ ${#ROUTES[@]} -eq 0 ]]; then
        info "暂无映射关系"
        return 0
    fi

    echo ""
    echo -n "  输入要删除的端口配置编号，0 返回: "
    local input line port
    read -r input </dev/tty 2>/dev/null || true
    [[ "$input" == "0" || -z "$input" ]] && { info "已取消删除映射"; return 0; }
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        error "请输入有效编号"
        return 0
    fi

    local index=$((10#$input - 1))
    if [[ "$index" -lt 0 || "$index" -ge ${#ROUTES[@]} ]]; then
        error "映射编号不存在"
        return 0
    fi
    IFS='|' read -r port _ _ _ _ _ _ <<< "${ROUTES[$index]}"

    local -a kept=()
    local deleted=0
    local current_index
    for current_index in "${!ROUTES[@]}"; do
        line="${ROUTES[$current_index]}"
        if [[ "$current_index" -eq "$index" ]]; then
            deleted=1
            continue
        fi
        kept+=("$line")
    done
    ROUTES=("${kept[@]}")
    save_routes

    if [[ "$deleted" -eq 1 ]]; then
        prune_disabled_routes
        info "已删除编号 ${input}（端口 ${port}）的配置"
        info "请选择 6「生成 Caddy 配置 / 网站首页」使其生效"
    else
        warn "未找到编号 ${input} 的映射"
    fi
}

edit_route_mapping() {
    print_subsection_title "编辑映射"
    load_routes
    if [[ ${#ROUTES[@]} -eq 0 ]]; then
        info "暂无映射关系"
        return 0
    fi

    show_route_mappings
    echo ""
    echo -n "  输入要编辑的编号，0 返回: "
    local input
    read -r input </dev/tty 2>/dev/null || true
    [[ "$input" == "0" || -z "$input" ]] && { info "已取消编辑映射"; return 0; }
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        error "请输入有效编号"
        return 0
    fi

    local index=$((10#$input - 1))
    if [[ "$index" -lt 0 || "$index" -ge ${#ROUTES[@]} ]]; then
        error "映射编号不存在"
        return 0
    fi

    local old_line="${ROUTES[$index]}"
    local old_port old_name old_backend old_type old_entry old_path old_nav
    IFS='|' read -r old_port old_name old_backend old_type old_entry old_path old_nav <<< "$old_line"
    local new_port="$old_port" new_name="$old_name" new_type="$old_type"
    local new_entry="$old_entry" new_path="$old_path" value change_entry type_label

    echo -n "  端口 [${old_port}]: "
    read -r value </dev/tty 2>/dev/null || true
    [[ -n "$value" ]] && new_port="$value"
    if ! valid_port "$new_port"; then
        error "端口必须是 1–65535 之间的整数"
        return 0
    fi
    if route_port_exists "$new_port" "$old_port"; then
        error "端口 ${new_port} 已被其他映射使用"
        return 0
    fi

    echo -n "  服务名称 [${old_name}]: "
    read -r value </dev/tty 2>/dev/null || true
    value="${value//|/}"
    [[ -n "$value" ]] && new_name="$value"

    [[ "$old_type" == "site" ]] && type_label="独立域名" || type_label="子路径"
    echo "  类型：1 独立域名，2 子路径"
    echo -n "  类型 [${type_label}，回车保持]: "
    read -r value </dev/tty 2>/dev/null || true
    case "$value" in
        "") ;;
        1) new_type="site" ;;
        2) new_type="path" ;;
        *) error "无效映射类型"; return 0 ;;
    esac

    echo -n "  是否更改映射入口？[y/N]: "
    read -r change_entry </dev/tty 2>/dev/null || true
    if [[ "$change_entry" =~ ^[Yy]$ ]]; then
        choose_route_entry yes || { info "已取消编辑映射"; return 0; }
        new_entry="$ROUTE_ENTRY"
    fi

    if [[ "$new_type" == "site" ]]; then
        new_path="/"
    else
        [[ "$old_type" == "path" ]] || new_path="/service/"
        echo -n "  访问路径 [${new_path}]: "
        read -r value </dev/tty 2>/dev/null || true
        [[ -n "$value" ]] && new_path="$value"
        [[ "$new_path" == /* ]] || new_path="/${new_path}"
        [[ "$new_path" == */ ]] || new_path="${new_path}/"
        if ! valid_route_path "$new_path"; then
            error "路径格式无效，只能使用字母、数字、下划线、短横线和斜杠"
            return 0
        fi
    fi

    if route_conflicts_except_port "$new_type" "$new_entry" "$new_path" "$old_port"; then
        error "修改后的入口与已有独立域名或子路径发生冲突"
        return 0
    fi

    load_routes
    ROUTES[$index]="${new_port}|${new_name}|127.0.0.1:${new_port}|${new_type}|${new_entry}|${new_path}|${old_nav}"
    save_routes

    load_disabled_routes
    local old_key="${old_entry}|${old_port}" new_key="${new_entry}|${new_port}" item
    local -a updated_disabled=()
    for item in "${DISABLED_ROUTES[@]}"; do
        [[ "$item" == "$old_key" ]] && item="$new_key"
        updated_disabled+=("$item")
    done
    DISABLED_ROUTES=("${updated_disabled[@]}")
    save_disabled_routes
    info "已更新映射: $(route_url "$new_type" "$new_entry" "$new_path") -> 127.0.0.1:${new_port}"
}

customize_route_mapping() {
    print_subsection_title "为不同域名配置"
    echo ""
    echo "  说明:"
    echo "  选择域名，设置该域名下的映射开启或关闭。"

    bootstrap_routes_from_legacy

    while true; do
        load_route_entries
        echo ""
        echo "  域名列表:"
        if [[ ${#ROUTE_ENTRIES[@]} -eq 0 ]]; then
            echo "  暂无已配置入口"
            return 0
        fi

        local i entry label
        for i in "${!ROUTE_ENTRIES[@]}"; do
            IFS='|' read -r entry label <<< "${ROUTE_ENTRIES[$i]}"
            printf "  %2d. %s\n" $((i+1)) "$label"
        done
        echo "   0. 退出"
        echo ""
        echo -n "  请输入序号: "

        local input
        read -r input </dev/tty 2>/dev/null || true
        [[ "$input" == "0" || -z "$input" ]] && { info "已退出不同域名配置"; return 0; }
        if ! [[ "$input" =~ ^[0-9]+$ ]]; then
            error "无效序号"
            continue
        fi

        local idx=$((10#$input - 1))
        if [[ $idx -lt 0 || $idx -ge ${#ROUTE_ENTRIES[@]} ]]; then
            error "无效序号"
            continue
        fi

        IFS='|' read -r entry label <<< "${ROUTE_ENTRIES[$idx]}"
        customize_entry_routes "$entry" "$label"
    done
}

customize_entry_routes() {
    local selected_entry="$1" label="$2"
    while true; do
        load_routes
        local -a related=()
        local line port name backend route_type entry path nav
        for line in "${ROUTES[@]}"; do
            IFS='|' read -r port name backend route_type entry path nav <<< "$line"
            if [[ "$route_type" == "path" || "$entry" == "$selected_entry" ]]; then
                related+=("$line")
            fi
        done

        print_section_title "$label"
        if [[ ${#related[@]} -eq 0 ]]; then
            info "该入口暂无映射关系"
            return 0
        fi

        echo ""
        printf "  %-6s %-8s %s\n" "编号" "端口" "服务名称"
        printf "  %-6s %-8s %s\n" "----" "----" "--------"

        local i status
        for i in "${!related[@]}"; do
            IFS='|' read -r port name backend route_type entry path nav <<< "${related[$i]}"
            status=""
            is_route_disabled "$selected_entry" "$port" && status="（关闭）"
            printf "  %-6s %-8s %s%s\n" $((i+1)) "$port" "$name" "$status"
        done

        echo ""
        echo "  输入序号切换开启/关闭，0 返回域名列表"
        echo -n "  请输入序号: "

        local input
        read -r input </dev/tty 2>/dev/null || true
        [[ "$input" == "0" || -z "$input" ]] && return 0
        if ! [[ "$input" =~ ^[0-9]+$ ]]; then
            error "无效序号"
            continue
        fi

        local idx=$((10#$input - 1))
        if [[ $idx -lt 0 || $idx -ge ${#related[@]} ]]; then
            error "无效序号"
            continue
        fi

        IFS='|' read -r port name backend route_type entry path nav <<< "${related[$idx]}"
        toggle_route_disabled "$selected_entry" "$port"
    done
}

show_route_mappings() {
    print_subsection_title "当前路由关系"

    load_routes

    if [[ ${#ROUTES[@]} -eq 0 ]]; then
        echo ""
        echo "  暂无映射关系。"
        echo "  请使用下方的 1 或 2 添加映射。"
        return 0
    fi

    echo ""
    printf "  %s%s%s%s%s\n" \
        "$(pad_terminal_column "编号" 6)" \
        "$(pad_terminal_column "端口" 8)" \
        "$(pad_terminal_column "服务名称" 16)" \
        "$(pad_terminal_column "类型" 12)" \
        "访问地址"
    printf "  %s%s%s%s%s\n" \
        "$(pad_terminal_column "----" 6)" \
        "$(pad_terminal_column "----" 8)" \
        "$(pad_terminal_column "--------" 16)" \
        "$(pad_terminal_column "----" 12)" \
        "--------"

    local line port name backend route_type entry path nav type_label url status index=0 display_name
    local route_entry_item access_entry first_url
    for line in "${ROUTES[@]}"; do
        index=$((index + 1))
        IFS='|' read -r port name backend route_type entry path nav <<< "$line"
        if [[ "$route_type" == "site" ]]; then
            type_label="独立域名"
        else
            type_label="子路径"
        fi
        display_name="$(route_service_display_name "$name")"
        if [[ "$route_type" == "site" ]]; then
            url="$(route_url "$route_type" "$entry" "$path")"
            status=""
            is_route_disabled "$entry" "$port" && status="（关闭）"
            printf "  %s%s%s%s%s%s\n" \
                "$(pad_terminal_column "$index" 6)" \
                "$(pad_terminal_column "$port" 8)" \
                "$(pad_terminal_column "$display_name" 16)" \
                "$(pad_terminal_column "$type_label" 12)" \
                "$url" "$status"
            continue
        fi

        load_route_entries
        first_url=1
        for route_entry_item in "${ROUTE_ENTRIES[@]}"; do
            access_entry="${route_entry_item%%|*}"
            route_entry_has_enabled_site "$access_entry" && continue
            url="$(route_url path "$access_entry" "$path")"
            status=""
            is_route_disabled "$access_entry" "$port" && status="（关闭）"
            if [[ "$first_url" -eq 1 ]]; then
                printf "  %s%s%s%s%s%s\n" \
                    "$(pad_terminal_column "$index" 6)" \
                    "$(pad_terminal_column "$port" 8)" \
                    "$(pad_terminal_column "$display_name" 16)" \
                    "$(pad_terminal_column "$type_label" 12)" \
                    "$url" "$status"
                first_url=0
            else
                printf "  %s%s%s%s%s%s\n" \
                    "$(pad_terminal_column "" 6)" \
                    "$(pad_terminal_column "" 8)" \
                    "$(pad_terminal_column "" 16)" \
                    "$(pad_terminal_column "" 12)" \
                    "$url" "$status"
            fi
        done
    done
    return 0
}

route_entry_has_enabled_site() {
    local target_entry="$1" line port route_type entry
    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r port _ _ route_type entry _ _ <<< "$line"
        [[ "$route_type" == "site" && "$entry" == "$target_entry" ]] || continue
        is_route_disabled "$target_entry" "$port" || return 0
    done
    return 1
}

route_service_display_name() {
    local name="$1"
    case "$name" in
        st) printf 'SillyTavern' ;;
        couchdb) printf 'CouchDB' ;;
        mihomo) printf 'Mihomo' ;;
        reader) printf '阅读' ;;
        hermes) printf 'Hermes' ;;
        *) printf '%s' "$name" ;;
    esac
}

pad_terminal_column() {
    local value="$1" width="$2" display_width spaces
    display_width="$(printf '%s' "$value" | wc -L | tr -d '[:space:]')"
    [[ "$display_width" =~ ^[0-9]+$ ]] || display_width=${#value}
    spaces=$((width - display_width))
    (( spaces < 1 )) && spaces=1
    printf '%s%*s' "$value" "$spaces" ''
}

html_escape() {
    local value="${1:-}"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&#39;}"
    printf '%s' "$value"
}

validate_route_table() {
    load_routes
    local line port name backend route_type entry path nav
    local line_no=0
    local -a seen_ports=() seen_entry_routes=()
    local key item

    for line in "${ROUTES[@]}"; do
        line_no=$((line_no + 1))
        IFS='|' read -r port name backend route_type entry path nav <<< "$line"
        valid_port "$port" || { error "路由表第 ${line_no} 行端口无效: ${port}"; return 1; }
        [[ -n "$name" && "$name" != *'|'* ]] || { error "路由表第 ${line_no} 行服务名称无效"; return 1; }
        [[ "$backend" == "127.0.0.1:${port}" ]] || { error "路由表第 ${line_no} 行后端地址无效: ${backend}"; return 1; }
        [[ "$route_type" == "site" || "$route_type" == "path" ]] || { error "路由表第 ${line_no} 行映射类型无效: ${route_type}"; return 1; }
        if [[ "$entry" != "ip" ]] && ! valid_route_entry "$entry"; then
            error "路由表第 ${line_no} 行入口无效: ${entry}"
            return 1
        fi
        [[ "$nav" == "yes" || "$nav" == "no" ]] || { error "路由表第 ${line_no} 行导航状态无效: ${nav}"; return 1; }
        if [[ "$route_type" == "site" ]]; then
            [[ "$path" == "/" ]] || { error "独立域名路径必须是 /（第 ${line_no} 行）"; return 1; }
            key="${entry}|site"
        else
            valid_route_path "$path" || { error "子路径格式无效（第 ${line_no} 行）"; return 1; }
            key="${entry}|path|${path}"
        fi
        for item in "${seen_ports[@]}"; do
            [[ "$item" == "$port" ]] && { error "端口 ${port} 在路由表中重复"; return 1; }
        done
        seen_ports+=("$port")
        for item in "${seen_entry_routes[@]}"; do
            if [[ "$item" == "$key" || "$item" == "${entry}|site" || "$key" == "${entry}|site" && "$item" == "${entry}|path|"* ]]; then
                error "入口 ${entry} 存在冲突映射"
                return 1
            fi
        done
        seen_entry_routes+=("$key")
    done
}

write_route_navigation() {
    local target="$1"
    local cards="" line port name backend route_type entry path nav url
    local safe_name safe_url safe_path disabled_entries route_entry_item access_entry
    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r port name backend route_type entry path nav <<< "$line"
        [[ "$nav" == "yes" ]] || continue
        safe_name="$(html_escape "$name")"
        if [[ "$route_type" == "path" ]]; then
            safe_path="$(html_escape "$path")"
            disabled_entries=""
            load_route_entries
            for route_entry_item in "${ROUTE_ENTRIES[@]}"; do
                access_entry="${route_entry_item%%|*}"
                if is_route_disabled "$access_entry" "$port"; then
                    disabled_entries+="${disabled_entries:+,}${access_entry}"
                fi
            done
            cards+="        <div class=\"card route-card\" data-disabled=\"${disabled_entries}\">
          <div class=\"card-title\">${safe_name}</div>
          <div class=\"card-links\"><a href=\"${safe_path}\" data-route-path=\"${safe_path}\" class=\"link\">${safe_path}</a></div>
        </div>
"
            continue
        fi
        is_route_disabled "$entry" "$port" && continue
        url="$(route_url "$route_type" "$entry" "$path")"
        safe_url="$(html_escape "$url")"
        cards+="        <div class=\"card\">
          <div class=\"card-title\">${safe_name}</div>
          <div class=\"card-links\"><a href=\"${safe_url}\" class=\"link\">${safe_url}</a></div>
        </div>
"
    done
    [[ -n "$cards" ]] || cards='        <div class="card"><div class="card-title">暂无已启用映射</div></div>'
    write_nav_html "$target" "https://localhost" "$cards" --raw
}

write_route_caddyfile() {
    local target="$1"
    local include_logs="${2:-yes}"
    local ip line port name backend route_type entry path nav actual_entry
    local item current_entry cert_file key_file strip_path domain_cert_file domain_key_file
    local -a entries=()

    ip="$(configured_ip_from_caddyfile)"
    load_domain_certs
    local domain
    for domain in "${DOMAIN_CERTS[@]}"; do
        local domain_exists=0
        for item in "${entries[@]}"; do
            [[ "$item" == "$domain" ]] && domain_exists=1 && break
        done
        [[ "$domain_exists" -eq 0 ]] && entries+=("$domain")
    done
    load_cloudflare_domains
    for domain in "${CLOUDFLARE_DOMAINS[@]}"; do
        local cloudflare_domain_exists_in_entries=0
        for item in "${entries[@]}"; do
            [[ "$item" == "$domain" ]] && cloudflare_domain_exists_in_entries=1 && break
        done
        [[ "$cloudflare_domain_exists_in_entries" -eq 0 ]] && entries+=("$domain")
    done
    # 域名 TLS 策略必须排在 :443 默认 IP 证书之前，否则域名会误用 IP 证书。
    [[ -n "$ip" ]] && entries+=("ip")

    load_routes
    for line in "${ROUTES[@]}"; do
        IFS='|' read -r port name backend route_type entry path nav <<< "$line"
        [[ "$route_type" == "site" ]] || continue
        local exists=0
        for item in "${entries[@]}"; do
            [[ "$item" == "$entry" ]] && exists=1 && break
        done
        [[ "$exists" -eq 0 ]] && entries+=("$entry")
    done

    cat > "$target" <<'CADDYEOF'
# Caddy 统一路由配置 - 由 setup.sh 自动生成，请勿直接修改
:80 {
    @acme path /.well-known/acme-challenge/*
    handle @acme {
        root * /var/www/html
        file_server
    }
    handle {
        redir https://{host}{uri} permanent
    }
}
CADDYEOF

    [[ -n "$ip" ]] && printf '\n# 公网 IP: %s\n' "$ip" >> "$target"

    for current_entry in "${entries[@]}"; do
        actual_entry="$current_entry"
        if [[ "$current_entry" == "ip" ]]; then
            if [[ -z "$ip" ]]; then
                error "路由表使用了公网 IP 证书入口，但 ${IP_CERT_STATE_FILE} 没有有效记录"
                return 1
            fi
            # 数字 IP 客户端可能不发送 SNI；使用 :443 作为默认 TLS 入口。
            # 域名请求仍会根据 SNI 匹配各自的域名站点块。
            actual_entry=":443"
            cert_file="${HOME}/.acme.sh/${ip}_ecc/fullchain.cer"
            key_file="${HOME}/.acme.sh/${ip}_ecc/${ip}.key"
            if [[ ! -s "$cert_file" || ! -s "$key_file" ]]; then
                error "公网 IP 证书文件不存在，请先运行功能 2：${ip}"
                return 1
            fi
        fi

        printf '\n%s {\n' "$actual_entry" >> "$target"
        if [[ "$current_entry" == "ip" ]]; then
            printf '    tls %s %s\n' "$cert_file" "$key_file" >> "$target"
        elif domain_cert_exists "$current_entry"; then
            domain_cert_file="${HOME}/.acme.sh/${current_entry}_ecc/fullchain.cer"
            domain_key_file="${HOME}/.acme.sh/${current_entry}_ecc/${current_entry}.key"
            if [[ ! -s "$domain_cert_file" || ! -s "$domain_key_file" ]]; then
                error "域名 ${current_entry} 已登记，但证书文件不存在，请先运行功能 3 重新配置"
                return 1
            fi
            printf '    tls %s %s\n' "$domain_cert_file" "$domain_key_file" >> "$target"
        fi

        local has_active_site=0
        for line in "${ROUTES[@]}"; do
            IFS='|' read -r port name backend route_type entry path nav <<< "$line"
            [[ "$entry" == "$current_entry" && "$route_type" == "site" ]] || continue
            is_route_disabled "$current_entry" "$port" || has_active_site=1
        done

        for line in "${ROUTES[@]}"; do
            IFS='|' read -r port name backend route_type entry path nav <<< "$line"
            if [[ "$route_type" == "site" ]]; then
                [[ "$entry" == "$current_entry" ]] || continue
                is_route_disabled "$current_entry" "$port" && continue
                cat >> "$target" <<ROUTE
    reverse_proxy ${backend} {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-For {remote_host}
    }
ROUTE
            else
                [[ "$has_active_site" -eq 0 ]] || continue
                is_route_disabled "$current_entry" "$port" && continue
                strip_path="${path%/}"
                cat >> "$target" <<ROUTE
    redir ${strip_path} ${path} 308
    handle_path ${path}* {
        reverse_proxy ${backend} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-For {remote_host}
        }
    }
ROUTE
            fi
        done

        if [[ "$has_active_site" -eq 0 ]]; then
            cat >> "$target" <<'ROUTE'
    handle / {
        root * /var/www/html
        file_server
    }
ROUTE
        fi
        if [[ "$include_logs" == "yes" ]]; then
            cat >> "$target" <<'ROUTE'
    log {
        output file /var/log/caddy/access.log {
            roll_size 50mb
            roll_keep 3
        }
    }
ROUTE
        fi
        cat >> "$target" <<'ROUTE'
}
ROUTE
    done
}

generate_route_config() {
    print_subsection_title "生成 Caddy 配置 / 网站首页"
    bootstrap_routes_from_legacy
    if ! command_exists caddy; then
        error "未安装 Caddy，请先运行功能 1 初始化环境"
        return 1
    fi
    validate_route_table || return 1
    prune_disabled_routes

    mkdir -p /etc/caddy /var/www/html /var/log/caddy
    local caddy_tmp html_tmp stamp
    caddy_tmp="$(mktemp /etc/caddy/.Caddyfile.route.XXXXXX)"
    html_tmp="$(mktemp /var/www/html/.index.route.XXXXXX)"
    if ! write_route_caddyfile "$caddy_tmp" no || ! write_route_navigation "$html_tmp"; then
        rm -f "$caddy_tmp" "$html_tmp"
        return 1
    fi
    caddy fmt --overwrite "$caddy_tmp" >/dev/null 2>&1 || true
    if ! caddy validate --config "$caddy_tmp" --adapter caddyfile; then
        rm -f "$caddy_tmp" "$html_tmp"
        error "新配置校验失败，现有 Caddyfile 和网站首页均未修改"
        return 1
    fi
    if ! write_route_caddyfile "$caddy_tmp" yes; then
        rm -f "$caddy_tmp" "$html_tmp"
        return 1
    fi
    caddy fmt --overwrite "$caddy_tmp" >/dev/null 2>&1 || true

    stamp="$(date +%Y%m%d%H%M%S)"
    local caddy_backup="/etc/caddy/Caddyfile.bak.${stamp}"
    local html_backup="/var/www/html/index.html.bak.${stamp}"
    local had_caddy=0 had_html=0
    if [[ -f /etc/caddy/Caddyfile ]]; then
        cp -a /etc/caddy/Caddyfile "$caddy_backup"
        had_caddy=1
    fi
    if [[ -f /var/www/html/index.html ]]; then
        cp -a /var/www/html/index.html "$html_backup"
        had_html=1
    fi
    chmod 644 "$caddy_tmp" "$html_tmp"
    mv "$caddy_tmp" /etc/caddy/Caddyfile
    mv "$html_tmp" /var/www/html/index.html
    if ! reload_caddy; then
        warn "新配置未能启动，正在恢复更新前的文件"
        [[ "$had_caddy" -eq 1 ]] && cp -a "$caddy_backup" /etc/caddy/Caddyfile
        [[ "$had_html" -eq 1 ]] && cp -a "$html_backup" /var/www/html/index.html
        reload_caddy || true
        error "更新失败，已恢复原 Caddyfile 和网站首页"
        return 1
    fi
    info "已根据 ${ROUTES_STATE_FILE} 更新 Caddy 路由和网站首页"
    info "关闭项已从路由规则和网站首页中隐藏"
}

# ---- IP 模式：添加子路径 ----
add_custom_routes() {
    local custom_dir="/etc/caddy/routes-custom.d"
    mkdir -p "$custom_dir"

    # 确保 Caddyfile 有 import 行，没有则自动添加
    if ! grep -q "routes-custom.d" /etc/caddy/Caddyfile 2>/dev/null; then
        sed -i '/^    handle \/ {/i\    import /etc/caddy/routes-custom.d/*.conf' /etc/caddy/Caddyfile
    fi

    echo ""
    echo "  添加/删除子路径"
    echo "  多个服务共用一个 IP 或域名，通过 /name/ 区分。"

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

        load_removed_services

        # 预配置服务（未删除的默认服务）
        for svc in "${base_services[@]}"; do
            IFS='|' read -r p h port _ <<< "$svc"
            [[ -z "$h" ]] && h="127.0.0.1"
            local _name="${p//\//}"
            [[ -z "$_name" ]] && continue
            is_service_removed "$p" && continue
            list_items+=("${p} → ${h}:${port}")
            delete_names+=("$p")
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
            local del_val="${delete_names[$idx]}"
            if [[ "$del_val" == /*/ ]]; then
                # 默认服务 — 标记为已删除并从 Caddyfile 移除
                echo "$del_val" >> /etc/caddy/.services-removed.conf
                REMOVED_SERVICES+=("$del_val")
                local strip_path="${del_val%/}"
                local escaped_path
                escaped_path=$(printf '%s\n' "$strip_path" | sed 's/[\/&]/\\&/g')
                sed -i "/^    # ${escaped_path} →/,/^    }/d" /etc/caddy/Caddyfile
                info "已删除默认服务: ${strip_path}"
                caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                rebuild_nav_ip
                reload_caddy
            else
                # 自定义服务 — 删除配置文件
                rm "${custom_dir}/${del_val}.conf"
                info "已删除: /${del_val}/"
                rebuild_nav_ip
                reload_caddy
            fi
            continue
        fi

        error "输入无效，请输入序号、回车或 0"
    done

    [[ "$changed" == "true" ]] && { rebuild_nav_ip; reload_caddy; }
}

# ---- 收集完整服务列表（默认+自定义-已删除）----
collect_all_services() {
    local custom_dir="/etc/caddy/routes-custom.d"
    load_removed_services

    if [[ -f /etc/caddy/.services.conf ]]; then
        mapfile -t ALL_SERVICES < /etc/caddy/.services.conf
    else
        ALL_SERVICES=("${DEFAULT_SERVICES[@]}")
    fi

    # 过滤已删除的默认服务
    local -a filtered=()
    for svc in "${ALL_SERVICES[@]}"; do
        IFS='|' read -r p _ _ _ <<< "$svc"
        is_service_removed "$p" && continue
        filtered+=("$svc")
    done
    ALL_SERVICES=("${filtered[@]}")

    # 添加自定义服务（IP 模式路由 + 域名模式子域名）
    local name port
    for f in /etc/caddy/routes-custom.d/*.conf /etc/caddy/subdomains.d/*.conf; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .conf)
        port=$(grep -oP ':\K\d+' "$f" 2>/dev/null | head -1 || true)
        [[ -n "$port" ]] && ALL_SERVICES+=("/${name}/|127.0.0.1|${port}|")
    done
}

rebuild_nav_ip() {
    local html="/var/www/html/index.html"
    local base_url="https://${PUBLIC_IP}"
    mkdir -p /var/www/html
    collect_all_services
    write_nav_html "$html" "$base_url" "${ALL_SERVICES[@]}"
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

    # 确保 Caddyfile 有 import 子域名目录（追加到文件末尾，必须在 site block 之外）
    if ! grep -q "subdomains.d" "$caddyfile" 2>/dev/null; then
        echo "" >> "$caddyfile"
        echo "# 子域名（自动引入）" >> "$caddyfile"
        echo "import /etc/caddy/subdomains.d/*.conf" >> "$caddyfile"
    fi

    echo ""
    echo "  添加/删除独立域名"
    echo "  给一个服务单独分配一个域名。"

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

        load_removed_services

        # 预配置服务（未删除的默认服务）
        for svc in "${base_services[@]}"; do
            IFS='|' read -r p h port _ <<< "$svc"
            [[ -z "$h" ]] && h="127.0.0.1"
            local _name="${p//\//}"
            [[ -z "$_name" ]] && continue
            is_service_removed "$p" && continue
            list_items+=("https://${DOMAIN}${p} → ${h}:${port}")
            delete_names+=("$p")
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
            local del_val="${delete_names[$idx]}"
            if [[ "$del_val" == /*/ ]]; then
                # 默认服务 — 标记为已删除并从 Caddyfile 移除
                echo "$del_val" >> /etc/caddy/.services-removed.conf
                REMOVED_SERVICES+=("$del_val")
                local strip_path="${del_val%/}"
                local escaped_path
                escaped_path=$(printf '%s\n' "$strip_path" | sed 's/[\/&]/\\&/g')
                sed -i "/^    # ${escaped_path} →/,/^    }/d" /etc/caddy/Caddyfile
                info "已删除默认服务: ${strip_path}"
                caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                rebuild_nav_domain "$domain"
                reload_caddy
            else
                rm "${sub_dir}/${del_val}.conf"
                info "已删除: ${del_val}.${DOMAIN}"
                rebuild_nav_domain "$domain"
                reload_caddy
            fi
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

    load_removed_services
    if [[ -f /etc/caddy/.services.conf ]]; then
        mapfile -t all_services < /etc/caddy/.services.conf
    else
        for svc in "${DEFAULT_SERVICES[@]}"; do
            all_services+=("$svc")
        done
    fi

    # 过滤已删除的默认服务
    local -a filtered=()
    for svc in "${all_services[@]}"; do
        IFS='|' read -r p _ _ _ <<< "$svc"
        is_service_removed "$p" && continue
        filtered+=("$svc")
    done
    all_services=("${filtered[@]}")

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
        local extra_links=""
        if [[ "$stype" == "subdomain" ]]; then
            # 子域名入口
            url="https://${name}.${domain}/"
            note=" <span style=\"color:#22d3ee;font-size:0.7rem;\">[子域名]</span>"
        else
            url="${base_url}${p}"
            if [[ "$name" == "st" ]]; then
                name="SillyTavern"
                extra_links=" <span style=\"color:#f87171;font-size:0.75rem;\">（CSS 错乱）</span><br><a href=\"http://${base_url#https://}:${port}/\" class=\"link\" target=\"_blank\">http://${base_url#https://}:${port}/</a> <span style=\"color:#10b981;font-size:0.75rem;\">（CSS 正常）</span>"
            elif [[ "$name" == "couchdb" ]]; then
                extra_links="<br><span style=\"color:#94a3b8;font-size:0.75rem;\">控制台: </span><a href=\"${base_url}/couchdb/_utils/\" class=\"link\" target=\"_blank\">${base_url}/couchdb/_utils/</a>"
            fi
        fi

        cards+="        <div class=\"card\">
          <div class=\"card-title\">${name}${note}</div>
          <div class=\"card-links\"><a href=\"${url}\" class=\"link\">${url}</a>${extra_links}</div>
        </div>
"
    done

    write_nav_html "$html" "$base_url" "$cards" --raw
    info "导航页已更新"
}

write_nav_html() {
    local file="$1"
    local base="$2"
    local raw_host="${base#https://}"
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
            local extra_links=""
            if [[ "$name" == "st" ]]; then
                name="SillyTavern"
                extra_links=" <span style=\"color:#f87171;font-size:0.75rem;\">（CSS 错乱）</span><br><a href=\"http://${raw_host}:${port}/\" class=\"link\" target=\"_blank\">http://${raw_host}:${port}/</a> <span style=\"color:#10b981;font-size:0.75rem;\">（CSS 正常）</span>"
            elif [[ "$name" == "couchdb" ]]; then
                extra_links="<br><span style=\"color:#94a3b8;font-size:0.75rem;\">控制台: </span><a href=\"${base}/couchdb/_utils/\" class=\"link\" target=\"_blank\">${base}/couchdb/_utils/</a>"
            fi
            cards_content+="        <div class=\"card\">
          <div class=\"card-title\">${name}${note}</div>
          <div class=\"card-links\"><a href=\"${base}${p}\" class=\"link\">${base}${p}</a>${extra_links}</div>
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
<title>我的导航</title>
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
<script>
(() => {
  const currentKey = location.hostname;
  document.querySelectorAll('[data-route-path]').forEach((link) => {
    const path = link.dataset.routePath;
    const url = location.origin + path;
    link.href = url;
    link.textContent = url;
  });
  document.querySelectorAll('.route-card[data-disabled]').forEach((card) => {
    const disabled = card.dataset.disabled.split(',').filter(Boolean);
    const ipKey = /^\d+\.\d+\.\d+\.\d+$/.test(currentKey) ? 'ip' : currentKey;
    if (disabled.includes(ipKey)) card.remove();
  });
})();
</script>
</body>
</html>
HTML
}

reload_caddy() {
    info "重载 Caddy..."
    # 确保日志目录权限正确
    mkdir -p /var/log/caddy
    if id -u caddy &>/dev/null; then
        chown -R caddy:caddy /var/log/caddy 2>/dev/null || true
    fi

    ensure_caddy_root

    if command -v systemctl &>/dev/null && systemctl is-active caddy &>/dev/null; then
        if systemctl reload caddy 2>&1; then
            info "Caddy 重载完成"
            return 0
        fi
        warn "Caddy reload 失败，尝试受控重启..."
        if systemctl restart caddy 2>&1 && systemctl is-active caddy &>/dev/null; then
            info "Caddy 重启完成"
            return 0
        fi
        error "Caddy 重载和受控重启均失败，请检查: journalctl -u caddy -n 50"
        return 1
    else
        if caddy reload --config /etc/caddy/Caddyfile 2>&1; then
            info "Caddy 重载完成"
            return 0
        fi
        warn "caddy reload 失败，尝试启动受管服务..."
        if command -v systemctl &>/dev/null && systemctl cat caddy.service &>/dev/null 2>&1 && systemctl start caddy 2>&1 && systemctl is-active caddy &>/dev/null; then
            info "Caddy 启动完成"
            return 0
        fi
        error "Caddy 启动失败，请手动检查"
        return 1
    fi
}

# ---- 已删除默认服务管理 ----
load_removed_services() {
    REMOVED_SERVICES=()
    if [[ -f /etc/caddy/.services-removed.conf ]]; then
        mapfile -t REMOVED_SERVICES < /etc/caddy/.services-removed.conf
    fi
}

is_service_removed() {
    local path="$1"
    for r in "${REMOVED_SERVICES[@]}"; do
        [[ "$r" == "$path" ]] && return 0
    done
    return 1
}

status_caddy_init() {
    collect_missing_basic_deps

    local missing=0
    [[ ${#MISSING_BASIC_DEPS[@]} -gt 0 ]] && missing=1
    command_exists caddy || missing=1
    [[ -f "${HOME}/.acme.sh/acme.sh" ]] || missing=1

    if [[ "$missing" -eq 0 ]]; then
        printf '已完成'
    elif command_exists caddy || [[ -f "${HOME}/.acme.sh/acme.sh" ]]; then
        printf '部分缺失'
    else
        printf '未初始化'
    fi
}

init_environment_is_complete() {
    collect_missing_basic_deps
    [[ ${#MISSING_BASIC_DEPS[@]} -eq 0 ]] || return 1
    command_exists caddy || return 1
    [[ -f "${HOME}/.acme.sh/acme.sh" ]] || return 1
    return 0
}

configured_ip_from_caddyfile() {
    if [[ -f "$IP_CERT_STATE_FILE" ]]; then
        head -1 "$IP_CERT_STATE_FILE" 2>/dev/null || true
        return
    fi
    local ip
    ip="$(grep -oP '^# 公网 IP: \K.*' /etc/caddy/Caddyfile 2>/dev/null | head -1 || true)"
    if [[ -z "$ip" ]]; then
        ip="$(grep -oP 'tls[[:space:]]+\S*/\K(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?=_ecc/fullchain\.cer)' /etc/caddy/Caddyfile 2>/dev/null | head -1 || true)"
    fi
    printf '%s' "$ip"
}

configured_domain_from_caddyfile() {
    if [[ -f "$DOMAIN_CERT_STATE_FILE" ]]; then
        head -1 "$DOMAIN_CERT_STATE_FILE" 2>/dev/null || true
        return
    fi
    grep -oP '^# 域名: \K.*' /etc/caddy/Caddyfile 2>/dev/null | head -1 || true
}

load_domain_certs() {
    DOMAIN_CERTS=()
    if [[ -f "$DOMAIN_CERT_STATE_FILE" ]]; then
        mapfile -t DOMAIN_CERTS < <(sed '/^[[:space:]]*$/d' "$DOMAIN_CERT_STATE_FILE" | sort -u)
    else
        local legacy_domain
        legacy_domain="$(grep -oP '^# 域名: \K.*' /etc/caddy/Caddyfile 2>/dev/null | head -1 || true)"
        [[ -n "$legacy_domain" ]] && DOMAIN_CERTS=("$legacy_domain")
    fi
    return 0
}

save_domain_certs() {
    mkdir -p /etc/caddy
    if [[ ${#DOMAIN_CERTS[@]} -eq 0 ]]; then
        rm -f "$DOMAIN_CERT_STATE_FILE"
        return 0
    fi
    printf '%s\n' "${DOMAIN_CERTS[@]}" | sed '/^[[:space:]]*$/d' | sort -u > "$DOMAIN_CERT_STATE_FILE"
}

domain_cert_exists() {
    local target="$1" item
    load_domain_certs
    for item in "${DOMAIN_CERTS[@]}"; do
        [[ "$item" == "$target" ]] && return 0
    done
    return 1
}

status_ip_cert() {
    local ip cert
    ip="$(configured_ip_from_caddyfile)"
    if [[ -z "$ip" ]]; then
        printf '未配置'
        return
    fi
    cert="${HOME}/.acme.sh/${ip}_ecc/fullchain.cer"
    if [[ -f "$cert" ]] && openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then
        printf '有效: %s' "$ip"
    else
        printf '已过期: %s' "$ip"
    fi
}

show_current_ip_cert() {
    local current_ip
    current_ip="$(configured_ip_from_caddyfile)"
    if [[ -n "$current_ip" ]]; then
        info "当前证书 IP: ${current_ip}"
    else
        info "当前证书 IP: 无"
    fi
}

ip_cert_tool_status() {
    if [[ -f "${HOME}/.acme.sh/acme.sh" ]]; then
        info "acme.sh 已安装"
    else
        warn "acme.sh 未安装，请安装"
    fi

    if command -v caddy &>/dev/null; then
        info "Caddy 已安装"
    else
        warn "Caddy 未安装，请安装"
    fi
}

status_domain_cert() {
    load_domain_certs
    if [[ ${#DOMAIN_CERTS[@]} -gt 0 ]]; then
        printf '已配置 %d 个' "${#DOMAIN_CERTS[@]}"
    else
        printf '未配置'
    fi
}

show_current_domain_cert() {
    load_domain_certs
    if [[ ${#DOMAIN_CERTS[@]} -gt 0 ]]; then
        info "当前域名证书:"
        local domain
        for domain in "${DOMAIN_CERTS[@]}"; do
            echo "  - ${domain}"
        done
    else
        info "当前域名证书: 无"
    fi
}

# ============================================================
# 初始化环境
# ============================================================
repair_init_environment() {
    check_root
    install_deps
    install_acme
    install_caddy
    ensure_caddy_root
    ensure_base_caddyfile

    if command_exists systemctl && systemctl cat caddy.service &>/dev/null; then
        systemctl enable caddy 2>/dev/null || true
        systemctl start caddy 2>/dev/null || true
    fi

    info "初始化环境完成"
}

show_init_menu() {
    print_section_title "1 初始化环境"
    echo ""
    echo "  1  自动检测网络并匹配下载源"
    echo "  2  更新全部依赖"
    echo "  3  下载修复"
    echo "  0  返回主菜单"
    echo ""
    echo -n "  请输入 [1/2/3/0]: "
}

mode_init_environment() {
    if init_environment_is_complete; then
        info "基础环境已完成，跳过自动补装"
    else
        repair_init_environment
    fi

    while true; do
        show_init_menu
        if tty -s; then
            read -r INIT_CHOICE </dev/tty || { info "已返回主菜单" ; return 0; }
        else
            info "未检测到交互终端，已返回主菜单"
            return 0
        fi
        echo ""

        case "$INIT_CHOICE" in
            1) detect_download_source ;;
            2) upgrade_all_deps ;;
            3) repair_apt_downloads ;;
            0) info "已返回主菜单" ; return 0 ;;
            *) error "无效选项，请输入 1、2、3 或 0" ;;
        esac
    done
}

update_ip_cert() {
    check_root
    mkdir -p /etc/caddy
    ip_cert_tool_status
    if [[ ! -f "${HOME}/.acme.sh/acme.sh" ]]; then
        install_acme
    fi
    if command -v caddy &>/dev/null; then
        ensure_caddy_root
    else
        install_caddy
    fi

    local old_ip
    old_ip="$(configured_ip_from_caddyfile)"
    if [[ -n "$old_ip" ]]; then
        info "当前证书 IP: ${old_ip}"
    else
        info "当前证书 IP: 无"
    fi

    detect_ip --quiet
    info "当前公网 IP: ${PUBLIC_IP}"
    prompt_ip

    if [[ -n "$old_ip" ]]; then
        info "发现已有 IP 证书配置: ${old_ip}，将删除后重新创建"
        remove_ip_cert_files "$old_ip"
    else
        info "未发现已有 IP 证书配置，将直接新建"
    fi
    remove_ip_cert_renew_task

    start_temp_caddy
    issue_ip_cert
    stop_temp_caddy
    restore_caddy_after_challenge
    setup_cron_renew_acme
    printf '%s\n' "$PUBLIC_IP" > "$IP_CERT_STATE_FILE"

    info "公网 IP 证书已完成: ${PUBLIC_IP}"
    info "证书文件: ${CERT_FILE}"
    info "服务路由和网站首页请进入「域名 / SSL 证书 / 导航页」中的「服务访问与导航页管理」配置"
}

delete_current_ip_cert() {
    check_root

    local current_ip
    current_ip="$(configured_ip_from_caddyfile)"
    if [[ -z "$current_ip" ]]; then
        warn "未发现当前 IP 证书配置"
    else
        remove_ip_cert_files "$current_ip"
    fi
    rm -f "$IP_CERT_STATE_FILE"
    remove_ip_cert_renew_task
    warn "已删除当前 IP 证书及自动拉取任务；如 Caddyfile 仍引用旧证书，请重新配置 IP 证书或切换域名模式"
}

show_ip_cert_menu() {
    echo ""
    echo "  1  新建/更改当前公网 IP 证书"
    echo "  2  删除当前证书及自动拉取任务"
    echo "  0  返回上级菜单"
    echo ""
    echo -n "  请输入 [1/2/0]: "
}

# ============================================================
# 模式 1: IP 证书
# ============================================================
mode_ip() {
    check_root
    print_child_page_title "2.1 配置公网 IP 证书"
    install_deps
    show_current_ip_cert

    while true; do
        show_ip_cert_menu
        if tty -s; then
            read -r IP_CHOICE </dev/tty || { info "已返回上级菜单" ; return 0; }
        else
            info "未检测到交互终端，已返回上级菜单"
            return 0
        fi
        echo ""

        case "$IP_CHOICE" in
            1) update_ip_cert ;;
            2) delete_current_ip_cert ;;
            0) info "已返回上级菜单" ; return 0 ;;
            *) error "无效选项，请输入 1、2 或 0" ;;
        esac
    done
}

# ============================================================
# 模式 2: 域名证书
# ============================================================
update_domain_cert() {
    check_root
    mkdir -p /etc/caddy
    ip_cert_tool_status
    if [[ ! -f "${HOME}/.acme.sh/acme.sh" ]]; then
        install_acme
    fi
    if command -v caddy &>/dev/null; then
        ensure_caddy_root
    else
        install_caddy
    fi

    DOMAIN=""
    prompt_domain

    if domain_cert_exists "$DOMAIN"; then
        warn "域名证书已登记，将重新申请并覆盖证书文件: ${DOMAIN}"
    else
        info "将新增域名证书: ${DOMAIN}"
    fi

    start_temp_caddy
    issue_domain_cert
    stop_temp_caddy
    restore_caddy_after_challenge
    setup_cron_renew_acme

    load_domain_certs
    DOMAIN_CERTS+=("$DOMAIN")
    save_domain_certs

    info "域名证书已完成: ${DOMAIN}"
    info "证书文件: ${CERT_FILE}"
    info "服务路由和网站首页请进入「域名 / SSL 证书 / 导航页」中的「服务访问与导航页管理」配置"
}

delete_domain_cert() {
    check_root

    load_domain_certs
    if [[ ${#DOMAIN_CERTS[@]} -eq 0 ]]; then
        warn "未发现当前域名证书配置"
        return
    fi

    echo ""
    echo "  当前域名证书:"
    local i
    for i in "${!DOMAIN_CERTS[@]}"; do
        printf "  %2d. %s\n" $((i+1)) "${DOMAIN_CERTS[$i]}"
    done
    echo ""
    echo -n "  输入序号删除，0 返回: "
    local input
    read -r input </dev/tty 2>/dev/null || true
    if [[ "$input" == "0" || -z "$input" ]]; then
        info "已取消删除域名证书"
        return 0
    fi
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        error "无效序号"
        return 0
    fi

    local idx=$((10#$input - 1))
    if [[ $idx -lt 0 || $idx -ge ${#DOMAIN_CERTS[@]} ]]; then
        error "无效序号"
        return 0
    fi

    local del_domain="${DOMAIN_CERTS[$idx]}"
    remove_domain_cert_files "$del_domain"
    unset 'DOMAIN_CERTS[idx]'
    DOMAIN_CERTS=("${DOMAIN_CERTS[@]}")
    save_domain_certs

    warn "如 Caddyfile 仍引用旧域名，请进入「服务访问与导航页管理」重新生成或修改配置"
}

show_domain_cert_menu() {
    echo ""
    echo "  1  新增/重新申请域名证书"
    echo "  2  查看/删除域名证书"
    echo "  0  返回上级菜单"
    echo ""
    echo -n "  请输入 [1/2/0]: "
}

mode_domain() {
    check_root
    print_child_page_title "2.2 配置域名证书"
    install_deps
    show_current_domain_cert

    while true; do
        show_domain_cert_menu
        if tty -s; then
            read -r DOMAIN_CHOICE </dev/tty || { info "已返回上级菜单" ; return 0; }
        else
            info "未检测到交互终端，已返回上级菜单"
            return 0
        fi
        echo ""

        case "$DOMAIN_CHOICE" in
            1) update_domain_cert ;;
            2) delete_domain_cert ;;
            0) info "已返回上级菜单" ; return 0 ;;
            *) error "无效选项，请输入 1、2 或 0" ;;
        esac
    done
}

# ============================================================
# 模式 4: 生成导航页内容
# ============================================================
mode_regenerate_nav() {
    print_section_title "生成导航页内容"
    local caddyfile="/etc/caddy/Caddyfile"
    if [[ ! -f "$caddyfile" ]]; then
        error "未找到 Caddyfile，请先运行模式 1 或 2"
        return 1
    fi

    parse_services
    local base_url
    local domain
    domain="$(configured_domain_from_caddyfile)"
    if [[ -n "$domain" ]]; then
        base_url="https://${domain}"
    else
        local ip
        ip="$(configured_ip_from_caddyfile)"
        if [[ -n "$ip" ]]; then
            base_url="https://${ip}"
        else
            detect_ip
            base_url="https://${PUBLIC_IP}"
        fi
    fi

    gen_root_html "$base_url"
    info "导航页内容已生成: ${base_url}"
}

# ============================================================
# 菜单
# ============================================================
show_access_menu() {
    print_section_title "2 域名 / SSL 证书 / 导航页"
    echo ""
    echo -e "${TITLE_YELLOW}  说明:${NC}"
    echo -e "${TITLE_YELLOW}  本模块用于帮你：Ⅰ. 搞个域名（网址）；Ⅱ. 搞个主页。${NC}"
    echo ""
    echo -e "${TITLE_YELLOW}  1. 个人服务器建议直接使用公网 IP 证书，无需专门购买或申请域名，也能满足许多必须${NC}"
    echo -e "${TITLE_YELLOW}     使用 HTTPS 连接的场景。请使用【1】配置公网 IP 证书。${NC}"
    echo ""
    echo -e "${TITLE_YELLOW}  2. 涉及少量对外分享时，建议使用域名证书；域名可以自行购买，也可以申请免费的二级域名。${NC}"
    echo -e "${TITLE_YELLOW}     请使用【2】配置域名证书。${NC}"
    echo ""
    echo -e "${TITLE_YELLOW}  3. 如涉及大量对外分享，可登录 Cloudflare 添加待管理域名，并按指引修改默认 DNS 服务器。${NC}"
    echo -e "${TITLE_YELLOW}     完成托管后，请在 Cloudflare 的 DNS 记录中确认代理状态为“已代理”（橙色云朵）。${NC}"
    echo -e "${TITLE_YELLOW}     Cloudflare 会维护域名证书并隐藏服务器真实 IP。请使用【3】配置服务网址及网站首页。${NC}"
    echo ""
    echo "  1  配置公网 IP 证书（$(status_ip_cert)）"
    echo "  2  配置域名证书（$(status_domain_cert)）"
    echo "  3  服务访问与导航页管理"
    echo "  0  返回主菜单"
    echo ""
    echo -n "  请输入 [1/2/3/0]: "
}

mode_access_menu() {
    while true; do
        show_access_menu
        local ACCESS_CHOICE
        if tty -s; then
            read -r ACCESS_CHOICE </dev/tty || { info "已返回主菜单" ; return 0; }
        else
            info "未检测到交互终端，已返回主菜单"
            return 0
        fi
        echo ""

        case "$ACCESS_CHOICE" in
            1) mode_ip ;;
            2) mode_domain ;;
            3) mode_paired ;;
            0) info "已返回主菜单" ; return 0 ;;
            *) error "无效选项，请输入 1、2、3 或 0" ;;
        esac
    done
}

show_menu() {
    print_root_title
    echo ""
    echo "  请选择需要的功能:"
    echo ""
    echo "  1  初始化环境（$(status_caddy_init)）"
    echo "  2  域名 / SSL 证书 / 导航页"
    echo "  3  CPA 反代安装与管理"
    echo "  0  退出"
    echo ""
    echo -n "  请输入 [1/2/3/0]: "
}

# ============================================================
# Main
# ============================================================
main() {
    if [[ "${1:-}" == "cpa" ]]; then
        shift
        cpa_dispatch "${1:-menu}" "${@:2}"
        return $?
    fi
    runtime_preflight
    while true; do
        show_menu
        if tty -s; then
            read -r CHOICE </dev/tty || { info "已退出" ; exit 0; }
        else
            info "未检测到交互终端，已退出"
            exit 0
        fi
        echo ""

        case "$CHOICE" in
            1) mode_init_environment ;;
            2) mode_access_menu ;;
            3) cpa_menu ;;
            0|q|Q) info "已退出" ; exit 0 ;;
            *) error "无效选项，请输入 1、2 或 0" ;;
        esac
    done
}

main "$@"
