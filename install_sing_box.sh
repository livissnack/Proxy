#!/usr/bin/env bash
set -euo pipefail
#
# 支持系统: Alpine; Debian/Ubuntu; RHEL 系（含 AlmaLinux 8–10、Rocky Linux、CentOS Stream、
# Fedora、Oracle Linux 等，依据 /etc/os-release 的 ID 与 ID_LIKE 识别）
#

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
succ() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
PROTOCOLS_FILE="/etc/sing-box/.protocols"

# -----------------------
# 工具函数 (提前统一声明，避免重复定义)
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

rand_pass() {
    openssl rand -base64 16 2>/dev/null | tr -d '\n\r' || head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r'
}

rand_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'
}

url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

read_port() {
    local prompt="$1"
    local value=""
    while true; do
        read -r -p "$prompt" value
        if [ -z "$value" ]; then
            echo "$(rand_port)"
            return 0
        fi
        if validate_port "$value"; then
            echo "$value"
            return 0
        fi
        warn "无效端口: $value (请输入 1-65535 之间的数字，或留空随机)"
    done
}

clear_protocol_credentials() {
    SS_PORT=""; SS_PSK=""; SS_METHOD=""
    HY2_PORT=""; HY2_PSK=""
    TUIC_PORT=""; TUIC_UUID=""; TUIC_PSK=""
    REALITY_PORT=""; REALITY_UUID=""
    REALITY_PK=""; REALITY_SID=""; REALITY_PUB=""
    ANYTLS_PORT=""; ANYTLS_PSK=""
    ANYTLS_CERT_PATH=""; ANYTLS_KEY_PATH=""
}

service_cmd() {
    local action="$1"
    if [ "$OS" = "alpine" ]; then
        rc-service sing-box "$action"
    else
        systemctl "$action" sing-box
    fi
}

resolve_singbox_bin() {
    if [ -x /etc/sing-box/bin/sing-box ]; then
        echo /etc/sing-box/bin/sing-box
    elif command -v sing-box >/dev/null 2>&1; then
        command -v sing-box
    elif [ -x /usr/local/bin/sing-box ]; then
        echo /usr/local/bin/sing-box
    else
        echo /etc/sing-box/bin/sing-box
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64|*armv8*) echo "arm64" ;;
        *)
            err "此脚本仅支持 64 位系统 (amd64/arm64): $(uname -m)"
            ;;
    esac
}

# -----------------------
# 233boy 风格：依赖检测 / wget 下载 / 后台预拉 sing-box
IS_CORE_REPO="SagerNet/sing-box"
PKG_CMD=""
IS_WGET=""
IS_SYSTEMD=""
IS_OPENRC=""
IS_ARCH=""
BOOT_TMPDIR=""
TMPCORE=""
IS_CORE_OK=""
IS_PKG_OK=""
CORE_DL_PID=""
PREFETCH_IP_FILE=""
IP_PREFETCH_PID=""
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-${HTTPS_PROXY:-}}"

_wget() {
    [ -n "$DOWNLOAD_PROXY" ] && export https_proxy="$DOWNLOAD_PROXY"
    wget --no-check-certificate "$@"
}

init_bootstrap() {
    IS_ARCH="$(detect_arch)"
    PKG_CMD="$(type -P apt-get || type -P yum || type -P dnf || type -P zypper || type -P apk || true)"
    IS_WGET="$(type -P wget || true)"
    IS_SYSTEMD="$(type -P systemctl || true)"
    IS_OPENRC="$(type -P rc-service || true)"

    [ -n "$PKG_CMD" ] || err "不支持的操作系统 (需 Debian/Ubuntu/CentOS/Alpine 等)"
    [ -n "$IS_SYSTEMD" ] || [ -n "$IS_OPENRC" ] || err "系统缺少 systemctl 或 rc-service，无法托管服务"

    BOOT_TMPDIR="$(mktemp -d 2>/dev/null || echo "/tmp/sb-install-$$")"
    TMPCORE="$BOOT_TMPDIR/sing-box.tgz"
    IS_CORE_OK="$BOOT_TMPDIR/sing-box.ok"
    IS_PKG_OK="$BOOT_TMPDIR/pkg.ok"
    mkdir -p "$BOOT_TMPDIR"
}

required_pkgs() {
    local pkgs="wget tar bash"
    if [ "$OS" = "alpine" ]; then
        pkgs="$pkgs gcompat openssl openrc"
    fi
    echo "$pkgs"
}

