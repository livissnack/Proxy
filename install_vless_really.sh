#!/bin/bash

# 配置路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
LOG_FILE="/var/log/xray.log"
ERR_LOG="/var/log/xray_err.log"

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 用户运行"
  exit 1
fi

# 1. 环境识别
get_env() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
        OS="debian"
    else
        echo "不支持的系统类型"; exit 1
    fi
}

install_dependencies() {
    echo "--- 正在检查依赖环境 ---"
    if [ "$OS" == "alpine" ]; then
        apk update && apk add curl openssl ca-certificates bash unzip libc6-compat gcompat libstdc++ jq logrotate
    else
        apt-get update && apt-get install -y curl openssl ca-certificates unzip jq logrotate
    fi
    # 配置 logrotate 防止日志塞满硬盘
    cat > /etc/logrotate.d/xray <<EOF
$LOG_FILE
$ERR_LOG {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

# 2. 安装 Xray 核心
install_xray() {
    if [ ! -f "$XRAY_BIN" ]; then
        echo "--- 正在安装 Xray-core ---"
        if [ "$OS" == "alpine" ]; then
            ARCH=$(uname -m)
            case $ARCH in
                x86_64)  X_ARCH="64" ;;
                aarch64) X_ARCH="arm64-v8a" ;;
                *) echo "不支持架构: $ARCH"; exit 1 ;;
            esac
            mkdir -p /tmp/xray
            curl -L -o /tmp/xray/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$X_ARCH.zip"
            unzip -o /tmp/xray/xray.zip -d /tmp/xray
            mkdir -p /usr/local/bin /usr/local/etc/xray
            cp /tmp/xray/xray $XRAY_BIN && chmod +x $XRAY_BIN
            rm -rf /tmp/xray
        else
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        fi
        touch $LOG_FILE $ERR_LOG
        chmod 666 $LOG_FILE $ERR_LOG
    fi
}

# 3. 服务控制
manage_service() {
    case $1 in
        start) [ "$OS" == "alpine" ] && rc-service xray start || systemctl start xray ;;
        stop) [ "$OS" == "alpine" ] && rc-service xray stop || systemctl stop xray ;;
        restart) [ "$OS" == "alpine" ] && rc-service xray restart || systemctl restart xray ;;
        status) [ "$OS" == "alpine" ] && rc-service xray status || systemctl status xray ;;
    esac
}

# 4. 功能模块
add_user() {
    install_xray
    read -p "请输入安装端口 (默认随机): " PORT
    [ -z "$PORT" ] && PORT=$((RANDOM % 50001 + 10000))

    DOMAINS=("www.apple.com" "www.microsoft.com" "www.amazon.com")
    DEST_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}
    UUID=$($XRAY_BIN uuid)
    KEYS=$($XRAY_BIN x25519)
    PRIV=$(echo "$KEYS" | grep "PrivateKey" | cut -d: -f2 | tr -d ' ')
    PUB=$(echo "$KEYS" | grep "Hash32" | cut -d: -f2 | tr -d ' ')
    SID=$(openssl rand -hex 4)

    cat > $CONFIG_FILE <<EOF
{
    "log": { "loglevel": "warning", "access": "$LOG_FILE", "error": "$ERR_LOG" },
    "inbounds": [{
        "port": $PORT, "protocol": "vless",
        "settings": {
            "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": false, "dest": "$DEST_DOMAIN:443", "xver": 0,
                "serverNames": ["$DEST_DOMAIN"], "privateKey": "$PRIV",
                "shortIds": ["$SID"]
            }
        }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF
    # Alpine 需要初始化脚本
    if [ "$OS" == "alpine" ] && [ ! -f /etc/init.d/xray ]; then
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="$XRAY_BIN"
command_args="run -c $CONFIG_FILE"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background="yes"
output_log="$LOG_FILE"
error_log="$ERR_LOG"
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default >/dev/null 2>&1
    fi

    manage_service restart
    echo "--- 安装完成 ---"
    show_config
}

show_config() {
    if [ ! -f $CONFIG_FILE ]; then echo "未检测到配置！"; return; fi
    local ip=$(curl -s ifconfig.me)
    local port=$(jq -r '.inbounds[0].port' $CONFIG_FILE)
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG_FILE)
    local sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $CONFIG_FILE)
    local priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' $CONFIG_FILE)
    local sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $CONFIG_FILE)
    local pub=$($XRAY_BIN x25519 -i "$priv" | grep "Hash32" | cut -d: -f2 | tr -d ' ')

    echo "========================================"
    echo "      VLESS + Reality 配置详情          "
    echo "========================================"
    echo "地址: $ip | 端口: $port"
    echo "UUID: $uuid"
    echo "SNI: $sni | ShortID: $sid"
    echo "PublicKey: $pub"
    echo "========================================"
    echo -e "\033[32mvless://$uuid@$ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$pub&sid=$sid&type=tcp#Reality_VLESS\033[0m"
}

