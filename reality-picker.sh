#!/bin/sh

# 自动识别包管理器并安装 curl
install_curl() {
    if [ -x "$(command -v curl)" ]; then return; fi

    echo "正在安装 curl..."
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache curl
    elif [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y curl
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl
    fi
}

install_curl

# 配置部分
REPO_URL="https://raw.githubusercontent.com/livissnack/Proxy/main"
BINARY_NAME="reality-picker"
DB_NAME="domains.json"

echo "🚀 开始部署 REALITY SNI 筛选工具..."

# 下载组件 (使用 -f 确保失败时报错)
curl -fL -O "$REPO_URL/$BINARY_NAME"
curl -fL -O "$REPO_URL/$DB_NAME"

chmod +x $BINARY_NAME

echo "✅ 部署完成！正在启动筛选..."
./$BINARY_NAME --top 10