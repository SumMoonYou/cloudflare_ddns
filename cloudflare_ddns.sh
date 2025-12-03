#!/bin/bash

# 配置文件路径和日志文件
CONFIG_FILE="/etc/cf_ddds.conf"
LAST_IP_FILE="/var/lib/cf_last_ip.txt"
LOG_FILE="/var/log/cf_ddds.log"
SCRIPT_PATH="/usr/local/bin/cf_ddds_update.sh"

# 获取 DNS 记录 ID 的函数
get_dns_record_id() {
    echo "正在获取 DNS 记录 ID..."
    
    # 通过 Cloudflare API 获取 DNS 记录 ID
    RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN_NAME" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")

    DNS_RECORD_ID=$(echo "$RESPONSE" | grep -oP '(?<="id":")[^"]*')

    if [[ -z "$DNS_RECORD_ID" ]]; then
        echo "未找到 DNS 记录 ID，请确保域名 $DOMAIN_NAME 在 Cloudflare 中已正确配置。" >&2
        exit 1
    else
        echo "成功获取 DNS 记录 ID: $DNS_RECORD_ID"
    fi
}

# 安装函数
install_script() {
    echo "正在安装脚本..."

    # 手动输入配置信息
    read -p "请输入 Cloudflare 区域 ID (ZONE_ID): " ZONE_ID
    read -p "请输入 Cloudflare API Token (CF_API_TOKEN): " CF_API_TOKEN
    read -p "请输入域名 (DOMAIN_NAME): " DOMAIN_NAME
    read -p "请输入 Telegram 机器人 Token (TG_BOT_TOKEN): " TG_BOT_TOKEN
    read -p "请输入 Telegram 聊天 ID (TG_CHAT_ID): " TG_CHAT_ID

    # 获取 DNS 记录 ID
    get_dns_record_id

    # 将配置保存到配置文件
    echo "# 配置 Cloudflare 和 Telegram 信息" > "$CONFIG_FILE"
    echo "ZONE_ID='$ZONE_ID'" >> "$CONFIG_FILE"
    echo "DNS_RECORD_ID='$DNS_RECORD_ID'" >> "$CONFIG_FILE"
    echo "CF_API_TOKEN='$CF_API_TOKEN'" >> "$CONFIG_FILE"
    echo "DOMAIN_NAME='$DOMAIN_NAME'" >> "$CONFIG_FILE"
    echo "TG_BOT_TOKEN='$TG_BOT_TOKEN'" >> "$CONFIG_FILE"
    echo "TG_CHAT_ID='$TG_CHAT_ID'" >> "$CONFIG_FILE"

    # 将脚本复制到指定目录
    cp "$0" "$SCRIPT_PATH"

    # 赋予执行权限
    chmod +x "$SCRIPT_PATH"

    echo "脚本已安装并可通过 $SCRIPT_PATH 手动运行。"
}

# 卸载函数
uninstall_script() {
    echo "正在卸载脚本..."

    # 删除脚本文件
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f "$SCRIPT_PATH"
        echo "脚本文件已删除：$SCRIPT_PATH"
    else
        echo "脚本文件不存在：$SCRIPT_PATH"
    fi

    # 删除配置文件
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        echo "配置文件已删除：$CONFIG_FILE"
    else
        echo "配置文件不存在：$CONFIG_FILE"
    fi

    # 删除 IP 记录文件
    if [[ -f "$LAST_IP_FILE" ]]; then
        rm -f "$LAST_IP_FILE"
        echo "IP 记录文件已删除：$LAST_IP_FILE"
    else
        echo "IP 记录文件不存在：$LAST_IP_FILE"
    fi

    echo "卸载完成。"
}

# 删除配置和记录文件
delete_files() {
    echo "正在删除配置和记录文件..."

    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        echo "配置文件已删除：$CONFIG_FILE"
    else
        echo "配置文件不存在：$CONFIG_FILE"
    fi

    if [[ -f "$LAST_IP_FILE" ]]; then
        rm -f "$LAST_IP_FILE"
        echo "IP 记录文件已删除：$LAST_IP_FILE"
    else
        echo "IP 记录文件不存在：$LAST_IP_FILE"
    fi

    echo "所有文件已删除。"
}

# 手动运行更新
run_update() {
    source "$CONFIG_FILE"

    if [[ -z "$ZONE_ID" || -z "$DNS_RECORD_ID" || -z "$CF_API_TOKEN" || -z "$DOMAIN_NAME" || -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        echo "请确保配置文件 $CONFIG_FILE 中的所有环境变量都已设置。" >&2
        exit 1
    fi

    CURRENT_IP=$(curl -s 'https://ip.164746.xyz/ipTop.html' | cut -d',' -f1)
    CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
    IP_INFO=$(curl -s "http://ip-api.com/json/$CURRENT_IP?lang=zh-CN")
    COUNTRY=$(echo "$IP_INFO" | grep -oP '(?<="country":").*?(?=")')
    ISP=$(echo "$IP_INFO" | grep -oP '(?<="isp":").*?(?=")')

    # 如果文件不存在则保存当前 IP
    [[ ! -f "$LAST_IP_FILE" ]] && echo "$CURRENT_IP" > "$LAST_IP_FILE"
    LAST_IP=$(cat "$LAST_IP_FILE")

    # 如果 IP 发生变化，则更新 Cloudflare 记录
    if [[ "$CURRENT_IP" != "$LAST_IP" ]]; then
        RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$DOMAIN_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")

        if echo "$RESPONSE" | grep -q '"success":true'; then
            echo "$CURRENT_IP" > "$LAST_IP_FILE"

            ### ============== Telegram 通知（精美版） ==============
            MSG="
✨ *Cloudflare DNS 自动更新通知*

📌 *域名：*
\`$DOMAIN_NAME\`

🆕 *新 IP：*
\`$CURRENT_IP\`

🌏 *IP 信息：*
• *国家地区：* $COUNTRY  
• *运营商：* $ISP  

⏰ *更新时间：*
\`$CURRENT_TIME\`

🔍 *IP 查询：*
• [ip.sb](https://ip.sb/ip/$CURRENT_IP)
• [ip-api](http://ip-api.com/json/$CURRENT_IP)

———————————————
🎉 *更新成功！DNS 已同步完成。*
"
            curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
                -d "chat_id=$TG_CHAT_ID&parse_mode=Markdown&text=$MSG"

            echo "[] 已更新 → $CURRENT_IP ($COUNTRY / $ISP)" >> "$LOG_FILE"
        else
            echo "[] Cloudflare 更新失败" >> "$LOG_FILE"
        fi
    else
        echo "[] IP 未变化 → $CURRENT_IP" >> "$LOG_FILE"
    fi
}

# 显示菜单
menu() {
    echo "===================================="
    echo "请选择操作:"
    echo "1. 安装脚本"
    echo "2. 卸载脚本"
    echo "3. 删除配置和记录文件"
    echo "4. 手动运行更新"
    echo "5. 退出"
    echo "===================================="
    read -p "请输入选项 (1-5): " choice

    case "$choice" in
        1)
            install_script
            ;;
        2)
            uninstall_script
            ;;
        3)
            delete_files
            ;;
        4)
            run_update
            ;;
        5)
            exit 0
            ;;
        *)
            echo "无效选项，请重新选择。"
            menu
            ;;
    esac
}

# 启动菜单
menu
