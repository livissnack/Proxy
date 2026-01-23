cat << 'EOF' > install_anytls.sh
#!/bin/bash

# 检查 Root 权限
[[ $EUID -ne 0 ]] && echo "请以 root 用户运行此脚本！" && exit 1

# 1. 识别 OS 类型
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    PKG_MGR="apk add"
    SERVICE_MGR="openrc"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS="debian"
    PKG_MGR="apt update && apt install -y"
    SERVICE_MGR="systemd"
else
    echo "不支持的系统，脚本仅支持 Debian/Ubuntu 或 Alpine。"
    exit 1
fi

echo "检测到系统类型: $OS"

# 2. 配置选项交互
echo "---------- anytls-go 配置选项 ----------"
read -p "请输入服务端口 [默认 443]: " user_port
user_port=${user_port:-443}
read -p "请输入连接密码 [默认 随机]: " user_password
user_password=${user_password:-$(openssl rand -base64 12)}
read -p "请输入伪装域名 (SNI) [默认 www.microsoft.com]: " user_sni
user_sni=${user_sni:-www.microsoft.com}
echo "---------------------------------------"

# 3. 安装依赖
if [ "$OS" == "alpine" ]; then
    apk update && apk add curl jq openssl ca-certificates
else
    apt update && apt install -y curl jq openssl ca-certificates
fi

# 4. 下载二进制文件
arch=$(uname -m)
case $arch in
    x86_64) arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *) echo "不支持的架构: $arch"; exit 1 ;;
esac

echo "正在下载 anytls-go ($arch)..."
latest_url=$(curl -s https://api.github.com/repos/6KmFi6Ovi9pz/anytls-go/releases/latest | jq -r ".assets[] | select(.name | contains(\"linux-$arch\")) | .browser_download_url")
wget -O /usr/local/bin/anytls-go "$latest_url"
chmod +x /usr/local/bin/anytls-go

# 5. 写入配置
mkdir -p /etc/anytls
cat << FIELD > /etc/anytls/config.json
{
  "server_addr": "0.0.0.0",
  "server_port": $user_port,
  "password": "$user_password",
  "snis": ["$user_sni"],
  "tunnel_type": "tcp",
  "log_level": "info"
}
FIELD

# 6. 配置服务守护
if [ "$SERVICE_MGR" == "systemd" ]; then
    # Debian/Ubuntu systemd 配置
    cat << FIELD > /etc/systemd/system/anytls.service
[Unit]
Description=anytls-go Service
After=network.target
[Service]
ExecStart=/usr/local/bin/anytls-go server -c /etc/anytls/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
FIELD
    systemctl daemon-reload
    systemctl enable anytls
    systemctl restart anytls
else
    # Alpine OpenRC 配置
    cat << FIELD > /etc/init.d/anytls
#!/sbin/openrc-run
description="anytls-go service"
command="/usr/local/bin/anytls-go"
command_args="server -c /etc/anytls/config.json"
pidfile="/run/anytls.pid"
command_background=true
depend() {
    need net
}
FIELD
    chmod +x /etc/init.d/anytls
    rc-update add anytls default
    rc-service anytls restart
fi

# 7. 打印结果
clear
echo "---------- anytls-go 安装成功 ----------"
echo "操作系统  : $OS"
echo "服务端口  : $user_port"
echo "连接密码  : $user_password"
echo "伪装域名  : $user_sni"
echo "---------------------------------------"
EOF

chmod +x install_anytls.sh && ./install_anytls.sh