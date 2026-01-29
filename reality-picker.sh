#!/bin/bash

# 配置部分
REPO_URL="https://raw.githubusercontent.com/livissnack/Proxy/main"
BINARY_NAME="reality-picker"
DB_NAME="domains.json"

echo "🚀 开始部署 REALITY SNI 筛选工具..."

# 1. 检查并安装依赖 (仅需 jq 处理简单的版本逻辑，可选)
if ! [ -x "$(command -v curl)" ]; then
  echo "Installer: 正在安装 curl..."
  apt-get update && apt-get install -y curl || yum install -y curl
fi

# 2. 下载二进制文件和数据库
echo "📥 正在从 GitHub 下载最新组件..."
curl -L -O "$REPO_URL/$BINARY_NAME"
curl -L -O "$REPO_URL/$DB_NAME"

# 3. 赋予执行权限
chmod +x $BINARY_NAME

# 4. 运行工具
echo "✅ 部署完成！正在启动筛选..."
./$BINARY_NAME --top 10