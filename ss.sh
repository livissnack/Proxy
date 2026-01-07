#!/bin/bash
# =================================================================
# Script Name: Shadowsocks-Rust 多节点全能兼容版
# Support:     Systemd, OpenRC, Docker, LXC, NAT, VPS
# OS:          Debian, Ubuntu, Alpine, CentOS, etc.
# =================================================================

# --- 1. 基础配置与颜色 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

CONF_DIR="/etc/ss-rust"
mkdir -p $CONF_DIR

IP4=$(curl -sL -4 ip.sb || curl -sL -4 ifconfig.me || echo "127.0.0.1")
CPU_ARCH=$(uname -m)
CIPHER_LIST=(aes-256-gcm aes-128-gcm chacha20-ietf-poly1305)

# --- 2. 核心环境检测 ---
check_env() {
    [[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1

    # 操作系统检测
    if [[ -f /etc/alpine-release ]]; then OS="alpine";
    elif command -v apt >/dev/null 2>&1; then OS="debian";
    elif command -v yum >/dev/null 2>&1; then OS="centos";
    fi

    # 运行环境/初始化系统检测
    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup; then
        INIT_TYPE="nohup" # 容器环境，降级使用进程管理
    elif [[ -x /sbin/init ]] || [[ -x /lib/systemd/systemd ]]; then
        if command -v systemctl >/dev/null 2>&1; then INIT_TYPE="systemd";
        elif command -v rc-service >/dev/null 2>&1; then INIT_TYPE="openrc";
        else INIT_TYPE="nohup"; fi
    else
        INIT_TYPE="nohup";
    fi
}

# --- 3. 依赖与核心安装 ---
install_core() {
    if [[ ! -f /usr/local/bin/ssserver ]]; then
        case "$CPU_ARCH" in
            x86_64|amd64) ARCH="x86_64-unknown-linux-musl" ;;
            aarch64|armv8) ARCH="aarch64-unknown-linux-musl" ;;
            *) echo "不支持的架构"; exit 1 ;;
        esac

        local ver="v1.24.0"
        local url="https://raw.githubusercontent.com/livissnack/Proxy/main/shadowsocks-${ver}.${ARCH}.tar.gz"
        echo -e "${YELLOW}正在从下载核心程序...${PLAIN}"
        curl -Lk "$url" | tar -xz -C /usr/local/bin/ ssserver ssurl
        chmod +x /usr/local/bin/ssserver /usr/local/bin/ssurl
    fi
}

# --- 4. 辅助函数 ---
generate_url() {
    local auth=$(echo -n "${2}:${3}" | openssl base64 -A)
    echo -n "ss://${auth}@${IP4}:${1}#livis-ss-${IP4}"
}

display_node() {
    local lnk=$(generate_url "$1" "$2" "$3")
    echo -e "${BLUE}--------------------------------------------------------------------------------${PLAIN}"
    echo -e " 端口: ${GREEN}$1${PLAIN} | 加密: ${YELLOW}$2${PLAIN} | 密码: ${YELLOW}$3${PLAIN}"
    echo -e " 链接: ${RED}${lnk}${PLAIN}"
}

# --- 5. 节点控制逻辑 (兼容核心) ---
manage_service() {
    local action=$1 # start, stop, restart
    local port=$2
    local cipher=$3
    local pass=$4

    case $INIT_TYPE in
        "systemd")
            if [[ "$action" == "start" || "$action" == "restart" ]]; then
                cat > /etc/systemd/system/ss-rust-${port}.service <<EOF
[Unit]
Description=SS-Rust Port ${port}
After=network.target
[Service]
ExecStart=/usr/local/bin/ssserver -s 0.0.0.0:${port} -m ${cipher} -k ${pass} -u
Restart=always
[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable ss-rust-${port} >/dev/null 2>&1
                systemctl restart ss-rust-${port}
            else
                systemctl stop ss-rust-${port} >/dev/null 2>&1
                systemctl disable ss-rust-${port} >/dev/null 2>&1
                rm -f /etc/systemd/system/ss-rust-${port}.service
            fi
            ;;
        "openrc")
            if [[ "$action" == "start" || "$action" == "restart" ]]; then
                cat > /etc/init.d/ss-rust-${port} <<EOF
