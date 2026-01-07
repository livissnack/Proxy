#!/bin/bash
# =================================================================
# Script Name: Shadowsocks-Rust 固化路径版
# =================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

CONF_DIR="/etc/ss-rust"
mkdir -p $CONF_DIR

# 固定安装路径
FINAL_SCRIPT="/usr/local/bin/ss-rust.sh"
IP4=$(curl -sL -4 ip.sb || curl -sL -4 ifconfig.me || echo "127.0.0.1")
CPU_ARCH=$(uname -m)
CIPHER_LIST=(aes-256-gcm aes-128-gcm chacha20-ietf-poly1305)

show_ads() {
    echo -e "${BLUE}------------- END -------------${PLAIN}"
    echo -e "关注(tg): ${YELLOW}https://t.me/livissnack${PLAIN}"
    echo -e "文档(doc): ${YELLOW}https://github.com/livissnack/Proxy/${PLAIN}"
}

check_env() {
    [[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1

    # 1. 强制落盘：如果当前执行路径不是固定路径，则尝试复制过去
    if [[ "$(readlink -f "$0")" != "$FINAL_SCRIPT" ]]; then
        cp "$0" "$FINAL_SCRIPT" 2>/dev/null || cat "$0" > "$FINAL_SCRIPT"
        chmod +x "$FINAL_SCRIPT"
    fi

    # 2. 弃用 alias，直接创建系统软链接 (这是在 Docker 中最生效的方式)
    # 这样你输入 sk 实际上是运行 /usr/local/bin/sk -> /usr/local/bin/ss-rust.sh
    ln -sf "$FINAL_SCRIPT" /usr/local/bin/sk

    # 3. 清理 .bashrc 中之前错误的 alias (可选)
    sed -i '/alias sk=/d' ~/.bashrc 2>/dev/null

    # 识别环境
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

# --- 核心安装与控制逻辑 (同前，已略) ---
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

check_status() {
    echo -e "\n${BLUE}=== 节点运行状态监控 ===${PLAIN}"

    # 获取所有配置文件
    local files=($CONF_DIR/*.conf)

    # 检查配置是否存在
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}提示：尚未发现任何节点配置。${PLAIN}"
        read -p "回车返回..." && return
    fi

    # 打印表头
    echo -e "------------------------------------------------"
    printf "%-6s %-10s %-12s %-10s\n" "序号" "端口" "状态" "PID"
    echo -e "------------------------------------------------"

    local count=1
    for f in "${files[@]}"; do
        local port=$(basename "$f" .conf)

        # 核心抓取逻辑：
        # 1. 寻找包含 ssserver 的进程
        # 2. 匹配该端口号
        # 3. 提取 PID (兼容所有 ps 格式)
        local pid=$(ps -ef | grep "ssserver" | grep -w "$port" | grep -v grep | awk '{print $2}')

        if [[ -n "$pid" ]]; then
            # 运行中显示 PID
            printf "${BLUE}[%2d]${PLAIN}   %-10s ${GREEN}%-12s${PLAIN} %-10s\n" "$count" "$port" "RUNNING" "$pid"
        else
            # 停止显示 -
            printf "${BLUE}[%2d]${PLAIN}   %-10s ${RED}%-12s${PLAIN} %-10s\n" "$count" "$port" "STOPPED" "-"
        fi
        ((count++))
    done
    echo -e "------------------------------------------------"
    read -p "点击回车返回主菜单..."
}

generate_url() {
    local auth=$(echo -n "${2}:${3}" | openssl base64 -A)
    echo -n "ss://${auth}@${IP4}:${1}#livis-ss-${IP4}"
}

display_node_line() {
    local idx=$1; local port=$2; local cipher=$3; local pass=$4
    local lnk=$(generate_url "$port" "$cipher" "$pass")
    echo -e "${BLUE}[$idx]${PLAIN} 协议：${GREEN}SS-Rust${PLAIN} | IP：${GREEN}${IP4} | 端口：${GREEN}${port}${PLAIN} | 加密：${YELLOW}${cipher}${PLAIN} | 密码: ${YELLOW}${pass}${PLAIN}"
    echo -e "    🔗 ${RED}${lnk}${PLAIN}"
}

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

add_node() {
    install_core
    echo -e "\n${BLUE}>>> 添加新节点配置${PLAIN}"
    local rand_p=$(shuf -i 10000-60000 -n 1)
    read -p "请输入端口 [默认随机 $rand_p]: " PORT
    [[ -z "$PORT" ]] && PORT=$rand_p
    if netstat -tuln | grep -q ":${PORT} "; then
        echo -e "${RED}错误: 端口 ${PORT} 已被占用。${PLAIN}"; read -p "回车继续..." && return
    fi
    echo -e "请选择加密方式:\n ${GREEN}1.${PLAIN} aes-256-gcm\n ${GREEN}2.${PLAIN} aes-128-gcm\n ${GREEN}3.${PLAIN} chacha20-ietf-poly1305"
    read -p "请输入序号 [1-3, 默认1]: " CP; [[ -z "$CP" ]] && CP=1
    CIPHER=${CIPHER_LIST[$((CP-1))]}
    read -p "请输入密码 [随机请回车]: " PASS; [[ -z "$PASS" ]] && PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    manage_service "start" "$PORT" "$CIPHER" "$PASS"
    echo "${CIPHER}|${PASS}" > "$CONF_DIR/${PORT}.conf"
    echo -e "\n${GREEN}[✔] 部署成功！${PLAIN}"
    display_node_line "NEW" "$PORT" "$CIPHER" "$PASS"
    show_ads; exit 0
}

list_nodes() {
    echo -e "\n${BLUE}=== 已安装节点列表 ===${PLAIN}"
    local count=1; local files=($CONF_DIR/*.conf)
    if [[ ! -e "${files[0]}" ]]; then echo -e "${YELLOW}当前暂无节点。${PLAIN}"; return 1; fi
    for f in "${files[@]}"; do
        local p=$(basename "$f" .conf); local c=$(cat "$f" | cut -d'|' -f1); local k=$(cat "$f" | cut -d'|' -f2)
        display_node_line "$count" "$p" "$c" "$k"
        echo -e "${BLUE}--------------------------------------------------------------------------------${PLAIN}"
        ((count++))
    done
    return 0
}

del_node() {
    if list_nodes; then
        read -p "请输入要删除的序号或端口: " INPUT; [[ -z "$INPUT" ]] && return
        local target_port=""; local files=($CONF_DIR/*.conf)
        if [[ "$INPUT" =~ ^[0-9]+$ ]] && [ "$INPUT" -le "${#files[@]}" ] && [ "$INPUT" -gt 0 ] && [ ${#INPUT} -le 2 ]; then
            local idx=$((INPUT-1)); target_port=$(basename "${files[$idx]}" .conf)
        else
            [[ -f "$CONF_DIR/${INPUT}.conf" ]] && target_port=$INPUT
        fi
        if [[ -n "$target_port" ]]; then
            manage_service "stop" "$target_port"; rm -f "$CONF_DIR/${target_port}.conf"
            echo -e "${GREEN}节点 $target_port 已删除。${PLAIN}"
        else
            echo -e "${RED}未找到节点。${PLAIN}"
        fi
    fi
    sleep 1
}

restart_all() {
    for f in $CONF_DIR/*.conf; do
        [[ ! -f "$f" ]] && continue
        local p=$(basename "$f" .conf); local c=$(cat "$f" | cut -d'|' -f1); local k=$(cat "$f" | cut -d'|' -f2)
        manage_service "restart" "$p" "$c" "$k"
    done
    echo -e "${GREEN}重启完成。${PLAIN}"; sleep 1
}

uninstall() {
    read -p "确定卸载吗？(y/n): " confirm; [[ "$confirm" != "y" ]] && return
    for f in $CONF_DIR/*.conf; do
        [[ ! -f "$f" ]] && continue
        manage_service "stop" "$(basename "$f" .conf)"
    done
    rm -rf $CONF_DIR /usr/local/bin/ssserver /usr/local/bin/ssurl /usr/local/bin/sk /usr/local/bin/ss-rust.sh
    echo -e "${GREEN}卸载完成。${PLAIN}"; exit 0
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${GREEN} Shadowsocks-Rust 多环境管理脚本 ${PLAIN}"
        echo -e " [ 环境: $INIT_TYPE | IP: $IP4 ]"
        echo -e " [ 快捷指令: sk ]"
        echo -e "${BLUE}========================================${PLAIN}"
        echo " 1. 添加节点 (默认随机端口)"
        echo " 2. 查看所有节点"
        echo " 3. 查看运行状态 (查看PID/存活)"
        echo " 4. 删除指定节点 (支持序号/端口)"
        echo " 5. 一键重启所有节点"
        echo " 6. 一键彻底卸载"
        echo " 0. 退出脚本"
        echo -e "${BLUE}========================================${PLAIN}"
        read -p "选择操作 [0-6]: " opt
        case $opt in
            1) add_node ;;
            2) list_nodes && show_ads && read -p "回车返回..." ;;
            3) check_status ;;
            4) del_node ;;
            5) restart_all ;;
            6) uninstall ;;
            0) exit 0 ;;
            *) continue ;;
        esac
    done
}

check_env
main_menu