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

redhat_install_pkg() {
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@" || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@" || return 1
    else
        err "未找到 dnf 或 yum，无法安装依赖"
        return 1
    fi
}

detect_os
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        exit 1
    fi
}
check_root

install_deps() {
    info "安装系统依赖..."
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq || { err "依赖安装失败"; exit 1; }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || { err "依赖安装失败"; exit 1; }
            ;;
        redhat)
            redhat_install_pkg curl ca-certificates openssl jq coreutils || { err "依赖安装失败"; exit 1; }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac
}
install_deps

# -----------------------
# 加载已有缓存状态
ENABLE_SS=false; ENABLE_HY2=false; ENABLE_TUIC=false; ENABLE_REALITY=false
SS_PORT=""; SS_PSK=""; SS_METHOD="2022-blake3-aes-128-gcm"
HY2_PORT=""; HY2_PSK=""
TUIC_PORT=""; TUIC_UUID=""; TUIC_PSK=""
REALITY_PORT=""; REALITY_UUID=""; REALITY_PK=""; REALITY_SID=""; REALITY_PUB=""; REALITY_SNI="addons.mozilla.org"
CUSTOM_IP=""

if [ -f "$PROTOCOLS_FILE" ]; then
    . "$PROTOCOLS_FILE"
fi
if [ -f "$CACHE_FILE" ]; then
    . "$CACHE_FILE"
fi

# -----------------------
# 选择要部署的协议 (支持追加)
select_protocols() {
    info "=== 协议部署管理 ==="
    local has_existing=false
    if $ENABLE_SS || $ENABLE_HY2 || $ENABLE_TUIC || $ENABLE_REALITY; then
        has_existing=true
        warn "检测到当前已安装协议: "
        $ENABLE_SS && echo "  - Shadowsocks"
        $ENABLE_HY2 && echo "  - Hysteria2"
        $ENABLE_TUIC && echo "  - TUIC"
        $ENABLE_REALITY && echo "  - VLESS Reality"
        echo "--------------------------------"
        echo "1) 追加/修改协议 (保留未勾选的现有协议)"
        echo "2) 全新覆盖安装 (清除所有老协议，重新选择)"
        read -r -p "请选择操作 [1-2] (默认 1): " mode_choice
        if [ "${mode_choice:-1}" = "2" ]; then
            ENABLE_SS=false; ENABLE_HY2=false; ENABLE_TUIC=false; ENABLE_REALITY=false
        fi
    fi

    echo ""
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo ""
    read -r -p "请输入要安装/保留的协议编号(多个用空格分隔，如 1 2 4): " protocol_input

    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done

    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY; then
        err "未选择任何协议, 退出"
        exit 1
    fi

    mkdir -p /etc/sing-box
    cat > "$PROTOCOLS_FILE" <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
EOF
}

select_protocols

# 选择SS加密方式
select_ss_method() {
    if ! $ENABLE_SS; return 0; fi
    if [ -n "${SS_METHOD:-}" ] && [ "$SS_METHOD" != "null" ]; then
        return 0 # 已有则不重复询问
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
select_ss_method

# 询问连接ip和sni配置
echo ""
read -r -p "请输入节点连接 IP 或 DDNS 域名 (留空默认自动获取出口 IP): " INPUT_IP
if [ -n "$INPUT_IP" ]; then
    CUSTOM_IP="$(echo "$INPUT_IP" | tr -d '[:space:]')"
fi

if $ENABLE_REALITY && [ "${REALITY_SNI:-addons.mozilla.org}" = "addons.mozilla.org" ]; then
    read -r -p "请输入 Reality 的 SNI (留空默认 addons.mozilla.org): " INPUT_SNI
    REALITY_SNI="$(echo "${INPUT_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
fi

# 交互端口与密钥
get_config() {
    info "开始配置端口和密码..."
    if $ENABLE_SS && [ -z "${SS_PORT:-}" ]; then
        read -r -p "请输入 SS 端口 (留空随机): " UP_SS
        SS_PORT="${UP_SS:-$(rand_port)}"
        SS_PSK=$(rand_pass)
    fi
    if $ENABLE_HY2 && [ -z "${HY2_PORT:-}" ]; then
        read -r -p "请输入 HY2 端口 (留空随机): " UP_HY2
        HY2_PORT="${UP_HY2:-$(rand_port)}"
        HY2_PSK=$(rand_pass)
    fi
    if $ENABLE_TUIC && [ -z "${TUIC_PORT:-}" ]; then
        read -r -p "请输入 TUIC 端口 (留空随机): " UP_TUIC
        TUIC_PORT="${UP_TUIC:-$(rand_port)}"
        TUIC_PSK=$(rand_pass)
        TUIC_UUID=$(rand_uuid)
    fi
    if $ENABLE_REALITY && [ -z "${REALITY_PORT:-}" ]; then
        read -r -p "请输入 VLESS Reality 端口 (留空随机): " UP_R
        REALITY_PORT="${UP_R:-$(rand_port)}"
        REALITY_UUID=$(rand_uuid)
    fi
}
get_config

# 配置节点名称后缀
if [ ! -f /root/node_names.txt ]; then
    read -r -p "请输入节点自定义名称后缀 (留空则无后缀): " user_name
    if [[ -n "$user_name" ]]; then
        echo "-${user_name}" > /root/node_names.txt
    else
        echo "" > /root/node_names.txt
    fi
fi
suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")

# 安装 sing-box本体
install_singbox() {
    if command -v sing-box >/dev/null 2>&1; then
        return 0
    fi
    info "开始安装 sing-box..."
    case "$OS" in
        alpine)
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || exit 1
            ;;
        debian|redhat)
            bash <(curl -fsSL https://sing-box.app/install.sh) || exit 1
            ;;
        *)
            err "不支持的系统"; exit 1
            ;;
    esac
}
install_singbox

