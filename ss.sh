#!/bin/bash
# =================================================================
# Script Name: Shadowsocks-Rust 多节点极速版
# Author:      LivisSnack <https://livissnack.com>
# Description: 流式下载，不留残余，支持多节点并发
# =================================================================

# --- 基础配置 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

IP4=$(curl -sL -4 ip.sb || echo "127.0.0.1")
CPU_ARCH=$(uname -m)
CIPHER_LIST=(aes-256-gcm aes-128-gcm chacha20-ietf-poly1305)

log_info()    { echo -e "${GREEN}[✔]${PLAIN} ${1}"; }
log_warn()    { echo -e "${YELLOW}[!]${PLAIN} ${1}"; }
log_error()   { echo -e "${RED}[✘]${PLAIN} ${1}"; }
log_step()    { echo -e "${BLUE}==>${PLAIN} ${1}"; }

# --- 环境检查 ---
check_env() {
    [[ $EUID -ne 0 ]] && log_error "请使用 root 权限运行" && exit 1
    if [[ -n "$(command -v yum)" ]]; then OS="yum"; elif [[ -n "$(command -v apt)" ]]; then OS="apt"; elif [[ -n "$(command -v apk)" ]]; then OS="apk"; else log_error "不支持的系统"; exit 1; fi
}

get_arch() {
    case "$CPU_ARCH" in
        x86_64|amd64) ARCH="x86_64-unknown-linux-musl" ;;
        aarch64|armv8) ARCH="aarch64-unknown-linux-musl" ;;
        *) log_error "暂不支持的架构: $CPU_ARCH"; exit 1 ;;
    esac
}

# --- 依赖安装 (解决卡死问题) ---
install_deps() {
    log_step "正在配置环境依赖 (xz, tar, curl)..."
    case ${OS} in
        yum)
            yum makecache quiet
            yum install -y xz tar curl wget net-tools >/dev/null 2>&1
            ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq xz-utils tar curl wget net-tools >/dev/null 2>&1
            ;;
        apk)
            apk add --no-cache xz tar curl wget net-tools >/dev/null 2>&1
            ;;
    esac
}

# --- 直接流式下载 (不留压缩包) ---
download_rust_bin() {
    if [[ ! -f /usr/local/bin/ssserver ]]; then
        install_deps
        log_step "正在流式下载 Shadowsocks-Rust 核心..."
        get_arch

        # 获取最新版本号
        local latest_ver=$(curl -s --connect-timeout 5 "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [[ -z "$latest_ver" ]] && latest_ver="v1.18.3"

        local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_ver}/shadowsocks-${latest_ver}.${ARCH}.tar.xz"

        # 【核心优化】：直接通过管道解压，不在硬盘生成 .tar.xz
        curl -L -s "$url" | tar -xJ -C /usr/local/bin/ ssserver ssurl

        if [[ ! -f /usr/local/bin/ssserver ]]; then
            log_error "下载失败！请检查网络是否能访问 GitHub。"
            exit 1
        fi

        chmod +x /usr/local/bin/ssserver /usr/local/bin/ssurl
        log_info "核心程序部署成功 ($latest_ver)"
    fi
}

# --- 添加新节点 ---
install_node() {
    download_rust_bin
    echo -e "\n${BLUE}>>> 节点配置${PLAIN}"

    while true; do
        read -p "请输入端口 [1-65535]: " PORT
        [[ -z "$PORT" ]] && PORT="6666"
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            log_error "端口格式错误"
        elif netstat -tuln | grep -q ":${PORT} "; then
            log_warn "端口 ${PORT} 已被占用"
        else
            break
        fi
    done

    echo -e "选择加密:"
    for i in "${!CIPHER_LIST[@]}"; do echo -e " ${GREEN}$((i+1)).${PLAIN} ${CIPHER_LIST[$i]}"; done
    read -p "选择 [1-3] (默认1): " pick
    [[ -z "$pick" ]] && pick=1
    CIPHER=${CIPHER_LIST[$((pick-1))]}

    read -p "设置密码 (回车随机): " PASS
    [[ -z "${PASS}" ]] && PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    # 部署服务
    if [[ ${OS} == "apk" ]]; then
        cat > /etc/init.d/ss-rust-${PORT} <<EOF
#!/sbin/openrc-run
command="/usr/local/bin/ssserver"
command_args="-s 0.0.0.0:${PORT} -m ${CIPHER} -k ${PASS} -u"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
EOF
        chmod +x /etc/init.d/ss-rust-${PORT}
        rc-update add ss-rust-${PORT} && service ss-rust-${PORT} restart
    else
        cat > /etc/systemd/system/ss-rust-${PORT}.service <<EOF
[Unit]
Description=ShadowSocks-Rust Port ${PORT}
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -s 0.0.0.0:${PORT} -m ${CIPHER} -k ${PASS} -u
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ss-rust-${PORT} && systemctl restart ss-rust-${PORT}
    fi

    log_info "端口 ${PORT} 启动成功"
    generate_url "$PORT" "$CIPHER" "$PASS"
    echo -e "回车返回菜单..." && read
}

# --- 查看所有节点 ---
list_nodes() {
    log_step "运行中的节点列表："
    local files=$(ls /etc/systemd/system/ss-rust-*.service /etc/init.d/ss-rust-* 2>/dev/null)
    if [[ -z "$files" ]]; then
        log_warn "空空如也"
    else
        echo -e "${BLUE}--------------------------------------------------${PLAIN}"
        for f in $files; do
            local p=$(echo $f | grep -oP 'ss-rust-\K[0-9]+')
            local m=$(grep -oP '(?<=-m )[^ ]+' $f)
            local k=$(grep -oP '(?<=-k )[^ ]+' $f)
            echo -e " 端口: ${GREEN}${p}${PLAIN} | 加密: ${YELLOW}${m}${PLAIN} | 密码: ${k}"
        done
        echo -e "${BLUE}--------------------------------------------------${PLAIN}"
    fi
    echo -e "回车返回菜单..." && read
}

# --- 删除节点 ---
delete_node() {
    read -p "请输入要删除的节点端口: " P_DEL
    [[ -z "$P_DEL" ]] && return
    if [[ ${OS} == "apk" ]]; then
        service ss-rust-${P_DEL} stop && rc-update del ss-rust-${P_DEL}
        rm -f /etc/init.d/ss-rust-${P_DEL}
    else
        systemctl stop ss-rust-${P_DEL} && systemctl disable ss-rust-${P_DEL}
        rm -f /etc/systemd/system/ss-rust-${P_DEL}.service && systemctl daemon-reload
    fi
    log_info "节点 ${P_DEL} 已清理"
}

generate_url() {
    local url=$(/usr/local/bin/ssurl --encode "ss://${2}:${3}@${IP4}:${1}#SS-Rust-${1}")
    echo -e " ${BLUE}节点链接:${PLAIN} ${RED}${url}${PLAIN}"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}########################################${PLAIN}"
        echo -e "${BLUE}#${PLAIN}    ${GREEN}Shadowsocks-Rust 多节点管理${PLAIN}      ${BLUE}#${PLAIN}"
        echo -e "${BLUE}########################################${PLAIN}"
        echo " 1) 添加新节点"
        echo " 2) 查看所有节点"
        echo " 3) 删除指定节点"
        echo " 0) 退出"
        echo ""
        read -p "选择操作: " num
        case "$num" in
            1) install_node ;;
            2) list_nodes ;;
            3) delete_node ;;
            0) exit 0 ;;
            *) continue ;;
        esac
    done
}

check_env
main_menu