#!/sbin/openrc-run
command="/usr/local/bin/ssserver"
command_args="-s 0.0.0.0:${port} -m ${cipher} -k ${pass} -u"
command_background=true
pidfile="/run/ss-rust-${port}.pid"
EOF
                chmod +x /etc/init.d/ss-rust-${port}
                rc-update add ss-rust-${port} default >/dev/null 2>&1
                service ss-rust-${port} restart
            else
                service ss-rust-${port} stop >/dev/null 2>&1
                rc-update del ss-rust-${port} >/dev/null 2>&1
                rm -f /etc/init.d/ss-rust-${port}
            fi
            ;;
        "nohup")
            # 容器/LXC 专用降级逻辑
            pkill -f "ssserver.*:${port} " >/dev/null 2>&1
            if [[ "$action" == "start" || "$action" == "restart" ]]; then
                nohup /usr/local/bin/ssserver -s 0.0.0.0:${port} -m ${cipher} -k ${pass} -u > /dev/null 2>&1 &
            fi
            ;;
    esac
}

# --- 6. 主功能函数 ---
add_node() {
    install_core
    read -p "端口 (默认6666): " PORT
    [[ -z "$PORT" ]] && PORT="6666"
    echo -e "1. aes-256-gcm\n2. aes-128-gcm\n3. chacha20-ietf-poly1305"
    read -p "选择加密 [1-3]: " CP; [[ -z "$CP" ]] && CP=1
    CIPHER=${CIPHER_LIST[$((CP-1))]}
    read -p "密码 (随机回车): " PASS; [[ -z "$PASS" ]] && PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    manage_service "start" "$PORT" "$CIPHER" "$PASS"
    echo "${CIPHER}|${PASS}" > "$CONF_DIR/${PORT}.conf"
    echo -e "${GREEN}节点已启动！${PLAIN}"
    display_node "$PORT" "$CIPHER" "$PASS"
    read -p "回车继续..."
}

list_nodes() {
    echo -e "${BLUE}=== 已安装节点列表 ===${PLAIN}"
    local count=0
    for f in $CONF_DIR/*.conf; do
        [[ ! -f "$f" ]] && continue
        count=$((count+1))
        local p=$(basename "$f" .conf)
        local c=$(cat "$f" | cut -d'|' -f1)
        local k=$(cat "$f" | cut -d'|' -f2)
        display_node "$p" "$c" "$k"
    done
    [[ $count -eq 0 ]] && echo "暂无节点"
    read -p "回车继续..."
}

del_node() {
    read -p "输入要删除的端口: " P
    if [[ -f "$CONF_DIR/${P}.conf" ]]; then
        manage_service "stop" "$P"
        rm -f "$CONF_DIR/${P}.conf"
        echo -e "${GREEN}节点 $P 已删除${PLAIN}"
    else
        echo -e "${RED}节点不存在${PLAIN}"
    fi
    sleep 1
}

restart_all() {
    echo -e "${YELLOW}正在重启所有节点...${PLAIN}"
    for f in $CONF_DIR/*.conf; do
        [[ ! -f "$f" ]] && continue
        local p=$(basename "$f" .conf)
        local c=$(cat "$f" | cut -d'|' -f1)
        local k=$(cat "$f" | cut -d'|' -f2)
        manage_service "restart" "$p" "$c" "$k"
        echo -e "重启端口 $p ... [OK]"
    done
    sleep 1
}

uninstall() {
    read -p "确定要卸载吗？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    for f in $CONF_DIR/*.conf; do
        local p=$(basename "$f" .conf)
        manage_service "stop" "$p"
    done
    rm -rf $CONF_DIR /usr/local/bin/ssserver /usr/local/bin/ssurl
    echo "卸载完成！"
    exit 0
}

# --- 7. 菜单入口 ---
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}Shadowsocks-Rust 多环境兼容管理 [Env: $INIT_TYPE]${PLAIN}"
        echo " 1. 添加节点"
        echo " 2. 查看节点"
        echo " 3. 删除节点"
        echo " 4. 一键重启"
        echo " 5. 一键卸载"
        echo " 0. 退出"
        read -p "选择: " opt
        case $opt in
            1) add_node ;;
            2) list_nodes ;;
            3) del_node ;;
            4) restart_all ;;
            5) uninstall ;;
            0) exit 0 ;;
        esac
    done
}

check_env
main_menu