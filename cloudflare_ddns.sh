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
echo "0) 退出"
echo "----------------------------------------"
read -p "请输入选择: " num

case $num in
1) install ;;
2) uninstall ;;
3) bash $SCRIPT_FILE ;;
4) tail -n 50 $LOG_FILE ;;
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

# 获取 DNS Record ID
DNS_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN_NAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | \
  jq -r '.result[0].id')

if [ -z "$DNS_RECORD_ID" ]; then
    echo "❌ 未找到匹配的 DNS 记录，请确保域名正确。"
    exit 1
fi

echo "🆔 找到 DNS Record ID: $DNS_RECORD_ID"

echo "📨 是否启用 Telegram 通知? (y/n)"
read TG_CHOICE
if [[ $TG_CHOICE == y ]]; then
    read -p "Bot Token: " TG_BOT_TOKEN
    read -p "Chat ID: " TG_CHAT_ID
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
cat > $SCRIPT_FILE <<EOF
#!/bin/bash
source $CONFIG_FILE

CURRENT_IP=\$(curl -s 'https://ip.164746.xyz/ipTop.html' | cut -d',' -f1)
CURRENT_TIME=\$(date "+%Y-%m-%d %H:%M:%S")
IP_INFO=\$(curl -s "http://ip-api.com/json/\$CURRENT_IP?lang=zh-CN")
COUNTRY=\$(echo "\$IP_INFO" | grep -oP '(?<="country":").*?(?=")')
ISP=\$(echo "\$IP_INFO" | grep -oP '(?<="isp":").*?(?=")')

# 如果文件不存在则保存当前 IP
[[ ! -f "/var/lib/cf_last_ip.txt" ]] && echo "\$CURRENT_IP" > /var/lib/cf_last_ip.txt
LAST_IP=\$(cat /var/lib/cf_last_ip.txt)

# 如果 IP 发生变化，则更新 Cloudflare 记录
if [[ "\$CURRENT_IP" != "\$LAST_IP" ]]; then
    RESPONSE=\$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/\$ZONE_ID/dns_records/\$DNS_RECORD_ID" \
        -H "Authorization: Bearer \$CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DOMAIN_NAME\",\"content\":\"\$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")

    if echo "\$RESPONSE" | grep -q '"success":true'; then
        
        echo "\$CURRENT_IP" > /var/lib/cf_last_ip.txt

        ### ============== Telegram 通知（精美版） ==============
        if [[ -n "\$TG_BOT_TOKEN" && -n "\$TG_CHAT_ID" ]]; then
            
MSG="
✨ *Cloudflare DNS 自动更新通知*

📌 *域名：*
\`$DOMAIN_NAME\`

🆕 *新 IP：*
\`$CURRENT_IP\`

🌏 *IP 信息：*
• *国家地区：* \$COUNTRY  
• *运营商：* \$ISP  

⏰ *更新时间：*
\`$CURRENT_TIME\`

🔍 *IP 查询：*
• https://ip.sb/ip/$CURRENT_IP
• http://ip-api.com/json/$CURRENT_IP

———————————————
🎉 *更新成功！DNS 已同步完成。*
"
            curl -s -X POST "https://api.telegram.org/bot\$TG_BOT_TOKEN/sendMessage" \
                -d "chat_id=\$TG_CHAT_ID&parse_mode=Markdown&text=\$MSG"
        fi

        echo "[$CURRENT_TIME] 已更新 → \$CURRENT_IP (\$COUNTRY / \$ISP)" >> $LOG_FILE
    else
        echo "[$CURRENT_TIME] Cloudflare 更新失败" >> $LOG_FILE
    fi
else
    echo "[$CURRENT_TIME] IP 未变化 → \$CURRENT_IP" >> $LOG_FILE
fi
EOF

chmod +x $SCRIPT_FILE

### ========================== 不重复添加定时任务 ==========================
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
