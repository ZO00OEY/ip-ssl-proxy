#!/usr/bin/env bash
# CLIProxyAPI lifecycle module.
# Sourcing this file only defines functions and defaults; it never installs,
# starts, stops, or edits a service.

CPA_INSTALL_DIR="${CPA_INSTALL_DIR:-/opt/cliproxyapi}"
CPA_CONFIG_DIR="${CPA_CONFIG_DIR:-/etc/cliproxyapi}"
CPA_DATA_DIR="${CPA_DATA_DIR:-/var/lib/cliproxyapi}"
CPA_AUTH_DIR="${CPA_AUTH_DIR:-${CPA_DATA_DIR}/auth-dir}"
CPA_BACKUP_ROOT="${CPA_BACKUP_ROOT:-/var/backups/ip-ssl-proxy/cpa}"
CPA_BINARY="${CPA_BINARY:-${CPA_INSTALL_DIR}/cli-proxy-api}"
CPA_UNIT="${CPA_UNIT:-cliproxyapi.service}"
CPA_USER_UNIT_DIR="${CPA_USER_UNIT_DIR:-/root/.config/systemd/user}"
CPA_UNIT_FILE="${CPA_USER_UNIT_DIR}/${CPA_UNIT}"
CPA_STATE_DIR="${CPA_STATE_DIR:-/etc/ip-ssl-proxy/cpa}"
CPA_STATE_FILE="${CPA_STATE_FILE:-${CPA_STATE_DIR}/state.env}"
CPA_PORT="${CPA_PORT:-8317}"
CPA_CADDYFILE="${CPA_CADDYFILE:-/etc/caddy/Caddyfile}"

cpa_paths() {
    CPA_CONFIG_FILE="${CPA_CONFIG_DIR}/config.yaml"
    CPA_UNIT_FILE="${CPA_USER_UNIT_DIR}/${CPA_UNIT}"
}

cpa_log_info() {
    if declare -F info >/dev/null 2>&1; then info "$*"; else printf '[INFO] %s\n' "$*" >&2; fi
}

cpa_log_warn() {
    if declare -F warn >/dev/null 2>&1; then warn "$*"; else printf '[WARN] %s\n' "$*" >&2; fi
}

cpa_log_error() {
    if declare -F error >/dev/null 2>&1; then error "$*"; else printf '[ERROR] %s\n' "$*" >&2; fi
}

cpa_require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || {
        cpa_log_error "CPA 管理需要 root 权限"
        return 1
    }
}

cpa_validate_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535))
}