install_pkg() {
    local missing="" pkg
    for pkg in $(required_pkgs); do
        type -P "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    if [ -z "$missing" ]; then
        : >"$IS_PKG_OK"
        return 0
    fi
    info "安装依赖:${missing}"
    if [[ "$PKG_CMD" =~ apk ]]; then
        apk update >/dev/null 2>&1 || { err "apk update 失败"; return 1; }
        apk add --no-cache $missing >/dev/null 2>&1 || { err "Alpine 依赖安装失败，请手动: apk add$missing"; return 1; }
    else
        $PKG_CMD install -y $missing >/dev/null 2>&1 || {
            if [[ "$PKG_CMD" =~ yum ]] && type -P dnf >/dev/null 2>&1; then
                dnf install -y $missing >/dev/null 2>&1 || return 1
            else
                [[ "$PKG_CMD" =~ yum ]] && yum install -y epel-release >/dev/null 2>&1 || true
                if [[ "$PKG_CMD" =~ zypper ]]; then
                    zypper --non-interactive refresh >/dev/null 2>&1 || true
                else
                    $PKG_CMD update -y >/dev/null 2>&1 || true
                fi
                $PKG_CMD install -y $missing >/dev/null 2>&1 || return 1
            fi
        }
    fi
    : >"$IS_PKG_OK"
}

download_core() {
    local ver link
    ver="$(_wget -qO- "https://api.github.com/repos/${IS_CORE_REPO}/releases/latest?v=$RANDOM" \
        | grep tag_name | grep -Eo 'v[0-9.]+' | head -1)"
    [ -n "$ver" ] || return 1
    link="https://github.com/${IS_CORE_REPO}/releases/download/${ver}/sing-box-${ver#v}-linux-${IS_ARCH}.tar.gz"
    info "下载 sing-box > ${link}"
    if _wget -t 3 -q -c "$link" -O "$TMPCORE"; then
        mv -f "$TMPCORE" "$IS_CORE_OK"
        echo "${ver#v}" > "$BOOT_TMPDIR/.version"
        return 0
    fi
    return 1
}

get_ip() {
    local ip_line ip=""
    ip_line="$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep -m1 '^ip=' || true)"
    [ -n "$ip_line" ] && ip="${ip_line#ip=}"
    if [ -z "$ip" ]; then
        ip_line="$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep -m1 '^ip=' || true)"
        [ -n "$ip_line" ] && ip="${ip_line#ip=}"
    fi
    [ -n "$ip" ] && echo "$ip" > "$PREFETCH_IP_FILE"
}

bootstrap_start() {
    init_bootstrap
    if [[ "$PKG_CMD" =~ apk ]]; then
        install_pkg || exit 1
    else
        install_pkg &
        local pkg_pid=$!
        if [ ! -x "$(resolve_singbox_bin)" ]; then
            info "后台下载 sing-box（填写配置时可并行进行）..."
            download_core &
            CORE_DL_PID=$!
        fi
        wait "$pkg_pid" || { err "依赖安装失败"; exit 1; }
    fi

    IS_WGET="$(type -P wget || true)"
    [ -n "$IS_WGET" ] || err "wget 不可用，无法下载 sing-box"

    if [ ! -x "$(resolve_singbox_bin)" ] && [ -z "$CORE_DL_PID" ]; then
        info "后台下载 sing-box（填写配置时可并行进行）..."
        download_core &
        CORE_DL_PID=$!
    fi
}

start_core_prefetch() {
    [ -x "$(resolve_singbox_bin)" ] && return 0
    [ -n "$CORE_DL_PID" ] && return 0
    download_core &
    CORE_DL_PID=$!
}

start_ip_prefetch() {
    [ -n "${CUSTOM_IP:-}" ] && return 0
    PREFETCH_IP_FILE="$BOOT_TMPDIR/public.ip"
    get_ip &
    IP_PREFETCH_PID=$!
}

install_core_from_cache() {
    local extract_dir version
    if [ -x "$(resolve_singbox_bin)" ]; then
        SING_BOX_BIN="$(resolve_singbox_bin)"
        info "sing-box 已安装: $SING_BOX_BIN"
        return 0
    fi

    if [ -n "$CORE_DL_PID" ]; then
        info "等待 sing-box 下载完成..."
        wait "$CORE_DL_PID" || err "sing-box 下载失败，请检查 github.com 连通性"
        CORE_DL_PID=""
    fi

    [ -f "$IS_CORE_OK" ] || err "sing-box 安装包不存在，下载可能失败"

    extract_dir="$BOOT_TMPDIR/extract"
    mkdir -p "$extract_dir" /etc/sing-box/bin
    tar zxf "$IS_CORE_OK" --strip-components 1 -C "$extract_dir" || err "sing-box 解压失败"
    [ -x "$extract_dir/sing-box" ] || err "安装包中未找到 sing-box 可执行文件"

    install -m 755 "$extract_dir/sing-box" /etc/sing-box/bin/sing-box
    ln -sf /etc/sing-box/bin/sing-box /usr/local/bin/sing-box 2>/dev/null || true
    ln -sf /etc/sing-box/bin/sing-box /usr/bin/sing-box 2>/dev/null || true
    SING_BOX_BIN="/etc/sing-box/bin/sing-box"

    if [ "$OS" = "alpine" ] && ! "$SING_BOX_BIN" version >/dev/null 2>&1; then
        warn "Alpine 需 gcompat 运行 glibc 版 sing-box，正在检查..."
        type -P gcompat >/dev/null 2>&1 || apk add --no-cache gcompat >/dev/null 2>&1 || true
    fi
    "$SING_BOX_BIN" version >/dev/null 2>&1 || err "sing-box 无法运行，Alpine 请确认已安装 gcompat"

    version="$(cat "$BOOT_TMPDIR/.version" 2>/dev/null || "$SING_BOX_BIN" version 2>/dev/null | head -1)"
    succ "sing-box 安装完成 ${version}"
}

