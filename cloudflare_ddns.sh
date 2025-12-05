#!/bin/bash

SCRIPT_VERSION="v1.2.0"  # 最终整合版

CONFIG_FILE="/etc/cf_ddds.conf"
SCRIPT_FILE="/usr/local/bin/cf_ddds_run.sh"
IP_FILE="/var/lib/cf_last_ip.txt"
LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/cf_ddds.log"
MAX_RETRIES=3

# ================== 系统依赖检查 ==================
install_dependencies(){
    echo "🔧 检查依赖 curl 和 jq..."
    for cmd in curl jq; do
        if ! command -v $cmd >/dev/null 2>&1; then
            echo "$cmd 未安装，尝试安装..."
            if [[ -f /etc/debian_version ]]; then
                apt-get update && apt-get install -y $cmd
            elif [[ -f /etc/redhat-release ]]; then
                yum install -y $cmd
            elif [[ -f /etc/alpine-release ]]; then
                apk add --no-cache $cmd
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
    echo "脚本版本: $SCRIPT_VERSION"
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

    mkdir -p /var/lib
    mkdir -p $LOG_DIR

    [[ ! -f "$CONFIG_FILE" ]] && touch $CONFIG_FILE
    [[ ! -f "$IP_FILE" ]] && touch $IP_FILE
    [[ ! -f "$LOG_FILE" ]] && touch $LOG_FILE

    chmod 600 $CONFIG_FILE

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

cat > $CONFIG_FILE <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
ZONE_ID="$ZONE_ID"
DNS_RECORD_ID="$DNS_RECORD_ID"
DOMAIN_NAME="$DOMAIN_NAME"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF

    chmod 600 $CONFIG_FILE

    create_run_script
    add_cron
    setup_logrotate

    echo "✨ 安装完成 → DDNS 已启动！"
}

# ================== 升级流程 ==================
upgrade(){
    install_dependencies
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "❌ 配置文件不存在，请先安装"
        exit 1
    fi
    echo "🔄 升级中..."
    create_run_script
    add_cron
    echo "✅ 升级完成"
}

# ================== 创建主运行脚本 ==================
create_run_script(){
cat > $SCRIPT_FILE <<'EOF'
#!/bin/bash
SCRIPT_VERSION="v1.2.0"
source /etc/cf_ddds.conf

MAX_RETRIES=3
IP_FILE="/var/lib/cf_last_ip.txt"
LOG_FILE="/var/log/cf_ddds.log"

log(){
    echo "[$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

log "运行 Cloudflare DDNS 脚本 $SCRIPT_VERSION"

# ================== 获取当前 IP ==================
for ((i=1;i<=MAX_RETRIES;i++)); do
    CURRENT_IP=$(curl -s --max-time 10 'https://ip.164746.xyz/ipTop.html' | cut -d',' -f1)
    [[ -n "$CURRENT_IP" ]] && break
    sleep 2
done

if [[ -z "$CURRENT_IP" ]]; then
    log "获取公网 IP 失败"
    exit 1
fi

CURRENT_TIME=$(TZ="Asia/Shanghai" date "+%Y-%m-%d %H:%M:%S")
LAST_IP=$(cat $IP_FILE 2>/dev/null || echo "")

# ================== 检查 IP 是否变化 ==================
if [[ "$CURRENT_IP" == "$LAST_IP" && "$1" != "force" ]]; then
    log "IP 未变化 → $CURRENT_IP"
    exit 0
fi

# ================== 获取 IP 详细信息 ==================
for ((i=1;i<=MAX_RETRIES;i++)); do
    IP_INFO=$(curl -s --max-time 10 "http://ip-api.com/json/$CURRENT_IP?lang=zh-CCN")
    STATUS=$(echo "$IP_INFO" | jq -r '.status')
    [[ "$STATUS" == "success" ]] && break
    sleep 2
done

if [[ "$STATUS" != "success" ]]; then
    log "IP 信息获取失败"
    exit 1
fi

COUNTRY=$(echo "$IP_INFO" | jq -r '.country')
CITY=$(echo "$IP_INFO" | jq -r '.city')
TIMEZONE=$(echo "$IP_INFO" | jq -r '.timezone')
ISP=$(echo "$IP_INFO" | jq -r '.isp')

# ================== 更新 Cloudflare DNS ==================
UPDATE_RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$DOMAIN_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":120,\"proxied\":false}")

SUCCESS=$(echo "$UPDATE_RESULT" | jq -r '.success')

if [[ "$SUCCESS" == "true" ]]; then
    echo "$CURRENT_IP" > $IP_FILE
    log "DNS 更新成功 → $DOMAIN_NAME = $CURRENT_IP"
else
    log "DNS 更新失败：$UPDATE_RESULT"
fi

# ================== Telegram 通知（成功/失败区分） ==================
HOUR=$(TZ='Asia/Shanghai' date +%H)

send_tg_msg(){
    local MSG="$1"
    for ((i=1;i<=MAX_RETRIES;i++)); do
        curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TG_CHAT_ID" \
            --data-urlencode "text=$MSG" \
            -d "parse_mode=HTML" >/dev/null 2>&1 && return 0
        sleep 2
    done
}

# ======= 成功通知：遵守夜间静默 =======
if [[ "$SUCCESS" == "true" ]]; then

    if (( HOUR >= 0 && HOUR < 6 )); then
        log "夜间静默：成功通知未发送"
        exit 0
    fi

    MSG="
<b>✨ <u>Cloudflare DNS 更新成功</u></b>

<b>🔤 域名：</b> <code>$DOMAIN_NAME</code>
<b>🌟 新 IP：</b> <code>$CURRENT_IP</code>

<b>🌏 IP 信息：</b>
• 国家：$COUNTRY
• 城市：$CITY
• 时区：$TIMEZONE
• ISP：$ISP

<b>⏰ 时间：</b> <code>$CURRENT_TIME</code>

<i>🎉 DNS 记录已成功更新！</i>
"
    send_tg_msg "$MSG"
    exit 0
fi

# ======= 失败通知：必须发送 =======
ERROR_MSG=$(echo "$UPDATE_RESULT" | jq -r '.errors | tostring')

MSG="
<b>❌ <u>Cloudflare DNS 更新失败</u></b>

<b>🔤 域名：</b> <code>$DOMAIN_NAME</code>

<b>🚫 错误原因：</b>
<code>$ERROR_MSG</code>

<b>⏰ 时间：</b> <code>$CURRENT_TIME</code>

<i>⚠ 请检查 API Token、Zone ID、DNS 记录是否正确。</i>
"

send_tg_msg "$MSG"

EOF

chmod +x $SCRIPT_FILE
}

# ================== 添加定时任务 ==================
add_cron(){
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_FILE"; then
            echo "⏰ 定时任务已存在"
        else
            (crontab -l 2>/dev/null; echo "*/10 * * * * $SCRIPT_FILE > /dev/null 2>&1") | crontab -
            echo "⏰ 已创建定时任务：每 10 分钟执行一次"
        fi
    else
        echo "⚠️ 未找到 crontab，请手动设置"
    fi
}

# ================== 日志轮换 ==================
setup_logrotate(){
    cat >/etc/logrotate.d/cf_ddds <<EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
}

# ================== 卸载 ==================
uninstall(){
    rm -f $SCRIPT_FILE $IP_FILE $LOG_FILE /etc/logrotate.d/cf_ddds
    if command -v crontab >/dev/null 2>&1; then
        crontab -l | grep -v "cf_ddds_run.sh" | crontab -
    fi
    echo "🗑️ 已卸载（配置文件保留）"
}

menu