cpa_config_scalar() {
    local key="$1" line value
    [[ -f "${CPA_CONFIG_FILE:-}" ]] || return 1
    line="$(grep -E "^[[:space:]]*${key}:[[:space:]]*" "$CPA_CONFIG_FILE" | head -n 1 || true)"
    [[ -n "$line" ]] || return 1
    value="${line#*:}"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    if [[ "$value" == \"*\" ]]; then value="${value#\"}"; value="${value%\"}"; fi
    if [[ "$value" == \'*\' ]]; then value="${value#\'}"; value="${value%\'}"; fi
    printf '%s\n' "$value"
}

cpa_resolve_auth_dir() {
    local configured
    configured="$(cpa_config_scalar auth-dir 2>/dev/null || true)"
    [[ -n "$configured" ]] || configured="$CPA_AUTH_DIR"
    if [[ "$configured" == ~/* ]]; then configured="/root/${configured#~/}"; fi
    [[ "$configured" == /* && "$configured" != *$'\n'* ]] || return 1
    CPA_AUTH_DIR="$configured"
    printf '%s\n' "$CPA_AUTH_DIR"
}

cpa_safe_path() {
    local path="${1:-}"
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *'..'* ]] || return 1
    case "$path" in
        /|/root|/etc|/var|/opt|/usr|/home|/tmp) return 1 ;;
    esac
    return 0
}

cpa_validate_layout() {
    local path
    for path in "$CPA_INSTALL_DIR" "$CPA_CONFIG_DIR" "$CPA_DATA_DIR" "$CPA_BACKUP_ROOT" "$CPA_STATE_DIR" "$CPA_USER_UNIT_DIR"; do
        cpa_safe_path "$path" || {
            cpa_log_error "CPA 路径过于宽泛或不安全: $path"
            return 1
        }
    done
}

cpa_actual_port() {
    local configured
    configured="$(cpa_config_scalar port 2>/dev/null || true)"
    [[ -n "$configured" ]] || configured="$CPA_PORT"
    cpa_validate_port "$configured" || return 1
    CPA_PORT="$((10#$configured))"
    printf '%s\n' "$CPA_PORT"
}

cpa_actual_host() {
    local configured
    configured="$(cpa_config_scalar host 2>/dev/null || true)"
    [[ -n "$configured" ]] || configured="127.0.0.1"
    printf '%s\n' "$configured"
}

cpa_upstream_addr() {
    local host port
    host="$(cpa_actual_host 2>/dev/null || printf '%s' '127.0.0.1')"
    port="$(cpa_actual_port 2>/dev/null || printf '%s' "$CPA_PORT")"
    [[ "$host" == "0.0.0.0" || "$host" == "::" || -z "$host" ]] && host="127.0.0.1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]:%s\n' "$host" "$port"
    else
        printf '%s:%s\n' "$host" "$port"
    fi
}

cpa_unit_is_ours() {
    local file="${1:-$CPA_UNIT_FILE}"
    [[ -f "$file" ]] || return 1
    grep -Fq "ExecStart=${CPA_BINARY} --config ${CPA_CONFIG_FILE}" "$file"
}

cpa_detect_external_install() {
    local unit_file
    cpa_paths
    for unit_file in "$CPA_USER_UNIT_DIR/$CPA_UNIT" "/etc/systemd/system/$CPA_UNIT"; do
        [[ -f "$unit_file" ]] || continue
        if ! cpa_unit_is_ours "$unit_file"; then
            printf '%s\n' "$unit_file"
            return 0
        fi
    done
    for unit_file in /root/cliproxyapi/cli-proxy-api /root/.cli-proxy-api/config.yaml /root/cliproxyapi/config.yaml; do
        [[ -e "$unit_file" ]] && { printf '%s\n' "$unit_file"; return 0; }
    done
    return 1
}

cpa_installed() {
    cpa_paths
    [[ -x "$CPA_BINARY" && -f "$CPA_CONFIG_FILE" ]] && cpa_unit_is_ours
}

cpa_user_systemctl() {
    local runtime="${XDG_RUNTIME_DIR:-}"
    command -v systemctl >/dev/null 2>&1 || {
        cpa_log_error "缺少 systemctl"
        return 1
    }
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        runtime=/run/user/0
    fi
    if [[ -n "$runtime" ]]; then
        XDG_RUNTIME_DIR="$runtime" systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

cpa_prepare_user_manager() {
    command -v systemctl >/dev/null 2>&1 || {
        cpa_log_error "缺少 systemctl"
        return 1
    }
    command -v loginctl >/dev/null 2>&1 || {
        cpa_log_error "缺少 loginctl"
        return 1
    }
    loginctl enable-linger root >/dev/null 2>&1 || {
        cpa_log_error "无法启用 root linger；不能保证退出 SSH 后服务继续运行"
        return 1
    }
    local runtime=/run/user/0
    if [[ ! -d "$runtime" ]]; then
        install -d -m 700 "$runtime" || {
            cpa_log_error "无法准备 XDG_RUNTIME_DIR: $runtime"
            return 1
        }
    fi
    XDG_RUNTIME_DIR="$runtime" systemctl --user daemon-reload
}

cpa_install_unit() {
    cpa_paths
    cpa_resolve_auth_dir >/dev/null || return 1
    cpa_safe_path "$CPA_AUTH_DIR" || {
        cpa_log_error "auth-dir 过于宽泛或不安全: $CPA_AUTH_DIR"
        return 1
    }
    install -d -m 700 "$CPA_USER_UNIT_DIR"
    cat > "$CPA_UNIT_FILE" <<EOF
[Unit]
Description=CLIProxyAPI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${CPA_INSTALL_DIR}
ExecStart=${CPA_BINARY} --config ${CPA_CONFIG_FILE}
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${CPA_CONFIG_DIR} ${CPA_DATA_DIR} ${CPA_AUTH_DIR}

[Install]
WantedBy=default.target
EOF
    chmod 600 "$CPA_UNIT_FILE"
}

cpa_validate_archive_members() {
    local archive="$1" member
    tar -tzf "$archive" >/dev/null 2>&1 || return 1
    tar -tvzf "$archive" 2>/dev/null | awk 'substr($1,1,1) == "l" || substr($1,1,1) == "h" { exit 1 }' || return 1
    while IFS= read -r member; do
        [[ "$member" != /* && "$member" != *$'\n'* ]] || return 1
        [[ "$member" != ".." && "$member" != ../* && "$member" != */../* && "$member" != */.. ]] || return 1
    done < <(tar -tzf "$archive" 2>/dev/null)
}

cpa_validate_zip_members() {
    local archive="$1" member
    unzip -Z1 "$archive" >/dev/null 2>&1 || return 1
    while IFS= read -r member; do
        [[ "$member" != /* && "$member" != *$'\n'* ]] || return 1
        [[ "$member" != ".." && "$member" != ../* && "$member" != */../* && "$member" != */.. ]] || return 1
    done < <(unzip -Z1 "$archive" 2>/dev/null)
    return 0
}

cpa_download() {
    local target="${1:-$CPA_BINARY}"
    local url="${CPA_DOWNLOAD_URL:-}" sha="${CPA_SHA256:-}"
    local stage archive candidate kind
    command -v curl >/dev/null 2>&1 || { cpa_log_error "缺少 curl"; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { cpa_log_error "缺少 sha256sum"; return 1; }
    [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || { cpa_log_error "请设置固定版本 CPA_DOWNLOAD_URL"; return 1; }
    [[ "$sha" =~ ^[A-Fa-f0-9]{64}$ ]] || { cpa_log_error "请设置 64 位 CPA_SHA256"; return 1; }
    stage="$(mktemp -d "${TMPDIR:-/tmp}/cpa-download.XXXXXX")" || return 1
    archive="$stage/archive"
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$archive"; then
        rm -rf "$stage"
        cpa_log_error "CPA 下载失败"
        return 1
    fi
    if ! printf '%s  %s\n' "$sha" "$archive" | sha256sum -c - >/dev/null 2>&1; then
        rm -rf "$stage"
        cpa_log_error "CPA SHA256 校验失败"
        return 1
    fi
    kind="${CPA_ASSET_NAME:-$url}"
    case "$kind" in
        *.tar.gz|*.tgz)
            cpa_validate_archive_members "$archive" || { rm -rf "$stage"; cpa_log_error "压缩包包含越界路径"; return 1; }
            if ! tar -xzf "$archive" -C "$stage"; then rm -rf "$stage"; cpa_log_error "CPA 压缩包解压失败"; return 1; fi
            ;;
        *.zip)
            command -v unzip >/dev/null 2>&1 || { rm -rf "$stage"; cpa_log_error "缺少 unzip"; return 1; }
            cpa_validate_zip_members "$archive" || { rm -rf "$stage"; cpa_log_error "zip 包包含越界路径"; return 1; }
            if ! unzip -q "$archive" -d "$stage"; then rm -rf "$stage"; cpa_log_error "CPA zip 解压失败"; return 1; fi
            ;;
        *)
            candidate="$archive"
            ;;
    esac
    if [[ -z "${candidate:-}" ]]; then
        candidate="$(find "$stage" -type f -name 'cli-proxy-api*' ! -name archive -print -quit)"
    fi
    [[ -n "$candidate" && -f "$candidate" ]] || { rm -rf "$stage"; cpa_log_error "下载包中未找到 cli-proxy-api"; return 1; }
    install -d -m 755 "$(dirname "$target")"
    if ! install -m 0755 "$candidate" "$target"; then rm -rf "$stage"; cpa_log_error "无法安装 CPA 二进制"; return 1; fi
    rm -rf "$stage"
}

cpa_config_has_placeholder() {
    [[ -f "$CPA_CONFIG_FILE" ]] || return 0
    grep -Eq '(^|[[:space:]-])("?)(CHANGE-ME|your-api-key-[0-9]+|your-api-key)("?)([[:space:]]|$)' "$CPA_CONFIG_FILE"
}

cpa_management_secret_ready() {
    local secret
    secret="$(cpa_config_scalar secret-key 2>/dev/null || true)"
    [[ -n "$secret" && "$secret" != "CHANGE-ME" && "$secret" != "your-management-secret" ]]
}

cpa_config_ready() {
    cpa_paths
    [[ -f "$CPA_CONFIG_FILE" ]] || return 1
    ! cpa_config_has_placeholder && cpa_management_secret_ready
}

cpa_prepare_config() {
    cpa_paths
    cpa_resolve_auth_dir >/dev/null || return 1
    cpa_validate_layout || return 1
    cpa_safe_path "$CPA_AUTH_DIR" || {
        cpa_log_error "auth-dir 过于宽泛或不安全: $CPA_AUTH_DIR"
        return 1
    }
    install -d -m 700 "$CPA_CONFIG_DIR" "$CPA_DATA_DIR" "$CPA_AUTH_DIR" "$CPA_BACKUP_ROOT"
    if [[ ! -f "$CPA_CONFIG_FILE" ]]; then
        cat > "$CPA_CONFIG_FILE" <<EOF
host: 127.0.0.1
port: ${CPA_PORT}
auth-dir: ${CPA_AUTH_DIR}
api-keys:
  - "CHANGE-ME"
remote-management:
  allow-remote: false
  secret-key: ""
  disable-control-panel: false
EOF
        chmod 600 "$CPA_CONFIG_FILE"
        cpa_log_warn "已生成配置模板；请在启动 CPA 前删除 CHANGE-ME，并设置客户端 API Key 与管理密码"
    else
        chmod 600 "$CPA_CONFIG_FILE"
    fi
}

cpa_write_state() {
    local version="${1:-unknown}"
    install -d -m 700 "$CPA_STATE_DIR"
    {
        printf 'version=%q\n' "$version"
        printf 'install_dir=%q\n' "$CPA_INSTALL_DIR"
        printf 'config_file=%q\n' "$CPA_CONFIG_FILE"
        printf 'auth_dir=%q\n' "$CPA_AUTH_DIR"
        printf 'port=%q\n' "$CPA_PORT"
        printf 'unit=%q\n' "$CPA_UNIT_FILE"
    } > "${CPA_STATE_FILE}.tmp"
    chmod 600 "${CPA_STATE_FILE}.tmp"
    mv -f "${CPA_STATE_FILE}.tmp" "$CPA_STATE_FILE"
}

cpa_hash_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file" | awk '{print $1}'; else shasum -a 256 "$file" | awk '{print $1}'; fi
}

cpa_copy_if_present() {
    local source="$1" destination="$2"
    [[ -e "$source" ]] || return 0
    if [[ -L "$source" ]]; then cpa_log_error "拒绝备份符号链接: $source"; return 1; fi
    install -d -m 700 "$(dirname "$destination")"
    cp -a "$source" "$destination"
}

cpa_restrict_tree() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    chmod -R go-rwx "$path"
}

cpa_backup() {
    cpa_require_root || return 1
    cpa_paths
    cpa_validate_layout || return 1
    cpa_resolve_auth_dir >/dev/null || { cpa_log_error "无法解析 CPA auth-dir"; return 1; }
    cpa_safe_path "$CPA_AUTH_DIR" || { cpa_log_error "auth-dir 过于宽泛或不安全: $CPA_AUTH_DIR"; return 1; }
    install -d -m 700 "$CPA_BACKUP_ROOT"
    local stamp stage archive final unit_source manifest status version
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/cpa-backup.XXXXXX")" || return 1
    archive="${stage}/archive.tar.gz"
    final="${CPA_BACKUP_ROOT}/cpa-${stamp}.tar.gz"
    while [[ -e "$final" ]]; do
        stamp="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
        final="${CPA_BACKUP_ROOT}/cpa-${stamp}.tar.gz"
    done
    unit_source="$CPA_UNIT_FILE"
    status="inactive"
    if command -v systemctl >/dev/null 2>&1 && cpa_user_systemctl is-active --quiet "$CPA_UNIT" 2>/dev/null; then status="active"; fi
    version="unknown"
    if [[ -x "$CPA_BINARY" ]]; then version="$("$CPA_BINARY" --version 2>/dev/null | head -n 1 || true)"; [[ -n "$version" ]] || version="unknown"; fi
    install -d -m 700 "$stage/config" "$stage/auth" "$stage/service" "$stage/meta"
    if ! cpa_copy_if_present "$CPA_CONFIG_FILE" "$stage/config/config.yaml"; then rm -rf "$stage"; return 1; fi
    if [[ ! -f "$stage/config/config.yaml" ]]; then rm -rf "$stage"; cpa_log_error "配置文件不存在，无法生成完整备份"; return 1; fi
    if [[ -d "$CPA_AUTH_DIR" ]]; then
        cpa_copy_if_present "$CPA_AUTH_DIR" "$stage/auth/auth-dir" || { rm -rf "$stage"; return 1; }
        cpa_restrict_tree "$stage/auth/auth-dir" || { rm -rf "$stage"; return 1; }
    fi
    cpa_copy_if_present "$unit_source" "$stage/service/${CPA_UNIT}" || { rm -rf "$stage"; return 1; }
    manifest="$stage/meta/manifest.txt"
    {
        printf 'format=1\n'
        printf 'version=%s\n' "$version"
        printf 'status=%s\n' "$status"
        printf 'config_source=%s\n' "$CPA_CONFIG_FILE"
        printf 'auth_source=%s\n' "$CPA_AUTH_DIR"
        printf 'binary=%s\n' "$CPA_BINARY"
        printf 'config_sha256=%s\n' "$(cpa_hash_file "$stage/config/config.yaml")"
        [[ -d "$stage/auth/auth-dir" ]] && printf 'auth_file_count=%s\n' "$(find "$stage/auth/auth-dir" -type f | wc -l | tr -d ' ')" || printf 'auth_file_count=0\n'
    } > "$manifest"
    chmod 600 "$manifest"
    if ! tar -czf "$archive" -C "$stage" config auth service meta; then rm -rf "$stage"; cpa_log_error "备份归档失败"; return 1; fi
    if ! cpa_validate_archive_members "$archive" || ! tar -xOzf "$archive" meta/manifest.txt >/dev/null 2>&1; then
        rm -rf "$stage"
        cpa_log_error "备份归档校验失败"
        return 1
    fi
    if ! mv -f "$archive" "$final"; then rm -rf "$stage"; cpa_log_error "无法保存备份归档"; return 1; fi
    chmod 600 "$final"
    rm -rf "$stage"
    cpa_log_info "CPA 备份已创建: $final"
    return 0
}

cpa_install() {
    cpa_require_root || return 1
    cpa_paths
    cpa_validate_layout || return 1
    cpa_validate_port "$CPA_PORT" || { cpa_log_error "CPA_PORT 无效: $CPA_PORT"; return 1; }
    if cpa_installed; then cpa_log_warn "检测到已由本工具管理的 CPA；请使用 cpa upgrade"; return 0; fi
    local external staged installed_version
    external="$(cpa_detect_external_install 2>/dev/null || true)"
    [[ -z "$external" ]] || { cpa_log_error "发现未接管的旧 CPA 安装: $external；请先执行接管/迁移，不会覆盖它"; return 1; }
    if [[ -e "$CPA_BINARY" ]]; then
        cpa_log_error "发现未接管的 CPA 二进制: $CPA_BINARY；为避免覆盖请先迁移或移走它"
        return 1
    fi
    install -d -m 755 "$CPA_INSTALL_DIR"
    staged="$(mktemp "$CPA_INSTALL_DIR/.cli-proxy-api.install.XXXXXX")" || return 1
    rm -f "$staged"
    if ! cpa_download "$staged"; then
        rm -f "$staged"
        return 1
    fi
    if ! cpa_prepare_config || ! cpa_install_unit || ! cpa_prepare_user_manager || ! cpa_user_systemctl daemon-reload; then
        rm -f "$staged"
        cpa_log_error "CPA 初始安装未完成；保留现有配置，已清理临时程序"
        return 1
    fi
    if ! mv -f "$staged" "$CPA_BINARY"; then
        rm -f "$staged"
        cpa_log_error "无法提交 CPA 二进制"
        return 1
    fi
    installed_version="$("$CPA_BINARY" --version 2>/dev/null | head -n 1 || true)"
    [[ -n "$installed_version" ]] || installed_version="unknown"
    cpa_write_state "$installed_version" || return 1
    if cpa_config_ready; then
        cpa_user_systemctl enable --now "$CPA_UNIT" || return 1
        cpa_wait_healthy || { cpa_log_error "CPA 服务未通过启动后的健康检查"; return 1; }
        cpa_status
    else
        cpa_log_warn "CPA 程序已安装但保持停止：配置仍含占位值，请完成配置后执行 cpa start"
        cpa_status
    fi
}

cpa_status() {
    cpa_paths
    local port host auth external
    port="$(cpa_actual_port 2>/dev/null || printf '%s' 'invalid')"
    host="$(cpa_actual_host 2>/dev/null || printf '%s' 'unknown')"
    auth="$(cpa_resolve_auth_dir 2>/dev/null || printf '%s' 'invalid')"
    printf 'CPA binary: %s\n' "$CPA_BINARY"
    printf 'CPA config: %s\n' "$CPA_CONFIG_FILE"
    printf 'CPA auth: %s\n' "$auth"
    printf 'CPA listen: %s:%s\n' "$host" "$port"
    if cpa_config_ready; then printf 'CPA config readiness: ready\n'; else printf 'CPA config readiness: incomplete (placeholder or missing)\n'; fi
    if cpa_installed; then printf 'CPA ownership: managed\n'; else printf 'CPA ownership: not-managed-or-incomplete\n'; fi
    external="$(cpa_detect_external_install 2>/dev/null || true)"
    [[ -z "$external" ]] || printf 'CPA external evidence: %s\n' "$external"
    if command -v systemctl >/dev/null 2>&1; then
        cpa_user_systemctl --no-pager --full status "$CPA_UNIT" || true
    else
        printf 'systemctl: unavailable\n'
    fi
    return 0
}

cpa_service() {
    local action="${1:-}"
    cpa_paths
    case "$action" in
        logs)
            command -v journalctl >/dev/null 2>&1 || { cpa_log_error "缺少 journalctl"; return 1; }
            journalctl --user -u "$CPA_UNIT" -n "${CPA_LOG_LINES:-80}" --no-pager
            ;;
        start|restart)
            cpa_require_root || return 1
            cpa_config_ready || { cpa_log_error "配置仍含占位值或不存在，拒绝启动"; return 1; }
            cpa_prepare_user_manager || return 1
            cpa_user_systemctl "$action" "$CPA_UNIT" || return 1
            cpa_wait_healthy || { cpa_log_error "CPA 服务启动命令成功，但端口/API 健康检查失败"; cpa_status; return 1; }
            cpa_status
            ;;
        stop)
            cpa_require_root || return 1
            cpa_user_systemctl stop "$CPA_UNIT" || return 1
            ;;
        *)
            cpa_log_error "未知服务操作: $action"
            return 2
            ;;
    esac
}

