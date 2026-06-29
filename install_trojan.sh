#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

echo -e "${GREEN}=========================================${PLAIN}"
echo -e "${GREEN}    sing-box 内核 Trojan 一键安装脚本      ${PLAIN}"
echo -e "${GREEN}=========================================${PLAIN}"

# 1. 获取用户输入
read -p "请输入你的域名 (确保已解析到当前VPS IP): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}域名不能为空！${PLAIN}" && exit 1
fi

read -p "请输入节点监听端口 (默认 27015): " PORT
PORT=${PORT:-27015}

# 生成随机密码 (UUID 格式)
PASSWORD=$(cat /proc/sys/kernel/random/uuid)

# 2. 安装基础依赖
echo -e "${YELLOW}[1/4] 正在安装系统依赖...${PLAIN}"
apt-get update -y && apt-get install -y curl socat jq cron unzip

# 3. 申请独立的 TLS 证书 (使用 Acme.sh)
echo -e "${YELLOW}[2/4] 正在向 Let's Encrypt 申请免费 SSL 证书...${PLAIN}"
curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --upgrade --auto-upgrade
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --listen-v4

# 创建证书存放目录
mkdir -p /etc/sing-box/certs
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --ecc \
    --key-file /etc/sing-box/certs/server.key \
    --fullchain-file /etc/sing-box/certs/server.crt

if [ ! -f "/etc/sing-box/certs/server.crt" ]; then
    echo -e "${RED}证书申请失败！请检查域名解析是否正确，且 80 端口未被占用。${PLAIN}" && exit 1
fi

# 4. 安装官方最新版 sing-box 核心
echo -e "${YELLOW}[3/4] 正在安装 sing-box 内核...${PLAIN}"
bash <(curl -fsSL https://sing-box.mp/install.sh)

# 5. 写入 sing-box 官方标准的 JSON 配置文件
echo -e "${YELLOW}[4/4] 正在配置 sing-box 服务...${PLAIN}"
cat <<EOF > /etc/sing-box/config.json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "/etc/sing-box/certs/server.crt",
        "key_path": "/etc/sing-box/certs/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
EOF

# 重启并开机自启 sing-box
systemctl restart sing-box
systemctl enable sing-box

# 获取当前 VPS IP
VPS_IP=$(curl -s ifconfig.me)

# 6. 打印完美对应的 Clash 节点配置
echo -e "${GREEN}=========================================${PLAIN}"
echo -e "${GREEN} 🎉 sing-box 部署成功！以下是你的 Clash 配置：${PLAIN}"
echo -e "${GREEN}=========================================${PLAIN}"
echo -e ""
echo -e "请将下方内容复制到你 Clash 配置文件中的 ${YELLOW}proxies:${PLAIN} 模块下方："
echo -e ""
echo -e "  - name: '🇭🇰 sing-box 自建 Trojan'"
echo -e "    type: trojan"
echo -e "    server: $VPS_IP"
echo -e "    port: $PORT"
echo -e "    password: $PASSWORD"
echo -e "    udp: true"
echo -e "    sni: $DOMAIN"
echo -e "    skip-cert-verify: false"
echo -e ""
echo -e "${GREEN}=========================================${PLAIN}"
echo -e "提示：如果你以后也用 sing-box 客户端，该服务端的入站配置也天然适配它。"