install_singbox() {
    install_core_from_cache
}

install_singbox_binary_sync() {
    rm -f "$IS_CORE_OK" /etc/sing-box/bin/sing-box 2>/dev/null || true
    info "重新下载 sing-box..."
    download_core || err "sing-box 下载失败"
    CORE_DL_PID=""
    install_core_from_cache
}

bootstrap_cleanup() {
    [ -n "$BOOT_TMPDIR" ] && [ -d "$BOOT_TMPDIR" ] && rm -rf "$BOOT_TMPDIR"
}

# 确保 /root/install_sing_box.sh 存在（供 sb 面板追加/查看使用）
ensure_install_script_backup() {
    [ -f /root/install_sing_box.sh ] && return 0
    local url="https://raw.githubusercontent.com/livissnack/Proxy/main/install_sing_box.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o /root/install_sing_box.sh 2>/dev/null || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO /root/install_sing_box.sh "$url" 2>/dev/null || return 1
    else
        return 1
    fi
    chmod +x /root/install_sing_box.sh 2>/dev/null || true
    return 0
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    local os_line="${OS_ID} ${OS_ID_LIKE}"
    if echo "$os_line" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$os_line" | grep -Eiq "debian|ubuntu"; then
        OS="debian"
    elif echo "$os_line" | grep -Eiq "almalinux|rocky|centos|rhel|fedora|ol|oracle|eurolinux|openeuler"; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        exit 1
    fi
}

# -----------------------
# 加载已有缓存状态
ENABLE_SS=false; ENABLE_HY2=false; ENABLE_TUIC=false; ENABLE_REALITY=false; ENABLE_ANYTLS=false
SS_PORT=""; SS_PSK=""; SS_METHOD=""
HY2_PORT=""; HY2_PSK=""
TUIC_PORT=""; TUIC_UUID=""; TUIC_PSK=""
REALITY_PORT=""; REALITY_UUID=""; REALITY_PK=""; REALITY_SID=""; REALITY_PUB=""; REALITY_SNI="addons.mozilla.org"
ANYTLS_PORT=""; ANYTLS_PSK=""
ANYTLS_CERT_PATH=""; ANYTLS_KEY_PATH=""
CUSTOM_IP=""
SING_BOX_BIN="/etc/sing-box/bin/sing-box"
suffix=""

load_state() {
    if [ -f "$PROTOCOLS_FILE" ]; then
        # shellcheck disable=SC1090
        . "$PROTOCOLS_FILE"
    fi
    if [ -f "$CACHE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CACHE_FILE"
    fi
}

# -----------------------
# 选择要部署的协议 (支持追加)
select_protocols() {
    info "=== 协议部署管理 ==="
    if $ENABLE_SS || $ENABLE_HY2 || $ENABLE_TUIC || $ENABLE_REALITY || $ENABLE_ANYTLS; then
        warn "检测到当前已安装协议: "
        $ENABLE_SS && echo "  - Shadowsocks"
        $ENABLE_HY2 && echo "  - Hysteria2"
        $ENABLE_TUIC && echo "  - TUIC"
        $ENABLE_REALITY && echo "  - VLESS Reality"
        $ENABLE_ANYTLS && echo "  - AnyTLS"
        echo "--------------------------------"
        echo "1) 追加/修改协议 (保留未勾选的现有协议)"
        echo "2) 全新覆盖安装 (清除所有老协议，重新选择)"
        read -r -p "请选择操作 [1-2] (默认 1): " mode_choice
        if [ "${mode_choice:-1}" = "2" ]; then
            ENABLE_SS=false; ENABLE_HY2=false; ENABLE_TUIC=false; ENABLE_REALITY=false; ENABLE_ANYTLS=false
            clear_protocol_credentials
        fi
    fi

    echo ""
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS"
    echo ""
    read -r -p "请输入要安装/保留的协议编号(多个用空格分隔，如 1 2 4): " protocol_input

    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done

    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议, 退出"
        exit 1
    fi

    mkdir -p /etc/sing-box
    cat > "$PROTOCOLS_FILE" <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOF
}

# 选择SS加密方式
select_ss_method() {
    if ! $ENABLE_SS; then return 0; fi
    if [ -n "${SS_PORT:-}" ] && [ -n "${SS_METHOD:-}" ] && [ "$SS_METHOD" != "null" ]; then
        return 0 # 已有 SS 配置则不重复询问
    fi
    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo "3) aes-256-gcm"
    read -r -p "请输入选择(默认为 1): " ss_method_choice
    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        3) SS_METHOD="aes-256-gcm" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac
}

