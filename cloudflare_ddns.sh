#!/bin/bash

CONFIG_FILE="/etc/cf_ddds.conf"
SCRIPT_FILE="/usr/local/bin/cf_ddds_run.sh"
IP_FILE="/var/lib/cf_last_ip.txt"
LOG_FILE="/var/log/cf_ddds.log"

# ================== 系统依赖检查 ==================
install_dependencies(){
    echo "🔧 检查依赖 curl 和 jq..."
    for cmd in curl jq; do
        if ! command -v $cmd >/dev/null 2>&1; then
            echo "$cmd 未安装，尝试安装..."
            if [[ -f /etc/debian_version ]]; then
                sudo apt-get update && sudo apt-get install -y $cmd
            elif [[ -f /etc/redhat-release ]]; then
                sudo yum install -y $cmd
            elif [[ -f /etc/alpine-release ]]; then
                sudo apk add --no-cache $cmd
            else
                echo "请手动安装 $cmd"
                exit 1
            fi
        fi
    done
}

# ================== 菜单 ==================
menu(){
    clear
    echo "======== Cloudflare DDNS 自动更新 ========"
    echo "1) 安装/配置"
    echo "2) 升级脚本（保留配置）"
    echo "3) 卸载"
    echo "4) 手动运行一次"
    echo "5) 查看日志"
    echo "6) 强制更新一次"
    echo "0) 退出"
    echo "----------------------------------------"
    read -p "请输入选择: " num

    case $num in
        1) install ;;
        2) upgrade ;;
        3) uninstall ;;
        4) bash $SCRIPT_FILE ;;
        5) tail -n 50 $LOG_FILE ;;
        6) bash $SCRIPT_FILE force ;;
        0) exit ;;
        *) echo "❌ 输入无效" && sleep 1 && menu ;;
    esac
}

# ================== 安装流程 ==================
install(){
    install_dependencies

    [[ ! -d "/var/lib" ]] && mkdir -p /var/lib
    [[ ! -d "/var/log" ]] && mkdir -p /var/log

    [[ ! -f "$CONFIG_FILE" ]] && touch $CONFIG_FILE
    [[ ! -f "$IP_FILE" ]] && touch $IP_FILE
    [[ ! -f "$LOG_FILE" ]] && touch $LOG_FILE

    echo "🔑 输入 Cloudflare API Token:"
    read CF_API_TOKEN
    echo "🌍 输入 Zone ID:"
    read ZONE_ID
    echo "🔤 请输入解析域名 (如: ddns.example.com):"
    read DOMAIN_NAME

    # 自动获取 DNS Record ID
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
    if [[ $TG_CHOICE == y ]]; then
        read -p "Bot Token: " TG_BOT_TOKEN
        read -p "Chat ID: " TG_CHAT_ID
    else
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi

    # 保存配置
    cat > $CONFIG_FILE <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
ZONE_ID="$ZONE_ID"
DNS_RECORD_ID="$DNS_RECORD_ID"
DOMAIN_NAME="$DOMAIN_NAME"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF

    create_run_script
    add_cron

    echo "✨ 安装完成 → DDNS 已启动！"
}

# ================== 升级流程 ==================
upgrade(){
    install_dependencies

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "❌ 配置文件不存在，请先安装"
        exit 1
    fi

    echo "🔄 升级中... 仅更新主运行脚本，保留配置文件"
    create_run_script
    add_cron
    echo "✅ 升级完成"
}

