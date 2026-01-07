#!/bin/bash
# =================================================================
# Script Name: Shadowsocks-Rust 多节点全能兼容最终版
# Alias:       sk (快速管理)
# Support:     Systemd, OpenRC, Docker, LXC, NAT, VPS
# =================================================================

# --- 1. 基础配置与颜色 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

CONF_DIR="/etc/ss-rust"
mkdir -p $CONF_DIR

# 获取公网IP
IP4=$(curl -sL -4 ip.sb || curl -sL -4 ifconfig.me || echo "127.0.0.1")
CPU_ARCH=$(uname -m)
CIPHER_LIST=(aes-256-gcm aes-128-gcm chacha20-ietf-poly1305)

# --- 2. 广告信息展示 ---
show_ads() {
    echo -e "${BLUE}------------- END -------------${PLAIN}"
    echo -e "关注(tg): ${YELLOW}https://t.me/livissnack${PLAIN}"
    echo -e "文档(doc): ${YELLOW}https://github.com/livissnack/Proxy/${PLAIN}"
    echo -e "博客(ads): 推荐: ${GREEN}https://livissnack.com/${PLAIN}"
}

# --- 3. 环境检测与 Alias 设置 ---
check_env() {
    [[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1

    # 设置别名 sk
    local script_path=$(readlink -f "$0")
    if ! grep -q "alias sk=" ~/.bashrc; then
        echo "alias sk='$script_path'" >> ~/.bashrc
        [[ -f ~/.zshrc ]] && echo "alias sk='$script_path'" >> ~/.zshrc
        source ~/.bashrc 2>/dev/null
    fi

    if [[ -f /etc/alpine-release ]]; then OS="alpine";
    elif command -v apt >/dev/null 2>&1; then OS="debian";
    elif command -v yum >/dev/null 2>&1; then OS="centos";
    fi

    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        INIT_TYPE="nohup"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_TYPE="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_TYPE="openrc"
    else
        INIT_TYPE="nohup"
    fi
}

# --- 4. 依赖与核心安装 ---
install_core() {
    if [[ ! -f /usr/local/bin/ssserver ]]; then
        case "$CPU_ARCH" in
            x86_64|amd64) ARCH="x86_64-unknown-linux-musl" ;;
            aarch64|armv8) ARCH="aarch64-unknown-linux-musl" ;;
            *) echo "不支持的架构"; exit 1 ;;
        esac

        local ver="v1.24.0"
        local url="https://raw.githubusercontent.com/livissnack/Proxy/main/shadowsocks-${ver}.${ARCH}.tar.gz"
        curl -Lk "$url" | tar -xz -C /usr/local/bin/ ssserver ssurl
        chmod +x /usr/local/bin/ssserver /usr/local/bin/ssurl
    fi
}

# --- 5. 辅助与展示函数 ---
generate_url() {
    local auth=$(echo -n "${2}:${3}" | openssl base64 -A)
    echo -n "ss://${auth}@${IP4}:${1}#livis-ss-${IP4}"
}

display_node_line() {
    local idx=$1; local port=$2; local cipher=$3; local pass=$4
    local lnk=$(generate_url "$port" "$cipher" "$pass")
    local prefix=""
    [[ -n "$idx" ]] && prefix="${BLUE}[$idx]${PLAIN} "
    echo -e "协议：${prefix}${GREEN}SS-Rust${PLAIN} | IP：${GREEN}${IP4} | 端口：${port}${PLAIN} | 加密：${YELLOW}${cipher}${PLAIN} | 密码: ${YELLOW}${pass}${PLAIN}"
    echo -e "  🔗 ${RED}${lnk}${PLAIN}"
}

# --- 6. 节点控制逻辑 ---
manage_service() {
    local action=$1; local port=$2; local cipher=$3; local pass=$4
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
                systemctl daemon-reload && systemctl enable ss-rust-${port} >/dev/null 2>&1
                systemctl restart ss-rust-${port}
            else
                systemctl stop ss-rust-${port} >/dev/null 2>&1
                rm -f /etc/systemd/system/ss-rust-${port}.service && systemctl daemon-reload
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
                chmod +x /etc/init.d/ss-rust-${port} && rc-update add ss-rust-${port} default >/dev/null 2>&1
                service ss-rust-${port} restart
            else
                service ss-rust-${port} stop >/dev/null 2>&1 && rc-update del ss-rust-${port} >/dev/null 2>&1
                rm -f /etc/init.d/ss-rust-${port}
            fi
            ;;
        "nohup")
            pkill -f "ssserver.*:${port} " >/dev/null 2>&1
            if [[ "$action" == "start" || "$action" == "restart" ]]; then
                nohup /usr/local/bin/ssserver -s 0.0.0.0:${port} -m ${cipher} -k ${pass} -u > /dev/null 2>&1 &
            fi
            ;;
    esac
}