cpa_service_is_healthy() {
    local upstream code
    cpa_paths
    if ! cpa_user_systemctl is-active --quiet "$CPA_UNIT" >/dev/null 2>&1; then
        return 1
    fi
    command -v curl >/dev/null 2>&1 || return 0
    upstream="$(cpa_upstream_addr)"
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://${upstream}/v1/models" 2>/dev/null || printf '000')"
    [[ "$code" != "000" ]]
}

cpa_wait_healthy() {
    local retries="${CPA_HEALTH_RETRIES:-10}" interval="${CPA_HEALTH_INTERVAL:-1}" i
    [[ "$retries" =~ ^[0-9]+$ && "$retries" -ge 1 ]] || retries=10
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=1
    for ((i = 1; i <= retries; i++)); do
        cpa_service_is_healthy && return 0
        ((i < retries)) && sleep "$interval"
    done
    return 1
}

cpa_route_file() { printf '%s\n' "${CPA_ROUTE_FILE:-/etc/caddy/routes-custom.d/cpa.conf}"; }

cpa_write_route() {
    local file upstream
    upstream="$(cpa_upstream_addr 2>/dev/null)" || { cpa_log_error "无法读取 CPA 实际监听地址"; return 1; }
    file="$(cpa_route_file)"
    install -d -m 755 "${file%/*}"
    cat > "$file" <<EOF
    # CPA API only; management panel remains local/SSH-only.
    redir /cpa /cpa/ 308
    handle_path /cpa/* {
        @cpa_management path /v1/management*
        @cpa_management_v0 path /v0/management*
        @cpa_panel path /management.html*
        respond @cpa_management 404
        respond @cpa_management_v0 404
        respond @cpa_panel 404
        @cpa_api path /v1/*
        handle @cpa_api {
            reverse_proxy ${upstream} {
                header_up X-Forwarded-Proto https
                header_up X-Forwarded-For {remote_host}
            }
        }
        respond 404
    }
EOF
    chmod 640 "$file"
}

cpa_ensure_routes_import() {
    local caddyfile="$CPA_CADDYFILE" tmp
    grep -Fq 'routes-custom.d/*.conf' "$caddyfile" 2>/dev/null && return 0
    tmp="$(mktemp "${caddyfile}.cpa.XXXXXX")" || return 1
    if ! awk 'BEGIN { inserted=0 } !inserted && $0 ~ /^[[:space:]]*handle[[:space:]]+\/[[:space:]]*\{/ { print "    import /etc/caddy/routes-custom.d/*.conf"; inserted=1 } { print } END { if (!inserted) exit 2 }' "$caddyfile" > "$tmp"; then
        rm -f "$tmp"
        cpa_log_error "无法在 Caddyfile 中定位主站点块，未插入 CPA 路由引用"
        return 1
    fi
    chmod --reference="$caddyfile" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$caddyfile"
}

cpa_remove_routes_import_if_empty() {
    local route="$(cpa_route_file)" caddyfile="$CPA_CADDYFILE" custom_dir="${route%/*}" f tmp other=0
    for f in "$custom_dir"/*.conf; do
        [[ -e "$f" ]] || continue
        [[ "$f" == "$route" ]] && continue
        other=1
        break
    done
    [[ "$other" -eq 1 ]] && return 0
    grep -Fq 'routes-custom.d/*.conf' "$caddyfile" 2>/dev/null || return 0
    tmp="$(mktemp "${caddyfile}.cpa.XXXXXX")" || return 1
    if ! awk '$0 !~ /routes-custom\.d\/\*\.conf/ { print }' "$caddyfile" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod --reference="$caddyfile" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$caddyfile"
}

cpa_connect_caddy() {
    cpa_require_root || return 1
    cpa_validate_layout || return 1
    cpa_config_ready || { cpa_log_error "CPA 配置未完成，拒绝公开反代入口"; return 1; }
    cpa_service_is_healthy || { cpa_log_error "CPA 服务未处于可用状态，拒绝公开反代入口"; return 1; }
    [[ -f "$CPA_CADDYFILE" ]] || { cpa_log_error "未找到 $CPA_CADDYFILE"; return 1; }
    local route caddyfile route_backup caddy_backup stamp had_route=0
    route="$(cpa_route_file)"
    caddyfile="$CPA_CADDYFILE"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    route_backup="${CPA_BACKUP_ROOT}/caddy-route-${stamp}.bak"
    caddy_backup="${CPA_BACKUP_ROOT}/Caddyfile-${stamp}.bak"
    install -d -m 700 "$CPA_BACKUP_ROOT"
    if [[ -f "$route" ]]; then
        cp -a "$route" "$route_backup" || { cpa_log_error "无法备份现有 CPA 路由，未修改"; return 1; }
        had_route=1
    fi
    cp -a "$caddyfile" "$caddy_backup" || return 1
    if ! cpa_write_route; then
        [[ "$had_route" -eq 1 ]] && cp -a "$route_backup" "$route" || rm -f "$route"
        cp -a "$caddy_backup" "$caddyfile"
        return 1
    fi
    if ! cpa_ensure_routes_import; then
        [[ "$had_route" -eq 1 ]] && cp -a "$route_backup" "$route" || rm -f "$route"
        cp -a "$caddy_backup" "$caddyfile"
        return 1
    fi
    if ! command -v caddy >/dev/null 2>&1 || ! caddy validate --config "$caddyfile" --adapter caddyfile; then
        cpa_log_error "新 Caddy 配置校验失败，正在恢复"
        [[ "$had_route" -eq 1 ]] && cp -a "$route_backup" "$route" || rm -f "$route"
        cp -a "$caddy_backup" "$caddyfile"
        return 1
    fi
    if ! reload_caddy; then
        cpa_log_error "Caddy 重载失败，正在恢复 CPA 路由和 Caddyfile"
        [[ "$had_route" -eq 1 ]] && cp -a "$route_backup" "$route" || rm -f "$route"
        cp -a "$caddy_backup" "$caddyfile"
        reload_caddy >/dev/null 2>&1 || true
        return 1
    fi
    cpa_log_info "CPA API 已接入现有入口 /cpa/v1；管理页面保持本机访问"
}

cpa_safe_extract_backup() {
    local archive="$1" destination="$2" member
    tar -tzf "$archive" >/dev/null 2>&1 || return 1
    tar -tvzf "$archive" 2>/dev/null | awk 'substr($1,1,1) == "l" || substr($1,1,1) == "h" { exit 1 }' || return 1
    while IFS= read -r member; do
        [[ "$member" != /* && "$member" != *$'\n'* ]] || return 1
        [[ "$member" != ".." && "$member" != ../* && "$member" != */../* && "$member" != */.. ]] || return 1
    done < <(tar -tzf "$archive")
    install -d -m 700 "$destination"
    tar -xzf "$archive" -C "$destination"
}