# ================== 创建主运行脚本 ==================
create_run_script(){
cat > $SCRIPT_FILE <<'EOF'
#!/bin/bash
source /etc/cf_ddds.conf

FORCE_UPDATE=$1

CURRENT_IP=$(curl -s 'https://ip.164746.xyz/ipTop.html' | cut -d',' -f1)
CURRENT_TIME=$(TZ="Asia/Shanghai" date "+%Y-%m-%d %H:%M:%S")

IP_INFO=$(curl -s "http://ip-api.com/json/$CURRENT_IP?lang=zh-CN")
COUNTRY=$(echo "$IP_INFO" | jq -r '.country')
REGION=$(echo "$IP_INFO" | jq -r '.regionName')
CITY=$(echo "$IP_INFO" | jq -r '.city')
ZIP=$(echo "$IP_INFO" | jq -r '.zip')
LAT=$(echo "$IP_INFO" | jq -r '.lat')
LON=$(echo "$IP_INFO" | jq -r '.lon')
TIMEZONE=$(echo "$IP_INFO" | jq -r '.timezone')
ISP=$(echo "$IP_INFO" | jq -r '.isp')
ORG=$(echo "$IP_INFO" | jq -r '.org')
ASN=$(echo "$IP_INFO" | jq -r '.as')

IP_FILE="/var/lib/cf_last_ip.txt"
LOG_FILE="/var/log/cf_ddds.log"

[[ ! -f "$IP_FILE" ]] && echo "$CURRENT_IP" > $IP_FILE
[[ ! -f "$LOG_FILE" ]] && touch $LOG_FILE

LAST_IP=$(cat $IP_FILE)

if [[ "$CURRENT_IP" != "$LAST_IP" || "$FORCE_UPDATE" == "force" ]]; then

    # ==== Cloudflare 更新 ====
    {
        RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$DOMAIN_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")
        
        if echo "$RESPONSE" | grep -q '"success":true'; then
            echo "$CURRENT_IP" > $IP_FILE
            echo "[$CURRENT_TIME] Cloudflare DNS 更新成功 → $CURRENT_IP" >> $LOG_FILE
        else
            echo "[$CURRENT_TIME] Cloudflare DNS 更新失败" >> $LOG_FILE
        fi
    }

    # ==== Telegram 消息（HTML 模式，夜间静默 0-6 点） ====
    {
        HOUR=$(TZ="Asia/Shanghai" date +%H)
        SEND_TG=true
        if (( HOUR >=0 && HOUR < 6 )); then
            SEND_TG=false
        fi

        if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" && "$SEND_TG" == true ]]; then

MSG="<b>✨ Cloudflare DNS 自动更新通知 ✨</b>

<b>📌 域名:</b> <code>$DOMAIN_NAME</code>
<b>🆕 新 IP:</b> <code>$CURRENT_IP</code>

<b>🌏 IP 信息:</b>
• 国家地区: $COUNTRY
• 省/州: $REGION
• 城市: $CITY
• 邮编: $ZIP
• 时区: $TIMEZONE
• 经纬度: $LAT, $LON
• ISP: $ISP
• 组织: $ORG
• ASN: $ASN

<b>⏰ 更新时间:</b> <code>$CURRENT_TIME</code>

<b>🔍 IP 查询:</b>
• <a href='https://ip.sb/ip/$CURRENT_IP'>IP.sb</a>
• <a href='http://ip-api.com/json/$CURRENT_IP'>ip-api.com</a>
"

            curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
                -d "chat_id=$TG_CHAT_ID" \
                --data-urlencode "text=$MSG" \
                -d "parse_mode=HTML"
        fi
    }

else
    echo "[$CURRENT_TIME] IP 未变化 → $CURRENT_IP" >> $LOG_FILE
fi
EOF

chmod +x $SCRIPT_FILE
}

# ================== 添加定时任务 ==================
add_cron(){
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_FILE"; then
            echo "⏰ 定时任务已存在，无需重复添加！"
        else
            (crontab -l 2>/dev/null; echo "0 * * * * $SCRIPT_FILE") | crontab -
            echo "⏰ 已创建定时任务（每小时执行一次）"
        fi
    else
        echo "⚠️ crontab 未找到，请手动设置定时任务"
    fi
}

# ================== 卸载 ==================
uninstall(){
    rm -f $SCRIPT_FILE $IP_FILE $LOG_FILE
    if command -v crontab >/dev/null 2>&1; then
        crontab -l | grep -v "cf_ddds_run.sh" | crontab -
    fi
    echo "🗑️ 已卸载并清理所有生成文件和定时任务，配置文件已保留。"
}

menu