# --- 7. 菜单功能函数 ---
add_node() {
    install_core
    echo -e "\n${BLUE}>>> 添加新节点配置${PLAIN}"
    read -p "请输入端口 [默认6666]: " PORT
    [[ -z "$PORT" ]] && PORT="6666"

    if netstat -tuln | grep -q ":${PORT} "; then
        echo -e "${RED}错误: 端口 ${PORT} 已被占用。${PLAIN}"
        read -p "回车继续..." && return
    fi

    # --- 恢复竖向排版 ---
    echo -e "请选择加密方式:"
    echo -e " ${GREEN}1.${PLAIN} aes-256-gcm"
    echo -e " ${GREEN}2.${PLAIN} aes-128-gcm"
    echo -e " ${GREEN}3.${PLAIN} chacha20-ietf-poly1305"
    read -p "请输入序号 [1-3, 默认1]: " CP; [[ -z "$CP" ]] && CP=1
    CIPHER=${CIPHER_LIST[$((CP-1))]}

    read -p "请输入密码 [随机请直接回车]: " PASS; [[ -z "$PASS" ]] && PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    manage_service "start" "$PORT" "$CIPHER" "$PASS"
    echo "${CIPHER}|${PASS}" > "$CONF_DIR/${PORT}.conf"

    echo -e "\n${GREEN}[✔] 部署成功！信息如下：${PLAIN}"
    display_node_line "" "$PORT" "$CIPHER" "$PASS"
    show_ads
    exit 0
}

list_nodes() {
    echo -e "\n${BLUE}=== 已安装节点列表 ===${PLAIN}"
    local count=1
    local files=$(ls $CONF_DIR/*.conf 2>/dev/null)
    if [[ -z "$files" ]]; then
        echo -e "${YELLOW}当前暂无节点。${PLAIN}"
    else
        for f in $files; do
            local p=$(basename "$f" .conf); local c=$(cat "$f" | cut -d'|' -f1); local k=$(cat "$f" | cut -d'|' -f2)
            display_node_line "$count" "$p" "$c" "$k"
            echo -e "${BLUE}--------------------------------------------------------------------------------${PLAIN}"
            ((count++))
        done
    fi
    show_ads
    read -p "回车返回..."
}

del_node() {
    read -p "请输入要删除的节点端口: " P
    if [[ -f "$CONF_DIR/${P}.conf" ]]; then
        manage_service "stop" "$P"; rm -f "$CONF_DIR/${P}.conf"
        echo -e "${GREEN}节点 $P 已删除。${PLAIN}"
    else
        echo -e "${RED}找不到该节点。${PLAIN}"
    fi
    sleep 1
}

restart_all() {
    echo -e "${YELLOW}正在重启所有节点...${PLAIN}"
    for f in $CONF_DIR/*.conf; do
        [[ ! -f "$f" ]] && continue
        local p=$(basename "$f" .conf); local c=$(cat "$f" | cut -d'|' -f1); local k=$(cat "$f" | cut -d'|' -f2)
        manage_service "restart" "$p" "$c" "$k"
    done
    echo -e "${GREEN}重启完成。${PLAIN}"
    show_ads
    sleep 1 && read -p "回车继续..."
}

uninstall() {
    echo -e "${RED}！！！警告：这将停止并删除所有节点及核心程序 ！！！${PLAIN}"
    read -p "确定卸载吗？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    for f in $CONF_DIR/*.conf; do
        local p=$(basename "$f" .conf); manage_service "stop" "$p"
    done
    rm -rf $CONF_DIR /usr/local/bin/ssserver /usr/local/bin/ssurl
    echo -e "${GREEN}彻底卸载完成。系统已恢复纯净。${PLAIN}"
    exit 0
}

# --- 8. 主菜单 ---
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${GREEN} Shadowsocks-Rust 多环境管理脚本 ${PLAIN}"
        echo -e " [ 环境: $INIT_TYPE | IP: $IP4 ]"
        echo -e " [ 别名快捷指令: sk ]"
        echo -e "${BLUE}========================================${PLAIN}"
        echo " 1. 添加节点 (完成后退出)"
        echo " 2. 查看所有节点"
        echo " 3. 删除指定节点"
        echo " 4. 一键重启所有节点"
        echo " 5. 一键彻底卸载"
        echo " 0. 退出脚本"
        echo -e "${BLUE}========================================${PLAIN}"
        read -p "选择操作 [0-5]: " opt
        case $opt in
            1) add_node ;;
            2) list_nodes ;;
            3) del_node ;;
            4) restart_all ;;
            5) uninstall ;;
            0) exit 0 ;;
            *) continue ;;
        esac
    done
}

check_env
main_menu