cpa_restore_snapshot() {
    local snapshot="$1" old_auth_dir="$2" old_auth_present="$3" old_unit_present="$4" new_auth_dir="${5:-}"
    [[ -f "$snapshot/config-dir/config.yaml" ]] || return 1
    install -d -m 700 "$CPA_CONFIG_DIR"
    cp -a "$snapshot/config-dir/config.yaml" "$CPA_CONFIG_FILE" || return 1
    chmod 600 "$CPA_CONFIG_FILE" || return 1
    if [[ -n "$new_auth_dir" && "$new_auth_dir" != "$old_auth_dir" ]] && cpa_safe_path "$new_auth_dir"; then
        rm -rf "$new_auth_dir"
    fi
    if [[ "$old_auth_present" -eq 1 ]]; then
        rm -rf "$old_auth_dir"
        [[ -d "$snapshot/auth-dir" ]] || return 1
        cp -a "$snapshot/auth-dir" "$old_auth_dir" || return 1
        cpa_restrict_tree "$old_auth_dir" || return 1
    elif [[ -n "$old_auth_dir" ]] && cpa_safe_path "$old_auth_dir"; then
        rm -rf "$old_auth_dir"
    fi
    if [[ "$old_unit_present" -eq 1 ]]; then
        [[ -f "$snapshot/service/${CPA_UNIT}" ]] || return 1
        install -d -m 700 "$CPA_USER_UNIT_DIR"
        cp -a "$snapshot/service/${CPA_UNIT}" "$CPA_UNIT_FILE" || return 1
        chmod 600 "$CPA_UNIT_FILE"
    else
        rm -f "$CPA_UNIT_FILE"
    fi
}

