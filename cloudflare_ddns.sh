#!/bin/bash

# 配置文件路径和日志文件
CONFIG_FILE="/etc/cf_ddds.conf"
LAST_IP_FILE="/var/lib/cf_last_ip.txt"
LOG_FILE="/var/log/cf_ddds.log"
SCRIPT_PATH="/usr/local/bin/cf_ddds_update.sh"
CRON_SCRIPT_PATH="/usr/local/bin/cf_ddns_update_cron.sh"

# 安装 jq 的函数
install_jq() {
    if ! command -v jq &> /dev/null; then
        echo "未检测到 jq，正在安装 jq..."
        
        # 安装 jq
        if [[ -x "$(command -v apt-get)" ]]; then
            sudo apt-get update && sudo apt-get install -y jq
        elif [[ -x "$(command -v yum)" ]]; then
            sudo yum install -y jq
        else
            echo "无法自动安装 jq。请手动安装 jq 后重试。" >&2
            exit 1
        fi
    else
        echo "jq 已安装，继续执行..."
    fi
}

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

# 检查是否在禁用时段内
check_disabled_time() {
    # 获取用户配置的禁用时段
    source "$CONFIG_FILE"
    
    # 提取禁用时段的小时部分（24小时制）
    DISABLED_START_HOUR=$(echo $DISABLED_TIME | cut -d'-' -f1 | cut -d':' -f1)
    DISABLED_END_HOUR=$(echo $DISABLED_TIME | cut -d'-' -f2 | cut -d':' -f1)

    # 确保时间格式正确（24小时制）
    if [[ ! "$DISABLED_START_HOUR" =~ ^[0-9]+$ ]] || [[ ! "$DISABLED_END_HOUR" =~ ^[0-9]+$ ]]; then
        echo "时间格式错误：禁用时段必须为 HH:MM-HH:MM 格式（24小时制）"
        exit 1
    fi

    # 获取当前小时（北京时间）
    CURRENT_HOUR=$(TZ='Asia/Shanghai' date +'%H')

    # 如果当前小时在禁用时段内，则返回 1（表示不执行）
    if (( CURRENT_HOUR >= DISABLED_START_HOUR && CURRENT_HOUR < DISABLED_END_HOUR )); then
        echo "当前时间在禁用时段内（$DISABLED_TIME），不执行更新。"
        return 1
    fi

    # 如果不在禁用时段内，则返回 0（表示可以执行）
    return 0
}

# 更新 DNS 记录
update_dns_record() {
    CURRENT_IP=$(curl -s 'https://ip.164746.xyz/ipTop.html' | cut -d',' -f1)
    CURRENT_TIME=$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S")

    # 获取 IP 信息（通过 IP-API 获取地理位置信息）
    IP_INFO=$(curl -s "http://ip-api.com/json/$CURRENT_IP?lang=zh-CN")
    COUNTRY=$(echo "$IP_INFO" | jq -r '.country')
    CITY=$(echo "$IP_INFO" | jq -r '.city')
    ISP=$(echo "$IP_INFO" | jq -r '.isp')

    # 更新 Cloudflare 记录
    RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DOMAIN_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")

    if echo "$RESPONSE" | grep -q '"success":true'; then
        # 无论 IP 是否变化，都更新记录并发送通知
        echo "$CURRENT_IP" > "$LAST_IP_FILE"

        # 发送 Telegram 消息通知
        MSG="
✨ *Cloudflare DNS 自动更新通知*

📌 *域名：*
\`$DOMAIN_NAME\`

🆕 *新 IP：*
\`$CURRENT_IP\`

🌏 *IP 信息：*
• *国家地区：* $COUNTRY  
• *城市：* $CITY  
• *运营商：* $ISP  

⏰ *更新时间：*
\`$CURRENT_TIME\`

🔍 *IP 查询：*
• [ip.sb](https://ip.sb/ip/$CURRENT_IP)
• [ip-api](http://ip-api.com/json/$CURRENT_IP)

———————————————
🎉 *更新成功！DNS 已同步完成。*
"

        # 发送 Telegram 消息
        curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TG_CHAT_ID&parse_mode=Markdown&text=$MSG"

        echo "[] 已更新 → $CURRENT_IP ($COUNTRY / $ISP)" >> "$LOG_FILE"
    else
        echo "[] Cloudflare 更新失败" >> "$LOG_FILE"
    fi
}

# 安装脚本
install_script() {
    echo "正在安装更新脚本..."

    # 手动输入配置信息
    read -p "请输入 Cloudflare 区域 ID (ZONE_ID): " ZONE_ID
    read -p "请输入 Cloudflare API Token (CF_API_TOKEN): " CF_API_TOKEN
    read -p "请输入域名 (DOMAIN_NAME): " DOMAIN_NAME
    read -p "请输入 Telegram 机器人 Token (TG_BOT_TOKEN): " TG_BOT_TOKEN
    read -p "请输入 Telegram 聊天 ID (TG_CHAT_ID): " TG_CHAT_ID
    read -p "请输入禁用时段（格式为 HH:MM-HH:MM, 例如 00:00-06:00）： " DISABLED_TIME

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
    echo "DISABLED_TIME='$DISABLED_TIME'" >> "$CONFIG_FILE"

    # 将更新脚本复制到指定目录
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    # 创建定时任务更新脚本
    echo "#!/bin/bash" > "$CRON_SCRIPT_PATH"
    echo "LOG_FILE='/var/log/cf_ddds.log'" >> "$CRON_SCRIPT_PATH"
    echo "SCRIPT_PATH='/usr/local/bin/cf_ddds_update.sh'" >> "$CRON_SCRIPT_PATH"
    echo "echo '==== 定时任务执行开始: \$(date) ====' >> '\$LOG_FILE'" >> "$CRON_SCRIPT_PATH"
    echo "'\$SCRIPT_PATH' >> '\$LOG_FILE' 2>&1" >> "$CRON_SCRIPT_PATH"
    echo "echo '==== 定时任务执行结束: \$(date) ====' >> '\$LOG_FILE'" >> "$CRON_SCRIPT_PATH"

    # 赋予执行权限
    chmod +x "$SCRIPT_PATH"
    chmod +x "$CRON_SCRIPT_PATH"

    # 自动添加到 crontab
    (crontab -l ; echo "0 * * * * $CRON_SCRIPT_PATH") | crontab -

    echo "更新脚本已安装到 $SCRIPT_PATH"
    echo "定时任务更新脚本已创建并自动添加到 crontab 中，每小时执行一次。"
}

# 卸载脚本
uninstall_script() {
    echo "正在卸载更新脚本..."

    # 删除相关文件
    rm -f "$CONFIG_FILE"
    rm -f "$SCRIPT_PATH"
    rm -f "$CRON_SCRIPT_PATH"

    # 删除定时任务
    crontab -l | grep -v "$CRON_SCRIPT_PATH" | crontab -

    echo "更新脚本和定时任务已卸载。"
}

# 显示菜单
echo "请选择操作："
echo "1. 安装更新脚本"
echo "2. 卸载更新脚本"
echo "3. 手动执行更新"

read -p "请输入选项 (1/2/3): " OPTION

case "$OPTION" in
    1)
        install_jq
        install_script
        ;;
    2)
        uninstall_script
        ;;
    3)
        check_disabled_time && update_dns_record
        ;;
    *)
        echo "无效选项，请重新选择。"
        exit 1
        ;;
esac