# 询问连接 IP 和 SNI 配置
prompt_network_settings() {
    echo ""
    read -r -p "请输入节点连接 IP 或 DDNS 域名 (留空默认自动获取出口 IP): " INPUT_IP
    if [ -n "$INPUT_IP" ]; then
        CUSTOM_IP="$(echo "$INPUT_IP" | tr -d '[:space:]')"
    fi

    if $ENABLE_REALITY && [ "${REALITY_SNI:-addons.mozilla.org}" = "addons.mozilla.org" ]; then
        read -r -p "请输入 Reality 的 SNI (留空默认 addons.mozilla.org): " INPUT_SNI
        REALITY_SNI="$(echo "${INPUT_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
    fi
}

prompt_node_suffix() {
    if [ ! -f /root/node_names.txt ]; then
        read -r -p "请输入节点自定义名称后缀 (留空则无后缀): " user_name
        if [[ -n "$user_name" ]]; then
            echo "-${user_name}" > /root/node_names.txt
        else
            echo "" > /root/node_names.txt
        fi
    fi
    suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
}

# AnyTLS 自定义证书配置
prompt_anytls_cert() {
    if ! $ENABLE_ANYTLS; then return 0; fi
    if [ -n "${ANYTLS_CERT_PATH:-}" ] && [ -n "${ANYTLS_KEY_PATH:-}" ]; then
        return 0 # 已有则不重复询问
    fi
    echo ""
    info "=== AnyTLS 证书配置 ==="
    echo "AnyTLS 推荐使用真实域名 + 合法证书（如 Let's Encrypt / 商业证书）"
    read -r -p "请输入 AnyTLS 证书 fullchain.pem 路径 (留空则使用自签名证书): " cert_path
    if [ -n "$cert_path" ]; then
        ANYTLS_CERT_PATH="$cert_path"
        read -r -p "请输入 AnyTLS 私钥 privkey.pem 路径 (留空默认与证书同目录): " key_path
        if [ -n "$key_path" ]; then
            ANYTLS_KEY_PATH="$key_path"
        else
            # 尝试自动推断
            local dir
            dir="$(dirname "$cert_path")"
            if [ -f "$dir/privkey.pem" ]; then
                ANYTLS_KEY_PATH="$dir/privkey.pem"
                info "自动使用: $ANYTLS_KEY_PATH"
            else
                read -r -p "请输入 AnyTLS 私钥完整路径: " ANYTLS_KEY_PATH
            fi
        fi
    else
        ANYTLS_CERT_PATH=""
        ANYTLS_KEY_PATH=""
        info "AnyTLS 将使用自签名证书 (www.bing.com)"
    fi
}

# 交互端口与密钥
get_config() {
    info "开始配置端口和密码..."
    if $ENABLE_SS && [ -z "${SS_PORT:-}" ]; then
        SS_PORT="$(read_port "请输入 SS 端口 (留空随机): ")"
        SS_PSK=$(rand_pass)
    fi
    if $ENABLE_HY2 && [ -z "${HY2_PORT:-}" ]; then
        HY2_PORT="$(read_port "请输入 HY2 端口 (留空随机): ")"
        HY2_PSK=$(rand_pass)
    fi
    if $ENABLE_TUIC && [ -z "${TUIC_PORT:-}" ]; then
        TUIC_PORT="$(read_port "请输入 TUIC 端口 (留空随机): ")"
        TUIC_PSK=$(rand_pass)
        TUIC_UUID=$(rand_uuid)
    fi
    if $ENABLE_REALITY && [ -z "${REALITY_PORT:-}" ]; then
        REALITY_PORT="$(read_port "请输入 VLESS Reality 端口 (留空随机): ")"
        REALITY_UUID=$(rand_uuid)
    fi
    if $ENABLE_ANYTLS && [ -z "${ANYTLS_PORT:-}" ]; then
        ANYTLS_PORT="$(read_port "请输入 AnyTLS 端口 (留空随机): ")"
        ANYTLS_PSK=$(rand_pass)
    fi
}

generate_reality_keys() {
    if ! $ENABLE_REALITY; then return 0; fi
    if [ -n "${REALITY_PK:-}" ] && [ -n "${REALITY_PUB:-}" ] && [ -n "${REALITY_SID:-}" ]; then return 0; fi
    info "生成 Reality 密钥对..."
    REALITY_KEYS=$("$SING_BOX_BIN" generate reality-keypair 2>&1)
    REALITY_PK=$(echo "$REALITY_KEYS" | awk '/PrivateKey/ {print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | awk '/PublicKey/ {print $NF}' | tr -d '\r')
    REALITY_SID=$("$SING_BOX_BIN" generate rand 8 --hex 2>/dev/null | tr -d '[:space:]')
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成失败"
        exit 1
    fi
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
}

generate_cert() {
    # AnyTLS 使用自定义证书时，不需要生成自签名
    local need_selfsigned=false
    if $ENABLE_HY2 || $ENABLE_TUIC; then
        need_selfsigned=true
    fi
    if $ENABLE_ANYTLS && [ -z "${ANYTLS_CERT_PATH:-}" ]; then
        need_selfsigned=true
    fi
    if ! $need_selfsigned; then return 0; fi

    if ! command -v openssl >/dev/null 2>&1; then
        err "HY2/TUIC/AnyTLS 需要 openssl 生成 TLS 证书，请安装 openssl 后重试"
        exit 1
    fi
    mkdir -p /etc/sing-box/certs
    if [ ! -f /etc/sing-box/certs/fullchain.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 -subj "/CN=www.bing.com"
    fi
}

# 生成配置文件（纯 bash 拼接 JSON，无需 jq）
create_config() {
    info "生成配置文件: $CONFIG_PATH"
    local items="" comma=""

    if $ENABLE_SS; then
        SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
        items+="${comma}{\"type\":\"shadowsocks\",\"listen\":\"::\",\"listen_port\":${SS_PORT},\"method\":\"$(json_escape "$SS_METHOD")\",\"password\":\"$(json_escape "$SS_PSK")\",\"tag\":\"ss-in\"}"
        comma=","
    fi

    if $ENABLE_HY2; then
        items+="${comma}{\"type\":\"hysteria2\",\"tag\":\"hy2-in\",\"listen\":\"::\",\"listen_port\":${HY2_PORT},\"users\":[{\"password\":\"$(json_escape "$HY2_PSK")\"}],\"tls\":{\"enabled\":true,\"alpn\":[\"h3\"],\"certificate_path\":\"/etc/sing-box/certs/fullchain.pem\",\"key_path\":\"/etc/sing-box/certs/privkey.pem\"}}"
        comma=","
    fi

    if $ENABLE_TUIC; then
        items+="${comma}{\"type\":\"tuic\",\"tag\":\"tuic-in\",\"listen\":\"::\",\"listen_port\":${TUIC_PORT},\"users\":[{\"uuid\":\"$(json_escape "$TUIC_UUID")\",\"password\":\"$(json_escape "$TUIC_PSK")\"}],\"congestion_control\":\"bbr\",\"tls\":{\"enabled\":true,\"alpn\":[\"h3\"],\"certificate_path\":\"/etc/sing-box/certs/fullchain.pem\",\"key_path\":\"/etc/sing-box/certs/privkey.pem\"}}"
        comma=","
    fi

    if $ENABLE_REALITY; then
        items+="${comma}{\"type\":\"vless\",\"tag\":\"vless-in\",\"listen\":\"::\",\"listen_port\":${REALITY_PORT},\"users\":[{\"uuid\":\"$(json_escape "$REALITY_UUID")\",\"flow\":\"xtls-rprx-vision\"}],\"tls\":{\"enabled\":true,\"server_name\":\"$(json_escape "$REALITY_SNI")\",\"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"$(json_escape "$REALITY_SNI")\",\"server_port\":443},\"private_key\":\"$(json_escape "$REALITY_PK")\",\"short_id\":[\"$(json_escape "$REALITY_SID")\"]}}}"
        comma=","
    fi

    if $ENABLE_ANYTLS; then
        local anytls_cert="${ANYTLS_CERT_PATH:-/etc/sing-box/certs/fullchain.pem}"
        local anytls_key="${ANYTLS_KEY_PATH:-/etc/sing-box/certs/privkey.pem}"
        items+="${comma}{\"type\":\"anytls\",\"tag\":\"anytls-in\",\"listen\":\"::\",\"listen_port\":${ANYTLS_PORT},\"users\":[{\"password\":\"$(json_escape "$ANYTLS_PSK")\"}],\"tls\":{\"enabled\":true,\"certificate_path\":\"$(json_escape "$anytls_cert")\",\"key_path\":\"$(json_escape "$anytls_key")\"},\"detour\":\"fallback-out\"}"
    fi

    if $ENABLE_ANYTLS; then
        cat > "$CONFIG_PATH" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [${items}],
  "outbounds": [
    { "type": "direct", "tag": "direct-out" },
    { "type": "direct", "tag": "fallback-out", "override_address": "www.microsoft.com", "override_port": 443 }
  ]
}
EOF
    else
        cat > "$CONFIG_PATH" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [${items}],
  "outbounds": [{ "type": "direct", "tag": "direct-out" }]
}
EOF
    fi

    if ! "$SING_BOX_BIN" check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        err "配置文件校验失败，请检查生成的 JSON"
        exit 1
    fi

    # 写缓存
    cat > "$CACHE_FILE" <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
SS_PORT=$SS_PORT
SS_PSK=$SS_PSK
SS_METHOD=$SS_METHOD
HY2_PORT=$HY2_PORT
HY2_PSK=$HY2_PSK
TUIC_PORT=$TUIC_PORT
TUIC_UUID=$TUIC_UUID
TUIC_PSK=$TUIC_PSK
REALITY_PORT=$REALITY_PORT
REALITY_UUID=$REALITY_UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
ANYTLS_PORT=$ANYTLS_PORT
ANYTLS_PSK=$ANYTLS_PSK
ANYTLS_CERT_PATH=$ANYTLS_CERT_PATH
ANYTLS_KEY_PATH=$ANYTLS_KEY_PATH
CUSTOM_IP=$CUSTOM_IP
EOF
}

# 守护进程与服务托管
setup_service() {
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        cat > "$SERVICE_PATH" <<OPENRC
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Proxy Server"
command="$SING_BOX_BIN"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /var/log /run; }
OPENRC
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || true
        service_cmd restart || exit 1
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        cat > "$SERVICE_PATH" <<SYSTEMD
[Unit]
Description=Sing-box Proxy Server
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=$SING_BOX_BIN run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        service_cmd restart || exit 1
    fi
}