cpa_restore() {
    cpa_require_root || return 1
    cpa_paths
    cpa_validate_layout || return 1
    local archive="${1:-}" stage target_backup old_active old_auth_dir restore_auth_dir restore_failed=0 old_auth_present=0 old_unit_present=0 expected_hash actual_hash
    [[ -f "$archive" ]] || { cpa_log_error "请指定备份文件: bash setup.sh cpa restore /path/to/cpa-*.tar.gz"; return 1; }
    stage="$(mktemp -d "${TMPDIR:-/tmp}/cpa-restore.XXXXXX")" || return 1
    if ! cpa_safe_extract_backup "$archive" "$stage"; then rm -rf "$stage"; cpa_log_error "备份格式或路径校验失败"; return 1; fi
    [[ -f "$stage/config/config.yaml" ]] || { rm -rf "$stage"; cpa_log_error "备份缺少 config/config.yaml"; return 1; }
    [[ -f "$stage/meta/manifest.txt" ]] || { rm -rf "$stage"; cpa_log_error "备份缺少 meta/manifest.txt，拒绝恢复未验证归档"; return 1; }
    expected_hash="$(awk -F= '$1 == "config_sha256" { print $2; exit }' "$stage/meta/manifest.txt")"
    actual_hash="$(cpa_hash_file "$stage/config/config.yaml")"
    [[ "$expected_hash" =~ ^[A-Fa-f0-9]{64}$ && "$expected_hash" == "$actual_hash" ]] || {
        rm -rf "$stage"
        cpa_log_error "备份配置 SHA256 与 manifest 不一致，拒绝恢复"
        return 1
    }
    cpa_backup || { rm -rf "$stage"; return 1; }
    old_active=0
    if command -v systemctl >/dev/null 2>&1 && cpa_user_systemctl is-active --quiet "$CPA_UNIT" 2>/dev/null; then old_active=1; fi
    target_backup="${CPA_BACKUP_ROOT}/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    install -d -m 700 "$target_backup"
    cpa_copy_if_present "$CPA_CONFIG_DIR" "$target_backup/config-dir" || { rm -rf "$stage" "$target_backup"; return 1; }
    old_auth_dir="$CPA_AUTH_DIR"
    cpa_safe_path "$old_auth_dir" || { rm -rf "$stage" "$target_backup"; cpa_log_error "当前 auth-dir 不安全，拒绝恢复: $old_auth_dir"; return 1; }
    [[ -d "$old_auth_dir" ]] && old_auth_present=1
    [[ -f "$CPA_UNIT_FILE" ]] && old_unit_present=1
    cpa_copy_if_present "$old_auth_dir" "$target_backup/auth-dir" || { rm -rf "$stage" "$target_backup"; return 1; }
    if [[ "$old_active" -eq 1 ]] && ! cpa_service stop >/dev/null 2>&1; then
        rm -rf "$stage"
        cpa_log_error "无法停止当前 CPA 服务，拒绝在运行中的实例上恢复"
        return 1
    fi
    install -d -m 700 "$CPA_CONFIG_DIR"
    if ! cp -a "$stage/config/config.yaml" "$CPA_CONFIG_FILE"; then restore_failed=1; fi
    chmod 600 "$CPA_CONFIG_FILE" 2>/dev/null || restore_failed=1
    if [[ "$restore_failed" -eq 0 && -d "$stage/auth/auth-dir" ]]; then
        restore_auth_dir="$(cpa_resolve_auth_dir 2>/dev/null || true)"
        if ! cpa_safe_path "$restore_auth_dir"; then
            cpa_log_error "备份中的 auth-dir 不安全，拒绝恢复: ${restore_auth_dir:-<empty>}"
            restore_failed=1
        else
            rm -rf "$restore_auth_dir"
            if ! cp -a "$stage/auth/auth-dir" "$restore_auth_dir"; then restore_failed=1; fi
            cpa_restrict_tree "$restore_auth_dir" || restore_failed=1
        fi
    fi
    if [[ "$restore_failed" -eq 0 && -f "$stage/service/${CPA_UNIT}" ]]; then
        if ! grep -Fq "ExecStart=${CPA_BINARY} --config ${CPA_CONFIG_FILE}" "$stage/service/${CPA_UNIT}"; then
            cpa_log_error "备份中的 service unit 不属于当前 CPA 路径，拒绝恢复"
            restore_failed=1
        else
            install -d -m 700 "$CPA_USER_UNIT_DIR"
            cp -a "$stage/service/${CPA_UNIT}" "$CPA_UNIT_FILE" || restore_failed=1
            chmod 600 "$CPA_UNIT_FILE" 2>/dev/null || restore_failed=1
        fi
    fi
    rm -rf "$stage"
    if [[ "$restore_failed" -ne 0 ]]; then
        cpa_log_error "恢复过程中发生错误，正在回滚到恢复前快照"
        cpa_restore_snapshot "$target_backup" "$old_auth_dir" "$old_auth_present" "$old_unit_present" "$restore_auth_dir" || true
        cpa_prepare_user_manager >/dev/null 2>&1 || true
        [[ "$old_active" -eq 1 ]] && cpa_service start >/dev/null 2>&1 || true
        return 1
    fi
    if ! cpa_prepare_user_manager; then
        cpa_log_error "恢复后无法刷新 user manager，正在回滚"
        cpa_restore_snapshot "$target_backup" "$old_auth_dir" "$old_auth_present" "$old_unit_present" "$restore_auth_dir" || true
        cpa_prepare_user_manager >/dev/null 2>&1 || true
        [[ "$old_active" -eq 1 ]] && cpa_service start >/dev/null 2>&1 || true
        return 1
    fi
    if [[ "$old_active" -eq 1 ]]; then
        if ! cpa_service start; then
            cpa_log_error "恢复后服务未能启动，正在回滚到恢复前快照"
            cpa_restore_snapshot "$target_backup" "$old_auth_dir" "$old_auth_present" "$old_unit_present" "$restore_auth_dir" || true
            cpa_prepare_user_manager >/dev/null 2>&1 || true
            cpa_service start >/dev/null 2>&1 || true
            return 1
        fi
    fi
    cpa_log_info "CPA 数据已恢复；恢复前快照保存在 $target_backup"
}

