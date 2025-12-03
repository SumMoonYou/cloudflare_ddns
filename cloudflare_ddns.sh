#!/bin/bash

CONFIG_FILE="/etc/cf_ddds.conf"
SCRIPT_FILE="/usr/local/bin/cf_ddds_run.sh"
IP_FILE="/var/lib/cf_last_ip.txt"
LOG_FILE="/var/log/cf_ddds.log"

### ========================== 菜单 ==========================
menu(){
    clear
    echo "======== Cloudflare DDNS 自动更新 ========"
    echo "1) 安装/配置"
    echo "2) 卸载"
    echo "3) 手动运行一次"
    echo "4) 查看日志"
    echo "5) 强制更新一次"
    echo "0) 退出"
    echo "----------------------------------------"
    read -p "请输入选择: " num

    case $num in
        1) install ;;
        2) uninstall ;;
        3) bash $SCRIPT_FILE ;;
        4) tail -n 50 $LOG_FILE ;;
        5) bash $SCRIPT_FILE force ;;
        0) exit ;;
        *) echo "❌ 输入无效" && sleep 1 && menu ;;
    esac
}

### ========================== 安装流程 ==========================
install(){
    echo "🔑 输入 Cloudflare API Token:"
    read CF_API_TOKEN
    echo "🌍 输入 Zone ID:"
    read ZONE_ID
    echo "🔤 请输入解析域名 (如: ddns.example.com):"
    read DOMAIN_NAME

    ### 自动获取 DNS Record ID
    DNS_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN_NAME" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [[ -z "$DNS_RECORD_ID" || "$DNS_RECORD_ID" == "null" ]]; then
        echo "❌ 未找到 $DOMAIN_NAME 的 A 记录，请先在 Cloudflare 添加该记录。"
        exit 1
    else
        echo "✅ 已自动获取 DNS Record ID: $DNS_RECORD_ID"
    fi

    echo "📨 是否启用 Telegram 通知? (y/n)"
    read TG_CHOICE
    if [[ $TG_CHOICE == y ]];then
        read -p "Bot Token: " TG_BOT_TOKEN
        read -p "Chat ID: " TG_CHAT_ID
    else
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi

    mkdir -p /var/lib

    ### 保存配置
    cat > $CONFIG_FILE <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
ZONE_ID="$ZONE_ID"
DNS_RECORD_ID="$DNS_RECORD_ID"
DOMAIN_NAME="$DOMAIN_NAME"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF

    ### ========================== 主运行脚本 ==========================
    cat > $SCRIPT_FILE <<'EOF'
#!/bin/bash
source /etc/cf_ddds.conf

FORCE_UPDATE=$1

CURRENT_IP=$(curl -s 'https://ip.164746.xyz/ipTop.html' | cut -d',' -f1)
CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
IP_INFO=$(curl -s "http://ip-api.com/json/$CURRENT_IP?lang=zh-CN")
COUNTRY=$(echo "$IP_INFO" | grep -oP '(?<="country":").*?(?=")')
ISP=$(echo "$IP_INFO" | grep -oP '(?<="isp":").*?(?=")')

IP_FILE="/var/lib/cf_last_ip.txt"
LOG_FILE="/var/log/cf_ddds.log"

# 如果文件不存在则保存当前 IP
[[ ! -f "$IP_FILE" ]] && echo "$CURRENT_IP" > $IP_FILE
LAST_IP=$(cat $IP_FILE)

# 判断是否需要更新
if [[ "$CURRENT_IP" != "$LAST_IP" || "$FORCE_UPDATE" == "force" ]]; then
    RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DOMAIN_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")

    if echo "$RESPONSE" | grep -q '"success":true'; then
        echo "$CURRENT_IP" > $IP_FILE

        # 判断是否在禁止通知时间段内 (北京时间 0-6 点)
        HOUR=$(TZ="Asia/Shanghai" date +%H)
        NO_NOTIFY_START=0
        NO_NOTIFY_END=6
        SEND_TG=true
        if (( HOUR >= NO_NOTIFY_START && HOUR < NO_NOTIFY_END )); then
            SEND_TG=false
        fi

        # Telegram 通知
        if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" && "$SEND_TG" == true ]]; then
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
• https://ip.sb/ip/$CURRENT_IP
• http://ip-api.com/json/$CURRENT_IP

———————————————
🎉 *更新成功！DNS 已同步完成。*
"
            curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
                -d "chat_id=$TG_CHAT_ID&parse_mode=Markdown&text=$MSG"
        fi

        if [[ "$FORCE_UPDATE" == "force" ]]; then
            echo "[$CURRENT_TIME] 强制更新 → $CURRENT_IP ($COUNTRY / $ISP)" >> $LOG_FILE
        else
            echo "[$CURRENT_TIME] 已更新 → $CURRENT_IP ($COUNTRY / $ISP)" >> $LOG_FILE
        fi
    else
        echo "[$CURRENT_TIME] Cloudflare 更新失败" >> $LOG_FILE
    fi
else
    echo "[$CURRENT_TIME] IP 未变化 → $CURRENT_IP" >> $LOG_FILE
fi
EOF

    chmod +x $SCRIPT_FILE

    ### ========================== 定时任务 ==========================
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_FILE"; then
        echo "⏰ 定时任务已存在，无需重复添加！"
    else
        (crontab -l 2>/dev/null; echo "0 * * * * $SCRIPT_FILE") | crontab -
        echo "⏰ 已创建定时任务（每小时执行一次）"
    fi

    echo "✨ 安装完成 → DDNS 已启动！"
}

### ========================== 卸载 ==========================
uninstall(){
    rm -f $CONFIG_FILE $SCRIPT_FILE $IP_FILE
    crontab -l | grep -v "cf_ddds_run.sh" | crontab -
    echo "🗑️ 已卸载并清理所有配置。"
}

menu
