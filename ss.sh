#!/bin/bash
# =================================================================
# Script Name: Shadowsocks-Rust 多节点版
# Author:      LivisSnack <https://livissnack.com>
# Description: 基于高效的 Rust 版本，支持单机多端口同时运行
# =================================================================

# --- 基础配置 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

IP4=$(curl -sL -4 ip.sb || echo "127.0.0.1")
CPU_ARCH=$(uname -m)
# Rust 版推荐的现代加密方式
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

# --- 架构适配 (Shadowsocks-Rust 命名规范) ---
get_arch() {
    case "$CPU_ARCH" in
        x86_64|amd64) ARCH="x86_64-unknown-linux-musl" ;;
        aarch64|armv8) ARCH="aarch64-unknown-linux-musl" ;;
        *) log_error "暂不支持的架构: $CPU_ARCH"; exit 1 ;;
    esac
}

# --- 核心程序下载 ---
download_rust_bin() {
    if [[ ! -f /usr/local/bin/ssserver ]]; then
        log_step "准备环境并下载核心程序..."

        # 1. 快速安装解压依赖（仅需几秒）
        if [[ ${OS} == "apk" ]]; then
            apk add xz tar curl >/dev/null 2>&1
        elif [[ ${OS} == "yum" ]]; then
            yum install -y xz tar curl >/dev/null 2>&1
        else
            apt-get update >/dev/null 2>&1 && apt-get install -y xz-utils tar curl >/dev/null 2>&1
        fi

        # 2. 获取架构和最新版本
        get_arch
        local latest_ver=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [[ -z "$latest_ver" ]] && latest_ver="v1.18.3"

        local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_ver}/shadowsocks-${latest_ver}.${ARCH}.tar.xz"

        # 3. 直接下载并解压到 /usr/local/bin，不保存压缩包
        log_step "正在从 GitHub 获取 ssserver (不占用临时空间)..."
        curl -L "$url" | tar -xJ -C /usr/local/bin/ ssserver ssurl

        if [[ $? -eq 0 ]]; then
            chmod +x /usr/local/bin/ssserver /usr/local/bin/ssurl
            log_info "核心程序安装成功！"
        else
            log_error "下载或解压失败，请检查网络连接或 GitHub 访问权限。"
            exit 1
        fi
    fi
}

# --- 添加新节点 ---
install_node() {
    log_step "开始添加新节点..."
    download_rust_bin

    # 端口检查
    while true; do
        read -p "请输入节点端口 [1-65535]: " PORT
        if [[ ! "${PORT}" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            log_error "无效端口！"
        elif netstat -tuln | grep -q ":${PORT} "; then
            log_warn "端口 ${PORT} 已被占用，请更换。"
        else
            break
        fi
    done

    # 加密与密码
    echo -e "\n选择加密方式:"
    for i in "${!CIPHER_LIST[@]}"; do echo -e " ${GREEN}$((i+1)).${PLAIN} ${CIPHER_LIST[$i]}"; done
    read -p "选择 [1-3] (默认1): " pick
    [[ -z "$pick" ]] && pick=1
    CIPHER=${CIPHER_LIST[$((pick-1))]}

    read -p "设置密码 (回车随机): " PASS
    [[ -z "${PASS}" ]] && PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    # 部署 Systemd 服务 (Rust版建议使用配置文件或命令行)
    # 为了方便多开，我们直接将配置嵌入命令行参数
    if [[ ${OS} == "apk" ]]; then
        cat > /etc/init.d/ss-rust-${PORT} <<EOF
#!/sbin/openrc-run
command="/usr/local/bin/ssserver"
command_args="-s 0.0.0.0:${PORT} -m ${CIPHER} -k ${PASS} -u"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
EOF
        chmod +x /etc/init.d/ss-rust-${PORT}
        rc-update add ss-rust-${PORT} && service ss-rust-${PORT} start
    else
        cat > /etc/systemd/system/ss-rust-${PORT}.service <<EOF
[Unit]
Description=ShadowSocks-Rust Port ${PORT}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ssserver -s 0.0.0.0:${PORT} -m ${CIPHER} -k ${PASS} -u
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ss-rust-${PORT} && systemctl restart ss-rust-${PORT}
    fi

    log_info "Rust 节点 [端口 ${PORT}] 启动成功！"
    generate_url "$PORT" "$CIPHER" "$PASS"
}

# --- 查看节点 ---
list_nodes() {
    log_step "当前运行中的 Rust 节点："
    local files=$(ls /etc/systemd/system/ss-rust-*.service /etc/init.d/ss-rust-* 2>/dev/null)

    if [[ -z "$files" ]]; then
        log_warn "暂无运行中的节点。"
        return
    fi

    echo -e "${BLUE}--------------------------------------------------${PLAIN}"
    for f in $files; do
        local p=$(echo $f | grep -oP 'ss-rust-\K[0-9]+')
        local m=$(grep -oP '(?<=-m )[^ ]+' $f)
        local k=$(grep -oP '(?<=-k )[^ ]+' $f)
        echo -e " 端口: ${GREEN}${p}${PLAIN} | 加密: ${YELLOW}${m}${PLAIN} | 密码: ${k}"
    done
    echo -e "${BLUE}--------------------------------------------------${PLAIN}"
}

# --- 删除节点 ---
delete_node() {
    list_nodes
    read -p "请输入要删除的节点端口: " P_DEL
    [[ -z "$P_DEL" ]] && return

    if [[ ${OS} == "apk" ]]; then
        service ss-rust-${P_DEL} stop && rc-update del ss-rust-${P_DEL}
        rm -f /etc/init.d/ss-rust-${P_DEL}
    else
        systemctl stop ss-rust-${P_DEL} && systemctl disable ss-rust-${P_DEL}
        rm -f /etc/systemd/system/ss-rust-${P_DEL}.service
        systemctl daemon-reload
    fi
    log_info "节点 ${P_DEL} 已卸载。"
}

# --- 生成链接 (使用 Rust 自带工具更标准) ---
generate_url() {
    local p=$1; local m=$2; local k=$3
    # 使用 ssurl 工具生成官方格式链接
    local url=$(/usr/local/bin/ssurl --encode "ss://${m}:${k}@${IP4}:${p}#SS-Rust-${p}")
    echo -e " ${BLUE}节点链接:${PLAIN} ${RED}${url}${PLAIN}"
}

# --- 菜单 ---
main_menu() {
    clear
    echo -e "${BLUE}########################################${PLAIN}"
    echo -e "${BLUE}#${PLAIN}    ${GREEN}Shadowsocks-Rust 多节点管理${PLAIN}      ${BLUE}#${PLAIN}"
    echo -e "${BLUE}#${PLAIN}       内存占用更低 | 性能更强         ${BLUE}#${PLAIN}"
    echo -e "${BLUE}########################################${PLAIN}"
    echo " 1) 添加新节点"
    echo " 2) 查看所有节点"
    echo " 3) 删除指定节点"
    echo " -----------------------"
    echo " 4) 重启所有 Rust 节点"
    echo " 0) 退出"
    echo ""
    read -p "选择操作: " num
    case "$num" in
        1) install_node ;;
        2) list_nodes ;;
        3) delete_node ;;
        4)
           if [[ ${OS} == "apk" ]]; then service ss-rust- restart; else systemctl restart "ss-rust-*"; fi
           log_info "重启任务已提交"
           ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

check_env
main_menu