# 防火墙端口自动放行
open_firewall_ports() {
    _fw_port_firewalld() {
        [ -z "$1" ] && return 0
        firewall-cmd --permanent --add-port="${1}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${1}/udp" >/dev/null 2>&1 || true
    }
    _fw_port_ufw() {
        [ -z "$1" ] && return 0
        ufw allow "${1}/tcp" >/dev/null 2>&1 || true
        ufw allow "${1}/udp" >/dev/null 2>&1 || true
    }

    local ports=()
    $ENABLE_SS && ports+=("$SS_PORT")
    $ENABLE_HY2 && ports+=("$HY2_PORT")
    $ENABLE_TUIC && ports+=("$TUIC_PORT")
    $ENABLE_REALITY && ports+=("$REALITY_PORT")
    $ENABLE_ANYTLS && ports+=("$ANYTLS_PORT")

    if [ "$OS" = "redhat" ] && command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for port in "${ports[@]}"; do _fw_port_firewalld "$port"; done
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld 端口已放行"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
        for port in "${ports[@]}"; do _fw_port_ufw "$port"; done
        info "ufw 端口已放行"
    fi
}

get_public_ip() {
    if [ -n "$PREFETCH_IP_FILE" ] && [ -f "$PREFETCH_IP_FILE" ]; then
        cat "$PREFETCH_IP_FILE"
        return 0
    fi
    local ip_line ip=""
    ip_line="$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep -m1 '^ip=' || true)"
    [ -n "$ip_line" ] && ip="${ip_line#ip=}"
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
    fi
    ip="$(_wget -qO- https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
    fi
    echo "YOUR_SERVER_IP"
}

