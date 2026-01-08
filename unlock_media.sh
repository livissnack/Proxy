#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

setup_env() {
    if ! command -v curl > /dev/null; then
        if [ -f /etc/alpine-release ]; then apk add --no-cache curl bash; else apt-get update && apt-get install -y curl; fi
    fi
    # 获取本机真实公网 IP
    REAL_IP=$(curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 api.ip.sb/ip)
    REAL_IP6=$(curl -s6 --max-time 5 ifconfig.me || curl -s6 --max-time 5 api.ip.sb/ip)
}

# 核心判定函数
check_status() {
    local name=$1
    local url=$2
    local keyword=$3
    local proto=${4:-4}
    local real_val=$([[ "$proto" == "6" ]] && echo "$REAL_IP6" || echo "$REAL_IP")

    if [[ "$proto" == "6" && -z "$REAL_IP6" ]]; then return; fi

    local resp=$(curl -s"$proto" -m 10 -o /tmp/media_res -w "%{http_code}|%{remote_ip}" "$url")
    local http_code=$(echo "$resp" | cut -d'|' -f1)
    local remote_ip=$(echo "$resp" | cut -d'|' -f2)
    local body=$(cat /tmp/media_res)

    printf " %-15s: " "$name"

    if [[ "$http_code" == "200" || "$http_code" == "302" || "$body" == *"$keyword"* ]]; then
        if [[ "$remote_ip" == "$real_val" ]]; then
            echo -e "${GREEN}已解锁 (原生)${PLAIN}"
        else
            echo -e "${YELLOW}已解锁 (DNS解锁)${PLAIN} ${BLUE}[$remote_ip]${PLAIN}"
        fi
    else
        echo -e "${RED}未解锁${PLAIN}"
    fi
}

# TikTok 检测函数
check_tiktok() {
    local proto=${1:-4}
    local real_val=$([[ "$proto" == "6" ]] && echo "$REAL_IP6" || echo "$REAL_IP")
    local suffix=$([[ "$proto" == "6" ]] && echo " (IPv6)" || echo "")

    if [[ "$proto" == "6" && -z "$REAL_IP6" ]]; then return; fi

    # TikTok 地区跳转检测
    local tt_resp=$(curl -s"$proto" -m 10 -o /dev/null -w "%{http_code}|%{remote_ip}|%{redirect_url}" "https://www.tiktok.com/")
    local tt_code=$(echo "$tt_resp" | cut -d'|' -f1)
    local tt_ip=$(echo "$tt_resp" | cut -d'|' -f2)
    local tt_redir=$(echo "$tt_resp" | cut -d'|' -f3)

    printf " %-15s: " "TikTok$suffix"
    if [[ "$tt_code" == "301" || "$tt_code" == "302" || "$tt_code" == "200" ]]; then
        # 从跳转链接中提取地区，如 tiktok.com/@tiktok?lang=en 会跳转到 vms.tiktok.com 等，通常看最后后缀
        local region=$(curl -s"$proto" -m 10 -I "https://www.tiktok.com" | grep -i "location" | grep -oE "tiktok\.com/@[^/]+" | cut -d'=' -f2 | tr '[:lower:]' '[:upper:]')
        [[ -z "$region" ]] && region=$(echo "$tt_redir" | cut -d'.' -f1 | cut -d'/' -f3 | tr '[:lower:]' '[:upper:]')
        [[ -z "$region" ]] && region="Global"

        local type_str="${GREEN}已解锁 ($region)${PLAIN}"
        [[ "$tt_ip" != "$real_val" ]] && type_str="${YELLOW}DNS解锁 ($region)${PLAIN} ${BLUE}[$tt_ip]${PLAIN}"
        echo -e "$type_str"
    else
        echo -e "${RED}未解锁${PLAIN}"
    fi
}

