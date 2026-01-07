#!/bin/bash
# =================================================================
# Script Name: Shadowsocks-Rust 多节点极速管理版 (信息增强)
# Author:      LivisSnack <https://livissnack.com>
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

# --- 状态显示函数 ---
log_info()    { echo -e "${GREEN}[✔]${PLAIN} ${1}"; }
log_warn()    { echo -e "${YELLOW}[!]${PLAIN} ${1}"; }
log_error()   { echo -e "${RED}[✘]${PLAIN} ${1}"; }
log_progress() {
    echo -e "${BLUE}[Step $1/$2]${PLAIN} ${YELLOW}$3...${PLAIN}"
}

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

# --- 核心下载逻辑 ---
download_rust_bin() {
    if [[ ! -f /usr/local/bin/ssserver ]]; then
        echo -e "\n${BLUE}首次运行，开始部署核心环境...${PLAIN}"

        log_progress "1" "2" "配置目标版本信息"
        get_arch
        local latest_ver="v1.24.0"
        log_info "目标版本: $latest_ver"

        log_progress "2" "2" "开始流式下载并解压 (.tar.gz)"
        local url="https://raw.githubusercontent.com/livissnack/Proxy/main/shadowsocks-${latest_ver}.${ARCH}.tar.gz"

        # 使用 -xz 解压 .tar.gz 文件
        curl -L "$url" | tar -xz -C /usr/local/bin/ ssserver ssurl

        if [[ ! -f /usr/local/bin/ssserver ]]; then
            log_error "下载或解压失败！请确认 URL 是否有效。"
            exit 1
        fi

        chmod +x /usr/local/bin/ssserver /usr/local/bin/ssurl
        log_info "Shadowsocks-Rust 核心程序部署成功！\n"
    fi
}

# --- 生成 URL 函数 ---
generate_url() {
    local p=$1; local m=$2; local k=$3
    # 格式: ss://base64(method:pass)@ip:port#备注
    /usr/local/bin/ssurl --encode "ss://${m}:${k}@${IP4}:${p}#livis-ss-${IP4}"
}

# --- 安装节点逻辑 ---
install_node() {
    download_rust_bin
    echo -e "${BLUE}>>> 进入节点配置流程${PLAIN}"
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

    echo -e "选择加密方式:"
    for i in "${!CIPHER_LIST[@]}"; do echo -e " ${GREEN}$((i+1)).${PLAIN} ${CIPHER_LIST[$i]}"; done
    read -p "选择 [1-3] (默认1): " pick
    [[ -z "$pick" ]] && pick=1
    CIPHER=${CIPHER_LIST[$((pick-1))]}

    read -p "设置密码 (回车随机): " PASS
    [[ -z "${PASS}" ]] && PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 40)

    echo -e "\n${BLUE}开始部署节点...${PLAIN}"
    if [[ ${OS} == "apk" ]]; then
        cat > /etc/init.d/ss-rust-${PORT} <<EOF
#!/sbin/openrc-run
command="/usr/local/bin/ssserver"
command_args="-s 0.0.0.0:${PORT} -m ${CIPHER} -k ${PASS} -u"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
EOF
        chmod +x /etc/init.d/ss-rust-${PORT}
        rc-update add ss-rust-${PORT} >/dev/null 2>&1
        service ss-rust-${PORT} restart
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
        systemctl enable ss-rust-${PORT} >/dev/null 2>&1
        systemctl restart ss-rust-${PORT}
    fi

    log_info "节点 ${PORT} 启动成功！"
    local ss_link=$(generate_url "$PORT" "$CIPHER" "$PASS")
    echo -e "\n${GREEN}节点链接:${PLAIN} ${RED}${ss_link}${PLAIN}"
    echo -e "\n请按回车键返回菜单..." && read
}