generate_reality_keys() {
    if ! $ENABLE_REALITY; then return 0; fi
    if [ -n "${REALITY_PK:-}" ] && [ -n "${REALITY_PUB:-}" ]; then return 0; fi
    info "生成 Reality 密钥对..."
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1)
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1)
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
}
generate_reality_keys

generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then return 0; fi
    mkdir -p /etc/sing-box/certs
    if [ ! -f /etc/sing-box/certs/fullchain.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 -subj "/CN=www.bing.com"
    fi
}
generate_cert

# 生成配置文件 (通过高内聚的 JSON 拼接生成)
create_config() {
    info "生成配置文件: $CONFIG_PATH"
    local TEMP_INBOUNDS="/tmp/sb_inbounds_tmp.json"
    echo "[]" > "$TEMP_INBOUNDS"

    if $ENABLE_SS; then
        jq --argjson port "$SS_PORT" --arg method "$SS_METHOD" --arg psk "$SS_PSK" \
        '. += [{ "type": "shadowsocks", "listen": "::", "listen_port": $port, "method": $method, "password": $psk, "tag": "ss-in" }]' \
        "$TEMP_INBOUNDS" > "$TEMP_INBOUNDS.bak" && mv "$TEMP_INBOUNDS.bak" "$TEMP_INBOUNDS"
    fi

    if $ENABLE_HY2; then
        jq --argjson port "$HY2_PORT" --arg psk "$HY2_PSK" \
        '. += [{ "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $port, "users": [{"password": $psk}], "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/sing-box/certs/fullchain.pem", "key_path": "/etc/sing-box/certs/privkey.pem"} }]' \
        "$TEMP_INBOUNDS" > "$TEMP_INBOUNDS.bak" && mv "$TEMP_INBOUNDS.bak" "$TEMP_INBOUNDS"
    fi

    if $ENABLE_TUIC; then
        jq --argjson port "$TUIC_PORT" --arg uuid "$TUIC_UUID" --arg psk "$TUIC_PSK" \
        '. += [{ "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": $port, "users": [{"uuid": $uuid, "password": $psk}], "congestion_control": "bbr", "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/sing-box/certs/fullchain.pem", "key_path": "/etc/sing-box/certs/privkey.pem"} }]' \
        "$TEMP_INBOUNDS" > "$TEMP_INBOUNDS.bak" && mv "$TEMP_INBOUNDS.bak" "$TEMP_INBOUNDS"
    fi

    if $ENABLE_REALITY; then
        jq --argjson port "$REALITY_PORT" --arg uuid "$REALITY_UUID" --arg sni "$REALITY_SNI" --arg pk "$REALITY_PK" --arg sid "$REALITY_SID" \
        '. += [{ "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": $port, "users": [{"uuid": $uuid, "flow": "xtls-rprx-vision"}], "tls": {"enabled": true, "server_name": $sni, "reality": {"enabled": true, "handshake": {"server": $sni, "server_port": 443}, "private_key": $pk, "short_id": [$sid]}} }]' \
        "$TEMP_INBOUNDS" > "$TEMP_INBOUNDS.bak" && mv "$TEMP_INBOUNDS.bak" "$TEMP_INBOUNDS"
    fi

    # 组装完整主体
    jq -n --argjson inbounds "$(<"$TEMP_INBOUNDS")" \
    '{ log: { level: "info", timestamp: true }, inbounds: $inbounds, outbounds: [{ type: "direct", tag: "direct-out" }] }' \
    > "$CONFIG_PATH"
    rm -f "$TEMP_INBOUNDS"

    # 写缓存
    cat > "$CACHE_FILE" <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
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
CUSTOM_IP=$CUSTOM_IP
EOF
}
create_config

# 守护进程与服务托管
setup_service() {
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
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
        rc-service sing-box restart || exit 1
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || exit 1
    fi
}
setup_service

# 防火墙端口自动放行
open_firewalld_for_singbox() {
    [ "$OS" != "redhat" ] && return 0
    command -v firewall-cmd >/dev/null 2>&1 || return 0
    firewall-cmd --state >/dev/null 2>&1 || return 0

    _fw_port() {
        [ -z "$1" ] && return 0
        firewall-cmd --permanent --add-port="${1}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${1}/udp" >/dev/null 2>&1 || true
    }
    $ENABLE_SS && _fw_port "$SS_PORT"
    $ENABLE_HY2 && _fw_port "$HY2_PORT"
    $ENABLE_TUIC && _fw_port "$TUIC_PORT"
    $ENABLE_REALITY && _fw_port "$REALITY_PORT"
    firewall-cmd --reload >/dev/null 2>&1 || true
}
open_firewalld_for_singbox() { :; } # 引用外置或内嵌

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"; return 0
        fi
    done
    echo "YOUR_SERVER_IP"
}

if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
else
    PUB_IP=$(get_public_ip)
fi

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
    # 重新载入主安装脚本的格式化输出
    if [ -f /root/install_sing_box.sh ]; then
        bash /root/install_sing_box.sh <<EOF
1
0
EOF
    else
        cat "$CACHE_FILE"
    fi
}

action_reconfig() {
    if [ -f /root/install_sing_box.sh ]; then
        clear
        exec bash /root/install_sing_box.sh
    else
        err "未在 /root/install_sing_box.sh 找到原始安装脚本，无法追加协议。"
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
            bash <(curl -fsSL https://sing-box.app/install.sh) 2>/dev/null || apk upgrade sing-box
            systemctl restart sing-box 2>/dev/null || rc-service sing-box restart || true
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
    cp "$0" /root/install_sing_box.sh 2>/dev/null || true
}

create_sb_panel
output_format_result