cpa_upgrade() {
    cpa_require_root || return 1
    cpa_paths
    cpa_validate_layout || return 1
    cpa_installed || { cpa_log_error "CPA 尚未由本工具管理"; return 1; }
    local staged old stamp
    staged="$(mktemp "${CPA_INSTALL_DIR}/.cli-proxy-api.new.XXXXXX")" || return 1
    rm -f "$staged"
    cpa_download "$staged" || { rm -f "$staged"; return 1; }
    cpa_backup || { rm -f "$staged"; return 1; }
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    old="${CPA_INSTALL_DIR}/cli-proxy-api.old.${stamp}"
    cp -a "$CPA_BINARY" "$old" || { rm -f "$staged"; return 1; }
    cpa_service stop || { rm -f "$staged"; return 1; }
    if cpa_user_systemctl is-active --quiet "$CPA_UNIT" 2>/dev/null; then
        rm -f "$staged"
        cpa_log_error "CPA 服务停止命令返回成功，但 unit 仍处于 active，拒绝替换程序"
        return 1
    fi
    if ! mv -f "$staged" "$CPA_BINARY"; then cpa_log_error "无法原子替换 CPA 程序"; cpa_service start || true; return 1; fi
    if ! cpa_service start || ! cpa_service_is_healthy; then
        cpa_log_error "升级后 CPA 未通过启动检查，正在恢复旧程序"
        mv -f "$old" "$CPA_BINARY"
        cpa_service start >/dev/null 2>&1 || true
        return 1
    fi
    local new_version
    new_version="$("$CPA_BINARY" --version 2>/dev/null | head -n 1 || true)"
    [[ -n "$new_version" ]] || new_version="unknown"
    cpa_write_state "$new_version" || cpa_log_warn "升级成功但状态文件未更新"
    cpa_log_info "CPA 升级完成；旧程序保留为 $old"
}