set_log_level() {
    if [ ! -f $CONFIG_FILE ]; then echo "配置不存在"; return; fi
    echo "1. 开启日志 (Warning级，用于排错)"
    echo "2. 关闭日志 (完全不记录，节省空间)"
    read -p "请选择: " log_opt
    case $log_opt in
        1) jq '.log.loglevel = "warning" | .log.access = "'$LOG_FILE'" | .log.error = "'$ERR_LOG'"' $CONFIG_FILE > t.json ;;
        2) jq '.log.loglevel = "none" | .log.access = "/dev/null" | .log.error = "/dev/null"' $CONFIG_FILE > t.json ;;
        *) return ;;
    esac
    mv t.json $CONFIG_FILE && manage_service restart && echo "日志设置已更新。"
}

# 菜单
get_env
install_dependencies
clear

while true; do
    echo "=============================="
    echo "   VLESS + Reality 综合管理   "
    echo "=============================="
    echo "1. 安装/重装 (自定义端口)"
    echo "2. 查看当前配置/链接"
    echo "3. 修改端口/UUID/域名"
    echo "4. 日志管理 (查看实时/开关控制)"
    echo "------------------------------"
    echo "5. 启动服务"
    echo "6. 停止服务"
    echo "7. 重启服务"
    echo "8. 服务状态"
    echo "------------------------------"
    echo "9. 一键卸载"
    echo "0. 退出脚本"
    echo "=============================="
    read -p "选择操作 [0-9]: " choice

    case $choice in
        1) add_user ;;
        2) show_config ;;
        3)  read -p "1.端口 2.UUID 3.域名: " mo
            case $mo in
                1) read -p "新端口: " p; jq ".inbounds[0].port = $p" $CONFIG_FILE > t.json ;;
                2) read -p "新UUID: " u; jq ".inbounds[0].settings.clients[0].id = \"$u\"" $CONFIG_FILE > t.json ;;
                3) read -p "新域名: " d; jq ".inbounds[0].streamSettings.realitySettings.serverNames[0] = \"$d\" | .inbounds[0].streamSettings.realitySettings.dest = \"$d:443\"" $CONFIG_FILE > t.json ;;
            esac
            [ -f t.json ] && mv t.json $CONFIG_FILE && manage_service restart && show_config ;;
        4)  echo "1. 查看实时日志 (Ctrl+C退出)"
            echo "2. 开启/关闭日志写入"
            read -p "请选择: " l_opt
            [ "$l_opt" == "1" ] && tail -f $LOG_FILE -f $ERR_LOG || set_log_level ;;
        5|6|7|8)
            case $choice in 5) manage_service start ;; 6) manage_service stop ;; 7) manage_service restart ;; 8) manage_service status ;; esac ;;
        9)  read -p "确认卸载? [y/N]: " conf
            if [[ "$conf" == [yY] ]]; then
                manage_service stop
                [ "$OS" == "alpine" ] && { rc-update del xray; rm -f /etc/init.d/xray; } || systemctl disable xray
                rm -rf /usr/local/bin/xray /usr/local/etc/xray $LOG_FILE $ERR_LOG /etc/logrotate.d/xray
                echo "已彻底卸载。"
            fi ;;
        0) break ;;
    esac
    read -n 1 -s -p "按任意键返回菜单..."
    clear
done