resolve_pub_ip() {
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUB_IP="$CUSTOM_IP"
        return 0
    fi
    if [ -n "$IP_PREFETCH_PID" ]; then
        wait "$IP_PREFETCH_PID" 2>/dev/null || true
        IP_PREFETCH_PID=""
    fi
    if [ -n "$PREFETCH_IP_FILE" ] && [ -f "$PREFETCH_IP_FILE" ]; then
        PUB_IP=$(cat "$PREFETCH_IP_FILE")
        rm -f "$PREFETCH_IP_FILE"
        PREFETCH_IP_FILE=""
        return 0
    fi
    PUB_IP=$(get_public_ip)
}

main_install() {
    ensure_install_script_backup
    select_protocols
    select_ss_method
    prompt_network_settings
    start_ip_prefetch
    get_config
    prompt_node_suffix
    prompt_anytls_cert

    info ">>> [1/6] 安装 sing-box 核心"
    install_singbox
    info ">>> [2/6] 生成 Reality 密钥"
    generate_reality_keys
    info ">>> [3/6] 生成 TLS 证书"
    generate_cert
    info ">>> [4/6] 生成配置文件"
    create_config
    info ">>> [5/6] 配置系统服务"
    setup_service
    info ">>> [6/6] 防火墙放行 & 获取公网 IP"
    open_firewall_ports
    resolve_pub_ip
}