cpa_uninstall() {
    cpa_require_root || return 1
    cpa_paths
    cpa_validate_layout || return 1
    cpa_installed || { cpa_log_warn "未发现由本工具管理的 CPA，未删除外部安装"; return 0; }
    cpa_backup || return 1
    install -d -m 700 "$CPA_BACKUP_ROOT"
    local route="$(cpa_route_file)" route_backup caddyfile_backup stamp
    if [[ -f "$route" ]] && grep -Fq '# CPA API only' "$route"; then
        stamp="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
        route_backup="${CPA_BACKUP_ROOT}/uninstall-route-${stamp}.bak"
        caddyfile_backup="${CPA_BACKUP_ROOT}/uninstall-Caddyfile-${stamp}.bak"
        cp -a "$route" "$route_backup"
        cp -a "$CPA_CADDYFILE" "$caddyfile_backup" 2>/dev/null || {
            cpa_log_error "无法备份 Caddyfile，未继续卸载"
            return 1
        }
        rm -f "$route"
        if cpa_remove_routes_import_if_empty && [[ -f "$CPA_CADDYFILE" ]] && command -v caddy >/dev/null 2>&1 && caddy validate --config "$CPA_CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
            reload_caddy || { cp -a "$route_backup" "$route"; [[ -f "$caddyfile_backup" ]] && cp -a "$caddyfile_backup" "$CPA_CADDYFILE"; return 1; }
        else
            cp -a "$route_backup" "$route"
            cpa_log_error "删除 CPA 路由后 Caddy 校验失败，未继续卸载"
            return 1
        fi
    fi
    cpa_user_systemctl disable --now "$CPA_UNIT" || return 1
    cpa_user_systemctl daemon-reload || return 1
    rm -f "$CPA_UNIT_FILE" "$CPA_BINARY"
    rm -f "$CPA_STATE_FILE"
    cpa_log_info "CPA 程序已卸载；配置、凭证和备份保留在 $CPA_CONFIG_DIR、$CPA_AUTH_DIR、$CPA_BACKUP_ROOT"
}

