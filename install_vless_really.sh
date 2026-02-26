#!/bin/bash

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 用户运行"
  exit 1
fi

# 1. 识别系统环境
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    PKGMGR="apk add"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS="debian"
    PKGMGR="apt-get install -y"
else
    echo "不支持的系统类型"
    exit 1
fi

# 2. 安装基础依赖
if [ "$OS" == "alpine" ]; then
    apk update
    $PKGMGR curl openssl ca-certificates bash unzip libc6-compat gcompat
else
    apt-get update
    $PKGMGR curl openssl ca-certificates unzip
fi

# 3. 安装 Xray-core
echo "正在安装 Xray-core..."
if [ "$OS" == "alpine" ]; then
    # Alpine 手动下载，绕过官方脚本对 systemd 的检查
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  X_ARCH="64" ;;
        aarch64) X_ARCH="arm64-v8a" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    mkdir -p /tmp/xray
    curl -L -o /tmp/xray/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$X_ARCH.zip"
    unzip -o /tmp/xray/xray.zip -d /tmp/xray
    mkdir -p /usr/local/bin /usr/local/etc/xray
    cp /tmp/xray/xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    rm -rf /tmp/xray
else
    # Debian/Ubuntu 使用官方脚本
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# 4. 随机选择伪装域名
DOMAINS=(
    "www.loewe.com"
    "www.apple.com"
    "www.amazon.com"
    "www.samsung.com"
    "www.adidas.com"
    "www.nike.com"
    "www.intel.com"
    "www.nvidia.com"
    "www.paypal.com"
)
DEST_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}
echo "本次随机选择的伪装域名为: $DEST_DOMAIN"

# 5. 生成配置参数
XRAY_BIN="/usr/local/bin/xray"
UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 4)
SERVER_IP=$(curl -s ifconfig.me)

# 6. 写入配置文件
cat > /usr/local/etc/xray/config.json <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$DEST_DOMAIN:443",
                    "xver": 0,
                    "serverNames": ["$DEST_DOMAIN"],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": ["$SHORT_ID"]
                }
            }
        }
    ],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 7. 配置启动服务
if [ "$OS" == "alpine" ]; then
    if [ ! -f /etc/init.d/xray ]; then
        cat > /etc/init.d/xray <<'EORC'
#!/sbin/openrc-run
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
EORC
        chmod +x /etc/init.d/xray
    fi
    rc-update add xray default
    rc-service xray restart
else
    systemctl enable xray
    systemctl restart xray
fi

# 8. 生成 vless:// 链接
VLESS_URL="vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DEST_DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#VLESS_Reality_$DEST_DOMAIN"

# 9. 输出结果
clear
echo "========================================"
echo "      VLESS + Reality 安装成功!  "
echo "========================================"
echo "地址: $(curl -s ifconfig.me)"
echo "端口: 443"
echo "UUID: $UUID"
echo "流控: xtls-rprx-vision"
echo "传输层安全: reality"
echo "SNI (ServerName): $DEST_DOMAIN"
echo "PublicKey: $PUBLIC_KEY"
echo "ShortID: $SHORT_ID"
echo "uTLS: chrome / safari"
echo "========================================"
echo "生成的配置链接 (直接复制到客户端):"
echo ""
echo -e "\033[32m$VLESS_URL\033[0m"
echo ""
echo "========================================"