# 特殊逻辑检测：Netflix / YouTube (带地区)
check_special() {
    local proto=${1:-4}
    local real_val=$([[ "$proto" == "6" ]] && echo "$REAL_IP6" || echo "$REAL_IP")
    local suffix=$([[ "$proto" == "6" ]] && echo " (IPv6)" || echo "")

    if [[ "$proto" == "6" && -z "$REAL_IP6" ]]; then return; fi

    # Netflix
    local nf_resp=$(curl -s"$proto" -m 10 -o /dev/null -w "%{http_code}|%{remote_ip}" "https://www.netflix.com/title/81215561")
    local nf_code=$(echo "$nf_resp" | cut -d'|' -f1)
    local nf_ip=$(echo "$nf_resp" | cut -d'|' -f2)

    printf " %-15s: " "Netflix$suffix"
    if [ "$nf_code" == "200" ]; then
        local region=$(curl -s"$proto" https://www.netflix.com/title/80018499 | cut -d'/' -f4 | cut -d'-' -f1 | tr [:lower:] [:upper:])
        [[ -z "$region" || ${#region} -gt 3 ]] && region="Global"
        local type_str="${GREEN}完整解锁 ($region)${PLAIN}"
        [[ "$nf_ip" != "$real_val" ]] && type_str="${YELLOW}DNS解锁 ($region)${PLAIN} ${BLUE}[$nf_ip]${PLAIN}"
        echo -e "$type_str"
    else
        echo -e "${RED}仅自制剧/未解锁${PLAIN}"
    fi

    # YouTube
    local yt_resp=$(curl -s"$proto" -m 10 -o /tmp/yt_res -w "%{remote_ip}" "https://www.youtube.com/red")
    local yt_ip=$(echo "$yt_resp")
    local yt_region=$(grep -o '"countryCode":"[^"]*"' /tmp/yt_res | cut -d'"' -f4)

    printf " %-15s: " "YouTube$suffix"
    if [ -n "$yt_region" ]; then
        local type_str="${GREEN}已解锁 ($yt_region)${PLAIN}"
        [[ "$yt_ip" != "$real_val" ]] && type_str="${YELLOW}DNS解锁 ($yt_region)${PLAIN} ${BLUE}[$yt_ip]${PLAIN}"
        echo -e "$type_str"
    else
        echo -e "${RED}未解锁${PLAIN}"
    fi
}

# 执行脚本
clear
setup_env
echo -e "${BLUE}================================================${PLAIN}"
echo -e " 本机真实 IPv4: ${CYAN}$REAL_IP${PLAIN}"
[[ -n "$REAL_IP6" ]] && echo -e " 本机真实 IPv6: ${CYAN}$REAL_IP6${PLAIN}"
echo -e "${BLUE}================================================${PLAIN}"

echo -e "${CYAN}[全球 AI & 视频平台]${PLAIN}"
check_status "ChatGPT" "https://chat.openai.com/auth/login" "200" 4
check_status "Gemini" "https://gemini.google.com/app" "200" 4
check_special 4
check_tiktok 4
check_status "Disney+" "https://www.disneyplus.com/" "200" 4
check_status "Spotify" "https://www.spotify.com/us/premium/" "200" 4

echo -e "\n${CYAN}[香港特色平台]${PLAIN}"
check_status "myTV SUPER" "https://www.mytvsuper.com/" "200" 4
check_status "Viu.tv" "https://www.viu.tv/" "200" 4
check_status "Now E" "https://www.nowe.com/" "200" 4

echo -e "\n${CYAN}[台湾特色平台]${PLAIN}"
check_status "巴哈姆特" "https://ani.gamer.com.tw/" "da_v" 4
check_status "4GTV" "https://www.4gtv.tv/" "4GTV" 4
check_status "LiTV" "https://www.litv.tv/" "200" 4
check_status "MyVideo" "https://www.myvideo.net.tw/" "200" 4

# IPv6 检测板块
if [[ -n "$REAL_IP6" ]]; then
    echo -e "\n${CYAN}[IPv6 媒体解锁]${PLAIN}"
    check_status "Google IPv6" "https://www.google.com" "200" 6
    check_special 6
    check_tiktok 6
    check_status "Disney+ IPv6" "https://www.disneyplus.com/" "200" 6
fi

echo -e "${BLUE}================================================${PLAIN}"