cpa_menu() {
    while true; do
        printf '\n-------- CPA 管理 --------\n'
        printf '1 安装 2 状态 3 启动 4 停止 5 重启 6 日志 7 接入 Caddy 8 备份 9 恢复 10 升级 11 卸载 0 返回\n'
        local choice archive
        read -r -p '请选择: ' choice </dev/tty || return 0
        case "$choice" in
            1) cpa_install;; 2) cpa_status;; 3) cpa_service start;; 4) cpa_service stop;; 5) cpa_service restart;; 6) cpa_service logs;; 7) cpa_connect_caddy;; 8) cpa_backup;;
            9) read -r -p '备份文件路径: ' archive </dev/tty || return 0; [[ -n "$archive" ]] && cpa_restore "$archive" || cpa_log_warn '未提供备份路径';;
            10) cpa_upgrade;; 11) cpa_uninstall;; 0) return 0;; *) cpa_log_warn '无效选项';;
        esac
    done
}

cpa_dispatch() {
    local action="${1:-menu}"
    shift || true
    cpa_paths
    case "$action" in
        menu) cpa_menu;; install) cpa_install;; status) cpa_status;; start|stop|restart|logs) cpa_service "$action";; route) cpa_connect_caddy;; backup) cpa_backup;; restore) cpa_restore "${1:-}";; upgrade) cpa_upgrade;; uninstall) cpa_uninstall;;
        *) cpa_log_error '用法: bash setup.sh cpa {menu|install|status|start|stop|restart|logs|route|backup|restore|upgrade|uninstall}'; return 2;;
    esac
}