# --- 查看节点 (增强版) ---
list_nodes() {
    log_info "正在检索详细节点信息..."
    local files=$(ls /etc/systemd/system/ss-rust-*.service /etc/init.d/ss-rust-* 2>/dev/null)

    if [[ -z "$files" ]]; then
        log_warn "未发现任何已安装的节点"
    else
        echo -e "${BLUE}================================================================================${PLAIN}"
        for f in $files; do
            local p=$(echo $f | grep -oP 'ss-rust-\K[0-9]+')
            local m=$(grep -oP '(?<=-m )[^ ]+' $f)
            local k=$(grep -oP '(?<=-k )[^ ]+' $f)
            local lnk=$(generate_url "$p" "$m" "$k")

            echo -e "【节点端口】: ${GREEN}${p}${PLAIN}"
            echo -e "  - 协议: Shadowsocks (Rust)"
            echo -e "  - IP地址: ${YELLOW}${IP4}${PLAIN}"
            echo -e "  - 加密方式: ${YELLOW}${m}${PLAIN}"
            echo -e "  - 节点密码: ${YELLOW}${k}${PLAIN}"
            echo -e "  - 节点链接: ${RED}${lnk}${PLAIN}"
            echo -e "${BLUE}--------------------------------------------------------------------------------${PLAIN}"
        done
        echo -e "${BLUE}================================================================================${PLAIN}"
    fi
    read -p "回车返回..." temp
}

# --- 删除节点 ---
delete_node() {
    read -p "请输入要删除的节点端口: " P_DEL
    [[ -z "$P_DEL" ]] && return
    log_progress "1" "1" "正在清理服务并停止进程..."
    if [[ ${OS} == "apk" ]]; then
        service ss-rust-${P_DEL} stop >/dev/null 2>&1
        rc-update del ss-rust-${P_DEL} >/dev/null 2>&1
        rm -f /etc/init.d/ss-rust-${P_DEL}
    else
        systemctl stop ss-rust-${P_DEL} >/dev/null 2>&1
        systemctl disable ss-rust-${P_DEL} >/dev/null 2>&1
        rm -f /etc/systemd/system/ss-rust-${P_DEL}.service
        systemctl daemon-reload
    fi
    log_info "端口 ${P_DEL} 相关配置已清理完毕"
    sleep 1
}

# --- 一键重启 ---
restart_all() {
    log_info "正在尝试重启所有 Shadowsocks-Rust 节点..."
    if [[ ${OS} == "apk" ]]; then
        local files=$(ls /etc/init.d/ss-rust-* 2>/dev/null)
        for f in $files; do
            local svc=$(basename $f); service $svc restart >/dev/null 2>&1
            echo -e " 重启服务: ${GREEN}$svc${PLAIN} ... [OK]"
        done
    else
        systemctl restart "ss-rust-*" >/dev/null 2>&1
        log_info "所有 ss-rust-* 服务已完成重启指令发送"
    fi
    sleep 1
    echo -e "\n请按回车键返回菜单..." && read
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}########################################${PLAIN}"
        echo -e "${BLUE}#${PLAIN}    ${GREEN}Shadowsocks-Rust 多节点管理${PLAIN}      ${BLUE}#${PLAIN}"
        echo -e "${BLUE}#${PLAIN}       [ IP: $IP4 | ARCH: $CPU_ARCH ]      ${BLUE}#${PLAIN}"
        echo -e "${BLUE}########################################${PLAIN}"
        echo " 1) 添加新节点 (部署+启动)"
        echo " 2) 查看所有节点 (详细信息+URL)"
        echo " 3) 删除指定节点"
        echo " 4) 一键重启所有节点"
        echo " 0) 退出脚本"
        echo ""
        read -p "选择操作 [0-4]: " num
        case "$num" in
            1) install_node ;;
            2) list_nodes ;;
            3) delete_node ;;
            4) restart_all ;;
            0) exit 0 ;;
            *) continue ;;
        esac
    done
}

check_env
main_menu