# -----------------------
# 排版优化的数据输出展示
output_format_result() {
    local host="$PUB_IP"
    echo -e "\033[1;32m"
    echo "=========================================================================="
    echo " 🎉  Sing-box 节点部署/更新成功！"
    echo "=========================================================================="
    echo -e "\033[0m"

    echo -e "\033[1;34m[1. 📊 核心配置详情]\033[0m"
    printf " 🔹 %-12s : \033[1;35m%s\033[0m\n" "服务器地址" "$host"
    $ENABLE_SS && printf " 🔹 %-12s : 端口 \033[1;33m%-5s\033[0m | 加密 \033[1;36m%-23s\033[0m | 密码 \033[1;36m%s\033[0m\n" "Shadowsocks" "$SS_PORT" "$SS_METHOD" "$SS_PSK"
    $ENABLE_HY2 && printf " 🔹 %-12s : 端口 \033[1;33m%-5s\033[0m | 密码 \033[1;36m%s\033[0m\n" "Hysteria2" "$HY2_PORT" "$HY2_PSK"
    $ENABLE_TUIC && printf " 🔹 %-12s : 端口 \033[1;33m%-5s\033[0m | 密码 \033[1;36m%-16s\033[0m | UUID \033[1;36m%s\033[0m\n" "TUIC" "$TUIC_PORT" "$TUIC_PSK" "$TUIC_UUID"
    $ENABLE_REALITY && printf " 🔹 %-12s : 端口 \033[1;33m%-5s\033[0m | SNI  \033[1;36m%-23s\033[0m | UUID \033[1;36m%s\033[0m\n" "VLESS Reality" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_UUID"
    $ENABLE_ANYTLS && printf " 🔹 %-12s : 端口 \033[1;33m%-5s\033[0m | 密码 \033[1;36m%s\033[0m\n" "AnyTLS" "$ANYTLS_PORT" "$ANYTLS_PSK"
    echo ""

    echo -e "\033[1;34m[2. 📋 客户端通用节点链接]\033[0m"
    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${SS_PSK}"
        local ss_b64=$(printf "%s" "$ss_userinfo" | base64 | tr -d '\n\r')
        echo -e " 🟢 \033[1;32mShadowsocks:\033[0m"
        echo "    ss://${ss_b64}@${host}:${SS_PORT}#ss${suffix}"
    fi
    if $ENABLE_HY2; then
        local hy2_encoded=$(url_encode "$HY2_PSK")
        echo -e " 🟢 \033[1;32mHysteria2:\033[0m"
        echo "    hy2://${hy2_encoded}@${host}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
    fi
    if $ENABLE_TUIC; then
        local tuic_encoded=$(url_encode "$TUIC_PSK")
        echo -e " 🟢 \033[1;32mTUIC:\033[0m"
        echo "    tuic://${TUIC_UUID}:${tuic_encoded}@${host}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
    fi
    if $ENABLE_REALITY; then
        echo -e " 🟢 \033[1;32mVLESS Reality:\033[0m"
        echo "    vless://${REALITY_UUID}@${host}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
    fi
    if $ENABLE_ANYTLS; then
        local anytls_encoded=$(url_encode "$ANYTLS_PSK")
        echo -e " 🟢 \033[1;32mAnyTLS:\033[0m"
        echo "    anytls://${anytls_encoded}@${host}:${ANYTLS_PORT}/?insecure=1&sni=www.bing.com#anytls${suffix}"
    fi
    echo ""

    echo -e "\033[1;34m[3. 📂 路径与运维指令]\033[0m"
    printf " 📂 %-12s : %s\n" "主配置文件" "$CONFIG_PATH"
    printf " 📂 %-12s : %s\n" "持久化缓存" "$CACHE_FILE"
    if [ "$OS" = "alpine" ]; then
        printf " 🔧 %-12s : \033[1;33mrc-service sing-box restart\033[0m\n" "重启服务"
        printf " 📜 %-12s : \033[1;33mtail -f /var/log/sing-box.log\033[0m\n" "查看日志"
    else
        printf " 🔧 %-12s : \033[1;33msystemctl restart sing-box\033[0m\n" "重启服务"
        printf " 📜 %-12s : \033[1;33mjournalctl -u sing-box -f -n 20\033[0m\n" "查看日志"
    fi
    echo "=========================================================================="
    echo -e "💡 \033[1;36m提示：在系统任意位置输入 [ sb ] 即可快捷唤醒图形化管理面板。\033[0m"
    echo "=========================================================================="
}

# -----------------------
# 创建唤醒 sb 管理面板的脚本
create_sb_panel() {
    local SB_PATH="/usr/local/bin/sb"
    cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
PROTOCOLS_FILE="/etc/sing-box/.protocols"

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

if [ ! -f "$CONFIG_PATH" ] || [ ! -f "$CACHE_FILE" ]; then
    err "未检测到完整的 sing-box 运行环境，请重新运行安装脚本！"
    exit 1
fi

. "$PROTOCOLS_FILE"
. "$CACHE_FILE"

# 动态菜单展示
show_menu() {
    . "$PROTOCOLS_FILE" 2>/dev/null || true
    echo -e "\033[1;36m=========================================\033[0m"
    echo -e "     ⚡ Sing-box 快捷运维面板 ⚡"
    echo -e "\033[1;36m=========================================\033[0m"
    echo " 1) 🔍 查看现有节点链接 (或重新导出)"
    echo " 2) ➕ 追加/修改/重装 协议节点"
    echo " 3) 📝 快捷调用终端编辑器修改 config.json"
    echo "-----------------------------------------"
    echo " 4) 🟢 启动服务      5) 🔴 停止服务"
    echo " 6) 🟡 重启服务      7) 🔵 查看当前运行状态"
    echo " 8) 🔄 升级 sing-box 核心内核"
    echo " 9) ❌ 彻底卸载清理 sing-box 及其配置"
    echo " 0) 🚪 退出面板"
    echo -e "\033[1;36m=========================================\033[0m"
}

action_view() {
    if [ -f /root/install_sing_box.sh ] || ensure_install_script_backup; then
        bash /root/install_sing_box.sh --show-links
    elif [ -f "$CACHE_FILE" ]; then
        cat "$CACHE_FILE"
    else
        err "未找到缓存配置，无法导出节点链接。"
    fi
}

action_reconfig() {
    if [ -f /root/install_sing_box.sh ] || ensure_install_script_backup; then
        clear
        exec bash /root/install_sing_box.sh
    else
        err "未在 /root/install_sing_box.sh 找到原始安装脚本，无法追加协议。"
        info "请手动执行: curl -fsSL https://raw.githubusercontent.com/livissnack/Proxy/main/install_sing_box.sh -o /root/install_sing_box.sh && chmod +x /root/install_sing_box.sh"
    fi
}

action_edit() {
    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"
    if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        info "配置检测合格，正在自动重启服务..."
        systemctl restart sing-box 2>/dev/null || rc-service sing-box restart 2>/dev/null || true
    else
        warn "检测到 JSON 配置有语法错误！未触发重启，请仔细排查。"
    fi
}

while true; do
    show_menu
    read -r -p "请选择交互序号: " opt
    case "$opt" in
        0) exit 0 ;;
        1) clear; action_view ;;
        2) action_reconfig; exit 0 ;;
        3) action_edit ;;
        4) systemctl start sing-box 2>/dev/null || rc-service sing-box start; info "指令下发成功。" ;;
        5) systemctl stop sing-box 2>/dev/null || rc-service sing-box stop; info "服务已停止。" ;;
        6) systemctl restart sing-box 2>/dev/null || rc-service sing-box restart; info "服务已重启。" ;;
        7) systemctl status sing-box 2>/dev/null || rc-service sing-box status || true ;;
        8)
            if [ -f /root/install_sing_box.sh ]; then
                bash /root/install_sing_box.sh --upgrade-singbox
            else
                warn "未找到安装脚本，请手动升级 sing-box"
            fi
            systemctl restart sing-box 2>/dev/null || rc-service sing-box restart || true
            info "sing-box 升级完成"
            ;;
        9)
            systemctl disable --now sing-box 2>/dev/null || rc-service sing-box stop || true
            rm -rf /etc/sing-box /usr/local/bin/sb /etc/systemd/system/sing-box.service /etc/init.d/sing-box
            info "sing-box 卸载完成。"
            exit 0
            ;;
        *) warn "请输入正确的菜单序号！" ;;
    esac
    echo ""
done
SB_SCRIPT
    chmod +x "$SB_PATH"
    # 将自身备份至 /root 下，保证菜单追加功能在任何时候都能被 sb 唤醒调用
    # 注意：仅当 $0 是普通文件时才备份（避免 bash <(curl ...) 时 /dev/fd/xx 被截断）
    if [ -f "$0" ] && [ -r "$0" ]; then
        case "$0" in
            /dev/fd/*|/proc/*/fd/*)
                : # 进程替换(fd)场景，跳过备份
                ;;
            *)
                cp "$0" /root/install_sing_box.sh 2>/dev/null || true
                ;;
        esac
    fi
}

# -----------------------
# 入口
case "${1:-}" in
    --show-links)
        detect_os
        load_state
        prompt_node_suffix
        resolve_pub_ip
        output_format_result
        exit 0
        ;;
    --upgrade-singbox)
        detect_os
        check_root
        init_bootstrap
        install_pkg || exit 1
        install_singbox_binary_sync
        bootstrap_cleanup
        exit 0
        ;;
esac

detect_os
check_root
load_state
bootstrap_start

main_install
create_sb_panel
output_format_result
bootstrap_cleanup